#!/usr/bin/env bash
# scripts/publish_to_pool.sh - push a published VM's snapshot to its Horizon
# desktop pool or RDS farm via the Horizon REST API. Called by build.sh.
#
# Usage: scripts/publish_to_pool.sh <image_key> <vm-name> [pool|farm <name>]
#   Without the last two arguments the target comes from horizon_pool_name /
#   horizon_farm_name in the image's group_vars (exactly one may be set) and
#   you're asked to confirm. With them (build.sh passes the target picked at
#   the placement prompt) no confirmation is asked.
#   The snapshot must have the same name as the VM.
#
# Pool: POST /rest/inventory/v2/desktop-pools/{id}/action/schedule-push-image
# Farm: POST /rest/inventory/v1/farms/{id}/action/schedule-maintenance
# Both use logoff_policy WAIT_FOR_LOGOFF and stop_on_first_error.
#
# Needs in group_vars: horizon_connection_server, horizon_api_username,
# horizon_api_domain; vault: vault_horizon_api_password.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAULT_PASS_FILE="$HOME/.vault_pass"

cd "$PROJECT_ROOT"

if [ $# -ne 2 ] && [ $# -ne 4 ]; then
  echo "Usage: $0 <image_key> <vm-name> [target_type target_name]" >&2
  echo "  e.g. $0 rdsh_2025_tpl gi-rdsh2025-20260910-121035" >&2
  echo "  e.g. $0 rdsh_2025_tpl gi-rdsh2025-20260910-121035 farm <farm-name>" >&2
  echo "  <image_key> is the images/ subdirectory name (same one build.sh uses)." >&2
  echo "  target_type/target_name are optional - when omitted, the target is" >&2
  echo "  derived from horizon_pool_name/horizon_farm_name in that image's own" >&2
  echo "  group_vars, same as always." >&2
  exit 1
fi
IMAGE_KEY="$1"
VM_NAME="$2"
PRESELECTED_TARGET_TYPE="${3:-}"
PRESELECTED_TARGET_NAME="${4:-}"

IMAGE_DIR="$PROJECT_ROOT/images/$IMAGE_KEY"
GROUP_VARS_FILE="$PROJECT_ROOT/inventory/group_vars/${IMAGE_KEY}.yml"
VARS_FILE="$IMAGE_DIR/.packer_vars.json"

if [ ! -d "$IMAGE_DIR" ]; then
  echo "No such image '$IMAGE_KEY' - expected a directory at $IMAGE_DIR" >&2
  exit 1
fi
if [ ! -f "$GROUP_VARS_FILE" ]; then
  echo "No such group_vars file: $GROUP_VARS_FILE" >&2
  exit 1
fi

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

if [ ! -f "$VAULT_PASS_FILE" ]; then
  echo "Vault password file not found at $VAULT_PASS_FILE - see the platform post's" >&2
  echo "'Credentials the platform needs' section." >&2
  exit 1
fi

source "$HOME/ansible-venv/bin/activate"

echo "==> Resolving platform + project vars via Ansible"
ansible-playbook \
  --vault-password-file "$VAULT_PASS_FILE" \
  -e "@$PROJECT_ROOT/inventory/group_vars/all.yml" \
  -e "@$PROJECT_ROOT/inventory/group_vars/all/vault.yml" \
  "${GROUP_VARS_ARGS[@]}" \
  "$IMAGE_DIR/resolve_vars.yml"

get() {
  python3 -c "import json,sys; print(json.load(open('$VARS_FILE')).get('$1',''))"
}

VCENTER_SERVER="$(get vcenter_server)"
VCENTER_DATACENTER="$(get vcenter_datacenter)"
HORIZON_SERVER="$(get horizon_connection_server)"
HORIZON_POOL="$(get horizon_pool_name)"
HORIZON_FARM="$(get horizon_farm_name)"
HORIZON_USERNAME="$(get horizon_api_username)"
HORIZON_DOMAIN="$(get horizon_api_domain)"
HORIZON_PASSWORD="$(get vault_horizon_api_password)"

if [ -n "$PRESELECTED_TARGET_TYPE" ]; then
  TARGET_TYPE="$PRESELECTED_TARGET_TYPE"
  TARGET_NAME="$PRESELECTED_TARGET_NAME"
  echo "==> Using the target selected at the placement prompt: $TARGET_TYPE '$TARGET_NAME'"
elif [ -n "$HORIZON_POOL" ] && [ -n "$HORIZON_FARM" ]; then
  echo "Both horizon_pool_name ($HORIZON_POOL) and horizon_farm_name ($HORIZON_FARM)" >&2
  echo "are set in $GROUP_VARS_FILE - set only whichever one actually applies to" >&2
  echo "$IMAGE_KEY so this script knows which Horizon REST workflow to use." >&2
  shred -u "$VARS_FILE" 2>/dev/null || rm -f "$VARS_FILE"
  exit 1
elif [ -n "$HORIZON_POOL" ]; then
  TARGET_TYPE="pool"
  TARGET_NAME="$HORIZON_POOL"
elif [ -n "$HORIZON_FARM" ]; then
  TARGET_TYPE="farm"
  TARGET_NAME="$HORIZON_FARM"
else
  echo "Neither horizon_pool_name nor horizon_farm_name is set in $GROUP_VARS_FILE -" >&2
  echo "fill in the 'Horizon farm/pool publish' section for $IMAGE_KEY before" >&2
  echo "running this script." >&2
  shred -u "$VARS_FILE" 2>/dev/null || rm -f "$VARS_FILE"
  exit 1
fi

for name_value in "horizon_connection_server:$HORIZON_SERVER" \
                   "horizon_api_username:$HORIZON_USERNAME" "horizon_api_domain:$HORIZON_DOMAIN" \
                   "vault_horizon_api_password:$HORIZON_PASSWORD"; do
  name="${name_value%%:*}"
  value="${name_value#*:}"
  if [ -z "$value" ]; then
    echo "Missing $name - fill in the 'Horizon farm/pool publish' section of" >&2
    echo "$GROUP_VARS_FILE (and vault_horizon_api_password in" >&2
    echo "inventory/group_vars/all/vault.yml) before running this script." >&2
    shred -u "$VARS_FILE" 2>/dev/null || rm -f "$VARS_FILE"
    exit 1
  fi
done

shred -u "$VARS_FILE" 2>/dev/null || rm -f "$VARS_FILE"

echo ""
if [ "$TARGET_TYPE" = "pool" ]; then
  echo "This will push $VM_NAME as the new base image for the '$TARGET_NAME' pool"
  echo "on $HORIZON_SERVER - every desktop in that pool starts recomposing onto the"
  echo "new image as soon as this is scheduled, logging off users per the"
  echo "logoff_policy below (currently: WAIT_FOR_LOGOFF, not a forced logoff)."
else
  echo "This will push $VM_NAME as the new base image for the '$TARGET_NAME' RDS farm"
  echo "on $HORIZON_SERVER - every RDSH host in that farm enters maintenance and"
  echo "recomposes onto the new image as soon as this is scheduled, logging off"
  echo "sessions per the logoff_policy below (currently: WAIT_FOR_LOGOFF, not a"
  echo "forced logoff)."
fi
echo ""
if [ -n "$PRESELECTED_TARGET_TYPE" ]; then
  CONFIRM=y
  echo "Publishing to $TARGET_TYPE '$TARGET_NAME' - selected at the placement prompt, no second confirmation."
else
  echo "Publish to $TARGET_TYPE '$TARGET_NAME' on $HORIZON_SERVER? [y/N], or type a"
  read -r -p "different $TARGET_TYPE name to publish to that one instead: " CONFIRM
fi
case "$CONFIRM" in
  y|Y|yes|Yes|YES)
    ;; # keep TARGET_NAME as resolved from group_vars
  n|N|no|No|NO|"")
    echo "Aborting - nothing was pushed." >&2
    exit 1
    ;;
  *)
    echo "Publishing to a different $TARGET_TYPE than configured: '$CONFIRM' (group_vars has '$TARGET_NAME')"
    TARGET_NAME="$CONFIRM"
    ;;
esac

# -k: internal CA not assumed trusted; drop it if your Connection Server cert is.
CURL_OPTS=(-sk)

api() {
  local method="$1" path="$2" body="${3:-}"
  local args=("${CURL_OPTS[@]}" -X "$method" "https://$HORIZON_SERVER$path" \
    -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json")
  if [ -n "$body" ]; then
    args+=(-d "$body")
  fi
  curl "${args[@]}"
}

echo "==> Logging in to $HORIZON_SERVER"
LOGIN_BODY="$(python3 -c "
import json, sys
print(json.dumps({'username': sys.argv[1], 'password': sys.argv[2], 'domain': sys.argv[3]}))
" "$HORIZON_USERNAME" "$HORIZON_PASSWORD" "$HORIZON_DOMAIN")"
LOGIN_RESPONSE="$(curl "${CURL_OPTS[@]}" -X POST "https://$HORIZON_SERVER/rest/login" \
  -H "Content-Type: application/json" -d "$LOGIN_BODY")"
unset LOGIN_BODY HORIZON_PASSWORD

ACCESS_TOKEN="$(python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))" <<<"$LOGIN_RESPONSE")"
if [ -z "$ACCESS_TOKEN" ]; then
  echo "Login failed - response was:" >&2
  echo "$LOGIN_RESPONSE" >&2
  exit 1
fi

json_get_id() {
  python3 -c "
import json, sys
items = json.loads(sys.argv[1])
for item in items:
    if item.get(sys.argv[2]) == sys.argv[3]:
        print(item.get(sys.argv[4], ''))
        break
" "$1" "$2" "$3" "$4"
}

echo "==> Looking up vCenter, datacenter, base VM and snapshot IDs"
VC_LIST="$(api GET "/rest/monitor/v2/virtual-centers")"
# /rest/monitor/v2/virtual-centers returns the SDK URL in 'name' - substring match.
VCENTER_ID="$(python3 -c "
import json, sys
items = json.loads(sys.argv[1])
target = sys.argv[2]
for item in items:
    server_spec = item.get('server_spec') or {}
    candidates = [item.get('name', ''), item.get('display_name', ''), server_spec.get('server_name', '')]
    if target and any(target in c for c in candidates if c):
        print(item.get('id', ''))
        break
" "$VC_LIST" "$VCENTER_SERVER")"
if [ -z "$VCENTER_ID" ]; then
  echo "Could not find a vCenter registered in Horizon matching '$VCENTER_SERVER'." >&2
  echo "Raw response: $VC_LIST" >&2
  exit 1
fi

DC_LIST="$(api GET "/rest/external/v1/datacenters?vcenter_id=$VCENTER_ID")"
DATACENTER_ID="$(json_get_id "$DC_LIST" "name" "$VCENTER_DATACENTER" "id")"
if [ -z "$DATACENTER_ID" ]; then
  echo "Could not find datacenter '$VCENTER_DATACENTER' under vCenter $VCENTER_ID." >&2
  echo "Raw response: $DC_LIST" >&2
  exit 1
fi

BASE_VM_LIST="$(api GET "/rest/external/v1/base-vms?datacenter_id=$DATACENTER_ID&vcenter_id=$VCENTER_ID")"
BASE_VM_ID="$(json_get_id "$BASE_VM_LIST" "name" "$VM_NAME" "id")"
if [ -z "$BASE_VM_ID" ]; then
  echo "Could not find a VM named '$VM_NAME' in Horizon's base-VM list for this vCenter/datacenter." >&2
  echo "Raw response: $BASE_VM_LIST" >&2
  exit 1
fi

SNAPSHOT_LIST="$(api GET "/rest/external/v1/base-snapshots?base_vm_id=$BASE_VM_ID&vcenter_id=$VCENTER_ID")"
SNAPSHOT_ID="$(json_get_id "$SNAPSHOT_LIST" "name" "$VM_NAME" "id")"
if [ -z "$SNAPSHOT_ID" ]; then
  echo "Could not find a snapshot named '$VM_NAME' on that VM." >&2
  echo "Raw response: $SNAPSHOT_LIST" >&2
  exit 1
fi

echo "    vCenter=$VCENTER_ID  datacenter=$DATACENTER_ID  base_vm=$BASE_VM_ID  snapshot=$SNAPSHOT_ID"

if [ "$TARGET_TYPE" = "pool" ]; then
  POOL_LIST="$(api GET "/rest/inventory/v1/desktop-pools")"
  POOL_ID="$(json_get_id "$POOL_LIST" "name" "$TARGET_NAME" "id")"
  if [ -z "$POOL_ID" ]; then
    echo "Could not find a desktop pool named '$TARGET_NAME'." >&2
    echo "Raw response: $POOL_LIST" >&2
    exit 1
  fi
  echo "    pool=$POOL_ID ($TARGET_NAME)"

  echo "==> Scheduling the desktop pool push-image operation"
  PUSH_BODY="$(python3 -c "
import json, sys
print(json.dumps({
    'parent_vm_id': sys.argv[1],
    'snapshot_id': sys.argv[2],
    'logoff_policy': 'WAIT_FOR_LOGOFF',
    'stop_on_first_error': True,
    'add_virtual_tpm': False,
}))
" "$BASE_VM_ID" "$SNAPSHOT_ID")"
  PUSH_RESPONSE="$(api POST "/rest/inventory/v2/desktop-pools/$POOL_ID/action/schedule-push-image" "$PUSH_BODY")"
  echo "$PUSH_RESPONSE"
  echo ""
  echo "==> Requested. Monitor progress in Horizon Console under the pool's Image"
  echo "    Management tab, or via GET /rest/inventory/v2/desktop-pools/$POOL_ID."

else
  FARM_LIST="$(api GET "/rest/inventory/v2/farms")"
  FARM_ID="$(json_get_id "$FARM_LIST" "name" "$TARGET_NAME" "id")"
  if [ -z "$FARM_ID" ]; then
    echo "Could not find an RDS farm named '$TARGET_NAME'." >&2
    echo "Raw response: $FARM_LIST" >&2
    exit 1
  fi
  echo "    farm=$FARM_ID ($TARGET_NAME)"

  echo "==> Scheduling the farm maintenance/push-image operation"
  PUSH_BODY="$(python3 -c "
import json, sys
print(json.dumps({
    'parent_vm_id': sys.argv[1],
    'snapshot_id': sys.argv[2],
    'logoff_policy': 'WAIT_FOR_LOGOFF',
    'maintenance_mode': 'IMMEDIATE',
    'stop_on_first_error': True,
}))
" "$BASE_VM_ID" "$SNAPSHOT_ID")"
  PUSH_RESPONSE="$(api POST "/rest/inventory/v1/farms/$FARM_ID/action/schedule-maintenance" "$PUSH_BODY")"
  echo "$PUSH_RESPONSE"
  echo ""
  echo "==> Requested. Monitor progress in Horizon Console under the farm's Image"
  echo "    Management tab, or via GET /rest/inventory/v2/farms/$FARM_ID."
fi
