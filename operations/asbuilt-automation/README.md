# Horizon AsBuilt Report — Air-Gapped Automation

PowerShell scripts for generating [AsBuiltReport](https://www.asbuiltreport.com/) documentation for an Omnissa Horizon environment in an air-gapped (offline) network.

Covers: **Horizon Connection Server · App Volumes · UAG · vSphere**

## Overview

Three scripts handle the full workflow:

| Script | Purpose | Run on |
|--------|---------|--------|
| `AsBuilt-Offline.ps1` | Downloads/installs all required modules | Internet machine (Download), air-gapped PAW (Install) |
| `AsBuilt-CreateJsonConfig.ps1` | Creates JSON config files on the network share | Air-gapped PAW (once) |
| `AsBuilt-GenerateReports.ps1` | Generates the HTML/Word reports | Air-gapped PAW |

## Prerequisites

- PowerShell 5.1 or PowerShell 7+
- Network share accessible via UNC path (e.g. `\\fileserver.domain.local\AsBuilt\`)
- Credentials for Horizon, App Volumes, UAG, and vSphere

## Usage

### Phase 1 — Internet machine (download modules)
```powershell
.\AsBuilt-Offline.ps1 -Mode Download
```

### Phase 2 — Air-gapped PAW (install modules)
```powershell
.\AsBuilt-Offline.ps1 -Mode Install
```

### Create config files (once)
```powershell
.\AsBuilt-CreateJsonConfig.ps1 -ConfigDir '\\fileserver.domain.local\AsBuilt\Config'
```

### Generate reports
```powershell
.\AsBuilt-GenerateReports.ps1
```

## Configuration

Edit the JSON files in your `Config\` folder after running `AsBuilt-CreateJsonConfig.ps1`.  
Credentials are stored using Windows DPAPI encryption — run `AsBuilt-CreateJsonConfig.ps1` interactively to populate them.

> **Note:** Use UNC paths (`\\server\share`) rather than mapped drive letters to avoid elevation issues with scheduled tasks.

## Blog post

Full walkthrough: [tech.iot-it.no](https://tech.iot-it.no)
