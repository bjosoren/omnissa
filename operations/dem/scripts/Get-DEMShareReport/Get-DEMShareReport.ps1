<#
.SYNOPSIS
    Get-DEMShareReport.ps1
    Generates a styled HTML documentation report for Omnissa Dynamic Environment
    Manager (DEM) file shares. Enumerates SMB share permissions, NTFS ACLs,
    folder ownership, subfolder structure and folder sizes for the DEM config,
    profile archive and folder redirection shares.

.DESCRIPTION
    Run this script as Administrator on the Windows server that hosts the DEM
    shares locally to get full SMB + NTFS output. When pointed at remote UNC
    paths (e.g. a Samba/Linux server), NTFS ACLs and subfolder data are still
    collected but the SMB section will show N/A.

    The HTML report opens automatically in the default browser when complete
    and includes a Print / Save as PDF button.

    No external dependencies - works on PowerShell 5.1 and later.

.PARAMETER ConfigSharePath
    Local path or UNC path to the DEM configuration share root.
    Example: C:\Shares\demcfg   or   \\fileserver\demcfg$

.PARAMETER ProfileSharePath
    Local path or UNC path to the DEM profile archive share root.
    Example: C:\Shares\demprf   or   \\fileserver\demprf$

.PARAMETER RedirSharePath
    (Optional) Local path or UNC path to the folder redirection share root.
    Example: C:\Shares\hzredir   or   \\fileserver\hzredir$

.PARAMETER Title
    Optional title shown in the report header.
    Defaults to "Omnissa DEM - Share Documentation Report"

.PARAMETER OutputPath
    Output path for the HTML report file.
    Defaults to .\DEM-ShareReport-<yyyyMMdd-HHmmss>.html

.EXAMPLE
    # Run locally on the DEM file server - full SMB + NTFS output
    .\Get-DEMShareReport.ps1 `
        -ConfigSharePath  "C:\DEM\demcfg" `
        -ProfileSharePath "C:\DEM\demprf" `
        -RedirSharePath   "C:\DEM\hzredir" `
        -Title            "My DEM Environment"

.EXAMPLE
    # Run against remote shares (NTFS only - no SMB permissions)
    .\Get-DEMShareReport.ps1 `
        -ConfigSharePath  "\\fileserver\demcfg$" `
        -ProfileSharePath "\\fileserver\demprf$"

.NOTES
    Author  : bjosoren (https://github.com/bjosoren)
    Blog    : https://tech.iot-it.no
    License : MIT
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string]$ConfigSharePath,

    [Parameter(Mandatory)]
    [string]$ProfileSharePath,

    [Parameter()]
    [string]$RedirSharePath,

    [Parameter()]
    [string]$Title = 'Omnissa DEM - Share Documentation Report',

    [Parameter()]
    [string]$OutputPath = ".\DEM-ShareReport-$(Get-Date -Format 'yyyyMMdd-HHmmss').html"
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helper: HTML encoding without System.Web dependency
# ---------------------------------------------------------------------------

function Encode-Html {
    param([string]$Text)
    if (-not $Text) { return '' }
    $Text = $Text -replace '&', '&amp;'
    $Text = $Text -replace '<', '&lt;'
    $Text = $Text -replace '>', '&gt;'
    $Text = $Text -replace '"', '&quot;'
    return $Text
}

# ---------------------------------------------------------------------------
# Helper: derive SMB share name from a path
# ---------------------------------------------------------------------------

function Get-ShareName {
    param([string]$Path)
    if ($Path -match '^\\\\[^\\]+\\([^\\]+)') { return $Matches[1] }
    return Split-Path $Path -Leaf
}

# ---------------------------------------------------------------------------
# Helper: get folder size (MB, approximate)
# ---------------------------------------------------------------------------

function Get-FolderSizeMB {
    param([string]$Path)
    try {
        $bytes = (Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue |
                  Measure-Object -Property Length -Sum).Sum
        if ($bytes -eq $null) { return '0 MB' }
        return "{0:N1} MB" -f ($bytes / 1MB)
    } catch {
        return 'N/A'
    }
}

# ---------------------------------------------------------------------------
# Helper: get NTFS ACL entries + owner for a path
# ---------------------------------------------------------------------------

function Get-NtfsAcl {
    param([string]$Path)
    try {
        $acl = Get-Acl -Path $Path
        $entries = @($acl.Access | Select-Object `
            @{N='Identity';   E={ $_.IdentityReference }},
            @{N='Rights';     E={ $_.FileSystemRights }},
            @{N='Type';       E={ $_.AccessControlType }},
            @{N='Inherited';  E={ $_.IsInherited }},
            @{N='Inheritance';E={ $_.InheritanceFlags }})
        return [PSCustomObject]@{
            Owner   = $acl.Owner
            Entries = $entries
        }
    } catch {
        return [PSCustomObject]@{
            Owner   = '(error)'
            Entries = @([PSCustomObject]@{
                Identity='(error reading ACL)'; Rights=$_.Exception.Message
                Type=''; Inherited=''; Inheritance=''
            })
        }
    }
}

# ---------------------------------------------------------------------------
# Helper: get SMB share permissions (works only when run locally on the host)
# ---------------------------------------------------------------------------

function Get-SmbPermissions {
    param([string]$ShareName)
    try {
        $perms = Get-SmbShareAccess -Name $ShareName -ErrorAction Stop
        return @($perms | Select-Object `
            @{N='Identity';     E={ $_.AccountName }},
            @{N='AccessRight';  E={ $_.AccessRight }},
            @{N='AccessControl';E={ $_.AccessControlType }})
    } catch {
        return @([PSCustomObject]@{
            Identity    = 'N/A - run script locally on the file server to read SMB permissions'
            AccessRight = ''
            AccessControl = 'info'
        })
    }
}

# ---------------------------------------------------------------------------
# Helper: enumerate subfolders with ACL, owner and size
# ---------------------------------------------------------------------------

function Get-SubfolderReport {
    param([string]$RootPath)
    $results = @()
    try {
        $subfolders = Get-ChildItem -Path $RootPath -Directory -ErrorAction Stop
        foreach ($folder in $subfolders) {
            $aclInfo = Get-NtfsAcl -Path $folder.FullName
            $size    = Get-FolderSizeMB -Path $folder.FullName
            $results += [PSCustomObject]@{
                Name     = $folder.Name
                FullPath = $folder.FullName
                Owner    = $aclInfo.Owner
                SizeMB   = $size
                Acl      = $aclInfo.Entries
            }
        }
    } catch {
        $results += [PSCustomObject]@{
            Name     = '(error enumerating subfolders)'
            FullPath = $RootPath
            Owner    = ''
            SizeMB   = ''
            Acl      = @()
        }
    }
    return $results
}

# ---------------------------------------------------------------------------
# Collect data
# ---------------------------------------------------------------------------

Write-Host "Collecting data..." -ForegroundColor Cyan

$reportTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$serverName = $env:COMPUTERNAME

$shares = @(
    [PSCustomObject]@{
        Label     = 'DEM Config Share (demcfg$)'
        Path      = $ConfigSharePath
        ShareName = Get-ShareName $ConfigSharePath
        Purpose   = 'FlexEngine configuration files - read-only for VDI desktops'
    },
    [PSCustomObject]@{
        Label     = 'DEM Profile Share (demprf$)'
        Path      = $ProfileSharePath
        ShareName = Get-ShareName $ProfileSharePath
        Purpose   = 'Per-user profile archives - read/write'
    }
)

if ($RedirSharePath) {
    $shares += [PSCustomObject]@{
        Label     = 'Folder Redirection Share (hzredir$)'
        Path      = $RedirSharePath
        ShareName = Get-ShareName $RedirSharePath
        Purpose   = 'Folder redirection targets (Documents, Downloads, etc.)'
    }
}

foreach ($share in $shares) {
    Write-Host "  Processing $($share.Label)..." -ForegroundColor Gray
    $rootAclInfo = Get-NtfsAcl -Path $share.Path
    $share | Add-Member -NotePropertyName SmbPerms   -NotePropertyValue @(Get-SmbPermissions -ShareName $share.ShareName)
    $share | Add-Member -NotePropertyName RootOwner  -NotePropertyValue $rootAclInfo.Owner
    $share | Add-Member -NotePropertyName RootAcl    -NotePropertyValue @($rootAclInfo.Entries)
    $share | Add-Member -NotePropertyName Subfolders -NotePropertyValue @(Get-SubfolderReport -RootPath $share.Path)
}

# ---------------------------------------------------------------------------
# HTML table builders
# ---------------------------------------------------------------------------

function Build-AclTable {
    param($AclEntries)
    if (-not $AclEntries -or @($AclEntries).Count -eq 0) {
        return '<p class="empty">No ACL entries found.</p>'
    }
    $rows = foreach ($entry in $AclEntries) {
        $srcBadge  = if ($entry.Inherited) {
            '<span class="badge badge-gray">Inherited</span>'
        } else {
            '<span class="badge badge-teal">Explicit</span>'
        }
        $typeBadge = if ($entry.Type -eq 'Allow') {
            '<span class="badge badge-allow">Allow</span>'
        } else {
            '<span class="badge badge-deny">Deny</span>'
        }
        "<tr>
            <td>$(Encode-Html($entry.Identity))</td>
            <td>$(Encode-Html($entry.Rights))</td>
            <td>$typeBadge</td>
            <td>$srcBadge</td>
            <td>$(Encode-Html($entry.Inheritance))</td>
        </tr>"
    }
    return @"
<table class="acl-table">
    <thead><tr>
        <th>Identity</th><th>Rights</th><th>Type</th><th>Source</th><th>Inheritance</th>
    </tr></thead>
    <tbody>$($rows -join "")</tbody>
</table>
"@
}

function Build-SmbTable {
    param($SmbEntries)
    if (-not $SmbEntries -or @($SmbEntries).Count -eq 0) {
        return '<p class="empty">No SMB permissions found.</p>'
    }
    $rows = foreach ($entry in $SmbEntries) {
        $typeBadge = if ($entry.AccessControl -eq 'Allow') {
            '<span class="badge badge-allow">Allow</span>'
        } elseif ($entry.AccessControl -eq 'info') {
            '<span class="badge badge-info">Info</span>'
        } else {
            '<span class="badge badge-deny">Deny</span>'
        }
        "<tr>
            <td>$(Encode-Html($entry.Identity))</td>
            <td>$(Encode-Html($entry.AccessRight))</td>
            <td>$typeBadge</td>
        </tr>"
    }
    return @"
<table class="acl-table">
    <thead><tr>
        <th>Identity</th><th>Access Right</th><th>Type</th>
    </tr></thead>
    <tbody>$($rows -join "")</tbody>
</table>
"@
}

function Build-ShareSection {
    param($Share, [int]$Index)

    $subHtml = foreach ($sub in $Share.Subfolders) {
        $aclTable = Build-AclTable -AclEntries $sub.Acl
        @"
        <div class="subfolder-block">
            <div class="subfolder-header">
                <span class="subfolder-name">$(Encode-Html($sub.Name))</span>
                <span class="subfolder-badges">
                    <span class="badge badge-gray">Owner: $(Encode-Html($sub.Owner))</span>
                    <span class="badge badge-purple">$($sub.SizeMB)</span>
                </span>
                <span class="subfolder-path">$(Encode-Html($sub.FullPath))</span>
            </div>
            $aclTable
        </div>
"@
    }

    if (-not $Share.Subfolders -or @($Share.Subfolders).Count -eq 0) {
        $subHtml = '<p class="empty">No subfolders found.</p>'
    }

    $colorClass = @('card-teal','card-purple','card-blue')[$Index % 3]
    $subCount   = @($Share.Subfolders).Count

    return @"
<div class="share-card $colorClass">
    <div class="share-card-header">
        <div class="share-title">$(Encode-Html($Share.Label))</div>
        <div class="share-meta">
            <span class="meta-item"><strong>Path:</strong> $(Encode-Html($Share.Path))</span>
            <span class="meta-item"><strong>Share name:</strong> $(Encode-Html($Share.ShareName))</span>
            <span class="meta-item"><strong>Owner:</strong> $(Encode-Html($Share.RootOwner))</span>
            <span class="meta-item"><strong>Purpose:</strong> $(Encode-Html($Share.Purpose))</span>
        </div>
    </div>

    <div class="section-group">
        <div class="section-label">SMB Share Permissions</div>
        $(Build-SmbTable -SmbEntries $Share.SmbPerms)
    </div>

    <div class="section-group">
        <div class="section-label">NTFS ACL - Share Root</div>
        $(Build-AclTable -AclEntries $Share.RootAcl)
    </div>

    <div class="section-group">
        <div class="section-label">Subfolders ($subCount found)</div>
        $($subHtml -join "")
    </div>
</div>
"@
}

# ---------------------------------------------------------------------------
# Build summary rows
# ---------------------------------------------------------------------------

$summaryRows = foreach ($share in $shares) {
    $subCount  = @($share.Subfolders).Count
    "<tr>
        <td><strong>$(Encode-Html($share.Label))</strong></td>
        <td>$(Encode-Html($share.Path))</td>
        <td>$(Encode-Html($share.ShareName))</td>
        <td>$(Encode-Html($share.RootOwner))</td>
        <td>$subCount</td>
    </tr>"
}

# ---------------------------------------------------------------------------
# Build share sections
# ---------------------------------------------------------------------------

$shareSections = for ($i = 0; $i -lt $shares.Count; $i++) {
    Build-ShareSection -Share $shares[$i] -Index $i
}

# ---------------------------------------------------------------------------
# Compose HTML
# ---------------------------------------------------------------------------

Write-Host "Building HTML report..." -ForegroundColor Cyan

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>$(Encode-Html($Title))</title>
<style>
    :root {
        --teal:   #1F756C;
        --purple: #805AF7;
        --navy:   #001E60;
        --slate:  #4F6193;
        --gray3:  #8390B3;
        --gray4:  #DBDFEB;
        --gray2:  #F2F2F2;
        --white:  #ffffff;
        --font:   'Segoe UI', Arial, sans-serif;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
        font-family: var(--font);
        font-size: 13px;
        background: #f0f2f7;
        color: #1a1a2e;
        padding: 32px 24px;
    }

    /* Print button */
    .print-btn {
        float: right;
        background: rgba(255,255,255,0.15);
        color: var(--white);
        border: 1px solid rgba(255,255,255,0.4);
        border-radius: 6px;
        padding: 8px 18px;
        font-size: 12px;
        font-family: var(--font);
        cursor: pointer;
        font-weight: 600;
        letter-spacing: 0.3px;
    }
    .print-btn:hover { background: rgba(255,255,255,0.25); }
    @media print { .print-btn { display: none; } }

    /* Header */
    .report-header {
        background: linear-gradient(135deg, var(--navy) 0%, var(--slate) 100%);
        color: var(--white);
        border-radius: 12px;
        padding: 28px 32px;
        margin-bottom: 28px;
    }
    .report-title {
        font-size: 22px;
        font-weight: 700;
        margin-bottom: 8px;
    }
    .report-meta {
        font-size: 12px;
        opacity: 0.8;
        display: flex;
        flex-wrap: wrap;
        gap: 20px;
    }
    .report-meta span { display: flex; align-items: center; gap: 5px; }
    .report-meta span::before { content: '|'; opacity: 0.4; }
    .report-meta span:first-child::before { display: none; }

    /* Summary */
    .summary-card {
        background: var(--white);
        border-radius: 10px;
        padding: 24px;
        margin-bottom: 28px;
        box-shadow: 0 1px 4px rgba(0,0,0,0.08);
    }
    .summary-card h2 {
        font-size: 13px;
        font-weight: 700;
        color: var(--navy);
        text-transform: uppercase;
        letter-spacing: 0.6px;
        margin-bottom: 16px;
        padding-bottom: 10px;
        border-bottom: 2px solid var(--teal);
    }

    /* Share cards */
    .share-card {
        background: var(--white);
        border-radius: 10px;
        margin-bottom: 28px;
        box-shadow: 0 1px 4px rgba(0,0,0,0.08);
        overflow: hidden;
        border-top: 4px solid var(--teal);
    }
    .card-teal   { border-top-color: var(--teal); }
    .card-purple { border-top-color: var(--purple); }
    .card-blue   { border-top-color: var(--slate); }

    .share-card-header {
        padding: 18px 24px;
        background: var(--gray2);
        border-bottom: 1px solid var(--gray4);
    }
    .share-title {
        font-size: 15px;
        font-weight: 700;
        color: var(--navy);
        margin-bottom: 8px;
    }
    .share-meta {
        display: flex;
        flex-wrap: wrap;
        gap: 20px;
        font-size: 12px;
        color: var(--slate);
    }
    .meta-item strong { color: var(--navy); }

    /* Section groups */
    .section-group {
        padding: 18px 24px;
        border-bottom: 1px solid var(--gray4);
    }
    .section-group:last-child { border-bottom: none; }
    .section-label {
        font-size: 11px;
        font-weight: 700;
        text-transform: uppercase;
        letter-spacing: 0.6px;
        color: var(--slate);
        margin-bottom: 12px;
    }

    /* Subfolder blocks */
    .subfolder-block {
        border: 1px solid var(--gray4);
        border-radius: 8px;
        margin-bottom: 12px;
        overflow: hidden;
    }
    .subfolder-header {
        background: var(--gray2);
        padding: 9px 14px;
        display: flex;
        align-items: center;
        gap: 10px;
        border-bottom: 1px solid var(--gray4);
        flex-wrap: wrap;
    }
    .subfolder-name {
        font-weight: 700;
        color: var(--navy);
        font-size: 13px;
    }
    .subfolder-badges { display: flex; gap: 6px; }
    .subfolder-path {
        font-size: 11px;
        color: var(--gray3);
        margin-left: auto;
        font-family: 'Consolas', monospace;
    }

    /* Tables */
    .acl-table {
        width: 100%;
        border-collapse: collapse;
        font-size: 12px;
    }
    .acl-table thead tr { background: var(--navy); color: var(--white); }
    .acl-table th {
        padding: 8px 12px;
        text-align: left;
        font-weight: 600;
        font-size: 10px;
        text-transform: uppercase;
        letter-spacing: 0.4px;
    }
    .acl-table td {
        padding: 7px 12px;
        border-bottom: 1px solid var(--gray4);
        color: #2c2c3e;
        font-family: 'Consolas', monospace;
        font-size: 11.5px;
        vertical-align: top;
    }
    .acl-table tbody tr:nth-child(even) { background: #fafafa; }
    .acl-table tbody tr:hover { background: #f0f0ff; }
    .acl-table tbody tr:last-child td { border-bottom: none; }
    .summary-table td { font-family: var(--font); font-size: 12px; }
    .summary-table td:nth-child(2),
    .summary-table td:nth-child(3) { font-family: 'Consolas', monospace; font-size: 11px; }

    /* Badges */
    .badge {
        display: inline-block;
        padding: 2px 7px;
        border-radius: 4px;
        font-size: 10px;
        font-weight: 700;
        text-transform: uppercase;
        letter-spacing: 0.3px;
        font-family: var(--font);
    }
    .badge-allow  { background: #e1f5ee; color: #0f6e56; }
    .badge-deny   { background: #fce8e6; color: #c0392b; }
    .badge-teal   { background: #e1f5ee; color: #0f6e56; }
    .badge-gray   { background: var(--gray4); color: var(--slate); }
    .badge-purple { background: #ede9fe; color: #5b21b6; }
    .badge-info   { background: #e0f0ff; color: #1d4ed8; }

    .empty { color: var(--gray3); font-style: italic; font-size: 12px; padding: 6px 0; }

    /* Footer */
    .report-footer {
        text-align: center;
        font-size: 11px;
        color: var(--gray3);
        margin-top: 32px;
        padding-top: 14px;
        border-top: 1px solid var(--gray4);
    }
</style>
</head>
<body>

<div class="report-header">
    <button class="print-btn" onclick="window.print()">Print / Save as PDF</button>
    <div class="report-title">$(Encode-Html($Title))</div>
    <div class="report-meta">
        <span>Server: $serverName</span>
        <span>Generated: $reportTime</span>
        <span>Shares: $($shares.Count)</span>
    </div>
</div>

<div class="summary-card">
    <h2>Summary</h2>
    <table class="acl-table summary-table">
        <thead><tr>
            <th>Share</th>
            <th>Path</th>
            <th>Share Name</th>
            <th>Owner</th>
            <th>Subfolders</th>
        </tr></thead>
        <tbody>$($summaryRows -join "")</tbody>
    </table>
</div>

$($shareSections -join "")

<div class="report-footer">
    Get-DEMShareReport.ps1 * $reportTime * $serverName
</div>

</body>
</html>
"@

# ---------------------------------------------------------------------------
# Write and open
# ---------------------------------------------------------------------------

$html | Out-File -FilePath $OutputPath -Encoding UTF8
Write-Host ""
Write-Host "Report saved to: $OutputPath" -ForegroundColor Green
Write-Host ""

try { Start-Process $OutputPath }
catch { Write-Host "(Could not open automatically - open manually)" -ForegroundColor Yellow }
