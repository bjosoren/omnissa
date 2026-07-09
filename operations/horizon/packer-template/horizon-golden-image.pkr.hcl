##############################################################################
# Omnissa Horizon Golden Image - HashiCorp Packer Build Template
#
# Target OS : Windows 11 24H2 Enterprise
# Hypervisor: VMware vSphere (vsphere-iso plugin)
#
# Build order per Omnissa TechZone guide:
#   1. Windows install + VMware Tools (autounattend.xml)
#   2. Disable audit.exe + reboot
#   3. .NET, Applications, Copilot disable      <- Phase 1
#   4. OSOT Optimize (cmd, logs to C:\Temp\OSOT-logs\)
#   5. PAUSE for log review
#   6. AppX cleanup + OSOT Generalize (sysprep shuts down VM)
#   7. Packer reconnects post-sysprep           <- Phase 3
#   8. Horizon Agent + DEM Agent
#   9. OSOT Finalize (cmd, logs to C:\Temp\OSOT-logs\)
#  10. PAUSE for log review
#  11. App Volumes Agent + Final cleanup
#
# Logs are downloaded from VM to C:\Packer\logs\ after each step.
# NOTE: Windows Update disabled for testing.
##############################################################################

packer {
  required_version = ">= 1.15.0"

  required_plugins {
    vsphere = {
      source  = "github.com/vmware/vsphere"
      version = ">= 2.1.2"
    }
    windows-update = {
      source  = "github.com/rgl/windows-update"
      version = ">= 0.16.0"
    }
  }
}

locals {
  build_timestamp = formatdate("DD.MM.YYYY-hh-mm", timestamp())
  vm_name         = "${var.vm_name_prefix}-${local.build_timestamp}"
}

source "vsphere-iso" "horizon_image" {

  vcenter_server      = var.vcenter_server
  username            = var.vcenter_username
  password            = var.vcenter_password
  insecure_connection = var.vcenter_insecure_connection
  datacenter          = var.datacenter
  cluster             = var.cluster
  datastore           = var.datastore
  folder              = var.vm_folder

  vm_name       = local.vm_name
  guest_os_type = var.guest_os_type
  notes         = "Omnissa Horizon Golden Image built by Packer on ${local.build_timestamp}"

  CPUs                 = var.vm_cpus
  cpu_cores            = var.vm_cpu_cores
  RAM                  = var.vm_ram_mb
  RAM_reserve_all      = false
  firmware             = var.vm_firmware
  disk_controller_type = ["pvscsi"]

  storage {
    disk_size             = var.vm_disk_size_gb * 1024
    disk_thin_provisioned = true
  }

  network_adapters {
    network      = var.vm_network
    network_card = "vmxnet3"
  }

  cdrom_type = "sata"

  iso_paths = [
    var.windows_iso_path,
    var.vmtools_iso_path,
  ]

  floppy_files = [
    "${path.root}/http/autounattend.xml",
    "${path.root}/http/setup.ps1",
  ]

  boot_order   = "cdrom,disk"
  boot_wait    = "3s"
  boot_command = ["<spacebar><spacebar>"]

  communicator      = "winrm"
  winrm_username    = var.winrm_username
  winrm_password    = var.winrm_password
  winrm_timeout     = "24h"
  winrm_use_ssl     = false
  winrm_insecure    = true
  ip_wait_timeout   = "90m"
  ip_settle_timeout = "5s"

  convert_to_template = false
  create_snapshot     = false

  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer build complete\""
  shutdown_timeout = "30m"
}

build {
  name    = "horizon-golden-image"
  sources = ["source.vsphere-iso.horizon_image"]

  ##########################################################################
  # STABILIZE
  # Remove audit.exe from Winlogon, reboot for clean WinRM session
  ##########################################################################

  provisioner "powershell" {
    script = "${path.root}/http/Disable-AuditMode.ps1"
  }

  provisioner "windows-restart" {
    restart_timeout       = "15m"
    restart_check_command = "powershell -command 'Write-Output ready'"
  }

  # Download FLC log after first boot
  provisioner "file" {
    source      = "C:\\Windows\\Temp\\packer-flc.log"
    destination = "C:/Packer/logs/packer-flc.log"
    direction   = "download"
    generated   = true
  }

  ##########################################################################
  # PHASE 1 - Applications (audit mode)
  ##########################################################################

  provisioner "powershell" {
    script           = "${path.root}/http/Show-BuildStatus.ps1"
    environment_vars = ["PHASE_NAME=PHASE 1 START: Applications + Copilot"]
  }

  provisioner "powershell" {
    script = "${path.root}/scripts/phase1/02-install-dotnet.ps1"
  }

  # Download .NET install log
  provisioner "file" {
    source      = "C:\\Windows\\Logs\\CBS\\CBS.log"
    destination = "C:/Packer/logs/phase1-cbs.log"
    direction   = "download"
    generated   = true
  }

  provisioner "powershell" {
    script           = "${path.root}/scripts/phase1/03-install-applications.ps1"
    environment_vars = ["APPS_SOURCE=${var.apps_share_path}"]
  }

  provisioner "powershell" {
    script = "${path.root}/scripts/phase1/03b-disable-copilot.ps1"
  }

  # Windows Update - DISABLED FOR TESTING
  # provisioner "windows-update" { ... }
  # provisioner "windows-restart" { restart_timeout = "20m" }

  ##########################################################################
  # PHASE 2 - OSOT Optimize then Generalize
  ##########################################################################

  provisioner "powershell" {
    script           = "${path.root}/http/Show-BuildStatus.ps1"
    environment_vars = ["PHASE_NAME=PHASE 2 START: OSOT Optimize + Generalize"]
  }

  # Upload OSOT exe, XML, JSON, cmd files and pause script
  provisioner "file" {
    source      = var.osot_local_path
    destination = "C:\\Temp\\OmnissaHorizonOSOptimizationTool-x86_64-1.2.2603.23605577104.exe"
  }

  provisioner "file" {
    source      = "./http/w11sysprep.xml"
    destination = "C:\\Temp\\w11sysprep.xml"
  }

  provisioner "file" {
    source      = "./installers/Windows 10, 11 and Server 2019, 2022 2026-07-08-085321.json"
    destination = "C:\\Temp\\Windows 10, 11 and Server 2019, 2022 2026-07-08-085321.json"
  }

  provisioner "file" {
    source      = "./http/Run-OSOTOptimize.cmd"
    destination = "C:\\Temp\\Run-OSOTOptimize.cmd"
  }

  provisioner "file" {
    source      = "./http/Run-OSOTGeneralize.cmd"
    destination = "C:\\Temp\\Run-OSOTGeneralize.cmd"
  }

  provisioner "file" {
    source      = "./http/Run-OSOTFinalize.cmd"
    destination = "C:\\Temp\\Run-OSOTFinalize.cmd"
  }

  provisioner "file" {
    source      = "./http/Pause-ForReview.ps1"
    destination = "C:\\Temp\\Pause-ForReview.ps1"
  }

  provisioner "file" {
    source      = "./http/Invoke-OSOTStep.ps1"
    destination = "C:\\Temp\\Invoke-OSOTStep.ps1"
  }

  # AppX cleanup before OSOT
  provisioner "powershell" {
    script = "${path.root}/scripts/phase2/05-cleanup-appx.ps1"
  }

  # OSOT Optimize - runs cmd file, pauses if fails so you can run manually
  provisioner "powershell" {
    script  = "${path.root}/http/Invoke-OSOTStep.ps1"
    environment_vars = ["STEP=OPTIMIZE"]
    timeout = "240m"
  }

  # Download OSOT Optimize logs
  provisioner "file" {
    source      = "C:\\Temp\\OSOT-logs\\"
    destination = "C:/Packer/logs/osot-optimize/"
    direction   = "download"
    generated   = true
  }

  # PAUSE after Optimize - signal: New-Item -ItemType File -Path 'C:\Temp\PAUSE_POST-OPTIMIZE_READY.txt' -Force
  provisioner "windows-restart" {
    restart_timeout       = "240m"
    restart_check_command = "powershell -ExecutionPolicy Bypass -File C:\\Temp\\Pause-ForReview.ps1 -PauseName POST-OPTIMIZE"
  }

  provisioner "windows-restart" {
    restart_timeout       = "30m"
    restart_check_command = "powershell -command 'Write-Output ready'"
  }

  # OSOT Generalize - runs cmd file, pauses if fails so you can run manually
  provisioner "powershell" {
    script  = "${path.root}/http/Invoke-OSOTStep.ps1"
    environment_vars = ["STEP=GENERALIZE"]
    timeout = "240m"
  }

  # Wait for sysprep reboot + OOBE + WinRM re-enable via RunOnce
  provisioner "windows-restart" {
    restart_timeout       = "90m"
    restart_check_command = "powershell -command 'Write-Output ready'"
  }

  ##########################################################################
  # PHASE 3 - Post-Sysprep Agent Installation
  ##########################################################################

  provisioner "powershell" {
    script           = "${path.root}/http/Show-BuildStatus.ps1"
    environment_vars = ["PHASE_NAME=PHASE 3 START: Agent Installation (post-sysprep)"]
  }

  # Re-upload OSOT, cmd files and pause script (C:\Temp cleared during sysprep)
  provisioner "file" {
    source      = var.osot_local_path
    destination = "C:\\Temp\\OmnissaHorizonOSOptimizationTool-x86_64-1.2.2603.23605577104.exe"
  }

  provisioner "file" {
    source      = "./http/Run-OSOTFinalize.cmd"
    destination = "C:\\Temp\\Run-OSOTFinalize.cmd"
  }

  provisioner "file" {
    source      = "./http/Pause-ForReview.ps1"
    destination = "C:\\Temp\\Pause-ForReview.ps1"
  }

  # Upload agent installers to C:\Temp
  provisioner "file" {
    source      = var.horizon_agent_installer
    destination = "C:\\Temp\\Omnissa-Horizon-Agent-x86_64-2603-8.18.0-24273927036.exe"
  }

  provisioner "file" {
    source      = "./installers/horizon-agent-settings.txt"
    destination = "C:\\Temp\\horizon-agent-settings.txt"
  }

  provisioner "file" {
    source      = var.dem_agent_installer
    destination = "C:\\Temp\\Omnissa Dynamic Environment Manager Enterprise 2603 10.19 x64.msi"
  }

  provisioner "file" {
    source      = var.appvolumes_agent_installer
    destination = "C:\\Temp\\App Volumes Agent.msi"
  }

  # Install Horizon Agent
  provisioner "powershell" {
    script  = "${path.root}/scripts/phase3/07-install-horizon-agent.ps1"
    timeout = "30m"
  }

  # Download Horizon Agent install log
  provisioner "file" {
    source      = "C:\\Temp\\horizon-agent-install.log"
    destination = "C:/Packer/logs/horizon-agent-install.log"
    direction   = "download"
    generated   = true
  }

  provisioner "file" {
    source      = "C:\\ProgramData\\Omnissa\\Horizon\\logs\\"
    destination = "C:/Packer/logs/horizon-agent-vminst/"
    direction   = "download"
    generated   = true
  }

  provisioner "windows-restart" {
    restart_timeout = "20m"
  }

  # Install DEM Agent
  provisioner "powershell" {
    script  = "${path.root}/scripts/phase3/08-install-dem-agent.ps1"
    timeout = "15m"
  }

  # Download DEM Agent install log
  provisioner "file" {
    source      = "C:\\Temp\\dem-agent-install.log"
    destination = "C:/Packer/logs/dem-agent-install.log"
    direction   = "download"
    generated   = true
  }

  provisioner "windows-restart" {
    restart_timeout = "20m"
  }

  # Upload sdelete64.exe to System32 (required for OSOT Finalize step 7)
  provisioner "file" {
    source      = "./installers/sdelete64.exe"
    destination = "C:\\Windows\\System32\\sdelete64.exe"
  }

  # OSOT Finalize - runs cmd file, pauses if fails so you can run manually
  # Step 7 (sdelete) included since sdelete64.exe is in System32
  provisioner "powershell" {
    script  = "${path.root}/http/Invoke-OSOTStep.ps1"
    environment_vars = ["STEP=FINALIZE"]
    timeout = "240m"
  }

  # Download OSOT Finalize logs
  provisioner "file" {
    source      = "C:\\Temp\\OSOT-logs\\"
    destination = "C:/Packer/logs/osot-finalize/"
    direction   = "download"
    generated   = true
  }

  # PAUSE after Finalize - signal: New-Item -ItemType File -Path 'C:\Temp\PAUSE_POST-FINALIZE_READY.txt' -Force
  provisioner "windows-restart" {
    restart_timeout       = "240m"
    restart_check_command = "powershell -ExecutionPolicy Bypass -File C:\\Temp\\Pause-ForReview.ps1 -PauseName POST-FINALIZE"
  }

  provisioner "windows-restart" {
    restart_timeout       = "20m"
    restart_check_command = "powershell -command 'Write-Output ready'"
  }

  # Install App Volumes Agent (always last per Omnissa guide)
  provisioner "powershell" {
    script  = "${path.root}/scripts/phase3/10-install-appvolumes-agent.ps1"
    timeout = "15m"
  }

  # Download App Volumes Agent install log
  provisioner "file" {
    source      = "C:\\Temp\\appvolumes-agent-install.log"
    destination = "C:/Packer/logs/appvolumes-agent-install.log"
    direction   = "download"
    generated   = true
  }

  # Final cleanup
  provisioner "powershell" {
    script = "${path.root}/scripts/phase3/11-final-cleanup.ps1"
  }

  post-processor "manifest" {
    output     = "builds/manifest-${local.build_timestamp}.json"
    strip_path = true
  }
}
