// Packer variables for w11_24h2_tpl. Values come from inventory/group_vars
// (<image>.yml, _agents, _osot, _adv-vm-settings, .local) and the vault via
// resolve_vars.yml + export_pkr_vars.sh - never put credentials in this file.

// ---- vCenter ----
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

// ---- Placement (overridden by scripts/select_placement.py) ----
variable "vcenter_datacenter" {
  type = string
}
variable "vcenter_cluster" {
  type = string
}
variable "vcenter_host" {
  type    = string
  default = ""
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

// ---- VM ----
variable "vm_name" {
  type = string
}
variable "mac_address" {
  type    = string
  default = "" # "" = auto-assign; set a 00:50:56:xx:xx:xx address to match a DHCP reservation
}
variable "vm_cpu_count" {
  type    = number
  default = 2
}
variable "vm_cores_per_socket" {
  type    = number
  default = 2
}
variable "vm_mem_size_mb" {
  type    = number
  default = 8192
}
variable "vm_vgpu_profile" { # e.g. "grid_a16-2q"; "" = no vGPU
  type    = string
  default = ""
}
variable "vm_disk_size_mb" {
  type    = number
  default = 81920
}

variable "vm_guest_os_type" {
  type    = string
  default = "windows11_64Guest"
}
variable "vm_secure_boot" {
  type    = bool
  default = true
}
variable "vm_advanced_settings" { # extraConfig key/values
  type    = map(string)
  default = {}
}
variable "vm_version" {
  type    = number
  default = 20
}

// ---- Install media ----
variable "win_iso_url" { # path on the control node, e.g. /mnt/wdnfs/Ansible/windows/<iso>
  type    = string
  default = ""
}
variable "win_iso_checksum" {
  type    = string
  default = "none" # or "sha256:<hash>"
}
variable "remote_cache_datastore" {
  type    = string
  default = ""
}
variable "remote_cache_path" {
  type    = string
  default = "packer_cache"
}
variable "iso_paths" {
  type = list(string)
  default = ["[] /vmimages/tools-isoimages/windows.iso"]
}

// ---- Guest OS ----
variable "guest_hostname" { # max 15 characters (NetBIOS)
  type    = string
  default = "w11-24h2-tpl"
}
variable "guest_ip_cidr" { # informational only - the guest uses DHCP
  type    = string
  default = ""
}
variable "guest_gateway" {
  type    = string
  default = ""
}
variable "guest_dns_servers" {
  type    = list(string)
  default = []
}
variable "domain_fqdn" {
  type = string
}
variable "timezone" {
  type    = string
  default = "W. Europe Standard Time" # Windows time zone name, not IANA
}
variable "win_language" {
  type    = string
  default = "en-US"
}
variable "win_keyboard" {
  type    = string
  default = "0409:00000409" # "0414:00000414" = Norwegian
}

variable "win_image_name" { # edition name in install.wim, e.g. "Windows 11 Enterprise"
  type = string
}
variable "win_kms_key" { # public KMS client setup key (GVLK)
  type = string
}

// ---- Build account (built-in Administrator, also used for WinRM) ----
variable "build_username" {
  type    = string
  default = "Administrator"
}
variable "build_password" {
  type      = string
  sensitive = true
}
variable "win_full_name" {
  type    = string
  default = "Administrator"
}
variable "win_org_name" {
  type = string
}

// ---- Platform ----
variable "winrm_port" {
  type    = number
  default = 5985
}

variable "inventory_dir" {
  type = string
}

// ---- Agent installers (paths on the control node's NFS mount) ----
variable "horizon_agent_installer" {
  type = string
}

variable "dem_agent_installer" {
  type = string
}

variable "appvolumes_agent_installer" {
  type = string
}
variable "appvolumes_manager" {
  type = string
}

// ---- Windows Update (placement picker) ----
variable "enable_windows_update" {
  type    = bool
  default = true
}
variable "windows_update_source" { # windows_update | wsus
  type    = string
  default = "windows_update"
  validation {
    condition     = contains(["windows_update", "wsus"], var.windows_update_source)
    error_message = "The windows_update_source variable must be windows_update or wsus."
  }
}
variable "wsus_server_url" { # e.g. http://wsus.example.com:8530
  type    = string
  default = ""
}
