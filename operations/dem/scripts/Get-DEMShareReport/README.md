# Get-DEMShareReport.ps1

A PowerShell script that generates a styled HTML documentation report for **Omnissa Dynamic Environment Manager (DEM)** file shares.

Useful for system documentation, change management, and as-built reports in environments running DEM with file-share-based config and profile storage.

![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![No dependencies](https://img.shields.io/badge/dependencies-none-green)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow)

---

## What it documents

For each share (config, profile archive, folder redirection):

- **SMB share permissions** — via `Get-SmbShareAccess` (requires local execution on the file server)
- **NTFS ACL on the share root** — identity, rights, Allow/Deny, Inherited/Explicit, inheritance flags
- **Folder owner** — on the root and each subfolder
- **Per-pool subfolders** — with full NTFS ACL and folder size
- **Summary table** — all shares at a glance

The HTML output includes a **Print / Save as PDF** button and opens automatically in the default browser.

---

## Requirements

- PowerShell 5.1 or later
- Run as **Administrator** on the file server for full SMB + NTFS output
- No external modules or dependencies required

---

## Usage

### Run locally on the DEM file server (recommended - full output)

```powershell
.\Get-DEMShareReport.ps1 `
    -ConfigSharePath  "C:\DEM\demcfg" `
    -ProfileSharePath "C:\DEM\demprf" `
    -RedirSharePath   "C:\DEM\hzredir" `
    -Title            "My DEM Environment"
```

### Run against remote UNC paths (NTFS only - no SMB permissions)

```powershell
.\Get-DEMShareReport.ps1 `
    -ConfigSharePath  "\\fileserver\demcfg$" `
    -ProfileSharePath "\\fileserver\demprf$"
```

---

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-ConfigSharePath` | Yes | Local or UNC path to the DEM config share root |
| `-ProfileSharePath` | Yes | Local or UNC path to the DEM profile archive share root |
| `-RedirSharePath` | No | Local or UNC path to the folder redirection share root |
| `-Title` | No | Report title shown in the header. Defaults to "Omnissa DEM - Share Documentation Report" |
| `-OutputPath` | No | Output HTML file path. Defaults to `.\DEM-ShareReport-<timestamp>.html` |

---

## Notes on SMB permissions

`Get-SmbShareAccess` is a Windows SMB cmdlet that can only query shares **hosted locally on the Windows machine running the script**. This means:

| Scenario | SMB permissions | NTFS ACLs | Subfolder data |
|----------|----------------|-----------|----------------|
| Script runs on the Windows file server that hosts the shares | Full output | Full output | Full output |
| Script runs on a workstation, shares on a remote Windows server | N/A (not supported remotely) | Full output | Full output |
| Script runs on any Windows machine, shares on Linux/Samba server | N/A (no Windows SMB API) | Full output | Full output |

**Recommended approach:** Copy the script to the Windows DEM file server and run it locally as Administrator. This gives you full SMB share permissions, NTFS ACLs, owner information, subfolder structure and folder sizes in one report.

If the DEM shares are hosted on a Linux/Samba server, document the SMB share permissions separately (e.g. from `smb.conf` or `net conf list` on the Linux server) and use this script for the NTFS ACL and subfolder documentation.

---

## Share structure this script is designed for

```
\\fileserver\demcfg$\          <- DEM config share (read-only for VDI desktops)
    pool1\                     <- Per-pool subfolder
    pool2\

\\fileserver\demprf$\          <- DEM profile archive share (read/write)
    pool1\
    pool2\

\\fileserver\hzredir$\         <- Folder redirection share (optional)
    %USERNAME%\                <- Auto-created per user
```

---

## License

MIT - see [LICENSE](LICENSE)

## Author

bjosoren - [tech.iot-it.no](https://tech.iot-it.no)