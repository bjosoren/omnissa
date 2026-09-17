# images/ubt_2404_tpl/export_pkr_vars.sh
# Sourced by scripts/build.sh (not run standalone) after resolve_vars.yml has
# written VARS_FILE and the get() helper is defined - both already in scope
# here. This is exactly the export block that used to be hardcoded inline in
# build.sh before it became a multi-image dispatcher; moved here verbatim so
# ubt_2404_tpl keeps building identically. See build.sh's own comment at the
# call site for why each image owns one of these instead of build.sh having
# one shared block.

export PKR_VAR_vcenter_server; PKR_VAR_vcenter_server="$(get vcenter_server)"
export PKR_VAR_vcenter_username; PKR_VAR_vcenter_username="$(get vcenter_username)"
export PKR_VAR_vcenter_password; PKR_VAR_vcenter_password="$(get vcenter_password)"
export PKR_VAR_vcenter_datacenter; PKR_VAR_vcenter_datacenter="$(get vcenter_datacenter)"
export PKR_VAR_vcenter_cluster; PKR_VAR_vcenter_cluster="$(get vcenter_cluster)"
export PKR_VAR_vcenter_datastore; PKR_VAR_vcenter_datastore="$(get vcenter_datastore)"
export PKR_VAR_vcenter_folder; PKR_VAR_vcenter_folder="$(get vcenter_folder)"
export PKR_VAR_vcenter_network; PKR_VAR_vcenter_network="$(get vcenter_network)"
export PKR_VAR_vm_cpu_count; PKR_VAR_vm_cpu_count="$(get vm_cpu_count)"
export PKR_VAR_vm_mem_size_mb; PKR_VAR_vm_mem_size_mb="$(get vm_mem_size_mb)"
export PKR_VAR_vm_disk_size_mb; PKR_VAR_vm_disk_size_mb="$(get vm_disk_size_mb)"
export PKR_VAR_guest_hostname; PKR_VAR_guest_hostname="$(get guest_hostname)"
export PKR_VAR_guest_ip_cidr; PKR_VAR_guest_ip_cidr="$(get guest_ip_cidr)"
export PKR_VAR_guest_gateway; PKR_VAR_guest_gateway="$(get guest_gateway)"
export PKR_VAR_mac_address; PKR_VAR_mac_address="$(get mac_address)"
export PKR_VAR_domain_fqdn; PKR_VAR_domain_fqdn="$(get domain_fqdn)"
export PKR_VAR_ssh_private_key_file; PKR_VAR_ssh_private_key_file="$(get ssh_private_key_file)"
# A leading "~" in group_vars (e.g. "~/.ssh/golden_image_ed25519") is only
# ever expanded by bash for a literal, unquoted word on the command line -
# not for the contents of a variable - so left as-is it breaks both the `cat`
# below and Packer's own ssh_private_key_file (Packer doesn't tilde-expand it
# either). Rewrite a leading "~" to $HOME once here so both consumers get a
# real absolute path; anything already absolute passes through unchanged.
PKR_VAR_ssh_private_key_file="${PKR_VAR_ssh_private_key_file/#\~/$HOME}"
export PKR_VAR_horizon_agent_tarball; PKR_VAR_horizon_agent_tarball="$(get horizon_agent_tarball)"
export PKR_VAR_horizon_agent_install_flags; PKR_VAR_horizon_agent_install_flags="$(get horizon_agent_install_flags)"
export PKR_VAR_nfs_server; PKR_VAR_nfs_server="$(get nfs_server)"
export PKR_VAR_nfs_export_path; PKR_VAR_nfs_export_path="$(get nfs_export_path)"
# guest_dns_servers and iso_paths are both lists - pull them as JSON and let
# Packer's own HCL parse it (PKR_VAR_ accepts JSON-encoded values for
# non-string types).
export PKR_VAR_guest_dns_servers
PKR_VAR_guest_dns_servers="$(python3 -c "import json; print(json.dumps(json.load(open('$VARS_FILE'))['guest_dns_servers']))")"
export PKR_VAR_iso_paths
PKR_VAR_iso_paths="$(python3 -c "import json; print(json.dumps(json.load(open('$VARS_FILE'))['iso_paths']))")"
# The build-time local account needs both forms: the SHA-512 hash goes into
# the autoinstall answer file to actually create the account, and Ansible's
# "become" (sudo) needs the plaintext directly since the account isn't
# NOPASSWD. Both stay in the environment only - never written to disk -
# and PKR_VAR_build_password is unset again by build.sh right after packer
# build, once the ansible provisioner that needs it has finished.
LOCAL_ADMIN_PASSWORD="$(get vault_local_admin_password)"
export PKR_VAR_build_password_hash
PKR_VAR_build_password_hash="$(openssl passwd -6 "$LOCAL_ADMIN_PASSWORD")"
export PKR_VAR_build_password="$LOCAL_ADMIN_PASSWORD"
unset LOCAL_ADMIN_PASSWORD

export PKR_VAR_ssh_public_key
PKR_VAR_ssh_public_key="$(cat "${PKR_VAR_ssh_private_key_file}.pub")"
