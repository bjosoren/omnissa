// variables.pkr.hcl
// Every value here is either non-secret (comes from the shared inventory/group_vars
// tree, two levels up from this file, via a PKR_VAR_ env export in scripts/build.sh)
// or secret (comes from the shared vault the same way) - same convention as
// images/ubt_2404_tpl/variables.pkr.hcl.
// Nothing in this file should ever be hand-edited with a real credential in it.

# ---- vCenter connection (shared platform credential) ----
variable "vcenter_server" {
  type = string
}
variable "vcenter_username" {
  type = string
}
variable "vcenter_password" {
  type      = string
  sensitive = true
}
variable "vcenter_insecure_connection" {
  type    = bool
  default = true
}

# ---- Placement ----
variable "vcenter_datacenter" {
  type = string
}
variable "vcenter_cluster" {
  type = string
}
variable "vcenter_datastore" {
  type = string
}
variable "vcenter_folder" {
  type    = string
  default = "golden-images"
}
variable "vcenter_network" {
  type = string
}

# ---- VM identity ----
# vm_name is intentionally NOT defaulted here - scripts/build.sh passes in a
# fixed, reused name (image.conf's VM_NAME), same reasoning as
# images/ubt_2404_tpl/variables.pkr.hcl's vm_name comment: a fixed, reused
# build VM lets mac_address below be safely pinned, and the post-build clone
# (not this VM) is what actually gets published to Horizon.
variable "vm_name" {
  type = string
}
variable "mac_address" {
  type    = string
  default = "" # empty = vSphere auto-assigns a MAC and the guest gets its address over DHCP; set to a reserved 00:50:56:xx:xx:xx address only if you also pre-created a DHCP reservation for it
}
variable "vm_cpu_count" {
  type    = number
  default = 4
  # RDSH hosts serve multiple concurrent sessions - the Omnissa Community RDSH
  # guide this was adapted from defaults to 4 vCPU / 2 cores-per-socket /
  # 16GB RAM for exactly this reason, well above ubt_2404_tpl's VDI-sized 2/4096.
}
variable "vm_cores_per_socket" {
  type    = number
  default = 2
}
variable "vm_mem_size_mb" {
  type    = number
  default = 16384
}
variable "vm_disk_size_mb" {
  type    = number
  default = 81920
}

# ---- Guest OS type ----
# VERIFIED against this environment's own vCenter (GPU-02 cluster, ESXi 8.0
# U2+): exported a throwaway VM created with "Microsoft Windows Server 2025
# (64-bit)" selected in the New VM wizard as OVF and read back its
# OperatingSystemSection - vmw:osType="windows2022srvNext_64Guest". So even
# though the friendly picker shows a dedicated "2025" entry here, the
# underlying guestId still reuses the 2022 "srvNext" identifier - matches
# the ambiguity this project's source guide itself had (its variables text
# said windows2022srvNext_64Guest, its .pkr.hcl default said
# windows2025srvNext_64Guest; this environment resolves that as the former).
# If you rebuild against a different vCenter/ESXi build later, re-verify the
# same way (Export OVF Template on a throwaway VM, or the MOB / PowerCLI
# ExtensionData.Config.GuestId route) rather than assuming this carries over.
variable "vm_guest_os_type" {
  type    = string
  default = "windows2022srvNext_64Guest"
}
variable "vm_version" {
  type    = number
  default = 20 # hardware version 20 required for a native Server 2025 guest profile (ESXi 8.0.3+)
}

# ---- Install media ----
# Same non-download, already-staged convention as ubt_2404_tpl: Packer mounts
# these directly, no iso_checksum. Three entries: the Windows Server install
# media, and the ESXi-provided VMware Tools ISO (no datastore name needed for
# that one - "[] /vmimages/tools-isoimages/windows.iso" resolves against
# whichever datastore the host already serves it from).
variable "iso_paths" {
  type = list(string)
  # e.g. [
  #   "[datastore1] ISOs/en-us_windows_server_2025_updated_x64.iso",
  #   "[] /vmimages/tools-isoimages/windows.iso",
  # ]
}

# ---- Guest OS / network answers for the autounattend ----
variable "guest_hostname" {
  type    = string
  default = "rdsh-2025-tpl"
  # Windows NetBIOS computer names are capped at 15 characters - keep whatever
  # you set here (and any per-run suffix a future variant might add) under
  # that limit, or Windows setup silently truncates it.
}
variable "guest_ip_cidr" {
  type    = string
  default = ""
  # Not consumed anywhere in this build today - no task in
  # floppy/autounattend.pkrtpl.hcl or playbook.yml sets a static IP, so the
  # guest already comes up on DHCP regardless of what this holds. Left
  # optional/unused on purpose for a DHCP-only setup; only fill this (and
  # add an actual static-IP task) if you later want a reserved address
  # instead. e.g. "192.0.2.60/24"
}
variable "guest_gateway" {
  type    = string
  default = ""
  # Same "currently unused, DHCP-only" note as guest_ip_cidr above.
}
variable "guest_dns_servers" {
  type    = list(string)
  default = []
  # Same "currently unused, DHCP-only" note as guest_ip_cidr above.
}
variable "domain_fqdn" {
  type = string
}
variable "timezone" {
  type    = string
  default = "W. Europe Standard Time"
  # Windows unattend.xml wants the Windows time zone display name, not an
  # IANA tz like Ubuntu's "Europe/Oslo" - see Microsoft's own reference list
  # ("W. Europe Standard Time" covers Norway/CET). Confirm against
  # `tzutil /l` on any existing Windows host if unsure.
}
variable "win_language" {
  type    = string
  default = "en-US"
}
variable "win_keyboard" {
  type    = string
  default = "0409:00000409" # US keyboard layout ID; "0414:00000414" for Norwegian - confirm which you want
}

# ---- Windows image selection ----
variable "win_image_name" {
  type = string
  # Must match an edition name inside the mounted install.wim EXACTLY - list
  # them with: dism /Get-WimInfo /WimFile:D:\sources\install.wim
  # e.g. "Windows Server 2025 Datacenter (Desktop Experience)"
}
variable "win_kms_key" {
  type = string
  # The Server 2025 Datacenter GVLK from Microsoft's public KMS client key
  # list - a generic volume-license placeholder key, not a real license key,
  # used only to get through setup unattended; activation against your real
  # KMS host happens later, same as any other VLK-licensed Windows Server.
}

# ---- Build-time local account (used by Packer/Ansible only) ----
variable "build_username" {
  type    = string
  default = "Administrator"
  # Unlike ubt_2404_tpl's separate build_username, Windows autounattend
  # provisions the built-in Administrator account directly (see
  # http/autounattend.pkrtpl.hcl) - there's no separate non-admin build
  # account here.
  #
  # REVERTED 2026-09-14: briefly changed to "winrmadmin" (a dedicated local
  # admin account created by floppy/autounattend.pkrtpl.hcl's specialize
  # pass) after Administrator's WinRM logons kept failing all session -
  # reverted back out per the user's explicit request after the very next
  # real build hung at a DIFFERENT point (Packer's own initial WinRM
  # communicator connection, before any Ansible role runs) with the console
  # showing a fully-booted desktop that was entirely unresponsive to
  # input - which looks like an ESXi/vCenter-level pending-question VM
  # pause, not something this file change would cause, but reverting this
  # one narrows things down while that gets checked separately. The
  # winrmadmin account itself is still created by autounattend.pkrtpl.hcl
  # (harmless, unused while this variable points back at Administrator) -
  # see that file's own comment for the full original rationale if this
  # needs revisiting once the actual cause of the freeze is confirmed.
}
variable "build_password" {
  type      = string
  sensitive = true
  # Plaintext Administrator password - baked into the autounattend template
  # (UserAccounts/AdministratorPassword, AutoLogon/Password) AND used as the
  # WinRM communicator/Ansible connection password. No password-hash
  # equivalent is needed the way ubt_2404_tpl needs build_password_hash -
  # Windows unattend.xml takes a plaintext (optionally base64'd, here plain)
  # value directly, not a precomputed hash.
}
variable "win_full_name" {
  type    = string
  default = "Administrator"
}
variable "win_org_name" {
  type = string
}

# ---- WinRM ----
variable "winrm_port" {
  type    = number
  default = 5985
}

# ---- Shared platform paths ----
variable "inventory_dir" {
  type = string
  # Absolute path to the shared golden-images/inventory directory, set by
  # scripts/build.sh - same as ubt_2404_tpl's inventory_dir.
}

# ---- Horizon Agent (RDSH mode) ----
# Component toggles map to the ADDLOCAL feature list playbook.yml's
# horizon_agent role builds - see inventory/group_vars/rdsh_2025_tpl.yml for
# the actual per-feature booleans (horizon_core, horizon_blast, etc.), kept
# there rather than here since they're plain non-secret config, same
# separation ubt_2404_tpl uses between variables.pkr.hcl (Packer-consumed)
# and group_vars (Ansible-consumed, forwarded via extra_arguments below).
variable "horizon_agent_installer" {
  type = string
  # path on the CONTROL NODE to the Omnissa-provided Horizon Agent for
  # Windows installer EXE, relative to this image dir, e.g.
  # "files/Omnissa-Horizon-Agent-x86_64-2603-8.18.0-24278394073.exe"
  # Omnissa gates the download behind a portal login, so this can't be
  # fetched automatically - stage it into images/rdsh_2025_tpl/files/ once
  # per agent version, same convention as ubt_2404_tpl's horizon_agent_tarball.
}

# ---- DEM Agent ----
variable "dem_agent_installer" {
  type = string
  # e.g. "files/Omnissa Dynamic Environment Manager Enterprise 2506 10.16 x64.msi"
}

# ---- App Volumes Agent ----
variable "appvolumes_agent_installer" {
  type = string
  # e.g. "files/Omnissa-App-Volumes-Agent-2506.msi"
}
variable "appvolumes_manager" {
  type = string
  # App Volumes Manager hostname/FQDN the agent phones home to.
}
