<#
.SYNOPSIS
    Adds missing NVIDIA vGPU profiles (default: L40S) to graphic-profiles.properties on an
    Omnissa Horizon Connection Server, then restarts the Connection Server service.

.DESCRIPTION
    Horizon keeps its own list of known vGPU profiles in graphic-profiles.properties. If a
    profile is missing there, instant clone provisioning fails with:

      No GPU capable host is available for provisioning <vm> with profile nvidia_l40s-16a

    and the CS debug log shows "[CPHost] VGPU_PROFILE is null or unknown". See KB 59271.

    The script:
      1. Finds graphic-profiles.properties (Omnissa or VMware install path)
      2. Shows which of the profiles are already listed
      3. Backs up the file and appends ONLY the missing profiles (safe to run again)
      4. Restarts the Connection Server service (wsbroker), after confirmation

    Run it on every Connection Server, one at a time. Drain the server from the load
    balancer before the restart.

.PARAMETER Profiles
    Profiles to ensure, as a hashtable (use [ordered] to keep the order) of name = max instances per physical GPU.
    Default: the NVIDIA L40S A, B and Q profiles.

.PARAMETER Header
    Comment line written above the added profiles. Default: '# NVIDIA L40S'.

.PARAMETER NoRestart
    Update the file but don't restart the service.

.PARAMETER Force
    Restart without asking.

.EXAMPLE
    .\Add-HorizonVgpuProfiles.ps1
    # adds missing L40S profiles, asks before restarting the service

.EXAMPLE
    .\Add-HorizonVgpuProfiles.ps1 -WhatIf
    # shows what would be added, changes nothing

.EXAMPLE
    .\Add-HorizonVgpuProfiles.ps1 -NoRestart

.NOTES
    The values are the maximum number of vGPUs of that profile per physical GPU. Verify
    them against the NVIDIA vGPU user guide for your driver release. Profile names are
    case-sensitive and must match what vCenter reports.

    Author : bjosoren - https://tech.iot-it.no
    License: MIT
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [System.Collections.IDictionary] $Profiles,
    [string] $Header = '# NVIDIA L40S',
    [switch] $NoRestart,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

if (-not $Profiles) {
    $Profiles = [ordered]@{
        'nvidia_l40s-48q' = 1;  'nvidia_l40s-24q' = 2;  'nvidia_l40s-16q' = 3;  'nvidia_l40s-12q' = 4
        'nvidia_l40s-8q'  = 6;  'nvidia_l40s-6q'  = 8;  'nvidia_l40s-4q'  = 12; 'nvidia_l40s-3q'  = 16
        'nvidia_l40s-2q'  = 24; 'nvidia_l40s-1q'  = 32
        'nvidia_l40s-48a' = 1;  'nvidia_l40s-24a' = 2;  'nvidia_l40s-16a' = 3;  'nvidia_l40s-12a' = 4
        'nvidia_l40s-8a'  = 6;  'nvidia_l40s-6a'  = 8;  'nvidia_l40s-4a'  = 12; 'nvidia_l40s-3a'  = 16
        'nvidia_l40s-2a'  = 24; 'nvidia_l40s-1a'  = 32
        'nvidia_l40s-3b'  = 16; 'nvidia_l40s-2b'  = 24; 'nvidia_l40s-1b'  = 32
    }
}

# ---------- Admin ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
               [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this script as Administrator on the Connection Server.' }

# ---------- 1. Find the file ----------
$conf = 'C:\Program Files\Omnissa\Horizon\Server\broker\conf\graphic-profiles.properties',
        'C:\Program Files\VMware\VMware View\Server\broker\conf\graphic-profiles.properties' |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $conf) { throw 'graphic-profiles.properties not found. Is this a Horizon Connection Server?' }
Write-Host "File: $conf" -ForegroundColor Cyan

# ---------- 2. Compare ----------
$content  = Get-Content -LiteralPath $conf
$existing = @{}
foreach ($line in $content) {
    if ($line -match '^\s*([^#=\s][^=]*?)\s*=\s*(.*)$') { $existing[$Matches[1]] = $Matches[2].Trim() }
}

$missing = [ordered]@{}
foreach ($name in $Profiles.Keys) {
    if ($existing.ContainsKey($name)) {
        if ($existing[$name] -ne [string]$Profiles[$name]) {
            Write-Warning "$name is already listed with value $($existing[$name]) (script default: $($Profiles[$name])). Left unchanged."
        }
    } else {
        $missing[$name] = $Profiles[$name]
    }
}

Write-Host ("Profiles already listed: {0} of {1}" -f ($Profiles.Count - $missing.Count), $Profiles.Count) -ForegroundColor DarkGray
if ($missing.Count -eq 0) {
    Write-Host 'Nothing to add. All profiles are already in the file.' -ForegroundColor Green
    return
}
Write-Host "Profiles to add ($($missing.Count)):" -ForegroundColor Yellow
$missing.Keys | ForEach-Object { Write-Host "  $_=$($missing[$_])" }

# ---------- 3. Back up and append ----------
if ($PSCmdlet.ShouldProcess($conf, "Add $($missing.Count) vGPU profile(s)")) {
    $backup = "$conf.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Copy-Item -LiteralPath $conf -Destination $backup
    Write-Host "Backup: $backup" -ForegroundColor DarkGray

    $lines = @('', $Header) + ($missing.Keys | ForEach-Object { "$_=$($missing[$_])" })
    Add-Content -LiteralPath $conf -Value $lines -Encoding ASCII
    Write-Host "Added $($missing.Count) profile(s)." -ForegroundColor Green
} else {
    return
}

# ---------- 4. Restart the Connection Server service ----------
if ($NoRestart) {
    Write-Host 'Restart the Connection Server service (wsbroker) for the change to take effect.' -ForegroundColor Yellow
    return
}
if (-not $Force) {
    $ans = Read-Host 'Restart the Connection Server service now? Drain this server from the load balancer first. (y/N)'
    if ($ans -notmatch '^[Yy]') {
        Write-Host 'Not restarted. Restart wsbroker later for the change to take effect.' -ForegroundColor Yellow
        return
    }
}
if ($PSCmdlet.ShouldProcess('wsbroker', 'Restart service')) {
    Write-Host 'Restarting wsbroker ...' -ForegroundColor Yellow
    Restart-Service -Name wsbroker -Force
    Write-Host "wsbroker is $((Get-Service -Name wsbroker).Status)." -ForegroundColor Green
    Write-Host 'Next: repeat on the other Connection Servers, then re-enable provisioning on the farm/pool (Maintain > Enable Provisioning).' -ForegroundColor DarkGray
}
