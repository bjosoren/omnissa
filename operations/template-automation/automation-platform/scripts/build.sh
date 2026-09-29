#!/usr/bin/env bash

# scripts/build.sh - build one golden image end to end:
#   placement picker (or a saved --config) -> resolve group_vars + vault ->
#   pre-flight checks -> packer build -> clone + snapshot -> publish to the
#   Horizon pool/farm -> optionally delete the build VM.
#
# Usage:
#   scripts/build.sh                            pick an image from a list
#   scripts/build.sh <image_key>                e.g. w11_24h2_tpl
#   scripts/build.sh <image_key> --config NAME  unattended, saved answers
#   scripts/build.sh --list | --list-placements <image_key>
#
# An image is any images/<key>/ with a *.pkr.hcl, an image.conf (VM_NAME,
# PUBLISHED_VM_PREFIX), resolve_vars.yml, preflight_check_vm.yml,
# delete_vm.yml, post_build_snapshot.yml and export_pkr_vars.sh, plus
# inventory/group_vars/<key>.yml. Optional, loaded in this order after it:
# <key>_agents.yml, <key>_osot.yml, <key>_adv-vm-settings.yml,
# <key>.local.yml (gitignored, site-specific values), then the picker's
# answers. The whole script is wrapped in main() so bash parses all of it
# before running - editing it during a build can't break that build.
main() {

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAULT_PASS_FILE="$HOME/.vault_pass"

cd "$PROJECT_ROOT"

discover_images() {
  local dir key
  for dir in "$PROJECT_ROOT"/images/*/; do
    [ -d "$dir" ] || continue
    key="$(basename "${dir%/}")"
    if compgen -G "${dir}*.pkr.hcl" >/dev/null; then
      echo "$key"
    fi
  done | sort
}

mapfile -t IMAGES < <(discover_images)

if [ "${#IMAGES[@]}" -eq 0 ]; then
  echo "No buildable images found under $PROJECT_ROOT/images/ (each image" >&2
  echo "needs its own directory containing at least one *.pkr.hcl file)." >&2
  exit 1
fi

# ---- Arguments ----
PLACEMENT_NAME=""
LIST_PLACEMENTS=false
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --placement|--config)
      if [ -z "${2:-}" ]; then
        echo "--placement requires a name - see 'scripts/build.sh --list-placements <image_key>'" >&2
        echo "for the saved names available for that image." >&2
        exit 1
      fi
      PLACEMENT_NAME="$2"
      shift 2
      ;;
    --list-placements)
      LIST_PLACEMENTS=true
      shift
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

if [ "$LIST_PLACEMENTS" = true ]; then
  IMAGE_KEY_FOR_LIST="${1:-}"
  if [ -z "$IMAGE_KEY_FOR_LIST" ]; then
    echo "Usage: scripts/build.sh --list-placements <image_key>" >&2
    exit 1
  fi
  SAVED=()
  for PLACEMENTS_DIR in "$PROJECT_ROOT/configs"; do
    [ -d "$PLACEMENTS_DIR" ] || continue
    for f in "$PLACEMENTS_DIR/${IMAGE_KEY_FOR_LIST}__"*.control.sh; do
      [ -e "$f" ] || continue
      base="$(basename "$f" .control.sh)"
      SAVED+=("${base#${IMAGE_KEY_FOR_LIST}__}")
    done
  done
  if [ "${#SAVED[@]}" -gt 0 ]; then
    printf '%s\n' "${SAVED[@]}" | sort -u
  else
    echo "No saved placements for '$IMAGE_KEY_FOR_LIST' yet - run" >&2
    echo "scripts/build.sh $IMAGE_KEY_FOR_LIST interactively and answer" >&2
    echo "'y' to 'Save these settings for unattended/scheduled reruns?'." >&2
  fi
  exit 0
fi

case "${1:-}" in
  --list)
    printf '%s\n' "${IMAGES[@]}"
    exit 0
    ;;
  -h|--help)
    echo "Usage: scripts/build.sh [image_key|--list] [--placement NAME]"
    echo ""
    echo "Available images:"
    printf '  %s\n' "${IMAGES[@]}"
    echo ""
    echo "  --placement NAME        skip the interactive placement picker and"
    echo "                          load a previously saved one (see the"
    echo "                          'Unattended / scheduled builds' comment"
    echo "                          near the top of this file)"
    echo "  --list-placements KEY   list saved placement names for that image"
    exit 0
    ;;
esac

if [ -n "${1:-}" ]; then
  IMAGE_KEY="$1"
  FOUND=false
  for img in "${IMAGES[@]}"; do
    if [ "$img" = "$IMAGE_KEY" ]; then
      FOUND=true
      break
    fi
  done
  if [ "$FOUND" != true ]; then
    echo "Unknown image '$IMAGE_KEY'." >&2
    echo "Available images:" >&2
    printf '  %s\n' "${IMAGES[@]}" >&2
    exit 1
  fi
else
  echo "Available images:"
  PS3="Image number: "
  select IMAGE_KEY in "${IMAGES[@]}"; do
    if [ -n "${IMAGE_KEY:-}" ]; then
      break
    fi
    echo "Invalid selection." >&2
  done
fi

echo "==> Building image: $IMAGE_KEY"

IMAGE_DIR="$PROJECT_ROOT/images/$IMAGE_KEY"
VARS_FILE="$IMAGE_DIR/.packer_vars.json"
GROUP_VARS_FILE="$PROJECT_ROOT/inventory/group_vars/${IMAGE_KEY}.yml"

if [ ! -f "$GROUP_VARS_FILE" ]; then
  echo "Missing $GROUP_VARS_FILE - every image needs group_vars matching" >&2
  echo "its directory name exactly (see inventory/group_vars/ubt_2404_tpl.yml" >&2
  echo "for reference)." >&2
  exit 1
fi

if [ ! -f "$VAULT_PASS_FILE" ]; then
  echo "Vault password file not found at $VAULT_PASS_FILE - see the platform post's" >&2
  echo "'Credentials the platform needs' section." >&2
  exit 1
fi

source "$HOME/ansible-venv/bin/activate"

# ---- Placement picker / saved config (scripts/select_placement.py) ----
PLACEMENT_OVERRIDE_FILE="$(mktemp "${TMPDIR:-/tmp}/placement_overrides.XXXXXX")"
PLACEMENT_CONTROL_FILE="$(mktemp "${TMPDIR:-/tmp}/placement_control.XXXXXX")"
trap 'shred -u "$PLACEMENT_OVERRIDE_FILE" "$PLACEMENT_CONTROL_FILE" 2>/dev/null' EXIT

if [ -n "$PLACEMENT_NAME" ]; then
  echo "==> Loading saved placement '$PLACEMENT_NAME' for $IMAGE_KEY"
  python3 "$PROJECT_ROOT/scripts/select_placement.py" \
    --project-root "$PROJECT_ROOT" \
    --image-key "$IMAGE_KEY" \
    --placement-output "$PLACEMENT_OVERRIDE_FILE" \
    --control-output "$PLACEMENT_CONTROL_FILE" \
    --load "$PLACEMENT_NAME"
else
  echo "==> Select build placement for $IMAGE_KEY"
  python3 "$PROJECT_ROOT/scripts/select_placement.py" \
    --project-root "$PROJECT_ROOT" \
    --image-key "$IMAGE_KEY" \
    --placement-output "$PLACEMENT_OVERRIDE_FILE" \
    --control-output "$PLACEMENT_CONTROL_FILE"
fi

source "$PLACEMENT_CONTROL_FILE"
: "${COLLECT_BUILD_LOGS:?select_placement.py did not set COLLECT_BUILD_LOGS}"
: "${PUBLISH_TO_POOL:?select_placement.py did not set PUBLISH_TO_POOL}"
: "${DELETE_VM_AFTER:?select_placement.py did not set DELETE_VM_AFTER}"

# ---- Vars files, later -e wins ----
GROUP_VARS_ARGS=(-e "@$GROUP_VARS_FILE")

AGENTS_VARS_FILE="$PROJECT_ROOT/inventory/group_vars/${IMAGE_KEY}_agents.yml"
if [ -f "$AGENTS_VARS_FILE" ]; then
  GROUP_VARS_ARGS+=(-e "@$AGENTS_VARS_FILE")
fi

OSOT_VARS_FILE="$PROJECT_ROOT/inventory/group_vars/${IMAGE_KEY}_osot.yml"
if [ -f "$OSOT_VARS_FILE" ]; then
  GROUP_VARS_ARGS+=(-e "@$OSOT_VARS_FILE")
fi

ADV_VM_SETTINGS_VARS_FILE="$PROJECT_ROOT/inventory/group_vars/${IMAGE_KEY}_adv-vm-settings.yml"
if [ -f "$ADV_VM_SETTINGS_VARS_FILE" ]; then
  GROUP_VARS_ARGS+=(-e "@$ADV_VM_SETTINGS_VARS_FILE")
fi

LOCAL_VARS_FILE="$PROJECT_ROOT/inventory/group_vars/${IMAGE_KEY}.local.yml"
if [ -f "$LOCAL_VARS_FILE" ]; then
  echo "==> Using local overrides from $LOCAL_VARS_FILE (not tracked in git)"
  GROUP_VARS_ARGS+=(-e "@$LOCAL_VARS_FILE")
fi

GROUP_VARS_ARGS+=(-e "@$PLACEMENT_OVERRIDE_FILE")

IMAGE_CONF="$IMAGE_DIR/image.conf"
if [ ! -f "$IMAGE_CONF" ]; then
  echo "Missing $IMAGE_CONF - every image needs an image.conf defining" >&2
  echo "VM_NAME and PUBLISHED_VM_PREFIX (see images/ubt_2404_tpl/image.conf" >&2
  echo "for reference)." >&2
  exit 1
fi
source "$IMAGE_CONF"
: "${VM_NAME:?VM_NAME not set in $IMAGE_CONF}"
: "${PUBLISHED_VM_PREFIX:?PUBLISHED_VM_PREFIX not set in $IMAGE_CONF}"

# Reusable build VM (VM_NAME) vs. published clone with a timestamped name.
PUBLISHED_VM_NAME="${PUBLISHED_VM_PREFIX}-$(date +%Y%m%d-%H%M%S)"

# ---- Transcript: images/<key>/logs/<published name>.log ----
LOG_DIR="$IMAGE_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/${PUBLISHED_VM_NAME}.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "==> Transcript: $LOG_FILE"

# WinRM images use NTLM transport, which needs requests_ntlm.
if [ "$IMAGE_KEY" = "rdsh_2025_tpl" ] || [ "$IMAGE_KEY" = "w11_24h2_tpl" ]; then
  echo "==> Checking for requests_ntlm (needed for $IMAGE_KEY's WinRM NTLM transport)"
  if ! python3 -c "import requests_ntlm" >/dev/null 2>&1; then
    echo "requests_ntlm is not installed in this control node's ansible-venv." >&2
    echo "$IMAGE_KEY's ansible provisioner connects via" >&2
    echo "ansible_winrm_transport=ntlm (see $IMAGE_KEY.pkr.hcl), which needs it." >&2
    echo "Install it into the same venv this script just activated, then re-run:" >&2
    echo "    pip install requests_ntlm" >&2
    exit 1
  fi
  echo "    requests_ntlm is present"
fi

echo "==> Resolving platform + image vars via Ansible"
ansible-playbook \
  --vault-password-file "$VAULT_PASS_FILE" \
  -e "@$PROJECT_ROOT/inventory/group_vars/all.yml" \
  -e "@$PROJECT_ROOT/inventory/group_vars/all/vault.yml" \
  "${GROUP_VARS_ARGS[@]}" \
  "$IMAGE_DIR/resolve_vars.yml"

# resolve_vars.yml writes nothing if hosts.ini has no [<key>] group.
if [ ! -f "$VARS_FILE" ]; then
  echo "resolve_vars.yml did not write $VARS_FILE." >&2
  echo "Most likely cause: no [$IMAGE_KEY] group in $PROJECT_ROOT/inventory/hosts.ini" >&2
  echo "(look for 'Could not match supplied host pattern' above). Add:" >&2
  echo "" >&2
  echo "    [$IMAGE_KEY]" >&2
  echo "    $IMAGE_KEY ansible_host=<reserved IP>" >&2
  echo "" >&2
  echo "then re-run." >&2
  exit 1
fi

get() {
  python3 -c "import json,sys; print(json.load(open('$VARS_FILE')).get('$1',''))"
}

# ---- Pre-flight: leftover build VM, DNS record, installers on NFS ----
echo "==> Checking whether $VM_NAME already exists in vCenter"
PREFLIGHT_FILE="$IMAGE_DIR/.preflight_check.json"
rm -f "$PREFLIGHT_FILE"
ansible-playbook \
  --vault-password-file "$VAULT_PASS_FILE" \
  -e "@$PROJECT_ROOT/inventory/group_vars/all.yml" \
  -e "@$PROJECT_ROOT/inventory/group_vars/all/vault.yml" \
  "${GROUP_VARS_ARGS[@]}" \
  -e "vm_name=$VM_NAME" \
  -e "check_result_file=$PREFLIGHT_FILE" \
  "$IMAGE_DIR/preflight_check_vm.yml"

VM_EXISTS="$(python3 -c "import json; print(json.load(open('$PREFLIGHT_FILE')).get('exists', False))")"
rm -f "$PREFLIGHT_FILE"

if [ "$VM_EXISTS" = "True" ]; then
  echo ""
  echo "A VM named '$VM_NAME' already exists in vCenter - probably left over"
  echo "from a previous build (successful or not)."
  read -r -p "Delete it now and continue this build? [y/N] " REPLY
  case "$REPLY" in
    [yY]|[yY][eE][sS])
      echo "==> Deleting existing $VM_NAME"
      ansible-playbook \
        --vault-password-file "$VAULT_PASS_FILE" \
        -e "@$PROJECT_ROOT/inventory/group_vars/all.yml" \
        -e "@$PROJECT_ROOT/inventory/group_vars/all/vault.yml" \
        "${GROUP_VARS_ARGS[@]}" \
        -e "vm_name=$VM_NAME" \
        "$IMAGE_DIR/delete_vm.yml"
      ;;
    *)
      echo "Not deleting $VM_NAME - aborting. Re-run when you're ready, or delete" >&2
      echo "it yourself first (in vCenter, or with delete_vm.yml directly)." >&2
      exit 1
      ;;
  esac
fi

echo "==> Checking DNS prerequisites"

GUEST_FQDN="$(get guest_hostname).$(get domain_fqdn)"
EXPECTED_IP="$(get guest_ip_cidr)"
EXPECTED_IP="${EXPECTED_IP%%/*}" # strip the /24 prefix
DNS_SERVER="$(python3 -c "import json; print(json.load(open('$VARS_FILE'))['guest_dns_servers'][0])")"

if command -v dig >/dev/null 2>&1; then
  RESOLVED_IP="$(dig +short +time=3 +tries=1 "@$DNS_SERVER" "$GUEST_FQDN" A | tail -n1)"
else
  echo "    dig not found - falling back to the system resolver (this may also" >&2
  echo "    consult /etc/hosts rather than querying DNS directly)" >&2
  RESOLVED_IP="$(python3 -c "
import socket, sys
try:
    print(socket.gethostbyname('$GUEST_FQDN'))
except socket.gaierror:
    sys.exit(1)
" 2>/dev/null)" || RESOLVED_IP=""
fi

if [ -z "$RESOLVED_IP" ]; then
  echo "DNS check failed: '$GUEST_FQDN' does not resolve via $DNS_SERVER." >&2
  echo "Create the A record (and reserve $EXPECTED_IP) before running a build -" >&2
  echo "see the platform post's 'Each of those ansible_host values needs a real," >&2
  echo "stable IP' section." >&2
  exit 1
fi

if [ "$RESOLVED_IP" != "$EXPECTED_IP" ]; then
  echo "DNS check failed: '$GUEST_FQDN' resolves to $RESOLVED_IP via $DNS_SERVER," >&2
  echo "expected $EXPECTED_IP. Either the DNS record is stale or guest_ip_cidr in" >&2
  echo "group_vars is wrong - fix whichever is out of date before running a build." >&2
  exit 1
fi

echo "    $GUEST_FQDN -> $RESOLVED_IP via $DNS_SERVER (matches guest_ip_cidr)"

echo "==> Checking installer prerequisites on this control node"
case "$IMAGE_KEY" in
  rdsh_2025_tpl)
    INSTALLER_VARS=(horizon_agent_installer dem_agent_installer appvolumes_agent_installer)
    ;;
  w11_24h2_tpl)
    INSTALLER_VARS=(horizon_agent_installer dem_agent_installer appvolumes_agent_installer win_iso_url)
    ;;
  ubt_2404_tpl)
    INSTALLER_VARS=(horizon_agent_tarball)
    ;;
  *)
    INSTALLER_VARS=()
    ;;
esac

for var in "${INSTALLER_VARS[@]}"; do
  path="$(get "$var")"
  if [ -z "$path" ]; then
    echo "Missing $var in $GROUP_VARS_FILE." >&2
    exit 1
  fi
  if [ ! -f "$path" ]; then
    echo "Installer prerequisite failed: $var points at '$path'," >&2
    echo "which doesn't exist (or isn't readable) on this control node." >&2
    echo "Check that the NFS share is mounted and the filename/version" >&2
    echo "matches what's actually on it, then re-run." >&2
    exit 1
  fi
done
if [ "${#INSTALLER_VARS[@]}" -gt 0 ]; then
  echo "    installer(s) found on this control node: ${INSTALLER_VARS[*]}"
fi
# ---- Packer ----
echo "==> Building $VM_NAME"

export PKR_VAR_vm_name="$VM_NAME"
export PKR_VAR_inventory_dir="$PROJECT_ROOT/inventory"

if [ "$IMAGE_KEY" = "rdsh_2025_tpl" ] || [ "$IMAGE_KEY" = "w11_24h2_tpl" ]; then
  export PKR_VAR_collect_build_logs="$COLLECT_BUILD_LOGS"
fi

source "$IMAGE_DIR/export_pkr_vars.sh"

shred -u "$VARS_FILE" 2>/dev/null || rm -f "$VARS_FILE"

cd "$IMAGE_DIR"
packer init .
packer validate .
packer build -on-error=cleanup -force .

unset PKR_VAR_build_password

# ---- Clone, snapshot, publish ----
if [ "$PUBLISH_TO_POOL" = true ]; then
  echo "==> Packer build finished, cloning to $PUBLISHED_VM_NAME and taking the instant-clone snapshot"
  ansible-playbook \
    --vault-password-file "$VAULT_PASS_FILE" \
    -e "@$PROJECT_ROOT/inventory/group_vars/all.yml" \
    -e "@$PROJECT_ROOT/inventory/group_vars/all/vault.yml" \
    "${GROUP_VARS_ARGS[@]}" \
    -e "vm_name=$VM_NAME" \
    -e "published_vm_name=$PUBLISHED_VM_NAME" \
    "$IMAGE_DIR/post_build_snapshot.yml"

  echo "==> $VM_NAME rebuilt; published as $PUBLISHED_VM_NAME (snapshotted, ready for Horizon)"

  echo "==> Pushing $PUBLISHED_VM_NAME to its Horizon pool/farm"
  if [ -n "$HORIZON_TARGET_TYPE" ]; then
    if bash "$PROJECT_ROOT/scripts/publish_to_pool.sh" "$IMAGE_KEY" "$PUBLISHED_VM_NAME" "$HORIZON_TARGET_TYPE" "$HORIZON_TARGET_NAME"; then
      PUBLISH_OK=true
    else
      PUBLISH_OK=false
    fi
  else
    if bash "$PROJECT_ROOT/scripts/publish_to_pool.sh" "$IMAGE_KEY" "$PUBLISHED_VM_NAME"; then
      PUBLISH_OK=true
    else
      PUBLISH_OK=false
    fi
  fi
else
  echo "==> $VM_NAME rebuilt. Skipping clone/snapshot/publish - answered/loaded No to"
  echo "    'Publish to Desktop-pool/Farm?' at the placement step."
  PUBLISH_OK=""
fi

echo ""
echo "==================== Build summary ===================="
echo "Image:         $IMAGE_KEY"
echo "Build VM:      $VM_NAME (rebuilt this run)"
if [ -n "$PLACEMENT_NAME" ]; then
  echo "Placement:     loaded from saved placement '$PLACEMENT_NAME'"
fi
if [ "$PUBLISH_TO_POOL" = true ]; then
  echo "Published VM:  $PUBLISHED_VM_NAME (snapshot: $PUBLISHED_VM_NAME)"
  if [ "$PUBLISH_OK" = true ]; then
    echo "Pool/farm push: requested successfully"
  else
    echo "Pool/farm push: FAILED or declined - see output above."
    echo "               $VM_NAME has been left in place so you can retry"
    if [ -n "$HORIZON_TARGET_TYPE" ]; then
      echo "               (scripts/publish_to_pool.sh $IMAGE_KEY $PUBLISHED_VM_NAME \\"
      echo "                 $HORIZON_TARGET_TYPE $HORIZON_TARGET_NAME)"
      echo "               - that target/name is the one you picked at the placement"
      echo "               prompt; omit them to fall back to whatever's configured in"
      echo "               group_vars instead."
    else
      echo "               (scripts/publish_to_pool.sh $IMAGE_KEY $PUBLISHED_VM_NAME)"
    fi
    echo "               or troubleshoot, without rebuilding from scratch."
  fi
else
  echo "Published VM:  none - publish was skipped (answered/loaded No at the placement step)"
fi
echo "=========================================================="
echo ""

if [ "$PUBLISH_TO_POOL" = true ] && [ "$PUBLISH_OK" != true ]; then
  exit 1
fi

# ---- Delete the build VM (asked at the placement prompt) ----
if [ "$DELETE_VM_AFTER" = true ]; then
  echo "==> Deleting $VM_NAME (requested at the placement prompt)"
  ansible-playbook \
    --vault-password-file "$VAULT_PASS_FILE" \
    -e "@$PROJECT_ROOT/inventory/group_vars/all.yml" \
    -e "@$PROJECT_ROOT/inventory/group_vars/all/vault.yml" \
    "${GROUP_VARS_ARGS[@]}" \
    -e "vm_name=$VM_NAME" \
    "$IMAGE_DIR/delete_vm.yml"
  echo "==> Done: $VM_NAME deleted."
else
  echo "Leaving $VM_NAME in place."
fi
}; main "$@"
