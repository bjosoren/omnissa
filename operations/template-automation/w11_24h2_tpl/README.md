# w11_24h2_tpl

Windows 11 24H2 Enterprise golden image for an Omnissa Horizon instant-clone
desktop pool, built with Packer (vsphere-iso) and Ansible (WinRM) from the
shared [automation-platform](../automation-platform).

## Build flow

1. **Packer** creates the VM (EFI + Secure Boot, no vTPM, pvscsi, vmxnet3),
   uploads the Windows ISO from the control node's NFS mount to a datastore
   cache, and installs Windows unattended from `floppy/autounattend.pkrtpl.hcl`.
   Setup boots straight into Audit Mode and enables WinRM.
2. **Ansible** (`playbook.yml`) runs once over WinRM:
   VMware Tools check → Audit Mode check → .NET 3.5 → Windows Update →
   optional apps → OSOT Optimize → Appx clean-up → OSOT Generalize (Sysprep) →
   Store app removal → OSOT Optimize again → Horizon Agent (VDI) → DEM →
   App Volumes → OSOT Finalize (two passes) → log collection → clean-up.
3. **scripts/build.sh** clones the build VM to `gi-w1124h2-<timestamp>`,
   snapshots it and pushes it to the Horizon desktop pool.

## Configuration

| File (inventory/group_vars/) | Contents |
|---|---|
| `w11_24h2_tpl.yml` | VM size, install media, Windows settings, pauses, Store apps |
| `w11_24h2_tpl_agents.yml` | Horizon Agent / DEM / App Volumes options, target pool |
| `w11_24h2_tpl_osot.yml` | OSOT installer and Finalize job numbers |
| `w11_24h2_tpl_adv-vm-settings.yml` | VM advanced parameters (extraConfig) |
| `w11_24h2_tpl.local.yml` | your real, site-specific values - copy from `.local.yml.example`, never committed |

Secrets come from `group_vars/all/vault.yml`: `vault_win_admin_password`,
`vault_vcenter_*`, `vault_horizon_api_password`.

## Requirements

- Control node set up as described in automation-platform (Ansible venv with
  `pywinrm`, `requests_ntlm`, `pyvmomi`; Packer; vault password file).
- Windows 11 business-editions ISO and the Horizon Agent, DEM, App Volumes,
  OSOT and `sdelete64.exe` installers on the NFS share.
- An `[w11_24h2_tpl]` group in `inventory/hosts.ini`, a DNS A record and DHCP
  reservation for `w11-24h2-tpl`, and a Horizon desktop pool.
- Internet or WSUS access from the build network (Windows Update).
- An isolated build network: WinRM runs over unencrypted HTTP during the build.

## Run

```bash
scripts/build.sh w11_24h2_tpl                  # interactive placement picker
scripts/build.sh w11_24h2_tpl --config NAME    # replay saved answers, unattended
```
