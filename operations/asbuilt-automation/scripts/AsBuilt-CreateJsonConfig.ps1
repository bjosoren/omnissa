<#
.SYNOPSIS
    AsBuilt Report - Create JSON Configuration Files

.DESCRIPTION
    Creates JSON configuration files for AsBuiltReport on a network share.
    Run once, or again to reset config to defaults.

    Note: Use UNC paths (\\server\share) instead of drive letters (I:\) to
    avoid issues with mapped network drives in elevated PowerShell sessions.

.NOTES
    Environment: YourOrg / ad.example.com
    Reports:     Horizon, AppVolumes, UAG, vSphere
    Storage:     \\fileserver.domain.local\Install\AsBuilt\Config\
#>

[CmdletBinding()]
param(
    [string]$ConfigDir = '\\fileserver.domain.local\Install\AsBuilt\Config'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Report config definitions -----------------------------------------------
$ReportConfigs = @(
    @{ Report = 'VMware.Horizon';    Filename = 'AsBuiltHorizon'    }
    @{ Report = 'VMware.AppVolumes'; Filename = 'AsBuiltAppVolumes' }
    @{ Report = 'VMware.UAG';        Filename = 'AsBuiltUAG'        }
    @{ Report = 'VMware.vSphere';    Filename = 'AsBuiltvSphere'    }
)

# --- Helper functions -------------------------------------------------------
function Write-Step { param([string]$Msg) Write-Host "`n[*] $Msg" -ForegroundColor Cyan }
function Write-OK   { param([string]$Msg) Write-Host "    [OK] $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "    [!]  $Msg" -ForegroundColor Yellow }

# --- Check that required modules are available ------------------------------
Write-Step "Checking modules..."

# Optional diagram modules - Horizon reports still generate without them
$optionalModules = @('PSGraph', 'Diagrammer.Core')

# Required modules - these must load for reports to work
$requiredModules = @(
    'AsBuiltReport.Core'
    'AsBuiltReport.VMware.Horizon'
    'AsBuiltReport.VMware.AppVolumes'
    'AsBuiltReport.VMware.UAG'
    'AsBuiltReport.VMware.vSphere'
)

foreach ($mod in $optionalModules) {
    if (Get-Module -Name $mod -ListAvailable) {
        try {
            Import-Module -Name $mod -ErrorAction Stop -WarningAction SilentlyContinue
            Write-OK "$mod imported (optional)"
        }
        catch { Write-Warn "$mod found but failed to import (diagram features may be unavailable): $_" }
    } else {
        Write-Warn "$mod not installed - diagram features will be unavailable but reports will still generate"
    }
}

foreach ($mod in $requiredModules) {
    if (-not (Get-Module -Name $mod -ListAvailable)) {
        Write-Error "Module not found: $mod - run AsBuilt-Offline.ps1 -Mode Install first."
    }
    Import-Module -Name $mod -ErrorAction Stop -WarningAction SilentlyContinue
    Write-OK "$mod imported"
}

# --- Connect to UNC share if ConfigDir is a network path --------------------
if ($ConfigDir -like '\\*') {
    # Extract the server\share portion (first two path components)
    $uncParts  = $ConfigDir.TrimStart('\') -split '\\'
    $uncRoot   = "\\$($uncParts[0])\$($uncParts[1])"

    Write-Step "Connecting to network share: $uncRoot"
    if (Test-Path $uncRoot) {
        Write-OK "Share already accessible: $uncRoot"
    } else {
        $shareCred = Get-Credential -Message "Credentials for $uncRoot"
        if (-not $shareCred) {
            Write-Error "No credentials provided - cannot access $uncRoot"
        }
        try {
            New-PSDrive -Name 'AsBuiltShare' -PSProvider FileSystem -Root $uncRoot `
                -Credential $shareCred -ErrorAction Stop | Out-Null
            Write-OK "Connected to: $uncRoot"
        }
        catch { Write-Error "Failed to connect to $uncRoot : $_" }
    }
}

# --- Create Config folder ---------------------------------------------------
Write-Step "Checking Config folder: $ConfigDir"
if (-not (Test-Path $ConfigDir)) {
    New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    Write-OK "Created: $ConfigDir"
} else {
    Write-OK "Already exists: $ConfigDir"
}

# --- Generate JSON files ----------------------------------------------------
Write-Step "Generating JSON configuration files..."

foreach ($rc in $ReportConfigs) {
    $jsonFile = Join-Path $ConfigDir "$($rc.Filename).json"

    if (Test-Path $jsonFile) {
        $answer = Read-Host "    '$($rc.Filename).json' already exists. Overwrite? (y/N)"
        if ($answer -notmatch '^[yY]$') {
            Write-Warn "Skipping: $($rc.Filename).json"
            continue
        }
        Remove-Item $jsonFile -Force
    }

    try {
        New-AsBuiltReportConfig -Report $rc.Report `
            -FolderPath $ConfigDir `
            -Filename   $rc.Filename
        Write-OK "Created: $jsonFile"
    }
    catch {
        Write-Warn "ERROR creating $($rc.Filename).json: $_"
    }
}

# --- Summary ----------------------------------------------------------------
Write-Host "`n+==============================================================+" -ForegroundColor Green
Write-Host "|  JSON configuration files ready                              |" -ForegroundColor Green
Write-Host "+==============================================================+" -ForegroundColor Green
Write-Host "`n  Location: $ConfigDir" -ForegroundColor Cyan
Write-Host "`n  Next step: Run AsBuilt-GenerateReports.ps1`n" -ForegroundColor White
