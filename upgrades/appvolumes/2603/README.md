# Upgrade-AppVolumesManager-2603.ps1

Automates the upgrade of **Omnissa App Volumes Manager** to version **2603 (v4.21.0_10042026)** via PowerCLI and PowerShell Remoting.

> **Blog post:** [tech.iot-it.no](https://tech.iot-it.no)

---

## What the script does

1. Runs prechecks (PowerCLI, credential files, ISO availability)
2. Connects to vCenter using stored credentials
3. Removes any existing snapshots on the AVM VM
4. Gracefully shuts down the VM
5. Takes a pre-upgrade snapshot (retained on failure for rollback)
6. Powers on the VM and waits for WinRM to become available
7. Mounts the App Volumes ISO
8. Backs up Nginx certificates and configuration
9. Copies the MSI locally and runs the installer
10. Reboots and runs a post-install health check (service + API version)
11. Restores Nginx certificates and configuration
12. Reboots and runs a final health check
13. Removes temp files and the pre-upgrade snapshot
14. Dismounts the ISO and disconnects from vCenter
15. Saves a full transcript log throughout

---

## Prerequisites

### Management host (where you run the script)

- Windows with **VMware PowerCLI** installed:
  ```powershell
  Install-Module -Name VMware.PowerCLI -Scope CurrentUser -Force
  ```

- **CredSSP** enabled as client, delegating to the AVM server:
  ```powershell
  Enable-WSManCredSSP -Role Client -DelegateComputer avm01.yourdomain.com
  ```

- **vCenter credentials** stored as a VICredentialStore file:
  ```powershell
  New-VICredentialStoreItem -User "domain\user" -Password "pass" `
      -Host "vcenter.yourdomain.com" -File "C:\Credentials\vcenter_creds.xml"
  ```

- **AVM admin credentials** stored as an encrypted CliXml:
  ```powershell
  $cred = Get-Credential
  $cred | Export-CliXml -Path "C:\Credentials\appvol_admin_${env:USERNAME}_${env:COMPUTERNAME}.xml"
  ```

- App Volumes Manager **2603 ISO** accessible on a local or mapped drive

### App Volumes Manager server

- **CredSSP** enabled as server:
  ```powershell
  Enable-WSManCredSSP -Role Server
  ```

- WinRM enabled and reachable from the management host

---

## Configuration

All environment-specific values are collected at the top of the script under the `# CONFIGURATION` section. Update these before running:

| Variable | Description |
|---|---|
| `$vCenterServer` | FQDN of your vCenter server |
| `$vCenterCredFile` | Path to the VICredentialStore XML file |
| `$avmHostname` | FQDN of the App Volumes Manager VM |
| `$avmCredFile` | Path to the AVM admin CliXml credential file |
| `$avmIsoPath` | Full path to the App Volumes 2603 ISO |
| `$snapshotName` | Name for the pre-upgrade snapshot |
| `$installDir` | Temp directory on the AVM for MSI and backups |
| `$transcriptDir` | Directory on the management host for transcript logs |
| `$winrmTimeout` | Seconds to wait for WinRM/API after reboot (default: 300) |
| `$winrmPollInterval` | Polling interval in seconds (default: 15) |

---

## Usage

```powershell
.\Upgrade-AppVolumesManager-2603.ps1
```

Run once per AVM node. In a multi-node environment, verify each node is healthy before proceeding to the next — see [Omnissa rolling upgrade guidance](https://docs.omnissa.com/bundle/AppVolumesInstallGuideV2312/page/ConsiderationsforPerformingRollingUpgrades.html).

---

## Health checks

After each reboot the script verifies:

- The **`svservice`** Windows service is in `Running` state
- The **`/app_volumes/version`** API endpoint responds with HTTP 200 and a version string containing `4.21.0`

If either check fails, the script throws, skips cleanup, and retains the pre-upgrade snapshot for rollback.

---

## Transcript

A timestamped transcript log is written to `$transcriptDir` on the management host for every run, e.g.:

```
C:\Logs\AppVolumes\Upgrade-AppVolumesManager-avm01-20260623_143022.log
```

---

## Rollback

If the upgrade fails at any point, the pre-upgrade snapshot **`Pre-Upgrade-AVM-2603`** is retained in vCenter. Revert to it from the vSphere Client to restore the previous state.

---

## Author

**Bjørn Sørensen** — [tech.iot-it.no](https://tech.iot-it.no)
