// variables.pkr.hcl
// Every value here is either non-secret (comes from the shared inventory/group_vars
// tree, two levels up from this file, via a PKR_VAR_ env export in scripts/build.sh)
// or secret (comes from the shared vault the same way).
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
# fixed, reused name (not a timestamped one - see that script's own comments
# for why this changed). Packer is invoked with -force so it can destroy and
# recreate this same-named VM on every run instead of erroring with "<name>
# already exists, you can use -force flag to destroy it".
#
# Reusing one fixed name/identity for the VM this actually builds onto -
# rather than a fresh timestamped VM every run, as earlier versions of this
# project did - is what makes mac_address below safe to pin: a real build
# found that once a prior run's finished VM got published to the Horizon
# pool, Horizon "locks" it, but it kept holding the SAME pinned MAC/static IP
# the next build's freshly-installed guest also tried to use - two VMs
# fighting over one identity on the network, which is what caused that run's
# SSH-after-reboot failures. scripts/build.sh's post-build step now clones
# this VM to a separate, freshly timestamped VM (letting vCenter assign IT a
# new MAC) before snapshotting - that clone is what actually gets published
# to Horizon, so the pinned identity here only ever lives on this one
# reusable build VM, never duplicated onto whatever's currently live in the
# pool.
variable "vm_name" {
  type = string
}

variable "mac_address" {
  type    = string
  default = "" # set to a reserved 00:50:56:xx:xx:xx address if you pre-created a DHCP reservation; empty = auto-assigned
  # Only ever applied to the one reusable build VM above (vm_name) - the
  # separate published clone scripts/build.sh creates from it deliberately
  # does NOT reuse this address, so it never collides with whatever's
  # currently locked in the Horizon pool. See vm_name's comment above.
}

variable "vm_cpu_count" {
  type    = number
  default = 2
}

variable "vm_mem_size_mb" {
  type    = number
  default = 4096
}

variable "vm_disk_size_mb" {
  type    = number
  default = 65536
}

# ---- Install media ----
# Points at an ISO already staged on a vSphere datastore or content library -
# Packer mounts it as-is, it doesn't download or re-upload anything, which is
# also why there's no iso_checksum here: that only applies to iso_url's
# download-and-verify path, and is meaningless for a file already in vSphere.
variable "iso_paths" {
  type = list(string)
  # Datastore syntax: "[datastore_name] path/to/file.iso"
  # Content library syntax: "LibraryName/ItemName/file.iso"
  # e.g. ["[datastore1] ISOs/ubuntu-24.04.3-desktop-amd64.iso"]
}

# ---- Guest OS / network answers for the autoinstall user-data ----
variable "guest_hostname" {
  type    = string
  default = "ubt-2404-tpl"
}

variable "guest_ip_cidr" {
  type = string
  # e.g. "192.0.2.50/24" - reserve this address ahead of time, see the platform post
}

variable "guest_gateway" {
  type = string
}

variable "guest_dns_servers" {
  type = list(string)
}

variable "domain_fqdn" {
  type = string
}

variable "timezone" {
  type    = string
  default = "Europe/Oslo"
}

variable "locale" {
  type    = string
  default = "en_US.UTF-8"
}

variable "keyboard_layout" {
  type    = string
  default = "no"
}

# ---- Build-time local account (used by Packer/Ansible only, not an end-user account) ----
variable "build_username" {
  type    = string
  default = "sysadm"
}

variable "build_password_hash" {
  type      = string
  sensitive = true
  # openssl passwd -6 output - scripts/build.sh generates this from vault_local_admin_password
}

variable "build_password" {
  type      = string
  sensitive = true
  # Same account, plaintext this time - the autoinstalled build_username account
  # isn't NOPASSWD, so Ansible's "become" (sudo) needs this to escalate.
  # scripts/build.sh passes it straight through from vault_local_admin_password
  # for the duration of the build only, same handling as build_password_hash.
}

variable "ssh_private_key_file" {
  type    = string
  default = "~/.ssh/golden_image_ed25519"
}

variable "ssh_public_key" {
  type = string
  # contents of golden_image_ed25519.pub - baked into user-data authorized-keys
}

# Domain join credentials (linux_domain_join_username / vault_linux_domain_join_password),
# computer_ou_dn and linux_login_group are deliberately NOT declared as Packer
# variables - the ansible provisioner below loads them straight from the
# shared group_vars/vault files, so they never need to pass through Packer
# (or show up in a `ps` listing as a plain -e key=value).

# ---- Shared platform paths ----
variable "inventory_dir" {
  type = string
  # Absolute path to the shared golden-images/inventory directory, set by
  # scripts/build.sh. Passing this in as an absolute path (rather than
  # having the ansible provisioner reach two directories up from path.root
  # via a relative reference) keeps this working the same way regardless of
  # how/where Packer is invoked from.
}

# ---- Horizon Agent ----
variable "horizon_agent_tarball" {
  type = string
  # path on the CONTROL NODE to the Omnissa-provided tarball, e.g.
  # "files/Omnissa-horizonagent-linux-x86_64-2506-8.16.0.tar.gz"
  # Omnissa gates the download behind a portal login, so this can't be fetched
  # automatically - stage it into images/ubt_2404_tpl/files/ once per agent version.
}

variable "horizon_agent_install_flags" {
  type    = string
  default = "-A yes"
  # -A yes accepts the EULA non-interactively, which is the one flag that's mandatory
  # for a silent run. Add more (audio, SSO, printing, ...) per Omnissa's own
  # "Command-line Options for Installing Horizon Agent for Linux" doc for your version -
  # I'm deliberately not hard-coding those here since they vary by agent release.
}

# ---- NFS home directories ----
variable "nfs_server" {
  type = string
}

variable "nfs_export_path" {
  type = string
}
