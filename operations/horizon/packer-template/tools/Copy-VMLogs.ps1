<#
.SYNOPSIS
    Copy-VMlogs.ps1
    Copies logs from the VM to the Packer host log folder after each phase.
    Called from Packer HCL with PHASE_NAME and VM_IP environment variables.
    Logs are saved to C:\Packer\logs\<phase>\ on the Packer host.
#>

$ErrorActionPreference = "Continue"

$phase   = $env:PHASE_NAME
$vmIp    = $env:VM_IP
$logRoot = "C:\Packer\logs"

if (-not $phase) { $phase = "unknown" }

$destDir = "$logRoot\$phase"
New-Item -ItemType Directory -Path $destDir -Force | Out-Null

Write-Output "=== Copying VM logs to Packer host ==="
Write-Output "Phase   : $phase"
Write-Output "VM IP   : $vmIp"
Write-Output "Dest    : $destDir"

if (-not $vmIp) {
    Write-Warning "VM_IP not set - cannot copy logs via WinRM"
    exit 0
}

$pass        = ConvertTo-SecureString "SommerFerie2020!" -AsPlainText -Force
$cred        = New-Object System.Management.Automation.PSCredential("Administrator", $pass)
$sessionOpts = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck

# Paths to collect on the VM
$vmLogPaths = @(
    "C:\Temp\OSOT-logs",
    "C:\Temp\packer-flc.log",
    "C:\Temp\vmtools.log",
    "C:\Windows\Temp\packer-flc.log",
    "C:\Windows\System32\Sysprep\Panther\setupact.log",
    "C:\Windows\System32\Sysprep\Panther\setuperr.log",
    "C:\Windows\Panther\UnattendGC\setupact.log",
    "C:\Temp\horizon-agent-install.log",
    "C:\Temp\horizon-agent-result.txt",
    "C:\ProgramData\Omnissa\Horizon\logs"
)

try {
    $session = New-PSSession -ComputerName $vmIp -Credential $cred `
        -Authentication Basic -SessionOption $sessionOpts -ErrorAction Stop

    foreach ($vmPath in $vmLogPaths) {
        try {
            # Check if path exists on VM
            $exists = Invoke-Command -Session $session -ScriptBlock {
                param($p)
                Test-Path $p
            } -ArgumentList $vmPath

            if ($exists) {
                Write-Output "Copying: $vmPath"
                Copy-Item -FromSession $session -Path $vmPath `
                    -Destination $destDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Warning "Could not copy $vmPath : $_"
        }
    }

    Remove-PSSession $session -ErrorAction SilentlyContinue
    Write-Output "Logs copied to: $destDir"

} catch {
    Write-Warning "Could not connect to VM at $vmIp : $_"
    Write-Warning "Logs not copied - check VM is reachable and WinRM is running."
}

Write-Output "=== Log copy complete ==="
