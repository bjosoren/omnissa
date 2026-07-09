<#
.SYNOPSIS
    Show-BuildStatus.ps1
    Displays current VM state at the start of each build phase.
    Called from Packer HCL with PHASE_NAME environment variable.

    Windows 11 24H2 uses ImageState (not AuditInProgress) to track audit mode:
      IMAGE_STATE_UNDEPLOYABLE      = Audit mode (correct for pre-generalize)
      IMAGE_STATE_SPECIALIZE_RESEAL_TO_OOBE = About to go through OOBE
      IMAGE_STATE_COMPLETE          = Post-sysprep/generalize (correct for agents)
#>

$phase = $env:PHASE_NAME
if (-not $phase) { $phase = "Unknown" }

$setupState  = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State" -ErrorAction SilentlyContinue
$imageState  = if ($setupState.ImageState) { $setupState.ImageState } else { "Unknown" }
$sysprepTag  = Test-Path "C:\Windows\System32\Sysprep\Sysprep_succeeded.tag"
$computer    = $env:COMPUTERNAME
$user        = $env:USERNAME
$uac         = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -ErrorAction SilentlyContinue).EnableLUA

# Determine mode description
$modeDesc = switch ($imageState) {
    "IMAGE_STATE_UNDEPLOYABLE"                    { ">>> AUDIT MODE - correct for pre-generalize <<<" }
    "IMAGE_STATE_SPECIALIZE_RESEAL_TO_OOBE"       { ">>> GOING TO OOBE <<<" }
    "IMAGE_STATE_SPECIALIZE_RESEAL_TO_AUDIT"      { ">>> GOING TO AUDIT <<<" }
    "IMAGE_STATE_COMPLETE"                        { ">>> POST-SYSPREP/GENERALIZE - OK for agent install <<<" }
    default                                       { ">>> $imageState <<<" }
}

Write-Output "======================================================"
Write-Output "BUILD STATUS: $phase"
Write-Output "======================================================"
Write-Output "Computer name                 : $computer"
Write-Output "Current user                  : $user"
Write-Output "Image state                   : $imageState"
Write-Output "Sysprep_succeeded.tag present : $sysprepTag"
Write-Output "UAC enabled (EnableLUA)       : $uac"
Write-Output "MODE: $modeDesc"

# Warn if agents are about to install in wrong state
if ($phase -like "*PHASE 3*" -and $imageState -ne "IMAGE_STATE_COMPLETE") {
    Write-Warning "PHASE 3 should run in IMAGE_STATE_COMPLETE (post-generalize)!"
    Write-Warning "Current state: $imageState"
    Write-Warning "Ensure OSOT Generalize ran correctly before continuing."
}

Write-Output "======================================================"
