# Omnissa Horizon Golden Image - HashiCorp Packer

Automated golden image pipeline for **Omnissa Horizon 8 (2603)** on VMware vSphere using HashiCorp Packer.

Builds a fully optimized Windows 11 24H2 Enterprise golden image with:
- VMware Tools
- Omnissa Horizon Agent 2603
- Omnissa Dynamic Environment Manager (DEM) 2603
- Omnissa App Volumes Agent 2603
- OSOT Optimization, Generalize and Finalize

## Architecture

```
Windows Install (autounattend.xml)
    |
    v
Audit Mode (sysprep /audit)
    |
    +-- Phase 1: .NET, Applications, Copilot disable
    |
    +-- Phase 2: OSOT Optimize (manual) -> OSOT Generalize (sysprep)
    |
    v
Post-Sysprep (IMAGE_STATE_COMPLETE)
    |
    +-- Phase 3: Horizon Agent -> DEM Agent -> OSOT Finalize -> App Volumes Agent
```

## Prerequisites

### Software
- HashiCorp Packer >= 1.15.0
- vsphere plugin >= 2.2.0
- windows-update plugin >= 0.16.0

### Installers (not included - download from Omnissa Customer Connect)
Place in `installers/`:
- `OmnissaHorizonOSOptimizationTool-x86_64-1.2.2603.23605577104.exe`
- `Omnissa-Horizon-Agent-x86_64-2603-8.18.0-24273927036.exe`
- `Omnissa Dynamic Environment Manager Enterprise 2603 10.19 x64.msi`
- `App Volumes Agent.msi`
- `Windows 10, 11 and Server 2019, 2022 2026-07-08-085321.json` (OSOT settings)
- `sdelete64.exe` (from Microsoft Sysinternals)
- Windows 11 24H2 Enterprise ISO
- VMware Tools ISO

## Setup

### 1. Clone the repository
```powershell
git clone https://github.com/bjosoren/omnissa-horizon-packer.git
cd omnissa-horizon-packer
```

### 2. Configure variables
Copy the example vars file and fill in your environment values:
```powershell
Copy-Item horizon.pkrvars.hcl.example horizon.pkrvars.hcl
notepad horizon.pkrvars.hcl
```

Key variables to set:
- `vcenter_server` - vCenter FQDN or IP
- `vcenter_username` / `vcenter_password` - vCenter credentials
- `datacenter`, `cluster`, `datastore` - vSphere placement
- `vm_network` - VM portgroup name
- `windows_iso_path` / `vmtools_iso_path` - ISO datastore paths
- `appvolumes_manager` - App Volumes Manager FQDN

> **Note:** `horizon.pkrvars.hcl` is in `.gitignore` - never commit credentials.

### 3. Place installers
Copy all required installers to the `installers/` folder.

### 4. Initialize Packer (on PAW or build host)
```powershell
powershell -ExecutionPolicy Bypass -File "tools\Initialize-PackerSession.ps1"
```

Or download prerequisites if not already available:
```powershell
powershell -ExecutionPolicy Bypass -File "tools\Download-PackerPrerequisites.ps1"
```

## Running a Build

```powershell
packer build -on-error=abort -var-file="horizon.pkrvars.hcl" . 2>&1 | Tee-Object -FilePath "logs\packer-build.log"
```

## Manual OSOT Steps

OSOT (OS Optimization Tool) cannot run non-interactively via WinRM. The build pauses at each OSOT step and waits for manual intervention.

### OSOT Optimize
When Packer pauses, on the VM console:
```cmd
C:\Temp\Run-OSOTOptimize.cmd
```
When complete, resume Packer:
```powershell
Remove-Item "C:\Temp\PAUSE_OSOT-OPTIMIZE.txt" -Force
```

### OSOT Generalize
When Packer pauses, on the VM console:
```cmd
C:\Temp\Run-OSOTGeneralize.cmd
```
The VM will shut down via sysprep. Packer reconnects automatically after reboot.
Then resume:
```powershell
Remove-Item "C:\Temp\PAUSE_OSOT-GENERALIZE.txt" -Force
```

### OSOT Finalize
When Packer pauses, on the VM console:
```cmd
C:\Temp\Run-OSOTFinalize.cmd
```
When complete, resume:
```powershell
Remove-Item "C:\Temp\PAUSE_OSOT-FINALIZE.txt" -Force
```

## Logs

Logs are downloaded from the VM to `logs/` on the build host after each step:

| Step | Log location |
|---|---|
| First boot / VMware Tools | `logs/packer-flc.log` |
| OSOT Optimize | `logs/osot-optimize/` |
| Horizon Agent | `logs/horizon-agent-install.log` |
| DEM Agent | `logs/dem-agent-install.log` |
| OSOT Finalize | `logs/osot-finalize/` |
| App Volumes Agent | `logs/appvolumes-agent-install.log` |

## Project Structure

```
.
+-- horizon-golden-image.pkr.hcl    Main Packer template
+-- variables.pkr.hcl               Variable declarations
+-- horizon.pkrvars.hcl.example     Example variable values (copy and fill in)
+-- http/                           Files uploaded to VM
|   +-- autounattend.xml            Windows unattended install
|   +-- setup.ps1                   WinRM configuration
|   +-- Disable-AuditMode.ps1       Prevents audit.exe from disrupting WinRM
|   +-- Show-BuildStatus.ps1        Build phase status display
|   +-- Invoke-OSOTStep.ps1         OSOT manual step handler
|   +-- Pause-ForReview.ps1         Build pause for log review
|   +-- Run-OSOTOptimize.cmd        OSOT Optimize command
|   +-- Run-OSOTGeneralize.cmd      OSOT Generalize command
|   +-- Run-OSOTFinalize.cmd        OSOT Finalize command
|   +-- w11sysprep.xml              Custom sysprep answer file
+-- scripts/
|   +-- phase1/                     Audit mode: apps and tweaks
|   +-- phase2/                     OSOT optimize and generalize
|   +-- phase3/                     Post-sysprep: agent installation
+-- installers/                     Place installer files here (not committed)
+-- tools/
|   +-- Initialize-PackerSession.ps1      PAW session setup
|   +-- Download-PackerPrerequisites.ps1  Downloads Packer and plugins
+-- logs/                           Build logs (not committed)
```

## References

- [Omnissa TechZone - Manually Creating Optimized Windows Images](https://techzone.omnissa.com/resource/manually-creating-optimized-windows-images-horizon-vms)
- [Omnissa Horizon Agent Silent Install - 2603](https://docs.omnissa.com/bundle/Desktops-and-Applications-in-Horizon/page/InstallHorizonAgentWindowsSilently.html)
- [Omnissa DEM Installation Guide - 2603](https://docs.omnissa.com/bundle/DEMInstallConfigGuide/page/UnattendedInstallationofOmnissaDynamicEnvironmentManager.html)
- [Omnissa App Volumes Install Guide - 2603](https://docs.omnissa.com/bundle/AppVolumesInstallGuide/page/InstallAppVolumesAgentSilently.html)
- [HashiCorp Packer vsphere-iso plugin](https://developer.hashicorp.com/packer/integrations/hashicorp/vsphere)
- [Pausing Packer's PowerShell process (Yaakov's technique)](https://blog.yaakov.online/pausing-packers-powershell-process/)

## Author

Bjorn Sorensen - [@bjosoren](https://github.com/bjosoren)
Atea Norway

## License

MIT
