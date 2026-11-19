# Add-HorizonVgpuProfiles.ps1

A PowerShell script that adds missing NVIDIA vGPU profiles (default: **L40S**) to `graphic-profiles.properties` on an **Omnissa Horizon Connection Server**, then restarts the Connection Server service.

![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![No dependencies](https://img.shields.io/badge/dependencies-none-green)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow)

Blog post: [Omnissa Horizon – "No GPU capable host is available" with NVIDIA L40S vGPU](https://tech.iot-it.no/?p=26330)

---

## The problem it fixes

Horizon keeps its own list of known vGPU profiles in `graphic-profiles.properties`. If a profile is missing there, Horizon can't work out the hosts' GPU capacity, and instant clone provisioning fails even though vCenter offers the profile:

```
Fault type is UNKNOWN_FAULT_FATAL - No GPU capable host is available for provisioning <vm> with profile nvidia_l40s-16a.
Please refer to this KB - https://kb.omnissa.com/s/article/59271 for more details.
```

The Connection Server debug log shows one line per host evaluated:

```
[CPHost] {HIC} VGPU_PROFILE is null or unknown.
```

Use [Get-HorizonGpuDebug](../Get-HorizonGpuDebug/) `-TraceError` to confirm.

---

## What it does

1. **Finds** `graphic-profiles.properties` in the Omnissa or VMware install path
2. **Compares** it with the profile list and shows what's already there
3. **Backs up** the file (`graphic-profiles.properties.bak-<timestamp>`) and appends **only the missing profiles**, so it's safe to run again
   - A profile that's already listed with a different value is left unchanged, with a warning
4. **Restarts** the Connection Server service (`wsbroker`) after asking for confirmation

`-WhatIf` shows what would be added without changing anything.

---

## Requirements

- Run **as Administrator** on the Connection Server
- Windows PowerShell 5.1 or PowerShell 7
- Drain the Connection Server from the load balancer before the service restart

---

## Usage

### Preview

```powershell
.\Add-HorizonVgpuProfiles.ps1 -WhatIf
```

### Add the L40S profiles and restart (asks first)

```powershell
.\Add-HorizonVgpuProfiles.ps1
```

### Update the file only, restart later

```powershell
.\Add-HorizonVgpuProfiles.ps1 -NoRestart
```

### Other GPU models

```powershell
$p = [ordered]@{ 'nvidia_l4-24q' = 1; 'nvidia_l4-12q' = 2; 'nvidia_l4-8q' = 3 }
.\Add-HorizonVgpuProfiles.ps1 -Profiles $p -Header '# NVIDIA L4'
```

**Repeat on every Connection Server, one at a time.** Afterwards, re-enable provisioning on the farm or pool (*Maintain → Enable Provisioning*); Horizon turns it off when *Stop Provisioning on Error* is set.

---

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Profiles` | No | Hashtable of profile name = max instances per physical GPU. Default: L40S A, B and Q profiles |
| `-Header` | No | Comment line written above the added profiles. Default `# NVIDIA L40S` |
| `-NoRestart` | No | Update the file but don't restart `wsbroker` |
| `-Force` | No | Restart without asking |
| `-WhatIf` | No | Show what would change, change nothing |

---

## Default L40S values

| Series | Profiles (max per GPU) |
|--------|------------------------|
| Q (vWS) | 48q=1, 24q=2, 16q=3, 12q=4, 8q=6, 6q=8, 4q=12, 3q=16, 2q=24, 1q=32 |
| A (vApps) | 48a=1, 24a=2, 16a=3, 12a=4, 8a=6, 6a=8, 4a=12, 3a=16, 2a=24, 1a=32 |
| B (vPC) | 3b=16, 2b=24, 1b=32 |

Verify these against the NVIDIA vGPU user guide for your driver release. Profile names are case-sensitive and must match what vCenter reports ([Get-VgpuProfiles](../Get-VgpuProfiles/) lists them).

---

## After a Connection Server upgrade

The file lives in the installation directory and can be replaced by an upgrade. Run the script again after every Connection Server upgrade. If nothing is missing, it changes nothing.

---

## License

MIT - see [LICENSE](LICENSE)

## Author

bjosoren - [tech.iot-it.no](https://tech.iot-it.no)
