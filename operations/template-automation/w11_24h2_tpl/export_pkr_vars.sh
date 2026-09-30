# Sourced by scripts/build.sh after resolve_vars.yml has written VARS_FILE;
# maps each resolved value to the PKR_VAR_* Packer reads (get() is build.sh's).

export PKR_VAR_vcenter_server; PKR_VAR_vcenter_server="$(get vcenter_server)"
export PKR_VAR_vcenter_username; PKR_VAR_vcenter_username="$(get vcenter_username)"
export PKR_VAR_vcenter_password; PKR_VAR_vcenter_password="$(get vcenter_password)"
export PKR_VAR_vcenter_datacenter; PKR_VAR_vcenter_datacenter="$(get vcenter_datacenter)"
export PKR_VAR_vcenter_cluster; PKR_VAR_vcenter_cluster="$(get vcenter_cluster)"
export PKR_VAR_vcenter_host; PKR_VAR_vcenter_host="$(get vcenter_host)"   # "" = DRS
export PKR_VAR_vcenter_datastore; PKR_VAR_vcenter_datastore="$(get vcenter_datastore)"
export PKR_VAR_vcenter_folder; PKR_VAR_vcenter_folder="$(get vcenter_folder)"
export PKR_VAR_vcenter_network; PKR_VAR_vcenter_network="$(get vcenter_network)"
export PKR_VAR_vm_cpu_count; PKR_VAR_vm_cpu_count="$(get vm_cpu_count)"
export PKR_VAR_vm_cores_per_socket; PKR_VAR_vm_cores_per_socket="$(get vm_cores_per_socket)"
export PKR_VAR_vm_mem_size_mb; PKR_VAR_vm_mem_size_mb="$(get vm_mem_size_mb)"
export PKR_VAR_vm_disk_size_mb; PKR_VAR_vm_disk_size_mb="$(get vm_disk_size_mb)"
export PKR_VAR_vm_guest_os_type; PKR_VAR_vm_guest_os_type="$(get vm_guest_os_type)"
export PKR_VAR_vm_version; PKR_VAR_vm_version="$(get vm_version)"
export PKR_VAR_vm_secure_boot; PKR_VAR_vm_secure_boot="$(get vm_secure_boot | tr '[:upper:]' '[:lower:]')"
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

# Install media (see the .pkr.hcl source block)
export PKR_VAR_win_iso_url; PKR_VAR_win_iso_url="$(get win_iso_url)"
export PKR_VAR_win_iso_checksum; PKR_VAR_win_iso_checksum="$(get win_iso_checksum)"
export PKR_VAR_remote_cache_datastore; PKR_VAR_remote_cache_datastore="$(get remote_cache_datastore)"
export PKR_VAR_remote_cache_path; PKR_VAR_remote_cache_path="$(get remote_cache_path)"

# Fail early if a key in <image>_adv-vm-settings.yml isn't indented under
# vm_advanced_settings: (YAML would silently treat it as a separate variable).
ADV_FILE="$PKR_VAR_inventory_dir/group_vars/w11_24h2_tpl_adv-vm-settings.yml"
if [ -f "$ADV_FILE" ]; then
  if ! python3 - "$ADV_FILE" <<'PYEOF'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1])) or {}
stray = [k for k in data if k != "vm_advanced_settings"]
if stray:
    print(f"{sys.argv[1]}: top-level key(s) {', '.join(stray)} are not under "
          "vm_advanced_settings: - indent them two spaces beneath it, e.g.\n"
          "vm_advanced_settings:\n  devices.hotplug: \"FALSE\"", file=sys.stderr)
    sys.exit(1)
PYEOF
  then
    exit 1
  fi
fi

# map(string) for Packer: YAML booleans become TRUE/FALSE, numbers strings.
export PKR_VAR_vm_advanced_settings
PKR_VAR_vm_advanced_settings="$(python3 -c "
import json
d = json.load(open('$VARS_FILE')).get('vm_advanced_settings') or {}
print(json.dumps({str(k): ('TRUE' if v is True else 'FALSE' if v is False else str(v)) for k, v in d.items()}))
")"

# Lists are passed as JSON.
export PKR_VAR_iso_paths
PKR_VAR_iso_paths="$(python3 -c "import json; print(json.dumps(json.load(open('$VARS_FILE'))['iso_paths']))")"
export PKR_VAR_guest_dns_servers
PKR_VAR_guest_dns_servers="$(python3 -c "import json; print(json.dumps(json.load(open('$VARS_FILE'))['guest_dns_servers']))")"

# Plaintext Administrator/WinRM password from the vault; environment only,
# build.sh unsets it after packer build.
export PKR_VAR_build_password; PKR_VAR_build_password="$(get vault_win_admin_password)"
