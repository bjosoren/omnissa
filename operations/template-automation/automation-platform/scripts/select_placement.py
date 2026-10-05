#!/usr/bin/env python3
"""
Interactive build options for scripts/build.sh, read live from vCenter and
Horizon: cluster, ESXi host (optional), datastore, port group, VM folder,
collect install logs, publish target (Desktop Pool / Farm / skip) and delete
the build VM afterwards.

Writes two files for build.sh:
  --placement-output  YAML with vcenter_* overrides (loaded last by Ansible)
  --control-output    KEY=value lines build.sh sources: COLLECT_BUILD_LOGS,
                      PUBLISH_TO_POOL, HORIZON_TARGET_TYPE,
                      HORIZON_TARGET_NAME, DELETE_VM_AFTER

The answers can be saved under a name (configs/<image>__<name>.*) and replayed
without prompts or vCenter/Horizon access:
  scripts/build.sh <image> --config <name>
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
    """Merge this image's group_vars files in build.sh's order (later files win)."""
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
    """Numbered picker. 0 = None (if allow_none_label); last = OTHER_SENTINEL (if allow_other_label)."""
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
    """Login + list; None on failure so the caller falls back to typing a name."""
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
    """Ask Farm / Desktop Pool / skip, then pick from Horizon's live list (or type a name). Returns (publish, type, name)."""
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
        if targets is not None:
            print(f"    Horizon returned no {target_type}s from {list_path} - enter the name directly.")
        target_name = _prompt_target_name(type_choice)

    return True, target_type, target_name

def pick_vgpu_profile(cluster, host):
    """Optional vGPU for the build VM. Profiles come from vCenter: what the
    picked host offers, or every connected host in the cluster when the host
    is left to DRS. Returns the profile name, or "" for none."""
    if not prompt_yes_no("Add a vGPU to the build VM?", default_yes=False):
        return ""
    hosts = [host] if host else sorted(cluster.host, key=lambda h: h.name)
    offered = {}
    for h in hosts:
        if h.runtime.connectionState != "connected":
            continue
        try:
            target = cluster.environmentBrowser.QueryConfigTarget(host=h)
        except Exception as e:
            print(f"    {h.name}: could not read vGPU profiles ({e})")
            continue
        for g in (target.sharedGpuPassthroughTypes or []):
            if g.vgpu:
                offered.setdefault(g.vgpu, []).append(h.name)
    where = host.name if host else f"cluster {cluster.name}"
    if not offered:
        print(f"    No vGPU profiles offered on {where}. Check that the NVIDIA vGPU host")
        print("    driver is installed and the host graphics type is 'Shared Direct'.")
        if prompt_yes_no("Type a profile name anyway?", default_yes=False):
            return input("vGPU profile (e.g. grid_a16-2q): ").strip()
        return ""
    names = sorted(offered)
    choice = prompt_choice(
        f"Select vGPU profile ({where})", names,
        lambda p: p if host else f"{p}  ({', '.join(offered[p])})",
        allow_none_label="No vGPU",
    )
    return choice or ""


WSUS_URL_RE = re.compile(r"https?://[A-Za-z0-9.-]+(:\d+)?/?")


def pick_windows_update(project_root, image_key, vault):
    """Windows images only (those with roles/windows_update): run Windows
    Update in the build, and from Windows Update or WSUS. Returns the vars
    for the overrides file, {} for images without Windows Update."""
    if not (project_root / "images" / image_key / "roles" / "windows_update").is_dir():
        return {}
    gv = load_group_vars(project_root, image_key, vault)
    source = str(gv.get("windows_update_source") or "windows_update")
    url = str(gv.get("wsus_server_url") or "")
    if not prompt_yes_no("Run Windows Update during the build?",
                         default_yes=bool(gv.get("enable_windows_update", True))):
        return {"enable_windows_update": False, "windows_update_source": source,
                "wsus_server_url": url}
    labels = {"windows_update": "Windows Update (Microsoft - needs internet)",
              "wsus": "WSUS"}
    source = prompt_choice("Update source", ["windows_update", "wsus"], lambda s: labels[s])
    if source == "wsus":
        while True:
            hint = f" [{url}]" if url else " (e.g. http://wsus.example.com:8530)"
            raw = input(f"WSUS server URL{hint}: ").strip() or url
            if WSUS_URL_RE.fullmatch(raw):
                url = raw.rstrip("/")
                break
            print("Use http(s)://host[:port], e.g. http://wsus.example.com:8530")
    return {"enable_windows_update": True, "windows_update_source": source,
            "wsus_server_url": url}


def config_paths(project_root: Path, image_key: str, name: str):
    """Paths of a saved config: configs/<image_key>__<name>.overrides.yml / .control.sh"""
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
    """Comment header for saved config files ('#' is a comment in YAML and bash)."""
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
    """--load: copy a saved config onto the output files; no vCenter/Horizon calls."""
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

        clusters = sorted(
            list_of_type(content, dc.hostFolder, vim.ClusterComputeResource),
            key=lambda c: c.name,
        )
        if not clusters:
            sys.exit("No clusters found under this datacenter")
        cluster = prompt_choice("Select Cluster", clusters, lambda c: c.name)

        hosts = sorted(cluster.host, key=lambda h: h.name)
        host = prompt_choice(
            "Select ESXi-host", hosts,
            lambda h: f"{h.name}  (ESXi {h.summary.config.product.version})",
            allow_none_label="Any (let DRS decide)",
        )

        vgpu_profile = pick_vgpu_profile(cluster, host)

        datastores = sorted(cluster.datastore, key=lambda d: d.name)
        if not datastores:
            sys.exit(f"No datastores visible to cluster '{cluster.name}'")
        datastore = prompt_choice(
            "Select Datastore", datastores,
            lambda d: f"{d.name}  ({d.summary.freeSpace / 2**30:.0f} GB free)",
        )

        networks = sorted(cluster.network, key=lambda n: n.name)
        if not networks:
            sys.exit(f"No networks visible to cluster '{cluster.name}'")
        network = prompt_choice("Select Portgroup", networks, lambda n: n.name)

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

        collect_logs = prompt_yes_no("Collect Install logs?", default_yes=True)

        windows_update = pick_windows_update(project_root, args.image_key, vault)

        publish_to_pool, horizon_target_type, horizon_target_name = pick_horizon_target(
            project_root, args.image_key, vault
        )

        delete_vm_after = prompt_yes_no("Delete template-vm after clone?", default_yes=False)

        placement_overrides = {
            "vcenter_cluster": cluster.name,
            "vcenter_host": host.name if host else "",
            "vcenter_datastore": datastore.name,
            "vcenter_network": network.name,
            "vcenter_folder": folder_path,
            "vm_vgpu_profile": vgpu_profile,
        }
        placement_overrides.update(windows_update)

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
