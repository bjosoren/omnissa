##############################################################################
# variables.pkr.hcl
##############################################################################

# -- vCenter / vSphere --------------------------------------------------------

variable "vcenter_server" {
  type        = string
  description = "Hostname or IP of the vCenter Server."
}

variable "vcenter_username" {
  type        = string
  description = "vCenter service account username (user@domain)."
}

variable "vcenter_password" {
  type        = string
  sensitive   = true
  description = "vCenter service account password."
}

variable "vcenter_insecure_connection" {
  type        = bool
  default     = false
  description = "Skip TLS certificate validation."
}

variable "datacenter" {
  type        = string
  description = "vSphere datacenter name."
}

variable "cluster" {
  type        = string
  description = "vSphere cluster or host name."
}

variable "datastore" {
  type        = string
  description = "vSphere datastore name."
}

variable "vm_folder" {
  type        = string
  default     = "Templates/Packer"
  description = "vSphere VM folder path."
}

variable "vm_network" {
  type        = string
  description = "vSphere portgroup name for the build VM NIC."
}

# -- VM Hardware --------------------------------------------------------------

variable "vm_name_prefix" {
  type        = string
  default     = "HORIZON-GOLD"
  description = "Prefix for the generated VM name."
}

variable "guest_os_type" {
  type        = string
  default     = "windows11_64Guest"
  description = "vSphere guest OS type identifier."
}

variable "vm_firmware" {
  type        = string
  default     = "efi"
  description = "VM firmware type: efi-secure, efi, or bios."
}

variable "vm_cpus" {
  type        = number
  default     = 4
  description = "Number of virtual sockets."
}

variable "vm_cpu_cores" {
  type        = number
  default     = 2
  description = "Cores per socket."
}

variable "vm_ram_mb" {
  type        = number
  default     = 8192
  description = "VM RAM in MB."
}

variable "vm_disk_size_gb" {
  type        = number
  default     = 100
  description = "OS disk size in GB."
}

# -- ISO paths ----------------------------------------------------------------

variable "windows_iso_path" {
  type        = string
  description = "Datastore path to Windows ISO. e.g. [datastore1] ISOs/Windows11.iso"
}

variable "vmtools_iso_path" {
  type        = string
  description = "Datastore path to VMware Tools ISO. e.g. [datastore1] ISOs/VMware-tools-windows.iso"
}

# -- WinRM communicator -------------------------------------------------------

variable "winrm_username" {
  type        = string
  default     = "Administrator"
  description = "Local administrator username."
}

variable "winrm_password" {
  type        = string
  sensitive   = true
  description = "Local administrator password. Must match autounattend.xml."
}

# -- Installer paths ----------------------------------------------------------

variable "osot_local_path" {
  type        = string
  default     = "./installers/OmnissaHorizonOSOptimizationTool-x86_64-1.2.2603.23605577104.exe"
  description = "Local path to the Omnissa OSOT executable."
}

variable "osot_template_name" {
  type        = string
  default     = "Windows 11 23H2"
  description = "OSOT template name to apply during Optimize."
}

variable "horizon_agent_installer" {
  type        = string
  default     = "./installers/Omnissa-Horizon-Agent-x86_64-2603-8.18.0-24273927036.exe"
  description = "Local path to the Horizon Agent installer."
}

variable "dem_agent_installer" {
  type        = string
  default     = "./installers/Omnissa Dynamic Environment Manager Enterprise 2603 10.19 x64.msi"
  description = "Local path to the DEM Agent MSI installer."
}

variable "appvolumes_agent_installer" {
  type        = string
  default     = "./installers/App Volumes Agent.msi"
  description = "Local path to the App Volumes Agent MSI installer."
}

# -- Omnissa product configuration --------------------------------------------

variable "horizon_connection_server" {
  type        = string
  description = "FQDN or IP of the Horizon Connection Server."
}

variable "horizon_agent_features" {
  type        = string
  default     = "Core,NGVC,USB,RTAV,SmartCard,TSMMR,HelpDesk"
  description = "Horizon Agent 2603 feature list."
}

variable "appvolumes_manager" {
  type        = string
  description = "FQDN or IP of the App Volumes Manager."
}

variable "appvolumes_manager_port" {
  type        = string
  default     = "443"
  description = "HTTPS port for App Volumes Manager."
}

variable "apps_share_path" {
  type        = string
  default     = "\\\\fileserver\\apps"
  description = "UNC path to application installers share."
}
