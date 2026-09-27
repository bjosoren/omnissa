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
#
# ADDED 2026-09-21, per the user's build-log audit (comparing the actual
# contents of a collected build_logs zip against every role in the
# pipeline): this install had NO log at all under build_log_dir, unlike
# appvolumes/dem/horizon_agent, which already land their own
# *_install.log there on their own. Root cause is specific to THIS
# script: it runs in auditUser RunSynchronous, before Ansible ever
# connects, so there is no Ansible task afterwards that could copy
# anything out of the guest (the OSOT-log pattern used elsewhere in this
# project - copy a vendor-written log into build_log_dir via a win_shell
# task - doesn't apply here, there IS no later task in roles/vmware_tools
# that runs post-install). Fixed the same way appvolumes/dem/horizon_agent
# apparently already do it: point the installer's OWN logging at
# build_log_dir directly, so nothing has to be copied later at all - the
# file is just already sitting there by the time roles/collect_build_logs
# zips the whole folder up.
#
# setup.exe here is an InstallShield wrapper around msiexec - the exact
# same "/v \"...\"" argument block that carries ADDLOCAL/REMOVE also
# carries anything else meant for the underlying MSI, so /l*v <path>
# (msiexec's own standard verbose-log switch, not something specific to
# VMware Tools) goes in that same quoted string. Not verified against a
# VMware-Tools-specific "how to log a silent install" section of the PDF
# (only the Components/REMOVE= section was available) - this is standard
# msiexec/InstallShield logging syntax, so it should hold, but worth a
# real build to confirm the log actually lands with content rather than
# an empty/missing file.
#
# build_log_dir's path is hardcoded here (not templated in from Ansible
# group_vars, since this script runs before Ansible ever touches the
# guest) - kept in sync by hand with inventory/group_vars/
# rdsh_2025_tpl.yml's own build_log_dir: C:\ProgramData\Omnissa\Logs.
#
# New-Item -Force below creates C:\ProgramData\Omnissa\Logs (and any
# missing parent, i.e. C:\ProgramData\Omnissa itself) if it doesn't exist
# yet - at this point in the build (audit mode, before any other Omnissa
# component has installed) there's a real chance nothing has created
# C:\ProgramData\Omnissa at all yet. -ErrorAction SilentlyContinue so a
# logging-directory problem never blocks the actual Tools install.
$buildLogDir = 'C:\ProgramData\Omnissa\Logs'
New-Item -ItemType Directory -Path $buildLogDir -Force -ErrorAction SilentlyContinue | Out-Null

$cdrom = Get-WmiObject Win32_CDROMDrive |
    Where-Object { Test-Path ($_.Drive + '\VMwareToolsUpgrader.exe') } |
    Select-Object -First 1

if ($cdrom) {
    $setup = $cdrom.Drive + '\setup.exe'
    $arglist = '/S /v "/qn REBOOT=ReallySuppress ADDLOCAL=ALL REMOVE=CBHelper,FileIntrospection,NetworkIntrospection,ServiceDiscovery,Hgfs,BootCamp,SaltMinion /l*v ' + $buildLogDir + '\vmware_tools_install.log"'
    Write-Host "Installing VMware Tools from $($cdrom.Drive)"
    Start-Process $setup -ArgumentList $arglist -Wait
    Write-Host "VMware Tools installation complete"
} else {
    Write-Host "ERROR: VMware Tools ISO not found"
}