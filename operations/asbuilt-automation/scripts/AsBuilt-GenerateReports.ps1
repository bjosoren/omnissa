<#
.SYNOPSIS
    AsBuilt Report - Generate Reports Automatically

.DESCRIPTION
    Generates As Built reports for Horizon, App Volumes, UAG and vSphere.
    Reports are stored at \\fileserver.domain.local\Install\AsBuilt\AsBuiltReports\ med tidsstempel in filnavn.

    Merk: Bruk UNC-sti (\\server\share) fremfor stasjonsbokstav (I:\) for a
    avoid issues with mapped network drives in elevated PowerShell sessions.

.PARAMETER SkipHorizon
    Skip the Horizon report.

.PARAMETER SkipAppVolumes
    Skip the App Volumes report.

.PARAMETER SkipUAG
    Skip the UAG report.

.PARAMETER Format
    Report format: Html, Word, Text or combination.
    Default: Html

.EXAMPLE
    # Generate all reports
    .\AsBuilt-GenerateReports.ps1

    # Kun Horizon og UAG, in HTML og Word
    .\AsBuilt-GenerateReports.ps1 -SkipAppVolumes -Format Html,Word

    # Run without confirmation prompt (e.g. scheduled task)
    .\AsBuilt-GenerateReports.ps1 -NonInteractive

.NOTES
    Environment: YourOrg / ad.example.com
    Reports:     Horizon, AppVolumes, UAG, vSphere
    Storage:     \\fileserver.domain.local\Install\AsBuilt\AsBuiltReports\<type>\
    Credentials: Prompted at runtime (Get-Credential)
#>

[CmdletBinding()]
param(
    [switch]$SkipHorizon,
    [switch]$SkipAppVolumes,
    [switch]$SkipUAG,
    [switch]$SkipvSphere,

    [ValidateSet('Html','Word','Text')]
    [string[]]$Format = @('Html'),

    [switch]$NonInteractive,

    # Paths - change here if needed
    [string]$BaseReportDir = '\\fileserver.domain.local\Install\AsBuilt\AsBuiltReports',
    [string]$ConfigDir     = '\\fileserver.domain.local\Install\AsBuilt\Config'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- PS version check -------------------------------------------------------
$psVersion = $PSVersionTable.PSVersion
Write-Host "`n[i] Windows PowerShell version: $($psVersion.Major).$($psVersion.Minor)" -ForegroundColor Gray
if ($psVersion.Major -lt 5 -or ($psVersion.Major -eq 5 -and $psVersion.Minor -lt 1)) {
    Write-Error "Requires minimum Windows PowerShell 5.1. Please install a newer version."
    exit 1
}
if ($psVersion.Major -lt 7) {
    Write-Host "[i] PS5.1 detected - using AsBuiltReport.VMware.vSphere v1.3.5 (last PS5.1-compatible version)" -ForegroundColor Yellow
    Write-Host "[i] VMware.Sdk.Srm warning during PowerCLI import can be ignored - does not affect reports" -ForegroundColor Yellow
}

# --- Timestamp for filenames ------------------------------------------------
$Timestamp = Get-Date -Format 'yyyy-MM-dd_HHmm'

# --- Report definitions -----------------------------------------------------
# Target: Connection Server used for Horizon.
# AppVolumes and UAG have their own FQDNs - adjust as needed.
$Reports = @(
    @{
        Name       = 'Horizon'
        Report     = 'VMware.Horizon'
        Target     = 'horizon-cs.domain.local'
        ConfigFile = Join-Path $ConfigDir 'AsBuiltHorizon.json'
        OutputDir  = Join-Path $BaseReportDir 'Horizon'
        Skip            = $SkipHorizon
        Module          = 'AsBuiltReport.VMware.Horizon'
        CredentialLabel = 'Horizon Connection Server'
    },
    @{
        Name       = 'AppVolumes'
        Report     = 'VMware.AppVolumes'
        Target     = 'appvolumes.domain.local'
        ConfigFile = Join-Path $ConfigDir 'AsBuiltAppVolumes.json'
        OutputDir  = Join-Path $BaseReportDir 'AppVolumes'
        Skip            = $SkipAppVolumes
        Module          = 'AsBuiltReport.VMware.AppVolumes'
        CredentialLabel = 'App Volumes Manager'
    },
    @{
        Name       = 'UAG'
        Report     = 'VMware.UAG'
        Target     = 'uag.example.com'
        ConfigFile = Join-Path $ConfigDir 'AsBuiltUAG.json'
        OutputDir  = Join-Path $BaseReportDir 'UAG'
        Skip            = $SkipUAG
        Module          = 'AsBuiltReport.VMware.UAG'
        CredentialLabel = 'Unified Access Gateway'
    },
    @{
        Name       = 'vSphere'
        Report     = 'VMware.vSphere'
        Target     = 'vcenter.domain.local'
        ConfigFile = Join-Path $ConfigDir 'AsBuiltvSphere.json'
        OutputDir  = Join-Path $BaseReportDir 'vSphere'
        Skip            = $SkipvSphere
        Module          = 'AsBuiltReport.VMware.vSphere'
        CredentialLabel = 'vCenter Server'
    }
)

# --- Helper functions -------------------------------------------------------
function Write-Step  { param([string]$Msg) Write-Host "`n[*] $Msg" -ForegroundColor Cyan }
function Write-OK    { param([string]$Msg) Write-Host "    [OK] $Msg" -ForegroundColor Green }
function Write-Warn  { param([string]$Msg) Write-Host "    [!]  $Msg" -ForegroundColor Yellow }
function Write-Fail  { param([string]$Msg) Write-Host "    [X] $Msg" -ForegroundColor Red }

# --- Connect to UNC share if paths are network paths ------------------------
$uncPathsToCheck = @($BaseReportDir, $ConfigDir) | Where-Object { $_ -like '\\*' } |
    ForEach-Object { $p = $_.TrimStart('\') -split '\\'; "\\$($p[0])\$($p[1])" } |
    Select-Object -Unique

foreach ($uncRoot in $uncPathsToCheck) {
    if (-not (Test-Path $uncRoot)) {
        Write-Host "`n[*] Connecting to network share: $uncRoot" -ForegroundColor Cyan
        $shareCred = Get-Credential -Message "Credentials for $uncRoot"
        if (-not $shareCred) { Write-Error "No credentials provided - cannot access $uncRoot" }
        try {
            New-PSDrive -Name "AsBuiltShare$(Get-Random -Maximum 999)" -PSProvider FileSystem `
                -Root $uncRoot -Credential $shareCred -ErrorAction Stop | Out-Null
            Write-Host "    [OK] Connected to: $uncRoot" -ForegroundColor Green
        }
        catch { Write-Error "Failed to connect to $uncRoot : $_" }
    }
}

# --- Banner -----------------------------------------------------------------
Write-Host "`n+==============================================================+" -ForegroundColor Magenta
Write-Host "|  AsBuilt Report - Automated report generation               |" -ForegroundColor Magenta
Write-Host "|  Timestamp:   $Timestamp                              |" -ForegroundColor Magenta
Write-Host "+==============================================================+" -ForegroundColor Magenta

# --- Import modules ---------------------------------------------------------
Write-Step "Importing modules..."

# Optional diagram modules - load if available, skip silently if not
foreach ($optMod in @('PSGraph', 'Diagrammer.Core')) {
    if (Get-Module -Name $optMod -ListAvailable) {
        try {
            Import-Module -Name $optMod -ErrorAction Stop -WarningAction SilentlyContinue
            Write-OK "$optMod imported (optional)"
        }
        catch { Write-Warn "$optMod failed to import - diagram features unavailable" }
    }
}

$modulesToLoad = @('AsBuiltReport.Core')
foreach ($r in $Reports) {
    if (-not $r['Skip']) { $modulesToLoad += $r['Module'] }
}
$modulesToLoad = $modulesToLoad | Select-Object -Unique

foreach ($mod in $modulesToLoad) {
    try {
        Import-Module -Name $mod -ErrorAction Stop -WarningAction SilentlyContinue
        Write-OK "$mod"
    }
    catch {
        Write-Fail "Could not load $mod - aborting. Run AsBuilt-Offline.ps1 -Mode Install."
        exit 1
    }
}

# --- Validate config files --------------------------------------------------
Write-Step "Validating JSON configuration files..."
$missingConfig = $false
foreach ($r in ($Reports | Where-Object { -not $_['Skip'] })) {
    if (-not (Test-Path $r['ConfigFile'])) {
        Write-Fail "Missing: $($r['ConfigFile'])"
        $missingConfig = $true
    } else {
        Write-OK "Found: $($r['ConfigFile'])"
    }
}
if ($missingConfig) {
    Write-Host "`n  Run AsBuilt-CreateJsonConfig.ps1 first to create missing files.`n" -ForegroundColor Yellow
    exit 1
}

# --- Credentials (one per report) -------------------------------------------
Write-Step "Collecting credentials..."
Write-Host "    You will be prompted for credentials for each report separately." -ForegroundColor Gray

$activeReportsForCreds = $Reports | Where-Object { -not $_['Skip'] }
foreach ($r in $activeReportsForCreds) {
    $cred = Get-Credential -Message "Credentials for $($r['CredentialLabel']) ($($r['Target']))"
    if (-not $cred) {
        Write-Fail "No credentials provided for $($r['Name']) - aborting."
        exit 1
    }
    $r['Credential'] = $cred
    Write-OK "$($r['Name']): $($cred.UserName)"
}


# --- Pre-run summary --------------------------------------------------------
$activeReports = $Reports | Where-Object { -not $_['Skip'] }
Write-Host "`n  Reports that will be generated:" -ForegroundColor White
foreach ($r in $activeReports) {
    Write-Host "    * $($r['Name'].PadRight(12)) -> $($r['Target'])  [$($r['Credential'].UserName)]" -ForegroundColor Gray
}
Write-Host "  Format: $($Format -join ', ')" -ForegroundColor Gray
Write-Host "  Output: $BaseReportDir\<type>\`n" -ForegroundColor Gray

if (-not $NonInteractive) {
    $confirm = Read-Host "  Start report generation? (Y/n)"
    if ($confirm -match '^[nN]$') {
        Write-Host "  Aborted.`n" -ForegroundColor Yellow
        exit 0
    }
}

# --- Generate reports -------------------------------------------------------
$Results      = @()
$reportList   = @($activeReports)   # Convert to array so we can use index
$pauseSeconds = 15                  # Seconds between reports (adjust as needed)

for ($i = 0; $i -lt $reportList.Count; $i++) {
    $r = $reportList[$i]

    Write-Step "[$($i+1)/$($reportList.Count)] Generating $($r['Name']) report against $($r['Target'])..."

    # Sikre at output-mappe finnes
    if (-not (Test-Path $r['OutputDir'])) {
        New-Item -ItemType Directory -Path $r['OutputDir'] -Force | Out-Null
        Write-OK "Created folder: $($r['OutputDir'])"
    }

    $startTime = Get-Date
    try {
        New-AsBuiltReport `
            -Report               $r['Report'] `
            -Target               $r['Target'] `
            -Credential           $r['Credential'] `
            -Format               $Format `
            -OutputFolderPath     $r['OutputDir'] `
            -ReportConfigFilePath $r['ConfigFile'] `
            -Timestamp `
            -Verbose

        $duration = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)

        # Sjekk at filer faktisk ble opprettet
        $generatedFiles = @(Get-ChildItem -Path $r['OutputDir'] -File |
            Where-Object { $_.LastWriteTime -gt $startTime } |
            Sort-Object LastWriteTime -Descending)

        if ($generatedFiles.Count -eq 0) {
            throw "No report files found in $($r['OutputDir']) after generation."
        }

        Write-OK "$($r['Name']) completed in $duration min - $($generatedFiles.Count) file(s) created:"
        foreach ($f in $generatedFiles) {
            Write-Host "       -> $($f.FullName)  ($([math]::Round($f.Length/1KB, 1)) KB)" -ForegroundColor DarkGreen
        }

        $Results += [PSCustomObject]@{
            Rapport = $r['Name']
            Status  = 'OK'
            Filer   = $generatedFiles.Count
            Tid     = "$duration min"
            Mappe   = $r['OutputDir']
        }
    }
    catch {
        $duration = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
        Write-Fail "$($r['Name']) failed after $duration min: $_"
        $Results += [PSCustomObject]@{
            Rapport = $r['Name']
            Status  = "ERROR: $_"
            Filer   = 0
            Tid     = "$duration min"
            Mappe   = $r['OutputDir']
        }
    }

    # Pause between reports (not after the last one)
    if ($i -lt ($reportList.Count - 1)) {
        Write-Host "`n  Waiting $pauseSeconds seconds before next report..." -ForegroundColor Yellow
        for ($s = $pauseSeconds; $s -gt 0; $s--) {
            Write-Host -NoNewline "`r  Starting in $s seconds...   "
            Start-Sleep -Seconds 1
        }
        Write-Host "`r  Starting next report...              " -ForegroundColor Cyan
    }
}

# --- Final summary ----------------------------------------------------------
Write-Host "`n+==============================================================+" -ForegroundColor Green
Write-Host "|  DONE - Summary                                       |" -ForegroundColor Green
Write-Host "+==============================================================+" -ForegroundColor Green

$Results | Format-Table -AutoSize | Out-String | Write-Host

Write-Host "  Reports saved to: $BaseReportDir`n" -ForegroundColor Cyan
