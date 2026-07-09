<#
.SYNOPSIS
    Initialize-PackerSession.ps1
    Run this at the start of each PAW session before executing Packer builds.

    Copies all Packer scripts and installers from the persistent UNC share
    to the local C:\Packer directory, then verifies the environment is ready.

    Uses UNC path directly to ensure compatibility with elevated (Admin)
    PowerShell sessions where mapped drives (I:\) may not be available.

.USAGE
    Run as Administrator:
    powershell -ExecutionPolicy Bypass -File "\\fs-01\install\Scripts\Packer\Initialize-PackerSession.ps1"

    Or if I:\ is already mapped in your session:
    powershell -ExecutionPolicy Bypass -File "I:\Scripts\Packer\Initialize-PackerSession.ps1"
#>

$ErrorActionPreference = "Stop"

# UNC path - works in elevated context regardless of drive mappings
$SourceUNC   = "\\fs-01\install\Scripts\Packer"
$SourceDrive = "I:\Scripts\Packer"
$Destination = "C:\Packer"
$LogFile     = "C:\Packer\init-session.log"

function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    $line = "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Msg"
    Write-Host $line -ForegroundColor $(if ($Level -eq "ERROR") {"Red"} elseif ($Level -eq "WARN") {"Yellow"} else {"Cyan"})
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

Clear-Host
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Packer Session Initializer" -ForegroundColor Green
Write-Host "  PAW -> C:\Packer setup" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""

# -- Check running as admin ----------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: Must run as Administrator." -ForegroundColor Red
    exit 1
}

# -- Resolve source path (UNC preferred, drive letter fallback) ----------------
Write-Host "Resolving source path..." -ForegroundColor Cyan
if (Test-Path $SourceUNC) {
    $Source = $SourceUNC
    Write-Host "  Using UNC: $Source" -ForegroundColor Green
} elseif (Test-Path $SourceDrive) {
    $Source = $SourceDrive
    Write-Host "  Using mapped drive: $Source" -ForegroundColor Yellow
} else {
    Write-Host "ERROR: Cannot reach source at:" -ForegroundColor Red
    Write-Host "  UNC  : $SourceUNC" -ForegroundColor Red
    Write-Host "  Drive: $SourceDrive" -ForegroundColor Red
    Write-Host "Ensure \\fs-01\install is accessible before running." -ForegroundColor Yellow
    exit 1
}

# -- Create destination --------------------------------------------------------
Write-Host "Creating $Destination..." -ForegroundColor Cyan
if (Test-Path $Destination) {
    Write-Host "  Removing existing C:\Packer..." -ForegroundColor Yellow
    Remove-Item -Path $Destination -Recurse -Force
}
New-Item -ItemType Directory -Path $Destination -Force | Out-Null
New-Item -ItemType Directory -Path "$Destination\logs" -Force | Out-Null

# -- Copy all files ------------------------------------------------------------
Write-Host "Copying from $Source to $Destination..." -ForegroundColor Cyan
$startTime = Get-Date
Copy-Item -Path "$Source\*" -Destination $Destination -Recurse -Force
$elapsed = [int]((Get-Date) - $startTime).TotalSeconds
Write-Host "  Copy complete in $elapsed seconds." -ForegroundColor Green

# -- Log file now available ----------------------------------------------------
New-Item -ItemType File -Path $LogFile -Force | Out-Null
Write-Log "Session initialized on $(hostname) by $env:USERNAME"
Write-Log "Source     : $Source"
Write-Log "Destination: $Destination"
Write-Log "Copy time  : $elapsed seconds"

# -- Verify key files ----------------------------------------------------------
Write-Host ""
Write-Host "Verifying key files..." -ForegroundColor Cyan

$requiredFiles = @(
    "horizon-golden-image.pkr.hcl",
    "variables.pkr.hcl",
    "horizon.pkrvars.hcl",
    "http\autounattend.xml",
    "http\setup.ps1",
    "http\Disable-AuditMode.ps1",
    "http\Show-BuildStatus.ps1",
    "http\Wait-ForCheckpoint.ps1",
    "http\OSOT-Optimize-Interactive.ps1",
    "http\OSOT-Generalize-Interactive.ps1",
    "http\OSOT-Finalize-Interactive.ps1",
    "http\w11sysprep.xml",
    "scripts\phase1\02-install-dotnet.ps1",
    "scripts\phase1\03-install-applications.ps1",
    "scripts\phase1\03b-disable-copilot.ps1",
    "scripts\phase2\04-osot-optimize.ps1",
    "scripts\phase2\05-cleanup-appx.ps1",
    "scripts\phase2\06-osot-generalize.ps1",
    "scripts\phase3\07-install-horizon-agent.ps1",
    "scripts\phase3\08-install-dem-agent.ps1",
    "scripts\phase3\09-osot-finalize.ps1",
    "scripts\phase3\10-install-appvolumes-agent.ps1",
    "scripts\phase3\11-final-cleanup.ps1",
    "installers\OmnissaHorizonOSOptimizationTool-x86_64-1.2.2603.23605577104.exe",
    "installers\Omnissa-Horizon-Agent-x86_64-2603-8.18.0-24273927036.exe",
    "installers\Omnissa Dynamic Environment Manager Enterprise 2603 10.19 x64.msi",
    "installers\App Volumes Agent.msi",
    "installers\horizon-agent-settings.txt",
    "installers\sdelete64.exe",
    "installers\Windows 10, 11 and Server 2019, 2022 2026-07-08-085321.json"
)

$missing = @()
foreach ($file in $requiredFiles) {
    $fullPath = Join-Path $Destination $file
    if (Test-Path $fullPath) {
        Write-Log "OK : $file"
    } else {
        Write-Log "MISSING: $file" "WARN"
        $missing += $file
    }
}

if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Host "WARNING: $($missing.Count) file(s) missing from $Destination :" -ForegroundColor Yellow
    $missing | ForEach-Object { Write-Host "  MISSING: $_" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "Copy missing files to $SourceUNC before continuing." -ForegroundColor Yellow
} else {
    Write-Host "  All required files present." -ForegroundColor Green
}


# -- Install Packer plugins via packer init ------------------------------------
Write-Host ""
Write-Host "Installing Packer plugins..." -ForegroundColor Cyan

# Ensure C:\Packer is in PATH before running packer init
$env:PATH += ";C:\Packer"

try {
    Write-Host "  Running: packer init C:\Packer" -ForegroundColor Gray
    $initResult = & "C:\Packer\packer.exe" init "C:\Packer" 2>&1
    $initResult | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Packer plugins installed successfully." -ForegroundColor Green
        Write-Log "packer init succeeded"
    } else {
        Write-Host "  WARNING: packer init failed (exit $LASTEXITCODE)." -ForegroundColor Yellow
        Write-Host "  Ensure the PAW has internet access or run Download-PackerPrerequisites.ps1" -ForegroundColor Yellow
        Write-Log "packer init failed: $LASTEXITCODE" "WARN"
    }
} catch {
    Write-Host "  ERROR: packer init failed: $_" -ForegroundColor Red
    Write-Log "packer init error: $_" "ERROR"
}

# -- Add C:\Packer to PATH (session + machine level)
$env:PATH += ";C:\Packer"
$machinePath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
if ($machinePath -notlike "*C:\Packer*") {
    [Environment]::SetEnvironmentVariable("PATH", "$machinePath;C:\Packer", "Machine")
    Write-Log "Added C:\Packer to machine PATH"
    Write-Host "  C:\Packer added to machine PATH (permanent)." -ForegroundColor Green
} else {
    Write-Log "C:\Packer already in machine PATH"
    Write-Host "  C:\Packer already in machine PATH." -ForegroundColor Green
}
# Refresh PATH in current session immediately
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
Write-Log "Session PATH refreshed"

# -- Create log subdirectories for VM log downloads
New-Item -ItemType Directory -Path "C:\Packer\logs\osot-optimize" -Force | Out-Null
New-Item -ItemType Directory -Path "C:\Packer\logs\osot-finalize" -Force | Out-Null
New-Item -ItemType Directory -Path "C:\Packer\logs\horizon-agent-vminst" -Force | Out-Null
Write-Log "Log subdirectories created"

# -- Check Packer executable ---------------------------------------------------
Write-Host ""
Write-Host "Checking Packer..." -ForegroundColor Cyan
$packerExe = $null

# Check PATH first
$packerInPath = Get-Command packer -ErrorAction SilentlyContinue
if ($packerInPath) {
    $packerExe = $packerInPath.Source
} else {
    # Check common locations
    $candidates = @(
        "C:\Packer\packer.exe",
        "$Destination\packer.exe",
        "C:\Program Files\packer\packer.exe",
        "C:\tools\packer\packer.exe"
    )
    $packerExe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($packerExe) {
        $env:PATH += ";$(Split-Path $packerExe)"
        Write-Log "Packer added to session PATH: $packerExe" "WARN"
    }
}

if ($packerExe) {
    $packerVersion = & packer version 2>&1 | Select-Object -First 1
    Write-Host "  $packerVersion" -ForegroundColor Green
    Write-Log "Packer: $packerExe ($packerVersion)"
} else {
    Write-Host "  WARNING: packer.exe not found." -ForegroundColor Yellow
    Write-Host "  Copy packer.exe to $Destination\ or install it." -ForegroundColor Yellow
    Write-Log "Packer not found" "WARN"
}

# -- Set up WinRM credential variables -----------------------------------------
Write-Host ""
Write-Host "Setting up WinRM credential variables..." -ForegroundColor Cyan
$pass = ConvertTo-SecureString "SommerFerie2020!" -AsPlainText -Force
$global:cred = New-Object System.Management.Automation.PSCredential("Administrator", $pass)
$global:sessionOpts = New-PSSessionOption -SkipCACheck -SkipCNCheck
Write-Host "  `$cred and `$sessionOpts are ready." -ForegroundColor Green

# -- Summary -------------------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Session ready!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Working directory : $Destination" -ForegroundColor White
Write-Host "Source share      : $SourceUNC" -ForegroundColor White
Write-Host "Log file          : $LogFile" -ForegroundColor White
Write-Host ""
Write-Host "To run a build:" -ForegroundColor White
Write-Host "  cd C:\Packer" -ForegroundColor Yellow
Write-Host "  packer build -on-error=abort -var-file=`"C:\Packer\horizon.pkrvars.hcl`" `"C:\Packer`" 2>&1 | Tee-Object -FilePath `"C:\Packer\logs\packer-build.log`"" -ForegroundColor Yellow
Write-Host ""
Write-Host "WinRM helper (replace IP):" -ForegroundColor White
Write-Host "  Invoke-Command -ComputerName <VM-IP> -Credential `$cred -Authentication Basic -SessionOption `$sessionOpts -ScriptBlock { whoami }" -ForegroundColor Yellow
Write-Host ""
