#!/usr/bin/env python3
"""
VM advanced parameters (vSphere extraConfig) for any image.

Settings live in inventory/group_vars/<image_key>_adv-vm-settings.yml:

    vm_advanced_settings:
      devices.hotplug: "FALSE"

build.sh loads that file and the image's Packer template passes the map to
vsphere-iso `configuration_parameters`; the published clone and instant
clones inherit it.

  dump <image> [--vm NAME] [--suggest] [--write [--force]]
      Read a VM's current advanced parameters into that file (printed unless
      --write). vSphere-managed keys are listed commented out, for reference.
      --suggest adds commented, commonly used Horizon VDI keys to review.
  diff <image> [--vm NAME]
      Compare the file with a VM; exit 1 if anything is missing or different.

--vm defaults to VM_NAME in images/<image>/image.conf. vSphere can only list
parameters already set on a VM - there is no catalogue of every possible key.
"""
import argparse
import fnmatch
import re
import ssl
import sys
from datetime import datetime
from pathlib import Path

import yaml
from pyVim.connect import SmartConnect, Disconnect
from pyVmomi import vim

sys.path.insert(0, str(Path(__file__).resolve().parent))
from select_placement import (  # noqa: E402  (shared vault/vCenter/group_vars helpers)
    find_datacenter,
    load_group_vars,
    load_vault,
    load_vcenter_context,
)

SETTINGS_KEY = "vm_advanced_settings"

# Keys ESXi/vCenter maintain themselves - never emitted as settings, ignored
# by diff. Case-insensitive globs.
MANAGED_PATTERNS = [
    "nvram", "pcibridge*", "hpet*", "vmci0.*", "*.present", "*.pcislotnumber",
    "ethernet*.generatedaddress*", "vmware.tools.*", "toolsinstallmanager.*",
    "tools.remindinstall", "sched.*", "numa.*", "migrate.*", "vmotion.*",
    "monitor.phys_bits_used", "softpoweroff", "cpuid.*", "featmask.*", "viv.*",
    "vc.uuid", "uuid.*", "checkpoint.*", "guestinfo.*", "guestos.detailed.data",
    "virtualhw.*", "vmxstats.*", "svga.guestbackedprimaryaware", "config.readonly",
]

# Emitted commented out by --suggest - review before enabling.
SUGGESTIONS = [
    ("devices.hotplug", "FALSE", "hide 'Safely Remove Hardware' for NICs/disks inside the desktop"),
    ("log.keepOld", "10", "number of vmware.log files kept"),
    ("log.rotateSize", "2048000", "rotate vmware.log at ~2 MB"),
    ("isolation.tools.copy.disable", "TRUE", "block VMRC console copy (Blast clipboard is a Horizon policy, not this)"),
    ("isolation.tools.paste.disable", "TRUE", "block VMRC console paste"),
    ("tools.setInfo.sizeLimit", "1048576", "cap guest -> VMX setinfo size (hardening guides)"),
]

def is_managed(key: str) -> bool:
    k = key.lower()
    return any(fnmatch.fnmatch(k, p) for p in MANAGED_PATTERNS)

def connect(project_root: Path):
    vault = load_vault(project_root)
    ctx = load_vcenter_context(project_root, vault)
    ssl_ctx = ssl.create_default_context()
    ssl_ctx.check_hostname = False
    ssl_ctx.verify_mode = ssl.CERT_NONE
    si = SmartConnect(host=ctx["host"], user=ctx["user"], pwd=ctx["password"], sslContext=ssl_ctx)
    return si, ctx, vault

def find_vm(content, dc, name):
    view = content.viewManager.CreateContainerView(dc.vmFolder, [vim.VirtualMachine], True)
    try:
        matches = [v for v in view.view if v.name == name]
    finally:
        view.Destroy()
    if not matches:
        sys.exit(f"No VM named '{name}' in datacenter '{dc.name}'.")
    if len(matches) > 1:
        sys.exit(f"{len(matches)} VMs named '{name}' in '{dc.name}' - pass a unique --vm.")
    return matches[0]

def default_vm_name(project_root: Path, image_key: str) -> str:
    conf = project_root / "images" / image_key / "image.conf"
    if conf.exists():
        m = re.search(r'^VM_NAME="?([^"\n]+)"?', conf.read_text(), re.M)
        if m:
            return m.group(1)
    sys.exit(f"Couldn't read VM_NAME from {conf} - pass --vm explicitly.")

def settings_path(project_root: Path, image_key: str) -> Path:
    return project_root / "inventory" / "group_vars" / f"{image_key}_adv-vm-settings.yml"

def q(v) -> str:
    """Render a value as a quoted YAML string (ESXi wants strings)."""
    return '"' + str(v).replace("\\", "\\\\").replace('"', '\\"') + '"'

def cmd_dump(args, project_root: Path):
    si, ctx, _ = connect(project_root)
    try:
        content = si.RetrieveContent()
        dc = find_datacenter(content, ctx["datacenter"])
        if dc is None:
            sys.exit(f"Datacenter '{ctx['datacenter']}' not found")
        vm_name = args.vm or default_vm_name(project_root, args.image_key)
        vm = find_vm(content, dc, vm_name)
        extra = sorted(((o.key, str(o.value)) for o in (vm.config.extraConfig or [])),
                       key=lambda kv: kv[0].lower())
    finally:
        Disconnect(si)

    settable = [(k, v) for k, v in extra if not is_managed(k)]
    managed = [(k, v) for k, v in extra if is_managed(k)]
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    out = [
        f"# inventory/group_vars/{args.image_key}_adv-vm-settings.yml",
        f"# Generated {now} by scripts/vm_advanced_settings.py from VM '{vm_name}'.",
        "# VM Advanced Configuration Parameters (vSphere extraConfig) applied to the",
        "# build VM by Packer (vsphere-iso configuration_parameters) - the published",
        "# clone and instant clones inherit them. Values are strings; keep them quoted.",
        "# Delete anything you don't want to manage - only keys listed here are set.",
        "",
        f"{SETTINGS_KEY}:",
    ]
    if settable:
        out.append(f"  # --- currently set on {vm_name} (review) ---")
        out += [f"  {k}: {q(v)}" for k, v in settable]
    else:
        out.append("  {}" if not (args.suggest or managed) else f"  # (nothing settable found on {vm_name})")
    if args.suggest:
        out.append("  # --- suggestions, commented out - review before enabling ---")
        present = {k.lower() for k, _ in extra}
        for k, v, why in SUGGESTIONS:
            flag = "  (already on VM)" if k.lower() in present else ""
            out.append(f"  # {k}: {q(v)}   # {why}{flag}")
    if managed:
        out.append("  # --- managed by vSphere/ESXi - do NOT set, reference only ---")
        out += [f"  # {k}: {q(v)}" for k, v in managed]
    text = "\n".join(out) + "\n"

    if yaml.safe_load(text).get(SETTINGS_KEY) is None:
        text = text.replace(f"{SETTINGS_KEY}:\n", f"{SETTINGS_KEY}: {{}}\n", 1)
    yaml.safe_load(text)

    if not args.write:
        sys.stdout.write(text)
        return
    path = settings_path(project_root, args.image_key)
    if path.exists() and not args.force:
        sys.exit(f"{path} already exists - add --force to overwrite, or run without --write to print.")
    path.write_text(text)
    print(f"==> Wrote {path}  ({len(settable)} settable, {len(managed)} managed/reference-only)")

def cmd_diff(args, project_root: Path):
    si, ctx, vault = connect(project_root)
    try:
        wanted = (load_group_vars(project_root, args.image_key, vault).get(SETTINGS_KEY) or {})
        content = si.RetrieveContent()
        dc = find_datacenter(content, ctx["datacenter"])
        if dc is None:
            sys.exit(f"Datacenter '{ctx['datacenter']}' not found")
        vm_name = args.vm or default_vm_name(project_root, args.image_key)
        vm = find_vm(content, dc, vm_name)
        actual = {o.key.lower(): str(o.value) for o in (vm.config.extraConfig or [])}
    finally:
        Disconnect(si)

    if not wanted:
        print(f"No {SETTINGS_KEY} in {args.image_key}'s group_vars - nothing to compare.")
        return
    bad = 0
    for k, v in sorted(wanted.items(), key=lambda kv: kv[0].lower()):
        want = "TRUE" if v is True else "FALSE" if v is False else str(v)
        have = actual.get(k.lower())
        if have is None:
            print(f"  MISSING   {k} (want {want})")
            bad += 1
        elif have.lower() != want.lower():
            print(f"  DIFFERENT {k}: VM has {have}, want {want}")
            bad += 1
        else:
            print(f"  ok        {k} = {have}")
    managed_wanted = [k for k in wanted if is_managed(k)]
    if managed_wanted:
        print(f"  NOTE: {', '.join(managed_wanted)} look vSphere-managed - setting them may not stick.")
    print(f"==> {vm_name}: {len(wanted) - bad}/{len(wanted)} match")
    sys.exit(1 if bad else 0)

def main():
    p = argparse.ArgumentParser(description="Dump/compare VM advanced parameters for an image.")
    p.add_argument("--project-root", default=str(Path(__file__).resolve().parent.parent),
                   help="golden-images root (default: parent of scripts/)")
    sub = p.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("dump", help="read a VM's advanced parameters into a yml skeleton")
    d.add_argument("image_key")
    d.add_argument("--vm", help="VM name (default: VM_NAME from images/<key>/image.conf)")
    d.add_argument("--suggest", action="store_true", help="add commented Horizon VDI suggestions")
    d.add_argument("--write", action="store_true", help=f"write inventory/group_vars/<key>_adv-vm-settings.yml")
    d.add_argument("--force", action="store_true", help="overwrite an existing file with --write")
    f = sub.add_parser("diff", help="compare group_vars' vm_advanced_settings with a VM")
    f.add_argument("image_key")
    f.add_argument("--vm", help="VM name (default: VM_NAME from images/<key>/image.conf)")
    args = p.parse_args()
    project_root = Path(args.project_root)
    {"dump": cmd_dump, "diff": cmd_diff}[args.cmd](args, project_root)

if __name__ == "__main__":
    main()
