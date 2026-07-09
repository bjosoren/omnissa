<#
.SYNOPSIS
    Download-PackerPrerequisites.ps1
    Downloads Packer and required plugins to \\fs-01\install\Scripts\Packer\

    Run this once whenever you need to update Packer or plugins.
    The Initialize-PackerSession.ps1 script will then copy everything to C:\Packer.

    Prerequisites downloaded:
      - packer.exe (1.15.4)
      - packer-plugin-vsphere (github.com/vmware/vsphere >= 2.2.0)
      - packer-plugin-windows-update (github.com/rgl/windows-update >= 0.16.0)

.USAGE
    powershell -ExecutionPolicy Bypass -File "\\fs-01\install\Scripts\Packer\Download-PackerPrerequisites.ps1"
#>

$ErrorActionPreference = "Stop"

# -- Configuration ------------------------------------------------------------
$PackerVersion         = "1.15.4"
$VSpherePluginVersion  = "2.2.0"
$WinUpdatePluginVersion = "0.16.0"

$DestDir     = "\\fs-01\install\Scripts\Packer"
$TempDir     = "C:\Windows\Temp\PackerDownload"
$LogFile     = "$TempDir\download.log"

# Plugin install path (where packer init stores plugins on Windows)
# Packer looks here: %APPDATA%\packer.d\plugins
$PluginDir   = "$env:APPDATA\packer.d\plugins"

function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    $line = "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Msg"
    Write-Host $line -ForegroundColor $(if ($Level -eq "ERROR") {"Red"} elseif ($Level -eq "WARN") {"Yellow"} elseif ($Level -eq "OK") {"Green"} else {"Cyan"})
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

Clear-Host
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Packer Prerequisites Downloader" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""

# -- Check destination reachable ----------------------------------------------
if (-not (Test-Path $DestDir)) {
    Write-Host "ERROR: Cannot reach $DestDir" -ForegroundColor Red
    exit 1
}

# -- Create temp dir ----------------------------------------------------------
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
New-Item -ItemType File -Path $LogFile -Force | Out-Null
Write-Log "Starting download to $DestDir"
Write-Log "Packer version        : $PackerVersion"
Write-Log "vSphere plugin version: $VSpherePluginVersion"
Write-Log "WinUpdate plugin ver  : $WinUpdatePluginVersion"

# -- Helper: Download with progress -------------------------------------------
function Download-File {
    param([string]$Url, [string]$OutFile, [string]$Label)
    Write-Log "Downloading: $Label"
    Write-Host "  -> $Url" -ForegroundColor Gray
    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($Url, $OutFile)
        Write-Log "OK: $Label ($([int]((Get-Item $OutFile).Length / 1MB)) MB)" "OK"
    } catch {
        Write-Log "FAILED: $Label - $_" "ERROR"
        throw
    }
}

# -- Helper: Extract zip ------------------------------------------------------
function Extract-Zip {
    param([string]$ZipFile, [string]$DestFolder)
    Write-Log "Extracting: $ZipFile -> $DestFolder"
    New-Item -ItemType Directory -Path $DestFolder -Force | Out-Null
    Expand-Archive -Path $ZipFile -DestinationPath $DestFolder -Force
}

# =============================================================================
# 1. PACKER EXE
# =============================================================================
Write-Host ""
Write-Host "[ 1/3 ] Downloading Packer $PackerVersion..." -ForegroundColor Cyan

$packerZip = "$TempDir\packer_${PackerVersion}_windows_amd64.zip"
$packerUrl = "https://releases.hashicorp.com/packer/${PackerVersion}/packer_${PackerVersion}_windows_amd64.zip"

Download-File -Url $packerUrl -OutFile $packerZip -Label "packer.exe"
Extract-Zip -ZipFile $packerZip -DestFolder "$TempDir\packer"

# Copy to share
$packerDest = "$DestDir\packer.exe"
Copy-Item "$TempDir\packer\packer.exe" $packerDest -Force
Write-Log "packer.exe copied to $packerDest" "OK"

# =============================================================================
# 2. VSPHERE PLUGIN
# =============================================================================
Write-Host ""
Write-Host "[ 2/3 ] Downloading vSphere plugin v$VSpherePluginVersion..." -ForegroundColor Cyan

$vsphereZip  = "$TempDir\packer-plugin-vsphere_v${VSpherePluginVersion}_x5.0_windows_amd64.zip"
$vsphereUrl  = "https://github.com/vmware/packer-plugin-vsphere/releases/download/v${VSpherePluginVersion}/packer-plugin-vsphere_v${VSpherePluginVersion}_x5.0_windows_amd64.zip"
$vsphereBin  = "packer-plugin-vsphere_v${VSpherePluginVersion}_x5.0_windows_amd64.exe"
$vspherePluginDest = "$PluginDir\github.com\vmware\vsphere"

Download-File -Url $vsphereUrl -OutFile $vsphereZip -Label "packer-plugin-vsphere"
Extract-Zip -ZipFile $vsphereZip -DestFolder "$TempDir\vsphere"

# Install to packer plugin dir
New-Item -ItemType Directory -Path $vspherePluginDest -Force | Out-Null
Copy-Item "$TempDir\vsphere\$vsphereBin" "$vspherePluginDest\$vsphereBin" -Force

# Also copy to share for portability
New-Item -ItemType Directory -Path "$DestDir\plugins\github.com\vmware\vsphere" -Force | Out-Null
Copy-Item "$TempDir\vsphere\$vsphereBin" "$DestDir\plugins\github.com\vmware\vsphere\$vsphereBin" -Force
Write-Log "vSphere plugin installed to $vspherePluginDest" "OK"

# =============================================================================
# 3. WINDOWS-UPDATE PLUGIN
# =============================================================================
Write-Host ""
Write-Host "[ 3/3 ] Downloading windows-update plugin v$WinUpdatePluginVersion..." -ForegroundColor Cyan

$wuZip  = "$TempDir\packer-plugin-windows-update_v${WinUpdatePluginVersion}_x5.0_windows_amd64.zip"
$wuUrl  = "https://github.com/rgl/packer-plugin-windows-update/releases/download/v${WinUpdatePluginVersion}/packer-plugin-windows-update_v${WinUpdatePluginVersion}_x5.0_windows_amd64.zip"
$wuBin  = "packer-plugin-windows-update_v${WinUpdatePluginVersion}_x5.0_windows_amd64.exe"
$wuPluginDest = "$PluginDir\github.com\rgl\windows-update"

Download-File -Url $wuUrl -OutFile $wuZip -Label "packer-plugin-windows-update"
Extract-Zip -ZipFile $wuZip -DestFolder "$TempDir\windows-update"

# Install to packer plugin dir
New-Item -ItemType Directory -Path $wuPluginDest -Force | Out-Null
Copy-Item "$TempDir\windows-update\$wuBin" "$wuPluginDest\$wuBin" -Force

# Also copy to share
New-Item -ItemType Directory -Path "$DestDir\plugins\github.com\rgl\windows-update" -Force | Out-Null
Copy-Item "$TempDir\windows-update\$wuBin" "$DestDir\plugins\github.com\rgl\windows-update\$wuBin" -Force
Write-Log "windows-update plugin installed to $wuPluginDest" "OK"

# =============================================================================
# CLEANUP
# =============================================================================
Write-Host ""
Write-Host "Cleaning up temp files..." -ForegroundColor Cyan
Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue

# =============================================================================
# VERIFY
# =============================================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Verification" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green

# Check packer.exe
if (Test-Path "$DestDir\packer.exe") {
    $ver = & "$DestDir\packer.exe" version 2>&1 | Select-Object -First 1
    Write-Host "  packer.exe    : $ver" -ForegroundColor Green
} else {
    Write-Host "  packer.exe    : NOT FOUND" -ForegroundColor Red
}

# Check plugins on share
$vsphereShare = "$DestDir\plugins\github.com\vmware\vsphere\$vsphereBin"
if (Test-Path $vsphereShare) {
    Write-Host "  vsphere plugin: OK ($vsphereShare)" -ForegroundColor Green
} else {
    Write-Host "  vsphere plugin: NOT FOUND" -ForegroundColor Red
}

$wuShare = "$DestDir\plugins\github.com\rgl\windows-update\$wuBin"
if (Test-Path $wuShare) {
    Write-Host "  windows-update: OK ($wuShare)" -ForegroundColor Green
} else {
    Write-Host "  windows-update: NOT FOUND" -ForegroundColor Red
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Done!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor White
Write-Host "  1. Run Initialize-PackerSession.ps1 on the PAW" -ForegroundColor Yellow
Write-Host "  2. cd C:\Packer && packer init ." -ForegroundColor Yellow
Write-Host "  3. packer build -on-error=abort -var-file=C:\Packer\horizon.pkrvars.hcl C:\Packer" -ForegroundColor Yellow
Write-Host ""
