<#
.SYNOPSIS
    Upgrades Omnissa App Volumes Manager to v2603 (v4.21.0_10042026).

.DESCRIPTION
    Automates the App Volumes Manager upgrade process via PowerCLI and PSRemoting.
    The script performs the following steps:
        1.  Connects to vCenter using stored credentials
        2.  Removes any existing snapshots on the target VM
        3.  Gracefully shuts down the VM
        4.  Takes a pre-upgrade snapshot
        5.  Powers on the VM and waits for WinRM to become available
        6.  Backs up Nginx certificates and configuration
        7.  Copies and installs the App Volumes Manager MSI
        8.  Restores Nginx certificates and configuration
        9.  Performs cleanup (removes temp files and pre-upgrade snapshot)
        10. Disconnects from vCenter

.PREREQUISITES
    - VMware PowerCLI installed on the management server
    - CredSSP enabled on both the management server and the AVM server
      (Enable-WSManCredSSP -Role Client -DelegateComputer <AVM FQDN>)
      (Enable-WSManCredSSP -Role Server  -- on the AVM)
    - vCenter credentials stored with New-VICredentialStoreItem:
        New-VICredentialStoreItem -User <user> -Password <pass> -Host <vcenter fqdn> -File <path>.xml
    - App Volumes admin credentials stored with Export-CliXml:
        $cred = Get-Credential
        $cred | Export-CliXml -Path "C:\Credentials\appvol_admin.xml"
    - App Volumes Manager 2603 ISO copied to C:\Install\ on the management host
      (ISO must be on a local drive — mounting from network/mapped drives is unreliable)

.NOTES
    Author  : Bjørn Sørensen
    Version : 2603 (v4.21.0_10042026)
    Blog    : https://tech.iot-it.no
    GitHub  : https://github.com/bjosoren/omnissa/blob/main/upgrades/appvolumes/2603/Upgrade-AppVolumesManager-2603.ps1

    Run this script once per AVM node. In a multi-node environment,
    follow Omnissa rolling upgrade guidelines before proceeding to the next node:
    https://docs.omnissa.com/bundle/AppVolumesInstallGuideV2312/page/ConsiderationsforPerformingRollingUpgrades.html
#>

# ============================================================
# CONFIGURATION — Update these values before running
# ============================================================

$vCenterServer       = "vcenter.yourdomain.com"
$vCenterCredFile     = "C:\Credentials\vcenter_creds.xml"  # Store on local C: drive, not a network share

$avmHostname         = "avm01.yourdomain.com"    # Must match the VM name in vCenter (FQDN)
$avmCredFile         = "C:\Credentials\appvol_admin.xml"

$avmIsoPath          = "C:\Install\Omnissa_App_Volumes_v4.21.0_10042026.ISO"  # Must be on local C: drive — ISO mounting does not work reliably from network/mapped drives
$avmMsiName          = "Installation\Manager\App Volumes Manager.msi"   # Path to MSI inside the ISO

$avmVendor           = "Omnissa"
$avmProduct          = "App Volumes Manager"
$avmVersion          = "4.21.0_10042026"
$avmExpectedVersion  = "4.21.0"           # Partial match — /app_volumes/version response must contain this string

$snapshotName        = "Pre-Upgrade-AVM-2603"
$installDir          = "C:\Install"             # Temp working directory on the AVM
$transcriptDir       = "C:\Logs\AppVolumes"   # Must exist or will be created; kept on local C: drive

# Nginx paths (these are typically static across AVM versions)
$nginxConfDir        = "C:\Program Files (x86)\CloudVolumes\Manager\nginx\conf"
# nginx.conf is always backed up. Certificate files are discovered dynamically at runtime
# since filenames vary between installations (e.g. avm-cert.crt, server.crt, custom names).
# All .crt and .key files found in $nginxConfDir will be included automatically.
$nginxStaticFiles    = @("nginx.conf")

# How long (seconds) to wait between WinRM polling attempts after power-on / reboot
$winrmPollInterval   = 15
$winrmTimeout        = 300   # Give up after this many seconds

# ============================================================
# TRANSCRIPT
# ============================================================

if (-not (Test-Path $transcriptDir)) {
    New-Item -Path $transcriptDir -ItemType Directory -Force | Out-Null
}
$transcriptFile = Join-Path $transcriptDir ("Upgrade-AppVolumesManager-{0}-{1}.log" -f
    $avmHostname.Split(".")[0],
    (Get-Date -Format "yyyyMMdd_HHmmss"))

Start-Transcript -Path $transcriptFile -Append
Write-Verbose "Transcript started: $transcriptFile" -Verbose

# ============================================================
# FUNCTIONS
# ============================================================

function Wait-ForWinRM {
    param(
        [string]$ComputerName,
        [System.Management.Automation.PSCredential]$Credential,
        [int]$TimeoutSeconds = 300,
        [int]$PollIntervalSeconds = 15
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Write-Verbose "Waiting for WinRM on $ComputerName (timeout: ${TimeoutSeconds}s)..." -Verbose
    while ((Get-Date) -lt $deadline) {
        try {
            $testSession = New-PSSession -ComputerName $ComputerName `
                                         -Credential $Credential `
                                         -Authentication CredSSP `
                                         -ErrorAction Stop
            Remove-PSSession $testSession
            Write-Verbose "WinRM is available on $ComputerName." -Verbose
            return $true
        } catch {
            Write-Verbose "  Not yet available. Retrying in ${PollIntervalSeconds}s..." -Verbose
            Start-Sleep -Seconds $PollIntervalSeconds
        }
    }
    throw "Timed out waiting for WinRM on $ComputerName after ${TimeoutSeconds} seconds."
}

function Wait-ForVMPowerOff {
    param(
        [string]$VMName,
        [int]$TimeoutSeconds = 180,
        [int]$PollIntervalSeconds = 5
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Write-Verbose "Waiting for '$VMName' to power off..." -Verbose
    while ((Get-Date) -lt $deadline) {
        $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
        if ($vm.PowerState -eq 'PoweredOff') {
            Write-Verbose "'$VMName' is powered off." -Verbose
            return
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
    throw "Timed out waiting for '$VMName' to power off."
}
function Invoke-AVMHealthCheck {
    param(
        [string]$ComputerName,
        [System.Management.Automation.PSCredential]$Credential,
        [string]$ServiceName        = "svmanager",
        [string]$ServiceDisplayName = "App Volumes Manager",
        [string]$ExpectedVersion    = "",          # e.g. "4.21.0" — leave empty to skip version check
        [int]$ApiTimeoutSeconds     = 120,
        [int]$ApiPollIntervalSeconds = 10
    )

    Write-Verbose "--- Health Check: $ComputerName ---" -Verbose
    $healthy = $true

    # --------------------------------------------------------
    # 1. Service check (via remote PSSession)
    # --------------------------------------------------------
    try {
        $svc = Invoke-Command -ComputerName $ComputerName `
                              -Credential $Credential `
                              -Authentication CredSSP `
                              -ScriptBlock {
                                  param($sn)
                                  Get-Service -Name $sn -ErrorAction Stop
                              } -ArgumentList $ServiceName

        if ($svc.Status -eq 'Running') {
            Write-Verbose "[OK] Service '$ServiceDisplayName' ($ServiceName) is Running." -Verbose
        } else {
            Write-Warning "[FAIL] Service '$ServiceDisplayName' ($ServiceName) status: $($svc.Status)"
            $healthy = $false
        }
    } catch {
        Write-Warning "[FAIL] Could not query service '$ServiceName' on ${ComputerName}: $_"
        $healthy = $false
    }

    # --------------------------------------------------------
    # 2 & 3. Web checks — configure SSL trust first (applies to both endpoints)
    # --------------------------------------------------------

    # Suppress SSL certificate errors for self-signed / internal certs.
    # Must be set before any Invoke-WebRequest / Invoke-RestMethod calls.
    if (-not ([System.Management.Automation.PSTypeName]'TrustAllCerts').Type) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCerts : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint sp, X509Certificate cert,
        WebRequest req, int problem) { return true; }
}
"@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCerts
    [System.Net.ServicePointManager]::SecurityProtocol  = [System.Net.SecurityProtocolType]::Tls12

    Write-Verbose "Health check timeout: ${ApiTimeoutSeconds}s / poll interval: ${ApiPollIntervalSeconds}s" -Verbose

    # --------------------------------------------------------
    # 2. Web GUI health check via /health_check
    #    - Recommended App Volumes 4.x health check endpoint (also used by HAProxy)
    #    - Returns HTTP 200 only when AVM is fully healthy (DB connected, services up)
    #    - More reliable than just checking port 443 — a degraded AVM returns non-200
    # --------------------------------------------------------

    $healthCheckUrl = "https://$ComputerName/health_check"
    $deadline       = (Get-Date).AddSeconds($ApiTimeoutSeconds)
    $healthCheckOk  = $false

    Write-Verbose "Polling $healthCheckUrl for up to ${ApiTimeoutSeconds}s..." -Verbose

    while ((Get-Date) -lt $deadline) {
        try {
            $hcResp = Invoke-WebRequest -Uri $healthCheckUrl -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
            if ($hcResp.StatusCode -eq 200) {
                Write-Verbose "[OK] /health_check returned HTTP 200 — AVM is healthy." -Verbose
                $healthCheckOk = $true
                break
            } else {
                Write-Verbose "  /health_check returned HTTP $($hcResp.StatusCode). Retrying in ${ApiPollIntervalSeconds}s..." -Verbose
            }
        } catch {
            Write-Verbose "  /health_check not yet available ($($_.Exception.Message)). Retrying in ${ApiPollIntervalSeconds}s..." -Verbose
        }
        Start-Sleep -Seconds $ApiPollIntervalSeconds
    }

    if (-not $healthCheckOk) {
        Write-Warning "[FAIL] /health_check at $healthCheckUrl did not return HTTP 200 within ${ApiTimeoutSeconds}s."
        $healthy = $false
    }

    # --------------------------------------------------------
    # 3. API version check via /app_volumes/version
    #    - No authentication required (confirmed in Omnissa docs)
    #    - Returns version, configured status, and uptime as JSON
    # --------------------------------------------------------

    $versionUrl = "https://$ComputerName/app_volumes/version"
    $deadline   = (Get-Date).AddSeconds($ApiTimeoutSeconds)
    $apiOk      = $false

    Write-Verbose "Polling $versionUrl for up to ${ApiTimeoutSeconds}s..." -Verbose

    while ((Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-RestMethod -Uri $versionUrl -Method Get -TimeoutSec 10 -ErrorAction Stop

            # The endpoint returns a JSON object. Field names observed across 4.x versions:
            #   .version        — human-readable version string e.g. "4.21.0_10042026"
            #   .internal       — internal build number
            #   .configured     — bool: whether AVM has completed initial configuration
            #   .uptime         — duration since service start
            Write-Verbose "[OK] API responded. Raw version data:" -Verbose
            Write-Verbose ($resp | ConvertTo-Json -Depth 3) -Verbose

            # -- Version match --
            if ($ExpectedVersion -and $resp.version) {
                if ($resp.version -like "*$ExpectedVersion*") {
                    Write-Verbose "[OK] Version verified: $($resp.version) matches expected '$ExpectedVersion'." -Verbose
                } else {
                    Write-Warning "[FAIL] Version mismatch! Installed: '$($resp.version)', Expected to contain: '$ExpectedVersion'."
                    $healthy = $false
                }
            } elseif ($resp.version) {
                Write-Verbose "[INFO] Installed version: $($resp.version) (no expected version set — skipping match)." -Verbose
            }

            # -- Configured status --
            if ($null -ne $resp.configured) {
                if ($resp.configured -eq $true) {
                    Write-Verbose "[OK] App Volumes Manager reports configured = true." -Verbose
                } else {
                    Write-Warning "[WARN] App Volumes Manager reports configured = false. Initial setup wizard may need to be completed."
                    # Not treated as fatal — the service is up and the version is correct
                }
            }

            $apiOk = $true
            break

        } catch {
            Write-Verbose "  API not yet available ($($_.Exception.Message)). Retrying in ${ApiPollIntervalSeconds}s..." -Verbose
            Start-Sleep -Seconds $ApiPollIntervalSeconds
        }
    }

    if (-not $apiOk) {
        Write-Warning "[FAIL] API at $versionUrl did not respond within ${ApiTimeoutSeconds}s."
        $healthy = $false
    }

    # --------------------------------------------------------
    # Result
    # --------------------------------------------------------
    if ($healthy) {
        Write-Verbose "[PASS] All health checks passed for $ComputerName." -Verbose
    } else {
        throw "Health check failed for $ComputerName. Review warnings above. The pre-upgrade snapshot has been retained for rollback."
    }
}


# ============================================================
# PRECHECK
# ============================================================

Write-Verbose "Running prechecks..." -Verbose

# --- Check PowerCLI is installed ---
$powerCLIModule = Get-Module -ListAvailable -Name "VMware.VimAutomation.Core"
if (-not $powerCLIModule) {
    Write-Error @"
VMware PowerCLI is not installed on this machine.

To install it, run the following from an elevated PowerShell session:
    Install-Module -Name VMware.PowerCLI -Scope CurrentUser -Force

Or for all users:
    Install-Module -Name VMware.PowerCLI -Scope AllUsers -Force

See: https://developer.broadcom.com/powercli
"@
    exit 1
}

$powerCLIVersion = $powerCLIModule | Sort-Object Version -Descending | Select-Object -First 1 -ExpandProperty Version
Write-Verbose "PowerCLI found: VMware.VimAutomation.Core v$powerCLIVersion" -Verbose

# --- Check credential files exist ---
foreach ($credFile in @($vCenterCredFile, $avmCredFile)) {
    if (-not (Test-Path $credFile)) {
        Write-Error "Credential file not found: $credFile"
        exit 1
    }
}
Write-Verbose "Credential files verified." -Verbose

# --- Check ISO is accessible ---
if (-not (Test-Path $avmIsoPath)) {
    Write-Error "App Volumes ISO not found at: $avmIsoPath`nEnsure the file exists and is accessible from this machine."
    exit 1
}
Write-Verbose "ISO verified: $avmIsoPath" -Verbose

Write-Verbose "All prechecks passed. Starting upgrade..." -Verbose

# ============================================================
# MAIN
# ============================================================

# --- Load PowerCLI ---
Import-Module VMware.VimAutomation.Core -ErrorAction Stop
Import-Module VMware.VimAutomation.Common -ErrorAction Stop
Set-PowerCLIConfiguration -Scope User -ParticipateInCeip $false -Confirm:$false | Out-Null
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
Set-PowerCLIConfiguration -DefaultVIServerMode Multiple -Confirm:$false | Out-Null

# --- Connect to vCenter ---
Write-Verbose "Connecting to vCenter: $vCenterServer" -Verbose
$viCred = Get-VICredentialStoreItem -File $vCenterCredFile -Host $vCenterServer
Connect-VIServer -Server $vCenterServer -User $viCred.User -Password $viCred.Password | Out-Null

# --- Load AVM credentials ---
$avmCredential = Import-CliXml -Path $avmCredFile

# --- Mount ISO ---
Write-Verbose "Mounting ISO: $avmIsoPath" -Verbose
$mountResult = Mount-DiskImage -ImagePath $avmIsoPath -PassThru
$isoDrive    = ($mountResult | Get-Volume).DriveLetter + ":"
$avmMsiSource = Join-Path $isoDrive $avmMsiName
Write-Verbose "ISO mounted at $isoDrive — MSI path: $avmMsiSource" -Verbose

try {

    # --- Remove existing snapshots ---
    Write-Verbose "Checking for existing snapshots on '$avmHostname'..." -Verbose
    $existingSnaps = Get-VM -Name $avmHostname | Get-Snapshot
    if ($existingSnaps) {
        Write-Verbose "Removing $($existingSnaps.Count) existing snapshot(s)..." -Verbose
        $existingSnaps | Remove-Snapshot -Confirm:$false
    } else {
        Write-Verbose "No existing snapshots found." -Verbose
    }

    # --- Graceful shutdown ---
    Write-Verbose "Shutting down '$avmHostname'..." -Verbose
    $vm = Get-VM -Name $avmHostname -ErrorAction Stop
    if ($vm.PowerState -eq 'PoweredOn') {
        Shutdown-VMGuest -VM $vm -Confirm:$false | Out-Null
        Wait-ForVMPowerOff -VMName $avmHostname
    } else {
        Write-Verbose "'$avmHostname' is already powered off." -Verbose
    }

    # --- Take pre-upgrade snapshot ---
    Write-Verbose "Taking snapshot '$snapshotName'..." -Verbose
    Get-VM -Name $avmHostname | New-Snapshot -Name $snapshotName | Out-Null

    # --- Power on and wait for WinRM ---
    Write-Verbose "Powering on '$avmHostname'..." -Verbose
    Start-VM -VM $avmHostname | Out-Null
    Wait-ForWinRM -ComputerName $avmHostname `
                  -Credential $avmCredential `
                  -TimeoutSeconds $winrmTimeout `
                  -PollIntervalSeconds $winrmPollInterval

    # --------------------------------------------------------
    # PHASE 1: Backup Nginx + Install MSI
    # --------------------------------------------------------
    Write-Verbose "Opening PSSession for install phase..." -Verbose
    $session = New-PSSession -ComputerName $avmHostname `
                              -Credential $avmCredential `
                              -Authentication CredSSP

    # Step 1a: Create temp directory and back up Nginx files on the remote AVM
    Invoke-Command -Session $session -ScriptBlock {
        param($installDir, $nginxConfDir, $nginxFiles)

        New-Item -Path $installDir -ItemType Directory -Force | Out-Null
        Write-Verbose "Created temp directory: $installDir" -Verbose

        # Back up static files (nginx.conf)
        foreach ($file in $nginxStaticFiles) {
            $src = Join-Path $nginxConfDir $file
            if (Test-Path $src) {
                Copy-Item -Path $src -Destination $installDir -Force
                Write-Verbose "Backed up: $file" -Verbose
            } else {
                Write-Warning "Nginx static file not found, skipping: $src"
            }
        }

        # Dynamically discover and back up all certificate files (.crt, .key, .pem)
        # Note: Get-ChildItem -Include requires -Recurse to match files in the target directory,
        # so we use Where-Object on the extension instead for reliable filtering.
        $certFiles = Get-ChildItem -Path $nginxConfDir -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.Extension -in ".crt", ".key", ".pem" }
        if ($certFiles) {
            foreach ($cert in $certFiles) {
                Copy-Item -Path $cert.FullName -Destination $installDir -Force
                Write-Verbose "Backed up cert file: $($cert.Name)" -Verbose
            }
        } else {
            Write-Warning "No certificate files (.crt/.key/.pem) found in $nginxConfDir — skipping cert backup."
        }
    } -ArgumentList $installDir, $nginxConfDir, $nginxStaticFiles

    # Step 1b: Copy MSI from ISO to a local temp folder on the management host first.
    # Copy-Item -ToSession cannot read directly from a mounted ISO (CD-ROM filesystem
    # does not support the required stream operations), so we stage it locally first.
    $stagingMsi = Join-Path $env:TEMP "App Volumes Manager.msi"
    Write-Verbose "Staging MSI locally: $avmMsiSource -> $stagingMsi ..." -Verbose
    Copy-Item -Path $avmMsiSource -Destination $stagingMsi -Force

    # Step 1c: Push staged MSI from management host temp folder to remote AVM
    $remoteMsi = Join-Path $installDir "App Volumes Manager.msi"
    Write-Verbose "Copying MSI to ${avmHostname}:$remoteMsi ..." -Verbose
    Copy-Item -Path $stagingMsi -Destination $remoteMsi -ToSession $session -Force

    # Clean up staging copy on management host
    Remove-Item -Path $stagingMsi -Force -ErrorAction SilentlyContinue
    Write-Verbose "Staging copy removed." -Verbose

    # Step 1d: Run the installer on the remote AVM
    Invoke-Command -Session $session -ScriptBlock {
        param($installDir, $avmVendor, $avmProduct, $avmVersion)

        $localMsi = Join-Path $installDir "App Volumes Manager.msi"
        $logFile  = Join-Path $installDir "UpgradeAppVol_$avmVersion.log"
        $msiArgs  = "/qb /l* `"$logFile`""
        Write-Verbose "Installing $avmVendor $avmProduct $avmVersion..." -Verbose
        $exitCode = (Start-Process -FilePath $localMsi -ArgumentList $msiArgs -Wait -PassThru).ExitCode
        if ($exitCode -ne 0) {
            throw "MSI installer exited with code $exitCode. Check log: $logFile"
        }
        Write-Verbose "Installation completed successfully (exit code: $exitCode)." -Verbose

    } -ArgumentList $installDir, $avmVendor, $avmProduct, $avmVersion

    Remove-PSSession $session

    # --------------------------------------------------------
    # Reboot 1: Post-install reboot
    # --------------------------------------------------------
    Write-Verbose "Restarting '$avmHostname' after installation..." -Verbose
    Restart-Computer -ComputerName $avmHostname -Force -Credential $avmCredential
    Start-Sleep -Seconds 30   # Brief pause before polling so the host has started shutting down
    Wait-ForWinRM -ComputerName $avmHostname `
                  -Credential $avmCredential `
                  -TimeoutSeconds $winrmTimeout `
                  -PollIntervalSeconds $winrmPollInterval

    # --- Health check: post-install ---
    Invoke-AVMHealthCheck -ComputerName $avmHostname `
                          -Credential $avmCredential `
                          -ExpectedVersion $avmExpectedVersion `
                          -ApiTimeoutSeconds $winrmTimeout `
                          -ApiPollIntervalSeconds $winrmPollInterval

    # --------------------------------------------------------
    # PHASE 2: Restore Nginx certificates
    # --------------------------------------------------------
    Write-Verbose "Opening PSSession for Nginx restore phase..." -Verbose
    $session = New-PSSession -ComputerName $avmHostname `
                              -Credential $avmCredential `
                              -Authentication CredSSP

    Invoke-Command -Session $session -ScriptBlock {
        param($installDir, $nginxConfDir, $nginxFiles)

        # Restore all files that were backed up to $installDir (nginx.conf + any certs)
        Write-Verbose "Restoring Nginx configuration files..." -Verbose
        $backedUp = Get-ChildItem -Path $installDir -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -in ".conf",".crt",".key",".pem" }
        if ($backedUp) {
            foreach ($file in $backedUp) {
                Copy-Item -Path $file.FullName -Destination $nginxConfDir -Force
                Write-Verbose "Restored: $($file.Name)" -Verbose
            }
        } else {
            Write-Warning "No nginx backup files found in $installDir to restore."
        }
    } -ArgumentList $installDir, $nginxConfDir

    Remove-PSSession $session

    # --------------------------------------------------------
    # Reboot 2: Post-Nginx restore reboot
    # --------------------------------------------------------
    Write-Verbose "Restarting '$avmHostname' to apply Nginx configuration..." -Verbose
    Restart-Computer -ComputerName $avmHostname -Force -Credential $avmCredential
    Start-Sleep -Seconds 30
    Wait-ForWinRM -ComputerName $avmHostname `
                  -Credential $avmCredential `
                  -TimeoutSeconds $winrmTimeout `
                  -PollIntervalSeconds $winrmPollInterval

    # --- Health check: post-Nginx restore ---
    Invoke-AVMHealthCheck -ComputerName $avmHostname `
                          -Credential $avmCredential `
                          -ExpectedVersion $avmExpectedVersion `
                          -ApiTimeoutSeconds $winrmTimeout `
                          -ApiPollIntervalSeconds $winrmPollInterval

    # --------------------------------------------------------
    # PHASE 3: Cleanup
    # --------------------------------------------------------
    Write-Verbose "Opening PSSession for cleanup phase..." -Verbose
    $session = New-PSSession -ComputerName $avmHostname `
                              -Credential $avmCredential `
                              -Authentication CredSSP

    Invoke-Command -Session $session -ScriptBlock {
        param($installDir)
        Write-Verbose "Removing temp directory: $installDir" -Verbose
        Remove-Item -Path $installDir -Recurse -Force -ErrorAction SilentlyContinue
    } -ArgumentList $installDir

    Remove-PSSession $session

    # --- Remove pre-upgrade snapshot ---
    Write-Verbose "Removing snapshot '$snapshotName'..." -Verbose
    Get-VM -Name $avmHostname | Get-Snapshot -Name $snapshotName | Remove-Snapshot -Confirm:$false

    Write-Verbose "Upgrade of $avmProduct on '$avmHostname' to $avmVersion completed successfully." -Verbose

} catch {
    Write-Error "An error occurred: $_"
    Write-Warning "The pre-upgrade snapshot '$snapshotName' has been retained for rollback."
} finally {
    # --- Dismount ISO ---
    if ($mountResult) {
        Write-Verbose "Dismounting ISO: $avmIsoPath" -Verbose
        Dismount-DiskImage -ImagePath $avmIsoPath | Out-Null
    }

    # --- Disconnect from vCenter ---
    Write-Verbose "Disconnecting from vCenter..." -Verbose
    Disconnect-VIServer -Server $vCenterServer -Confirm:$false -ErrorAction SilentlyContinue

    # --- Stop transcript ---
    Write-Verbose "Transcript saved to: $transcriptFile" -Verbose
    Stop-Transcript
}
