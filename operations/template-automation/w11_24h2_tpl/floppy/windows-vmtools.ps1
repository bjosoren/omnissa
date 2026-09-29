# Run from the autounattend auditUser pass (floppy A:\): silent VMware Tools
# install from whichever CD-ROM carries the Tools ISO.
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
