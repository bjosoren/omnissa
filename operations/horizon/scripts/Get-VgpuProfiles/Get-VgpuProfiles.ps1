<#
.SYNOPSIS
    Connects to vCenter and lists the NVIDIA vGPU profiles available on ESXi hosts
    in a cluster (or on specific hosts), plus the physical GPUs and their graphics mode.

.DESCRIPTION
    Per host it reads (vSphere API, via PowerCLI):
      - Config.GraphicsInfo        : physical GPUs (model, memory, current mode)
      - Config.GraphicsConfig      : host default graphics type (vGPU needs "Shared Direct")
      - Config.SharedPassthruGpuTypes : vGPU profiles the host offers (e.g. grid_a40-8q / nvidia_l4-4q)

    Output:
      1. GPUs per host
      2. All profiles, decoded (GPU, framebuffer, series, MIG), with the hosts that offer them
      3. Optional CSV export

    The password is asked for at runtime and never stored.

.PARAMETER VCenter
    vCenter FQDN.
.PARAMETER User
    vCenter user, e.g. administrator@vsphere.local.
.PARAMETER Cluster
    Cluster name. All hosts in the cluster are checked.
.PARAMETER VMHost
    One or more ESXi host names, as registered in vCenter. Can be combined with -Cluster
    (then only these hosts in that cluster are checked).
.PARAMETER SkipCertificateCheck
    Ignore an untrusted vCenter certificate for this session only.
.PARAMETER ExportCsv
    Write the decoded profile list (one row per host + profile) to CSV.

.EXAMPLE
    .\Get-VgpuProfiles.ps1 -VCenter vc01.lab.local -User administrator@vsphere.local -Cluster GPU-Cluster

.EXAMPLE
    .\Get-VgpuProfiles.ps1 -VCenter vc01.lab.local -User administrator@vsphere.local `
        -VMHost esx01.lab.local, esx02.lab.local -SkipCertificateCheck -ExportCsv C:\Temp\vgpu.csv
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]   $VCenter,
    [Parameter(Mandatory)] [string]   $User,
    [string]   $Cluster,
    [string[]] $VMHost,
    [switch]   $SkipCertificateCheck,
    [string]   $ExportCsv
)

$ErrorActionPreference = 'Stop'

if (-not $Cluster -and -not $VMHost) {
    throw 'Specify -Cluster, -VMHost, or both.'
}

# ---------- PowerCLI ----------
if (-not (Get-Module -ListAvailable -Name VMware.VimAutomation.Core)) {
    throw "PowerCLI is not installed. Install it with: Install-Module VCF.PowerCLI -Scope CurrentUser  (older name: VMware.PowerCLI)"
}
Import-Module VMware.VimAutomation.Core -ErrorAction Stop | Out-Null
Set-PowerCLIConfiguration -Scope Session -ParticipateInCEIP $false -DisplayDeprecationWarnings $false -Confirm:$false | Out-Null
if ($SkipCertificateCheck) {
    Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
}

# ---------- Helpers ----------
$seriesName = @{
    'q' = 'Q - Virtual Workstation'
    'b' = 'B - Virtual PC'
    'a' = 'A - Virtual Apps'
    'c' = 'C - Compute'
}

function ConvertFrom-VgpuProfile([string]$Name) {
    # grid_a40-8q, nvidia_l4-4q, grid_a100-3-20c (MIG: <slices>-<fb>), grid_rtx6000-4q, grid_a16-2b
    $r = [pscustomobject]@{ GPU = ''; FramebufferGB = $null; Series = ''; MIG = '' }
    if ($Name -match '^(?:grid|nvidia)_(?<gpu>[a-z0-9]+(?:_[a-z0-9]+)*)-(?:(?<mig>\d+)-)?(?<fb>\d+)(?<type>[a-z]+)$') {
        $r.GPU           = $Matches.gpu.ToUpper()
        $r.FramebufferGB = [int]$Matches.fb
        $t               = $Matches.type.ToLower()
        $r.Series        = if ($seriesName.ContainsKey($t)) { $seriesName[$t] } else { $t.ToUpper() }
        if ($Matches.mig) { $r.MIG = "$($Matches.mig) slice(s)" }
    }
    $r
}

$graphicsModeName = @{
    'basic'        = 'Basic'
    'shared'       = 'Shared (vSGA)'
    'direct'       = 'Direct (passthrough)'
    'sharedDirect' = 'Shared Direct (vGPU)'
}

# ---------- Connect ----------
# Prompt in the console (Get-Credential may open a GUI dialog that ends up hidden behind the terminal)
$securePwd = Read-Host "Password for $User on $VCenter" -AsSecureString
if (-not $securePwd -or $securePwd.Length -eq 0) { throw 'No password entered.' }
$cred = New-Object System.Management.Automation.PSCredential ($User, $securePwd)
$securePwd = $null
Write-Host "Connecting to $VCenter ..." -ForegroundColor Yellow
$vi = Connect-VIServer -Server $VCenter -Credential $cred
$cred = $null

try {
    # ---------- Hosts ----------
    $hosts = if ($Cluster) {
        $cl = Get-Cluster -Server $vi -Name $Cluster
        $h  = Get-VMHost -Server $vi -Location $cl
        if ($VMHost) { $h | Where-Object { $VMHost -contains $_.Name } } else { $h }
    } else {
        Get-VMHost -Server $vi -Name $VMHost
    }
    $hosts = @($hosts | Sort-Object Name)
    if ($hosts.Count -eq 0) { throw 'No matching ESXi hosts found.' }

    $views = Get-View -Server $vi -Id ($hosts | ForEach-Object { $_.Id }) `
                      -Property Name, Runtime.ConnectionState, Config.GraphicsInfo, Config.GraphicsConfig, Config.SharedPassthruGpuTypes

    $gpuRows     = New-Object System.Collections.Generic.List[object]
    $profileRows = New-Object System.Collections.Generic.List[object]

    foreach ($v in ($views | Sort-Object Name)) {
        if ($v.Runtime.ConnectionState -ne 'connected') {
            Write-Warning "$($v.Name) is $($v.Runtime.ConnectionState) and was skipped."
            continue
        }

        $defaultType = $v.Config.GraphicsConfig.HostDefaultGraphicsType
        $nvidiaGpus  = @($v.Config.GraphicsInfo | Where-Object { $_.VendorName -match 'NVIDIA' })

        foreach ($g in $nvidiaGpus) {
            $mode = [string]$g.GraphicsType
            $gpuRows.Add([pscustomobject]@{
                Host        = $v.Name
                GPU         = $g.DeviceName
                'Mem (GB)'  = [Math]::Round($g.MemorySizeInKB / 1MB, 0)
                PciId       = $g.PciId
                Mode        = if ($graphicsModeName.ContainsKey($mode)) { $graphicsModeName[$mode] } else { $mode }
                'VMs'       = @($g.Vm).Count
            })
        }

        if ($nvidiaGpus.Count -eq 0) {
            Write-Warning "$($v.Name): no NVIDIA GPU found."
        } elseif ($defaultType -ne 'sharedDirect') {
            Write-Warning "$($v.Name): host default graphics type is '$defaultType'. vGPU requires 'Shared Direct' (Host > Configure > Graphics)."
        }

        $types = @($v.Config.SharedPassthruGpuTypes)
        if ($nvidiaGpus.Count -gt 0 -and $types.Count -eq 0) {
            Write-Warning "$($v.Name): no vGPU profiles reported. Check that the NVIDIA vGPU host driver (VIB) is installed and the host has been rebooted after switching to Shared Direct."
        }

        foreach ($t in $types) {
            $d = ConvertFrom-VgpuProfile $t
            # Max instances per physical GPU (time-sliced, same profile on the whole GPU)
            $gpuMemGB = ($nvidiaGpus | Select-Object -First 1 | ForEach-Object { [Math]::Round($_.MemorySizeInKB / 1MB, 0) })
            $perGpu = if ($d.FramebufferGB -and $gpuMemGB -and -not $d.MIG) { [Math]::Floor($gpuMemGB / $d.FramebufferGB) } else { $null }

            $profileRows.Add([pscustomobject]@{
                Host          = $v.Name
                Profile       = $t
                GPU           = $d.GPU
                FramebufferGB = $d.FramebufferGB
                Series        = $d.Series
                MIG           = $d.MIG
                MaxPerGPU     = $perGpu
            })
        }
    }

    # ---------- Output ----------
    Write-Host ''
    Write-Host 'Physical NVIDIA GPUs' -ForegroundColor Cyan
    if ($gpuRows.Count) { $gpuRows | Format-Table -AutoSize | Out-String -Width 4096 | Write-Host }
    else                { Write-Host '  (none)' -ForegroundColor DarkGray }

    Write-Host 'Available vGPU profiles' -ForegroundColor Cyan
    if ($profileRows.Count -eq 0) {
        Write-Host '  (none)' -ForegroundColor DarkGray
    } else {
        $hostCount = @($profileRows | Select-Object -ExpandProperty Host -Unique).Count
        $summary = $profileRows | Group-Object Profile | ForEach-Object {
            $first = $_.Group[0]
            $hostsWithIt = @($_.Group | Select-Object -ExpandProperty Host -Unique)
            [pscustomobject]@{
                Profile       = $_.Name
                GPU           = $first.GPU
                'FB (GB)'     = $first.FramebufferGB
                Series        = $first.Series
                MIG           = $first.MIG
                'Max/GPU'     = $first.MaxPerGPU
                Hosts         = if ($hostsWithIt.Count -eq $hostCount) { "all ($hostCount)" } else { ($hostsWithIt -join ', ') }
            }
        } | Sort-Object GPU, Series, @{ e = { [int]$_.'FB (GB)' } }

        $summary | Format-Table -AutoSize | Out-String -Width 4096 | Write-Host
        Write-Host '  Max/GPU = profiles of this size per physical GPU (time-sliced; a GPU runs one profile size at a time unless mixed-size mode is enabled).' -ForegroundColor DarkGray

        # Profiles not offered on every host (matters for DRS / vMotion)
        $partial = @($summary | Where-Object { $_.Hosts -notlike 'all*' })
        if ($partial.Count -gt 0 -and $hostCount -gt 1) {
            Write-Warning "$($partial.Count) profile(s) are not available on every host. VMs using them can't move freely between all hosts."
        }
    }

    if ($ExportCsv) {
        $profileRows | Export-Csv -LiteralPath $ExportCsv -NoTypeInformation -Encoding UTF8
        Write-Host "Exported $($profileRows.Count) rows to $ExportCsv" -ForegroundColor Green
    }
}
finally {
    Disconnect-VIServer -Server $vi -Confirm:$false -ErrorAction SilentlyContinue
}
