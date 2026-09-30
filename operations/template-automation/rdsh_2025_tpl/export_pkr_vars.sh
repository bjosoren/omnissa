# images/rdsh_2025_tpl/export_pkr_vars.sh
# Sourced by scripts/build.sh after resolve_vars.yml has written VARS_FILE
# and the get() helper is defined - both already in scope here. See
# images/ubt_2404_tpl/export_pkr_vars.sh's header and build.sh's comment at
# the call site for why each image owns one of these instead of one shared
# block: this image's variable schema (WinRM plaintext password, KMS key,
# no SSH keys, no NFS home dirs) barely overlaps ubt_2404_tpl's at all.

export PKR_VAR_vcenter_server; PKR_VAR_vcenter_server="$(get vcenter_server)"
export PKR_VAR_vcenter_username; PKR_VAR_vcenter_username="$(get vcenter_username)"
export PKR_VAR_vcenter_password; PKR_VAR_vcenter_password="$(get vcenter_password)"
export PKR_VAR_vcenter_datacenter; PKR_VAR_vcenter_datacenter="$(get vcenter_datacenter)"
export PKR_VAR_vcenter_cluster; PKR_VAR_vcenter_cluster="$(get vcenter_cluster)"
export PKR_VAR_vcenter_datastore; PKR_VAR_vcenter_datastore="$(get vcenter_datastore)"
export PKR_VAR_vcenter_folder; PKR_VAR_vcenter_folder="$(get vcenter_folder)"
export PKR_VAR_vcenter_network; PKR_VAR_vcenter_network="$(get vcenter_network)"
export PKR_VAR_vm_cpu_count; PKR_VAR_vm_cpu_count="$(get vm_cpu_count)"
export PKR_VAR_vm_cores_per_socket; PKR_VAR_vm_cores_per_socket="$(get vm_cores_per_socket)"
export PKR_VAR_vm_mem_size_mb; PKR_VAR_vm_mem_size_mb="$(get vm_mem_size_mb)"
export PKR_VAR_vm_disk_size_mb; PKR_VAR_vm_disk_size_mb="$(get vm_disk_size_mb)"
export PKR_VAR_vm_guest_os_type; PKR_VAR_vm_guest_os_type="$(get vm_guest_os_type)"
export PKR_VAR_vm_version; PKR_VAR_vm_version="$(get vm_version)"
export PKR_VAR_guest_hostname; PKR_VAR_guest_hostname="$(get guest_hostname)"
export PKR_VAR_guest_ip_cidr; PKR_VAR_guest_ip_cidr="$(get guest_ip_cidr)"
export PKR_VAR_guest_gateway; PKR_VAR_guest_gateway="$(get guest_gateway)"
export PKR_VAR_mac_address; PKR_VAR_mac_address="$(get mac_address)"
export PKR_VAR_domain_fqdn; PKR_VAR_domain_fqdn="$(get domain_fqdn)"
export PKR_VAR_timezone; PKR_VAR_timezone="$(get timezone)"
export PKR_VAR_win_language; PKR_VAR_win_language="$(get win_language)"
export PKR_VAR_win_keyboard; PKR_VAR_win_keyboard="$(get win_keyboard)"
export PKR_VAR_win_image_name; PKR_VAR_win_image_name="$(get win_image_name)"
export PKR_VAR_win_kms_key; PKR_VAR_win_kms_key="$(get win_kms_key)"
export PKR_VAR_win_full_name; PKR_VAR_win_full_name="$(get win_full_name)"
export PKR_VAR_win_org_name; PKR_VAR_win_org_name="$(get win_org_name)"
export PKR_VAR_winrm_port; PKR_VAR_winrm_port="$(get winrm_port)"
export PKR_VAR_horizon_agent_installer; PKR_VAR_horizon_agent_installer="$(get horizon_agent_installer)"
export PKR_VAR_dem_agent_installer; PKR_VAR_dem_agent_installer="$(get dem_agent_installer)"
export PKR_VAR_appvolumes_agent_installer; PKR_VAR_appvolumes_agent_installer="$(get appvolumes_agent_installer)"
export PKR_VAR_appvolumes_manager; PKR_VAR_appvolumes_manager="$(get appvolumes_manager)"

# iso_paths is a list - pull it as JSON and let Packer's own HCL parse it
# (PKR_VAR_ accepts JSON-encoded values for non-string types), same as
# ubt_2404_tpl's guest_dns_servers/iso_paths handling.
export PKR_VAR_iso_paths
PKR_VAR_iso_paths="$(python3 -c "import json; print(json.dumps(json.load(open('$VARS_FILE'))['iso_paths']))")"
export PKR_VAR_guest_dns_servers
PKR_VAR_guest_dns_servers="$(python3 -c "import json; print(json.dumps(json.load(open('$VARS_FILE'))['guest_dns_servers']))")"

# No password-hash step here the way ubt_2404_tpl needs one - Windows
# unattend.xml (see floppy/autounattend.pkrtpl.hcl) takes this as plaintext
# directly, and it's also what the WinRM communicator/Ansible connection
# authenticate with. Stays environment-only, never written to disk; build.sh
# unsets PKR_VAR_build_password right after packer build finishes, same as
# it does for ubt_2404_tpl.
export PKR_VAR_build_password; PKR_VAR_build_password="$(get vault_win_admin_password)"
