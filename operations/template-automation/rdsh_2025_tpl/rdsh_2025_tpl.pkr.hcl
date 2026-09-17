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
// UPDATED 2026-09-11: OSOT (OS Optimization Tool) IS now automated
// (playbook.yml's osot_optimize/osot_generalize/osot_finalize roles) - this
// comment previously called it "a known, previously-unresolved blocker on
// this exact platform (hangs under Packer's WinRM provisioner due to
// window-station restrictions)". That diagnosis was correct for the GUI
// (a WPF app needing an interactive desktop/window station a non-interactive
// WinRM session doesn't have) but the fix was never actually blocked - OSOT
// ships a documented CLI (Omnissa docs: "Run Windows OS Optimization Tool
// for Horizon from Command Line") that runs headless by design, sidestepping
// the window-station problem entirely. See playbook.yml's own header and
// roles/osot_optimize/osot_generalize/osot_finalize for the full rewrite,
// done per the user's explicit request after reviewing Omnissa's "Using
// Automation to Create Optimized Windows Images for Horizon VMs" and
// "Manually creating optimized Windows images for Horizon VMs" guides.
//
// In-pipeline Windows Update IS automated (playbook.yml's windows_update
// role) - this comment previously said it was deliberately skipped as
// "optional" in the source guide, matching ubt_2404_tpl's own precedent of
// not doing it in-pipeline. That was wrong on the specific point that
// matters here: the source guide only marks .NET Framework 3.5 (NetFx3,
// now its own dotnet35 role) as optional - the full Windows Update pass
// itself is a required step in that guide, run in a loop with restarts
// until nothing's left, positioned between hypervisor tools and everything
// after it. Skipping it is what actually caused a real build failure
// (rds_role_install's "Error: 0x800f0922" - see that role's own history and
// windows_update's header comment), not just a flaky nice-to-have being
// left out. Needs the build VM's network segment to have real internet or
// WSUS reachability; ubt_2404_tpl not doing this in-pipeline is no longer
// treated as precedent to follow here.
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
  # EFI without Secure Boot or vTPM - not required for Windows Server RDSH,
  # unlike Windows 11 VDI (which needs both). Matches the source guide's own
  # windowsserver-rdsh.pkr.hcl.
  firmware = "efi"

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

  # ---- Autounattend handoff ----
  # floppy_content (not the genisoimage+CD-ROM approach the source guide
  # uses) - see this file's header comment for why. Windows Setup reads
  # autounattend.xml from removable media root automatically, no boot_command
  # needed to point it there. windows-vmtools.ps1 rides along on the same
  # floppy (mounted as A:\, and still attached at this point regardless of
  # which configuration pass is running - see floppy/autounattend.pkrtpl.hcl's
  # own header) - autounattend.xml's own auditUser RunSynchronous pass
  # invokes it to silently install VMware Tools from the second CD-ROM
  # (iso_paths[1]). UPDATED 2026-09-16: this invocation used to be in
  # oobeSystem's own FirstLogonCommands (the source guide's own
  # script/invocation split, just delivered via floppy instead of the answer
  # ISO); moved to auditUser as part of entering Audit Mode automatically
  # during install itself - see roles/enter_audit_mode's own header for the
  # full rationale. windows-vmtools.ps1 itself needed no changes for the
  # move (no OOBE-specific assumptions).
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
    extra_arguments = [
      # Same three-file convention as ubt_2404_tpl.pkr.hcl: shared platform
      # vars, shared vault, this image's own non-secret vars - nothing
      # image-specific redeclared here.
      "-e", "@${var.inventory_dir}/group_vars/all.yml",
      "-e", "@${var.inventory_dir}/group_vars/all/vault.yml",
      "-e", "@${var.inventory_dir}/group_vars/rdsh_2025_tpl.yml",
      "--vault-password-file", "~/.vault_pass",
      # WinRM connection details for the ansible provisioner's own generated
      # inventory - ansible_password isn't picked up from the WinRM
      # communicator settings above automatically, it has to be forwarded
      # explicitly, same "nothing crosses from Packer to Ansible on its own"
      # lesson ubt_2404_tpl's ansible_become_password comment already
      # documents for the Linux side.
      "-e", "ansible_password=${var.build_password}",
      "-e", "ansible_winrm_server_cert_validation=ignore",
      # NTLM transport, not pywinrm's Basic-auth default - CHANGED 2026-09-14
      # per the Omnissa Community "Horizon Gold Image creation with Ansible"
      # guide's own vars/rdsh_image.yml (winrm_transport: "ntlm"), tried as a
      # fix for this build's ongoing WinRM instability. The guide's own
      # stated reason: Windows Update's API needs the token NTLM negotiation
      # provides, Basic auth doesn't carry it - and separately, Basic auth's
      # failure modes are exactly the kind of generic, undifferentiated
      # "Access is denied" this pipeline has been chasing all session
      # (lockout, bad password, and must-change-password all surfaced
      # identically under Basic - see floppy/autounattend.pkrtpl.hcl's
      # lockoutthreshold comment). Requires the requests_ntlm Python package
      # in the control node's ansible-venv (pip install requests_ntlm) -
      # pywinrm itself is already a prerequisite for the Basic path this
      # replaces, so only requests_ntlm is new. WinRM's service side now
      # enables BOTH Basic and Negotiate (see floppy/autounattend.pkrtpl.hcl's
      # own auditSystem/auditUser passes - this content used to live in
      # roles/enter_audit_mode/templates/audit_answer.xml.j2, now deleted,
      # its proven WinRM-bootstrap sequence moved verbatim into that file
      # instead - and roles/osot_generalize/templates/generalize_answer.xml.j2 -
      # both updated together) so this is additive, not a replacement - if NTLM
      # doesn't pan out, dropping this one line reverts to Basic without
      # touching the Windows-side config at all.
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
      # ADDED 2026-09-15 after a real build died mid-playbook with
      # "[ERROR]: Task failed: Bad HTTP response returned from server.
      # Code 400" - not an OSOT-specific error at all, a genuine WinRM
      # transport failure, thrown from
      # roles/osot_optimize/tasks/main.yml's own "Wait for OSOT Optimize
      # pass to finish" polling task after only ~21 retries (~5 minutes),
      # while an earlier file-gate pause task in that SAME build (roles/
      # enter_audit_mode, same short-WinRM-call-in-a-loop pattern) had
      # already run 222 retries (~55 minutes) without incident - so this
      # wasn't "polling eventually breaks WinRM," it was specific to
      # whatever that particular task's WinRM traffic was doing.
      #
      # Root cause candidate, from Ansible's own WinRM docs
      # (docs.ansible.com/projects/ansible/latest/os_guide/windows_winrm.html):
      # "HTTP can be used when the authentication option is NTLM, Kerberos
      # or CredSSP. These protocols will encrypt the WinRM payload with
      # their own encryption method before sending it to the server" -
      # i.e. with winrm_use_ssl=false/winrm_insecure=true above (Packer's
      # own deliberate choice, unrelated to this) and ntlm transport
      # (added 2026-09-14, see that var's own comment), every single WinRM
      # request this whole playbook sends is being wrapped in NTLM's own
      # message-level encryption automatically - "message-level encryption
      # is not used when running over HTTPS" (same doc), confirming this
      # only applies because this build deliberately isn't using HTTPS.
      # A real, still-open ansible-project forum thread
      # (forum.ansible.com/t/kerberos-bad-http-response-returned-from-server-code-400/26869)
      # documents the IDENTICAL error text, root-caused there to that same
      # message-encryption layer failing and producing a malformed
      # request, for the Kerberos case specifically - fixed by setting
      # ansible_winrm_message_encryption=never (or moving to HTTPS, port
      # 5986, not used here). That thread is Kerberos, not NTLM - this is
      # inference by analogy to NTLM's own equivalent encryption wrapping,
      # not a confirmed identical bug report for NTLM, so treat this as
      # the best-evidenced candidate worth testing next, not a confirmed
      # fix yet.
      #
      # Disabling message encryption here does NOT newly expose anything -
      # winrm_insecure=true above already means Packer's own WinRM
      # communicator traffic is unencrypted plain HTTP on this same
      # isolated build subnet; this just stops Ansible's own separate
      # WinRM connection from adding (and apparently sometimes corrupting)
      # an extra encryption layer on top of a transport that was already
      # deliberately left unencrypted.
      "-e", "ansible_winrm_message_encryption=never",
    ]
  }
}
