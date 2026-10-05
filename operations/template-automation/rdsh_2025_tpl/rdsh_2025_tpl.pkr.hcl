// rdsh_2025_tpl.pkr.hcl
// Builds the Windows Server 2025 Omnissa Horizon RDSH instant-clone golden
// image: boots the Windows Server install ISO under vSphere, feeds it an
// autounattend.xml answer file over a virtual floppy, then hands off to
// Ansible over WinRM for everything in-guest. Adapted from the Omnissa
// Community guide "Horizon Gold Image creation with Ansible" - see
// playbook.yml and roles/ for the step-by-step mapping, and this file's
// inline comments for where this deliberately diverges from that guide.
//
// Two structural differences from that guide, both intentional, matching
// how images/ubt_2404_tpl/ubt_2404_tpl.pkr.hcl already does things on this
// platform rather than reproducing the guide's own different architecture:
//
//   1. Answer file delivery: the guide burns autounattend.xml onto a real
//      ISO via genisoimage and stages it on the NFS share as a second
//      vsphere-iso CD-ROM device. This project already has a simpler,
//      self-contained pattern for that (ubt_2404_tpl's http_content +
//      templatefile()) - floppy_content (confirmed present in
//      packer-plugin-vsphere's FloppyConfig) is the Windows-side
//      equivalent, so that's what's used below instead. No genisoimage
//      dependency, no NFS ISO staging step.
//
//   2. Provisioning: the guide runs Packer only up through first WinRM
//      contact, then hands off to a SEPARATE set of manually-orchestrated
//      ansible-playbook stages (power on, run one stage, snapshot, power
//      off, repeat) outside of Packer entirely. This project instead keeps
//      everything in ONE packer build, same as ubt_2404_tpl: a single
//      "ansible" provisioner runs playbook.yml top to bottom, and
//      ansible.windows.win_reboot (used inside roles/rds_role_install and
//      roles/horizon_agent) survives being called mid-playbook over WinRM
//      just fine - Ansible's own Windows modules are built for exactly
//      this, so no separate Packer "windows-restart" provisioner or
//      external stage orchestration is needed either.
//
// Also NOT in this file, on purpose: no domain_join role/stage anywhere in
// this build. Per the source guide's own horizon_pool.yml (pool_ic_domain_
// account, pool_customization_type = "CLONE_PREP"), an RDSH/VDI Horizon
// INSTANT CLONE pool joins each spawned host to the domain itself, per
// clone, at spawn time - the golden image is never domain-joined. That's
// different from ubt_2404_tpl's Linux flow (which does join the build VM to
// the domain directly, since Horizon Agent for Linux doesn't have the same
// native per-clone customization support Windows does) - don't assume the
// two images need the same domain-join treatment.
//
// This does NOT convert the VM to a vSphere template, same reasoning as
// ubt_2404_tpl: Horizon instant clones are built from a snapshot on a
// normal VM, not a vCenter template.
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
  description = "Zip build_log_dir (C:\\ProgramData\\Omnissa\\Logs) at the end of the build and fetch it to this control node - see roles/collect_build_logs. scripts/build.sh sets this from an interactive prompt at the start of the build; override with PKR_VAR_collect_build_logs=false to skip the prompt and always decline."
}

locals {
  # Rendered once and reused for floppy_content, so it can't drift from what
  # actually gets fed to Windows setup - same reasoning as ubt_2404_tpl's
  # local.user_data. Note the directory is floppy/, not http/ - this image
  # doesn't use Packer's built-in HTTP server at all (see this file's header
  # comment on floppy_content vs. http_content).
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
  })
}

source "vsphere-iso" "rdsh_2025_tpl" {
  # ---- vCenter ----
  vcenter_server      = var.vcenter_server
  username            = var.vcenter_username
  password            = var.vcenter_password
  insecure_connection = var.vcenter_insecure_connection
  datacenter          = var.vcenter_datacenter
  cluster             = var.vcenter_cluster
  datastore           = var.vcenter_datastore
  folder              = var.vcenter_folder

  # ---- VM identity & placement ----
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
  // UEFI + Secure Boot when vm_secure_boot = true (default). No vTPM:
  // Horizon adds its own to the clones.
  firmware = var.vm_secure_boot ? "efi-secure" : "efi"

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

  # ---- Install media ----
  # Already staged on the datastore - Packer mounts directly, no download,
  # no iso_checksum. iso_paths[0] is the Windows Server install ISO;
  # iso_paths[1] (see variables.pkr.hcl's comment) is the ESXi-provided
  # VMware Tools ISO, mounted as a second CD-ROM the same way the source
  # guide's own windowsserver-rdsh.pkr.hcl does it.
  iso_paths = var.iso_paths

  floppy_content = {
    "autounattend.xml"     = local.autounattend
    "windows-vmtools.ps1" = file("${path.root}/floppy/windows-vmtools.ps1")
  }

  # A brand-new disk boots straight to the Windows Server install ISO with
  # no interactive prompt to press a key (unlike older Windows media) as
  # long as the CD-ROM has a valid, connected ISO - same reasoning as
  # ubt_2404_tpl's boot_command comment about EFI firmware falling through
  # boot_order on its own. The handful of <enter> keystrokes below exist
  # purely as a safety net in case a "Press any key to boot from CD/DVD..."
  # prompt does appear (some ISO builds still show one); harmless no-ops if
  # it doesn't, same pattern the source guide's own pkr.hcl uses.
  boot_order   = "disk,cdrom"
  boot_wait    = "5s"
  boot_command = ["<enter><enter><enter><enter><enter>"]

  # ---- Guest connection once the OS is up ----
  communicator    = "winrm"
  winrm_username  = var.build_username
  winrm_password  = var.build_password
  winrm_port      = var.winrm_port
  winrm_use_ssl   = false
  winrm_insecure  = true
  winrm_timeout   = "90m" # unattended Server install + first boot is slow, same order of magnitude as ubt_2404_tpl's 45m SSH timeout
  ip_wait_timeout = "45m"

  tools_upgrade_policy = true
  remove_cdrom          = true
  convert_to_template   = false # see file header - instant clones need a snapshotted VM, not a template

  # Plain `shutdown /s` rather than ubt_2404_tpl's piped-sudo-password
  # approach - the WinRM communicator is already authenticated as
  # build_username (Administrator), which can shut itself down without an
  # extra credential prompt the way the Linux build's non-NOPASSWD sudo
  # account needed one.
  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer build complete\""
  shutdown_timeout = "15m"
}

build {
  sources = ["source.vsphere-iso.rdsh_2025_tpl"]

  provisioner "ansible" {
    playbook_file = "${path.root}/playbook.yml"
    user          = var.build_username
    use_proxy     = false
    extra_arguments = concat(
      [
        # Same three-file convention as ubt_2404_tpl.pkr.hcl: shared platform
        # vars, shared vault, this image's own non-secret vars - nothing
        # image-specific redeclared here.
        "-e", "@${var.inventory_dir}/group_vars/all.yml",
        "-e", "@${var.inventory_dir}/group_vars/all/vault.yml",
        "-e", "@${var.inventory_dir}/group_vars/rdsh_2025_tpl.yml",
        "-e", "@${var.inventory_dir}/group_vars/rdsh_2025_tpl_agents.yml",
        "-e", "@${var.inventory_dir}/group_vars/rdsh_2025_tpl_osot.yml",
      ],
      fileexists("${var.inventory_dir}/group_vars/rdsh_2025_tpl.local.yml") ? [
        "-e", "@${var.inventory_dir}/group_vars/rdsh_2025_tpl.local.yml",
      ] : [],
      [
        "--vault-password-file", "~/.vault_pass",
        # WinRM connection details for the ansible provisioner's own generated
        # inventory - ansible_password isn't picked up from the WinRM
        # communicator settings above automatically, it has to be forwarded
        # explicitly, same "nothing crosses from Packer to Ansible on its own"
        # lesson ubt_2404_tpl's ansible_become_password comment already
        # documents for the Linux side.
        "-e", "ansible_password=${var.build_password}",
        "-e", "ansible_winrm_server_cert_validation=ignore",
        "-e", "ansible_winrm_transport=ntlm",
        # Scoped here, NOT in group_vars/all.yml: this build's WinRM plays need
        # cmd (Ansible's win_* action plugins build their command lines for cmd
        # and this project's default connection is winrm), but group_vars/all.yml
        # is shared with the connection: local utility plays (resolve_vars.yml,
        # preflight_check_vm.yml, etc.) elsewhere in this repo, where forcing
        # ansible_shell_type=cmd breaks the local shell instead. Setting it only
        # as a provisioner -e here means it only ever applies to this playbook's
        # own WinRM run. Without this, Ansible warns "The winrm connection
        # plugin should have the shell type of cmd and not powershell" and
        # win_* tasks fail confusingly (WSMan OperationTimeout, "resource is in
        # use", garbled command dumps) - confirmed by an actual build failure
        # dying on the very first task (Gathering Facts) with exactly this
        # warning immediately above the error.
        "-e", "ansible_shell_type=cmd",
        # Disabling message encryption here does NOT newly expose anything -
        # winrm_insecure=true above already means Packer's own WinRM
        # communicator traffic is unencrypted plain HTTP on this same
        # isolated build subnet; this just stops Ansible's own separate
        # WinRM connection from adding (and apparently sometimes corrupting)
        # an extra encryption layer on top of a transport that was already
        # deliberately left unencrypted.
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
