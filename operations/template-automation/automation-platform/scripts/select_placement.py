#!/usr/bin/env python3
"""
Interactive placement/build-options picker, run by build.sh at the start of
every build. Connects to vCenter and walks through, in order: cluster,
ESXi host (optional), datastore, network/portgroup, VM folder (with a free-
text "Other" option), collect-install-logs, publish-to-pool-or-farm (a type
choice - Farm / Desktop Pool / skip - each enumerated live against Horizon
with its own free-text "Other" fallback), and delete-the-build-VM-after-
clone. Writes two files:

  --placement-output : YAML, loaded by build.sh as the last (highest-
                        precedence) -e override into the existing Ansible
                        group_vars pipeline - same mechanism as
                        *_adv-vm-settings.yml. Holds the vCenter placement
                        keys only (vcenter_cluster/host/datastore/network/
                        folder).

  --control-output    : plain `KEY=value` bash assignments, sourced
                         directly by build.sh for the answers that drive
                         its OWN control flow (not Ansible/Packer vars):
                         COLLECT_BUILD_LOGS, PUBLISH_TO_POOL,
                         HORIZON_TARGET_TYPE, HORIZON_TARGET_NAME,
                         DELETE_VM_AFTER.

The Horizon step (step 7/8, pick_horizon_target()) asks Farm vs Desktop
Pool vs "No - skip" FIRST, as an explicit choice - it does NOT derive the
type from this image's horizon_pool_name/horizon_farm_name group_vars the
way publish_to_pool.sh's own standalone fallback still does. Those two
group_vars keys are only used here as a "(configured default: ...)" hint
printed alongside whichever type you picked, nothing more - CHANGED from
an earlier version that filtered to (and enforced) exactly one of the two,
which meant you'd only ever see the type group_vars happened to have set,
even when other pools/farms existed and you wanted to publish somewhere
else for a one-off run. After the type choice, it logs into the SAME
Connection Server publish_to_pool.sh uses, with the SAME credentials
(horizon_connection_server/horizon_api_username/horizon_api_domain/
vault_horizon_api_password), read directly from this image's own group_vars
files (base + _agents + _osot + _adv-vm-settings + .local, layered in the
same order build.sh's GROUP_VARS_ARGS uses) rather than via a full
ansible-playbook run - resolve_vars.yml hasn't run yet at this point in
build.sh, this picker runs before it. Endpoints (GET
/rest/inventory/v1/desktop-pools, GET /rest/inventory/v2/farms) are taken
directly from publish_to_pool.sh's own, already-working implementation -
see that script's "Pool vs farm" header comment for the full story,
including that the farms endpoint specifically has NOT been run for real
yet against this environment's Connection Server. If the login/enumerate
call itself fails (bad creds, network, Horizon down) or comes back empty,
this falls back to letting you type the name directly instead of aborting
the whole build - same "Other (Provide)" escape hatch as the enumerated
list itself, just reached a different way.

Credentials and vcenter_server/vcenter_datacenter are resolved the same way
every other part of this platform gets them: plaintext from
inventory/group_vars/all.yml, secrets decrypted from
inventory/group_vars/all/vault.yml via the standing ~/.vault_pass file.

Usage (called from build.sh - after the ansible-venv is activated, since
this needs pyyaml/pyvmomi/requests from that venv):
  python3 scripts/select_placement.py \
      --project-root "$PROJECT_ROOT" \
      --image-key "$IMAGE_KEY" \
      --placement-output "$PLACEMENT_OVERRIDE_FILE" \
      --control-output "$PLACEMENT_CONTROL_FILE"

---- Saved configs / --load (ADDED 2026-09-28) ----
At the very end of the interactive walk-through above (right after "Proceed
with these values?"), you're now also asked whether to save the answers
under a name, e.g. "nightly-rdsh". Saying yes writes the SAME two outputs
you'd otherwise only get as build.sh's throwaway temp files to a permanent
pair under <project-root>/configs/: <image_key>__<name>.overrides.yml
and <image_key>__<name>.control.sh - nothing about their format changes,
they're just kept around instead of shredded at exit. Called a "config"
rather than a "placement" because it's really the whole bundle - vCenter
placement AND the collect-logs/publish/delete-after answers - not just
where the VM lands.

  python3 scripts/select_placement.py \
      --project-root "$PROJECT_ROOT" \
      --image-key "$IMAGE_KEY" \
      --placement-output "$PLACEMENT_OVERRIDE_FILE" \
      --control-output "$PLACEMENT_CONTROL_FILE" \
      --load nightly-rdsh

--load skips EVERY prompt above, and - just as importantly for a cron/
systemd context - never touches vCenter or Horizon at all: it just reads
the saved pair back and copies them onto --placement-output/--control-
output, exactly as if you'd answered the same way interactively. That
makes it safe to run genuinely unattended: no terminal needed, and no
build-time dependency on vCenter/Horizon being reachable at THIS step
(the actual build further down in build.sh still needs vCenter, same as
always). See build.sh's own "Unattended / scheduled builds" comment for
how --config NAME there maps to this flag.

Nothing about PUBLISH_TO_POOL is special-cased for --load - whatever was
true when the config was saved (including "No - skip" publish) is what
plays back. If you want a saved config that only ever builds and
snapshots without ever pushing to a live pool/farm, answer "No - skip
clone/snapshot/publish" at save time and it stays that way on every
unattended rerun.
"""
import argparse
import re
import ssl
import subprocess
import sys
from datetime import datetime
from pathlib import Path

import requests
import urllib3
import yaml
from pyVim.connect import SmartConnect, Disconnect
from pyVmomi import vim

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

OTHER_SENTINEL = object()

# Saved-config names become part of a filename (see config_paths() below)
# - restricted to this set so a typo or stray character can't put a path
# separator, or anything else surprising, into a path under configs/. A
# dot is allowed (on top of letters/numbers/-/_) so a name can look like
# "rdsh_2025.cfg" if you want it to - it's just a label, nothing parses it
# as a real file extension.
CONFIG_NAME_RE = re.compile(r"^[A-Za-z0-9_.-]+$")


def load_vault(project_root: Path):
    vault_path = project_root / "inventory/group_vars/all/vault.yml"
    vault_pass_file = Path.home() / ".vault_pass"
    decrypted = subprocess.run(
        ["ansible-vault", "view", str(vault_path),
         "--vault-password-file", str(vault_pass_file)],
        check=True, capture_output=True, text=True,
    ).stdout
    return yaml.safe_load(decrypted)


def resolve_jinja(value, vault):
    # Committed group_vars files reference vault secrets as
    # "{{ vault_some_name }}" - resolve that one specific pattern (not a
    # full Jinja engine) against the already-decrypted vault dict. Anything
    # else (a plain string, number, bool, list, dict) passes through as-is.
    if isinstance(value, str) and value.startswith("{{") and value.endswith("}}"):
        return vault.get(value.strip("{} ").strip(), "")
    return value


def load_vcenter_context(project_root: Path, vault):
    all_yml = yaml.safe_load((project_root / "inventory/group_vars/all.yml").read_text())
    return {
        "host": all_yml["vcenter_server"],
        "user": resolve_jinja(all_yml["vcenter_username"], vault),
        "password": resolve_jinja(all_yml["vcenter_password"], vault),
        "datacenter": all_yml["vcenter_datacenter"],
    }


def load_group_vars(project_root: Path, image_key: str, vault):
    """
    Layers this image's group_vars files in the same order build.sh's
    GROUP_VARS_ARGS does (base -> _agents -> _osot -> _adv-vm-settings ->
    .local), each later file's keys overriding earlier ones - mirroring
    Ansible's later-`-e`-wins semantics without needing a real
    ansible-playbook run (resolve_vars.yml hasn't executed yet when this
    picker runs).
    """
    merged = {}
    for suffix in ("", "_agents", "_osot", "_adv-vm-settings"):
        path = project_root / "inventory/group_vars" / f"{image_key}{suffix}.yml"
        if path.exists():
            merged.update(yaml.safe_load(path.read_text()) or {})
    local_path = project_root / "inventory/group_vars" / f"{image_key}.local.yml"
    if local_path.exists():
        merged.update(yaml.safe_load(local_path.read_text()) or {})
    return {k: resolve_jinja(v, vault) for k, v in merged.items()}


def find_datacenter(content, name):
    container = content.viewManager.CreateContainerView(content.rootFolder, [vim.Datacenter], True)
    try:
        for dc in container.view:
            if dc.name == name:
                return dc
    finally:
        container.Destroy()
    return None


def list_of_type(content, root, vimtype):
    container = content.viewManager.CreateContainerView(root, [vimtype], True)
    try:
        return list(container.view)
    finally:
        container.Destroy()


def list_folders(dc):
    """Flatten the VM folder tree under this datacenter into 'path/like/this' strings."""
    results = []

    def walk(folder, prefix):
        for child in folder.childEntity:
            if isinstance(child, vim.Folder):
                path = f"{prefix}/{child.name}" if prefix else child.name
                results.append((path, child))
                walk(child, path)

    walk(dc.vmFolder, "")
    return results


def prompt_choice(label, items, name_fn, allow_none_label=None, allow_other_label=None):
    """
    Numbered picker. 0 (if allow_none_label) = None. A trailing entry (if
    allow_other_label) returns the OTHER_SENTINEL object, letting the
    caller fall through to a free-text prompt - used for VM folder's
    "Other (Provide)" option.
    """
    print(f"\n{label}:")
    if allow_none_label:
        print(f"  0) {allow_none_label}")
    for i, item in enumerate(items, start=1):
        print(f"  {i}) {name_fn(item)}")
    other_idx = len(items) + 1
    if allow_other_label:
        print(f"  {other_idx}) {allow_other_label}")
    lo = 0 if allow_none_label else 1
    hi = other_idx if allow_other_label else len(items)
    while True:
        raw = input(f"Select [{lo}-{hi}]: ").strip()
        if not raw.isdigit():
            print("Enter a number.")
            continue
        idx = int(raw)
        if allow_none_label and idx == 0:
            return None
        if allow_other_label and idx == other_idx:
            return OTHER_SENTINEL
        if 1 <= idx <= len(items):
            return items[idx - 1]
        print("Out of range.")


def prompt_yes_no(label, default_yes=True):
    suffix = "[Y/n]" if default_yes else "[y/N]"
    raw = input(f"{label} {suffix}: ").strip().lower()
    return default_yes if not raw else raw.startswith("y")


def horizon_login(server, username, password, domain):
    resp = requests.post(
        f"https://{server}/rest/login",
        json={"username": username, "password": password, "domain": domain},
        verify=False, timeout=30,
    )
    resp.raise_for_status()
    token = resp.json().get("access_token")
    if not token:
        raise RuntimeError(f"Horizon login to {server} failed: {resp.text}")
    return token


def horizon_list(server, token, path):
    resp = requests.get(
        f"https://{server}{path}",
        headers={"Authorization": f"Bearer {token}"},
        verify=False, timeout=30,
    )
    resp.raise_for_status()
    return resp.json()


def _try_horizon_list(server, user, password, domain, list_path, type_label):
    """
    Best-effort login + list - returns the (possibly empty) list on success,
    or None if the login/request itself failed (bad creds, network, Horizon
    down). Callers treat None the same as an empty result: fall back to
    letting the person type the target name directly rather than aborting
    the whole build over a Horizon-side hiccup at this one step.
    """
    try:
        print(f"\n==> Logging in to {server}")
        token = horizon_login(server, user, password, domain)
        return horizon_list(server, token, list_path)
    except (requests.exceptions.RequestException, RuntimeError) as e:
        print(f"    Could not reach Horizon to list {type_label}s ({e}) - enter the name directly below.")
        return None


def _prompt_target_name(type_label):
    while True:
        name = input(f"{type_label} name: ").strip()
        if name:
            return name
        print(f"{type_label} name can't be empty.")


def pick_horizon_target(project_root: Path, image_key: str, vault):
    """
    Asks Farm vs Desktop Pool vs "No - skip" first (an explicit choice, not
    derived from this image's horizon_pool_name/horizon_farm_name group_vars
    - see this module's docstring for why), then enumerates that ONE type
    live against Horizon and lets you pick from it or type a name directly
    ("Other (Provide)", same pattern as the VM-folder step). Returns
    (do_publish, target_type, target_name) - do_publish is False (with the
    other two "") when "No - skip" was chosen; target_type is "farm" or
    "pool" otherwise.
    """
    type_choice = prompt_choice(
        "Publish to Desktop-pool / Farm?",
        ["Farm", "Desktop Pool"], lambda t: t,
        allow_none_label="No - skip clone/snapshot/publish",
    )
    if type_choice is None:
        return False, "", ""

    gv = load_group_vars(project_root, image_key, vault)
    if type_choice == "Farm":
        target_type = "farm"
        list_path = "/rest/inventory/v2/farms"
        configured_name = gv.get("horizon_farm_name") or ""
    else:
        target_type = "pool"
        list_path = "/rest/inventory/v1/desktop-pools"
        configured_name = gv.get("horizon_pool_name") or ""

    server = gv.get("horizon_connection_server", "")
    user = gv.get("horizon_api_username", "")
    domain = gv.get("horizon_api_domain", "")
    password = vault.get("vault_horizon_api_password", "")
    missing = [n for n, v in [
        ("horizon_connection_server", server), ("horizon_api_username", user),
        ("horizon_api_domain", domain), ("vault_horizon_api_password", password),
    ] if not v]

    targets = None
    if missing:
        print(f"    Missing {', '.join(missing)} - can't reach Horizon to list {target_type}s; enter the name directly.")
    else:
        targets = _try_horizon_list(server, user, password, domain, list_path, type_choice)

    label = f"Select {type_choice}"
    if configured_name:
        label += f" (configured default: {configured_name})"

    if targets:
        chosen = prompt_choice(
            label, targets, lambda t: t.get("name", "<unnamed>"),
            allow_other_label="Other (Provide)",
        )
        target_name = _prompt_target_name(type_choice) if chosen is OTHER_SENTINEL else chosen.get("name", "")
    else:
        if targets is not None:  # reached Horizon fine, it just has none of this type
            print(f"    Horizon returned no {target_type}s from {list_path} - enter the name directly.")
        target_name = _prompt_target_name(type_choice)

    return True, target_type, target_name


def config_paths(project_root: Path, image_key: str, name: str):
    """
    Where a saved config named `name` for `image_key` lives on disk.
    Namespaced by image_key (as "<image_key>__<name>") so the same short
    name - "nightly", say - can be reused across different images without
    one silently overwriting or getting loaded for the other.
    """
    if not CONFIG_NAME_RE.fullmatch(name):
        sys.exit(
            f"Invalid config name '{name}' - use only letters, numbers, "
            "'.', '-' and '_'."
        )
    base = project_root / "configs"
    return (
        base / f"{image_key}__{name}.overrides.yml",
        base / f"{image_key}__{name}.control.sh",
    )


def config_header(image_key: str, name: str, describes: str) -> str:
    """
    A short comment header written at the top of a saved config's on-disk
    files. Safe on both sides - '#' is a comment in YAML the same as it is
    in bash, so this doesn't affect either the -e @file Ansible load of
    the .overrides.yml or build.sh sourcing the .control.sh - and
    load_saved_config()'s own summary printout filters '#' lines back out
    when it echoes a loaded config's contents.
    """
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    return (
        f"# {describes} for saved config '{name}' (image '{image_key}')\n"
        f"# Saved: {now}\n"
        "#\n"
        "# Written by scripts/select_placement.py's interactive picker - not\n"
        "# meant to be hand-edited; re-save under this same name to update it.\n"
        "#\n"
        "# To rerun scripts/build.sh unattended with these settings:\n"
        f"#   scripts/build.sh {image_key} --config {name}\n"
        "#\n"
    )


def load_saved_config(project_root: Path, image_key: str, name: str,
                       placement_output: str, control_output: str):
    """
    --load path: read a previously saved config back and copy it onto
    --placement-output/--control-output, with no vCenter or Horizon call at
    all - see this module's docstring for why that matters for unattended/
    scheduled runs.
    """
    overrides_path, control_path = config_paths(project_root, image_key, name)
    if not overrides_path.exists() or not control_path.exists():
        sys.exit(
            f"No saved config named '{name}' for image '{image_key}' - expected\n"
            f"  {overrides_path}\n"
            f"  {control_path}\n"
            "Run the interactive picker once (scripts/build.sh "
            f"{image_key}) and save it under this name at the "
            "'Save these settings for unattended/scheduled reruns?' prompt first."
        )

    print(f"==> Loading saved config '{name}' for {image_key} "
          "(no vCenter/Horizon connection needed)")
    print(f"      {overrides_path}")
    print(f"      {control_path}")
    placement_overrides = yaml.safe_load(overrides_path.read_text()) or {}
    print("--- Loaded config ---")
    for k, v in placement_overrides.items():
        print(f"  {k}: {v}")
    for line in control_path.read_text().splitlines():
        if line.strip() and not line.lstrip().startswith("#"):
            print(f"  {line}")

    Path(placement_output).write_text(overrides_path.read_text())
    Path(control_output).write_text(control_path.read_text())


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--project-root", required=True)
    p.add_argument("--image-key", required=True,
                    help="Needed to resolve this image's own group_vars for the Horizon pool/farm step")
    p.add_argument("--placement-output", required=True,
                    help="Path to write the vCenter placement YAML override to")
    p.add_argument("--control-output", required=True,
                    help="Path to write build.sh's own KEY=value control flags to")
    p.add_argument("--load", default=None, metavar="NAME",
                    help="Skip every interactive prompt and vCenter/Horizon "
                         "call - load a previously saved config by name "
                         "instead (see 'Saved configs / --load' in this "
                         "file's own docstring, and build.sh's --config "
                         "flag).")
    args = p.parse_args()

    project_root = Path(args.project_root)

    if args.load:
        load_saved_config(
            project_root, args.image_key, args.load,
            args.placement_output, args.control_output,
        )
        return

    vault = load_vault(project_root)
    ctx = load_vcenter_context(project_root, vault)

    ssl_ctx = ssl.create_default_context()
    ssl_ctx.check_hostname = False
    ssl_ctx.verify_mode = ssl.CERT_NONE

    si = SmartConnect(host=ctx["host"], user=ctx["user"], pwd=ctx["password"], sslContext=ssl_ctx)
    try:
        content = si.RetrieveContent()
        dc = find_datacenter(content, ctx["datacenter"])
        if dc is None:
            sys.exit(f"Datacenter '{ctx['datacenter']}' not found")

        # ---- 1. Cluster ----
        clusters = sorted(
            list_of_type(content, dc.hostFolder, vim.ClusterComputeResource),
            key=lambda c: c.name,
        )
        if not clusters:
            sys.exit("No clusters found under this datacenter")
        cluster = prompt_choice("Select Cluster", clusters, lambda c: c.name)

        # ---- 2. ESXi host (optional) ----
        hosts = sorted(cluster.host, key=lambda h: h.name)
        host = prompt_choice(
            "Select ESXi-host", hosts,
            lambda h: f"{h.name}  (ESXi {h.summary.config.product.version})",
            allow_none_label="Any (let DRS decide)",
        )

        # ---- 3. Datastore ----
        datastores = sorted(cluster.datastore, key=lambda d: d.name)
        if not datastores:
            sys.exit(f"No datastores visible to cluster '{cluster.name}'")
        datastore = prompt_choice(
            "Select Datastore", datastores,
            lambda d: f"{d.name}  ({d.summary.freeSpace / 2**30:.0f} GB free)",
        )

        # ---- 4. Portgroup / network ----
        networks = sorted(cluster.network, key=lambda n: n.name)
        if not networks:
            sys.exit(f"No networks visible to cluster '{cluster.name}'")
        network = prompt_choice("Select Portgroup", networks, lambda n: n.name)

        # ---- 5. VM folder (enumerated, or free-text "Other (Provide)") ----
        folders = list_folders(dc)
        if not folders:
            sys.exit(f"No VM folders found under datacenter '{dc.name}'")
        folder_choice = prompt_choice(
            "Select VM-Folder", folders, lambda f: f[0],
            allow_other_label="Other (Provide)",
        )
        if folder_choice is OTHER_SENTINEL:
            while True:
                folder_path = input("Folder path (e.g. EUC/Desktops/HZ-Templates): ").strip()
                if folder_path:
                    break
                print("Folder path can't be empty.")
        else:
            folder_path = folder_choice[0]

        # ---- 6. Collect install logs? ----
        collect_logs = prompt_yes_no("Collect Install logs?", default_yes=True)

        # ---- 7/8. Publish to Desktop-pool/Farm? + which one ----
        # The type choice (Farm / Desktop Pool / "No - skip") and the actual
        # target picker are one step now, both inside pick_horizon_target() -
        # see that function and this module's docstring for why this no
        # longer derives the type from group_vars.
        publish_to_pool, horizon_target_type, horizon_target_name = pick_horizon_target(
            project_root, args.image_key, vault
        )

        # ---- 9. Delete template-vm after clone? ----
        delete_vm_after = prompt_yes_no("Delete template-vm after clone?", default_yes=False)

        placement_overrides = {
            "vcenter_cluster": cluster.name,
            "vcenter_host": host.name if host else "",
            "vcenter_datastore": datastore.name,
            "vcenter_network": network.name,
            "vcenter_folder": folder_path,
        }

        print("\n--- Selected placement ---")
        for k, v in placement_overrides.items():
            print(f"  {k}: {v}")
        print(f"  collect_build_logs: {collect_logs}")
        print(f"  publish_to_pool: {publish_to_pool}")
        if publish_to_pool:
            print(f"  horizon target: {horizon_target_type} '{horizon_target_name}'")
        print(f"  delete_vm_after: {delete_vm_after}")
        if not prompt_yes_no("\nProceed with these values?", default_yes=True):
            sys.exit("Aborted at placement selection.")

        # ---- Save for unattended/scheduled reruns? (ADDED 2026-09-28) ----
        # Asked here, after the values are locked in but before they're
        # written anywhere - a "no" (the default) leaves this run behaving
        # exactly as it always has, one-off and un-persisted. A "yes" writes
        # the SAME placement_overrides/control_lines computed below to a
        # permanent, image_key-namespaced pair under configs/ as well as
        # to this run's own (still-temp, still-shredded-at-exit)
        # --placement-output/--control-output - see config_paths() and
        # this module's docstring. Called a "config" (not "placement")
        # since it also carries collect-logs/publish/delete-after, not just
        # the vCenter placement fields.
        save_name = None
        if prompt_yes_no(
            "Save these settings for unattended/scheduled reruns?", default_yes=False
        ):
            while True:
                raw_name = input(
                    "Name for this saved config (letters/numbers/./-/_ only, "
                    "e.g. rdsh_2025.cfg): "
                ).strip()
                if CONFIG_NAME_RE.fullmatch(raw_name):
                    save_name = raw_name
                    break
                print("Use only letters, numbers, '.', '-' and '_'.")

        placement_yaml = yaml.safe_dump(placement_overrides, sort_keys=False)
        Path(args.placement_output).write_text(placement_yaml)

        def bash_bool(b):
            return "true" if b else "false"

        def bash_quote(s):
            return "'" + s.replace("'", "'\\''") + "'"

        control_lines = (
            f"COLLECT_BUILD_LOGS={bash_bool(collect_logs)}\n"
            f"PUBLISH_TO_POOL={bash_bool(publish_to_pool)}\n"
            f"HORIZON_TARGET_TYPE={bash_quote(horizon_target_type)}\n"
            f"HORIZON_TARGET_NAME={bash_quote(horizon_target_name)}\n"
            f"DELETE_VM_AFTER={bash_bool(delete_vm_after)}\n"
        )
        Path(args.control_output).write_text(control_lines)

        if save_name:
            overrides_path, control_path = config_paths(project_root, args.image_key, save_name)
            overrides_path.parent.mkdir(parents=True, exist_ok=True)
            overrides_header = config_header(args.image_key, save_name, "vCenter placement overrides")
            control_header = config_header(args.image_key, save_name, "build.sh control flags")
            overrides_path.write_text(overrides_header + placement_yaml)
            control_path.write_text(control_header + control_lines)
            print(f"\n==> Saved as '{save_name}'")
            print(f"    The saved files will be placed here: {overrides_path.parent}/")
            print(f"      {overrides_path.name}")
            print(f"      {control_path.name}")
            print(f"    Each file also has a header comment with this same rerun command in it.")
            print(f"    Rerun unattended (no prompts, no vCenter/Horizon call at this step) with:")
            print(f"      scripts/build.sh {args.image_key} --config {save_name}")
    finally:
        Disconnect(si)


if __name__ == "__main__":
    main()
