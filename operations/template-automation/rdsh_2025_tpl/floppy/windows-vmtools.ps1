# windows-vmtools.ps1
# Invoked from floppy/autounattend.pkrtpl.hcl's auditUser RunSynchronous
# pass (moved there 2026-09-16 from the old oobeSystem FirstLogonCommands -
# see that file's own header). Finds the VMware Tools ISO on the CD drive
# (attached by Packer from ESXi's /vmimages/tools-isoimages/windows.iso,
# per iso_paths[1] in rdsh_2025_tpl.pkr.hcl) and runs a silent install.
#
# REMOVE= list ADDED 2026-09-16, per the user's explicit request and the
# attached "VMware Tools 12.5.0" PDF (VMware by Broadcom) - previously this
# installed with plain ADDLOCAL=ALL and no REMOVE clause (the source
# guide's own version had a REMOVE=<feature> clause that got clipped
# illegibly in the copy this project was adapted from, and rather than
# guess at what belonged there, it was left out entirely - see this file's
# own prior header for that history). The PDF's own "Specify VMware Tools
# Components in Silent Installation" section (p.59) gives the exact,
# confirmed syntax:
#   setup.exe /S /v "/qn msi_args ADDLOCAL=ALL REMOVE=component"
# "Component name is feature name and is case-sensitive. If you want to
# remove more than one component, the feature names must be comma
# separated." Its own worked example removes Hgfs, FileIntrospection,
# NetworkIntrospection, and SaltMinion together this same way.
#
# Feature names below are copied verbatim from the PDF's own Table 4
# ("VMware Tools Customizable Components", p.60-61) - case matters, so
# note Hgfs is capitalized exactly that way in the table (NOT "HgFs"):
#   CBHelper              - Carbon Black Sensor install helper
#   FileIntrospection      - NSX File Introspection driver (vsepflt.sys)
#   NetworkIntrospection    - NSX Network Introspection driver (vnetflt.sys)
#   ServiceDiscovery       - discovery of services running inside the VM
#   Hgfs                   - VMware shared-folders driver (Workstation/
#                            Fusion only, not useful on ESXi/vSphere)
#   BootCamp               - Mac BootCamp support, not applicable here
#   SaltMinion              - Salt Minion setup scripts
# All seven are excluded per the user's explicit list - none of them are
# needed for an ESXi/vSphere-hosted RDSH host: CBHelper/ServiceDiscovery/
# SaltMinion are for agents this image doesn't run, FileIntrospection/
# NetworkIntrospection are NSX guest-introspection drivers this environment
# doesn't use, Hgfs only matters on Workstation/Fusion, and BootCamp is
# Mac-only. REBOOT=ReallySuppress (a documented MSI REBOOT property value,
# unlike the PDF's own example command which uses the undocumented
# shorthand "REBOOT=R") is unchanged from before this edit - already
# proven working in this pipeline.
$cdrom = Get-WmiObject Win32_CDROMDrive |
    Where-Object { Test-Path ($_.Drive + '\VMwareToolsUpgrader.exe') } |
    Select-Object -First 1

if ($cdrom) {
    $setup = $cdrom.Drive + '\setup.exe'
    $arglist = '/S /v "/qn REBOOT=ReallySuppress ADDLOCAL=ALL REMOVE=CBHelper,FileIntrospection,NetworkIntrospection,ServiceDiscovery,Hgfs,BootCamp,SaltMinion"'
    Write-Host "Installing VMware Tools from $($cdrom.Drive)"
    Start-Process $setup -ArgumentList $arglist -Wait
    Write-Host "VMware Tools installation complete"
} else {
    Write-Host "ERROR: VMware Tools ISO not found"
}