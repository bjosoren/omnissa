// Windows 11 24H2 golden image for an Omnissa Horizon instant-clone desktop pool.
// Packer creates the VM and installs Windows unattended (autounattend on a
// virtual floppy, Audit Mode entered during setup); a single Ansible run over
// WinRM does everything in-guest. Run via scripts/build.sh, which supplies all
// variables from inventory/group_vars and the vault.

packer {
  required_plugins {
    vsphere = {
      source  = "github.com/hashicorp/vsphere"
      version = "~> 1"
    }
    ansible = {
      source  = "github.com/hashicorp/ansible"
      version = "~> 1"
    }
  }
}

variable "collect_build_logs" {
  type        = bool
  default     = true
  description = "Zip C:\\ProgramData\\Omnissa\\Logs at the end of the build and fetch it to the control node (roles/collect_build_logs)."
}

locals {
  autounattend = templatefile("${path.root}/floppy/autounattend.pkrtpl.hcl", {
    guest_hostname = var.guest_hostname
    win_image_name = var.win_image_name
    win_kms_key    = var.win_kms_key
    win_full_name  = var.win_full_name
    win_org_name   = var.win_org_name
    win_language   = var.win_language
    win_keyboard   = var.win_keyboard
    timezone       = var.timezone
    build_password = var.build_password
    secure_boot    = var.vm_secure_boot
  })
}

source "vsphere-iso" "w11_24h2_tpl" {
  vcenter_server      = var.vcenter_server
  username            = var.vcenter_username
  password            = var.vcenter_password
  insecure_connection = var.vcenter_insecure_connection
  datacenter          = var.vcenter_datacenter
  cluster             = var.vcenter_cluster
  host                = var.vcenter_host != "" ? var.vcenter_host : null # "" = let DRS place it
  datastore           = var.vcenter_datastore
  folder              = var.vcenter_folder

  vm_name       = var.vm_name
  guest_os_type = var.vm_guest_os_type
  vm_version    = var.vm_version
  CPUs          = var.vm_cpu_count
  cpu_cores     = var.vm_cores_per_socket
  RAM           = var.vm_mem_size_mb
  // vGPU from the placement picker ("" = none). A vGPU VM needs all its
  // memory reserved.
  vgpu_profile    = var.vm_vgpu_profile != "" ? var.vm_vgpu_profile : null
  RAM_reserve_all = var.vm_vgpu_profile != ""

  // UEFI + Secure Boot. No vTPM (needs a key provider); Setup's TPM check is
  // bypassed in the autounattend instead.
  firmware = var.vm_secure_boot ? "efi-secure" : "efi"

  // VM advanced parameters from <image>_adv-vm-settings.yml.
  configuration_parameters = var.vm_advanced_settings

  disk_controller_type = ["pvscsi"]
  storage {
    disk_size             = var.vm_disk_size_mb
    disk_thin_provisioned = true
  }

  network_adapters {
    network      = var.vcenter_network
    network_card = "vmxnet3"
    mac_address  = var.mac_address
  }

  // Install ISO is read from the control node (NFS mount) and uploaded to
  // [datastore] packer_cache/ once; later builds reuse the cached copy.
  // Set win_iso_url = "" to use a datastore ISO as iso_paths[0] instead.
  iso_url                = var.win_iso_url != "" ? var.win_iso_url : null
  iso_checksum           = var.win_iso_url != "" ? var.win_iso_checksum : null
  remote_cache_datastore = var.remote_cache_datastore != "" ? var.remote_cache_datastore : null
  remote_cache_path      = var.remote_cache_path
  iso_paths              = var.iso_paths # VMware Tools ISO

  floppy_content = {
    "autounattend.xml"    = local.autounattend
    "windows-vmtools.ps1" = file("${path.root}/floppy/windows-vmtools.ps1")
  }

  boot_order   = "disk,cdrom"
  boot_wait    = "5s"
  boot_command = ["<enter><enter><enter><enter><enter>"] # "Press any key to boot from CD"

  communicator    = "winrm"
  winrm_username  = var.build_username
  winrm_password  = var.build_password
  winrm_port      = var.winrm_port
  winrm_use_ssl   = false
  winrm_insecure  = true
  winrm_timeout   = "90m"
  ip_wait_timeout = "45m"

  tools_upgrade_policy = true
  remove_cdrom         = true
  convert_to_template  = false # instant clones use a snapshot of a normal VM

  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer build complete\""
  shutdown_timeout = "15m"
}

build {
  sources = ["source.vsphere-iso.w11_24h2_tpl"]

  provisioner "ansible" {
    playbook_file = "${path.root}/playbook.yml"
    user          = var.build_username
    use_proxy     = false
    extra_arguments = concat(
      [
        "-e", "@${var.inventory_dir}/group_vars/all.yml",
        "-e", "@${var.inventory_dir}/group_vars/all/vault.yml",
        "-e", "@${var.inventory_dir}/group_vars/w11_24h2_tpl.yml",
        "-e", "@${var.inventory_dir}/group_vars/w11_24h2_tpl_agents.yml",
        "-e", "@${var.inventory_dir}/group_vars/w11_24h2_tpl_osot.yml",
      ],
      fileexists("${var.inventory_dir}/group_vars/w11_24h2_tpl_adv-vm-settings.yml") ? [
        "-e", "@${var.inventory_dir}/group_vars/w11_24h2_tpl_adv-vm-settings.yml",
      ] : [],
      // Site-specific overrides (gitignored), loaded last so they win.
      fileexists("${var.inventory_dir}/group_vars/w11_24h2_tpl.local.yml") ? [
        "-e", "@${var.inventory_dir}/group_vars/w11_24h2_tpl.local.yml",
      ] : [],
      [
        "--vault-password-file", "~/.vault_pass",
        "-e", "ansible_password=${var.build_password}",
        "-e", "ansible_winrm_server_cert_validation=ignore",
        // NTLM (needs requests_ntlm on the control node): Windows Update's API
        // needs the token Basic auth doesn't provide.
        "-e", "ansible_winrm_transport=ntlm",
        "-e", "ansible_shell_type=cmd",
        // Plain HTTP on an isolated build network; NTLM message encryption on
        // top of it caused intermittent "Bad HTTP response ... Code 400".
        "-e", "ansible_winrm_message_encryption=never",
        "-e", "collect_build_logs=${var.collect_build_logs}",
        // Windows Update choice from the placement picker (JSON keeps types intact).
        "-e", jsonencode({
          enable_windows_update = var.enable_windows_update
          windows_update_source = var.windows_update_source
          wsus_server_url       = var.wsus_server_url
        }),
      ]
    )
  }
}
