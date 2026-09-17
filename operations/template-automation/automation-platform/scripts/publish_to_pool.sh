#!/usr/bin/env bash
# scripts/publish_to_pool.sh
# Pushes a golden image snapshot built by scripts/build.sh out to its
# Horizon target - a VDI desktop pool (ubt_2404_tpl -> HZUBTP1_ref) or an
# RDSH farm (rdsh_2025_tpl -> RDSHFARM1P1) - via the Horizon REST API's
# image-push operation for whichever target type that image is configured
# for. See "Pool vs farm" below for how that's decided.
#
# build.sh now calls this script itself at the end of a successful build -
# it is no longer a separate manual step you have to remember to run. What's
# still true, and still enforced right here rather than in build.sh, is that
# a successful build only means the image itself is good; pushing it
# immediately starts recomposing (desktop pool) or entering maintenance and
# recomposing (RDS farm) every machine currently provisioned from the
# target, so this script still stops and makes a human type the target's
# name to confirm before it touches anything live - see below. That
# confirmation is exactly why build.sh calls this as a normal foreground
# step rather than trying to run it unattended.
#
# ---- Fixed 2026-09-10: this used to be hardcoded to ubt_2404_tpl ----
# This script originally had IMAGE_DIR hardcoded to images/ubt_2404_tpl and
# only ever called the desktop-pools REST endpoints - it had no way to know
# about any other image. Run against a real rdsh_2025_tpl build
# (gi-rdsh2025-20260910-121035), it silently resolved ubt_2404_tpl's vars
# and got as far as its own confirmation prompt for pushing onto
# HZUBTP1_ref - the *Ubuntu VDI reference pool*, not anything related to
# the RDSH image just built - which is exactly what the confirm-by-typing-
# the-name gate is there for; that mismatch is what it caught (nothing was
# pushed). Confirmed via Horizon Console (screenshots) that rdsh_2025_tpl's
# real target, RDSHFARM1P1, is a Farm (Type: Automated Farm, Source:
# Instant Clone), not a desktop pool at all - Horizon's REST API models
# farms and pools as genuinely separate object types with separate
# endpoints (see "Pool vs farm" below), so even with the right vars this
# could never have pushed to a farm correctly; the desktop-pools code path
# is structurally the wrong one for that target no matter what name gets
# plugged into it.
#
# Fixed by: (1) parameterizing this script by image_key, the same way
# build.sh already discovers/passes it, instead of hardcoding one image's
# directory and group_vars file; (2) reading BOTH horizon_pool_name and
# horizon_farm_name from that image's own group_vars and branching to the
# matching REST workflow, rather than assuming every image is a desktop
# pool.
#
# ---- Pool vs farm ----
# Exactly one of horizon_pool_name / horizon_farm_name must be set in the
# image's own inventory/group_vars/<image_key>.yml - whichever one is set
# decides which REST workflow below runs. ubt_2404_tpl sets
# horizon_pool_name (a VDI desktop pool); rdsh_2025_tpl sets
# horizon_farm_name (an RDSH farm) - see that file's own "Horizon
# farm/pool publish" comment.
#
#   Desktop pool workflow (unchanged from before this fix):
#     GET  /rest/inventory/v1/desktop-pools
#     POST /rest/inventory/v2/desktop-pools/{pool_id}/action/schedule-push-image
#
#   RDS farm workflow (new):
#     GET  /rest/inventory/v2/farms
#     POST /rest/inventory/v1/farms/{farm_id}/action/schedule-maintenance
#   Confirmed against two independent, actively-maintained community
#   reference scripts by the same author, explicitly split by workload
#   type specifically because farms and pools are NOT interchangeable in
#   this API - Horizon_Rest_Push_Image_RDS.ps1 (farms) vs
#   Horizon_Rest_Push_Image_VDI_2206.ps1 (pools), both in
#   github.com/Magneet/Various_Scripts - field-for-field cross-checked
#   against this script's existing pool-side body shape (parent_vm_id,
#   snapshot_id, logoff_policy, stop_on_first_error all line up; the farm
#   side additionally needs maintenance_mode and has no add_virtual_tpm
#   key). Like the original pool workflow below, this has NOT been run
#   against your specific Connection Server version, and unlike the pool
#   workflow, it has never been run for real at all yet - check your own
#   server's live REST API reference (usually
#   https://<connection-server>/rest/swagger-ui.html from a browser on your
#   network) and confirm the schedule-maintenance body below still
#   matches, ideally by trying it against a test/throwaway farm first,
#   before trusting this against RDSHFARM1P1 for real.
#
# Usage: scripts/publish_to_pool.sh <image_key> <vm-name>
#   <image_key> is the images/ subdirectory name, e.g. ubt_2404_tpl or
#   rdsh_2025_tpl - the same image_key build.sh prints/accepts.
#   <vm-name> is the exact name build.sh printed at the end of a run (or
#   passes to this script directly when it calls it itself), e.g.
#   gi-ubt2404-20260825-093615 - this project's convention is that the
#   snapshot Packer/post_build_snapshot.yml took is named identically to
#   the VM, so one name identifies both. Includes time as well as date
#   because this project gets rebuilt more than once a day while
#   iterating - a date-only name would collide on a same-day re-run.
#
# Can still be run standalone too - e.g. to re-push a specific past build
# without rebuilding, or to retry a push that failed partway through.
#
# What this needs beyond what build.sh already uses (see <image_key>'s own
# inventory/group_vars/<image_key>.yml "Horizon farm/pool publish"
# section):
#   horizon_connection_server  - your Connection Server's hostname
#   horizon_pool_name          - target pool's name in Horizon (VDI images only)
#   horizon_farm_name          - target farm's name in Horizon (RDSH images only)
#   horizon_api_username       - a Horizon administrator-role account for
#                                 the REST API (does NOT need to be, and
#                                 shouldn't be, an AD domain admin - Horizon
#                                 role-based delegation covers this)
#   horizon_api_domain         - the AD domain that account authenticates
#                                 against
#   vault_horizon_api_password - that account's password, in
#                                 inventory/group_vars/all/vault.yml

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAULT_PASS_FILE="$HOME/.vault_pass"

cd "$PROJECT_ROOT"

if [ $# -ne 2 ]; then
  echo "Usage: $0 <image_key> <vm-name>" >&2
  echo "  e.g. $0 rdsh_2025_tpl gi-rdsh2025-20260910-121035" >&2
  echo "  <image_key> is the images/ subdirectory name (same one build.sh uses)." >&2
  exit 1
fi
IMAGE_KEY="$1"
VM_NAME="$2"

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

# ---- Local, untracked overrides (ADDED 2026-09-17) ----
# Same mechanism as scripts/build.sh's own "Local, untracked overrides"
# block - see that file's comment for the full rationale (real
# site-specific values, like guest_ip_cidr/guest_gateway/guest_dns_servers,
# kept out of this public repo via an optional, .gitignore'd
# inventory/group_vars/${IMAGE_KEY}.local.yml). This script resolves vars
# independently of build.sh (it can be run standalone - see this file's own
# header), so it needs the same local-file check rather than assuming
# build.sh already handled it.
LOCAL_VARS_FILE="$PROJECT_ROOT/inventory/group_vars/${IMAGE_KEY}.local.yml"
GROUP_VARS_ARGS=(-e "@$GROUP_VARS_FILE")
if [ -f "$LOCAL_VARS_FILE" ]; then
  echo "==> Using local overrides from $LOCAL_VARS_FILE (not tracked in git)"
  GROUP_VARS_ARGS+=(-e "@$LOCAL_VARS_FILE")
fi

if [ ! -f "$VAULT_PASS_FILE" ]; then
  echo "Vault password file not found at $VAULT_PASS_FILE - see the platform post's" >&2
  echo "'Credentials the platform needs' section." >&2
  exit 1
fi

# shellcheck disable=SC1090
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

# ---- Decide pool vs farm ----
# Exactly one of these must be set - see this script's own "Pool vs farm"
# header comment for why this can't just always assume a pool the way the
# pre-fix version of this script did.
if [ -n "$HORIZON_POOL" ] && [ -n "$HORIZON_FARM" ]; then
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

# The resolved-vars file held plaintext secrets - it's done its job now.
shred -u "$VARS_FILE" 2>/dev/null || rm -f "$VARS_FILE"

# ---- Confirm before touching a live pool/farm ----
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
# CHANGED 2026-09-17, per the user's explicit request: was "type the exact
# target name to confirm" (a full retype, deliberately slower/harder to
# fat-finger past). Now a lighter y/n prompt that also accepts a different
# target name typed directly, to push to a target other than the one
# resolved from group_vars without having to edit that file first - e.g.
# publishing a one-off test build to a throwaway farm. Trade-off worth
# knowing: a bare "y" is easier to hit by reflex than retyping "RDSHFARM1P1"
# was, so this leans on the summary printed just above (which target, what
# happens) being read before answering, not on the confirmation step itself
# to catch inattention. Empty input (just Enter) is treated as "no".
echo "Publish to $TARGET_TYPE '$TARGET_NAME' on $HORIZON_SERVER? [y/N], or type a"
read -r -p "different $TARGET_TYPE name to publish to that one instead: " CONFIRM
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

# curl -k: this platform's internal CA isn't assumed trusted by the caller's
# resolver, same posture as vcenter_insecure_connection elsewhere in this
# project. Remove -k below if your Connection Server presents a certificate
# you do trust.
CURL_OPTS=(-sk)

api() {
  # api METHOD PATH [JSON_BODY]
  local method="$1" path="$2" body="${3:-}"
  local args=("${CURL_OPTS[@]}" -X "$method" "https://$HORIZON_SERVER$path" \
    -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json")
  if [ -n "$body" ]; then
    args+=(-d "$body")
  fi
  curl "${args[@]}"
}

echo "==> Logging in to $HORIZON_SERVER"
# Passed as argv, not interpolated into the Python source text, so a
# password containing a quote or backslash can't break this the way
# string-interpolating it into '-c' would.
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
  # json_get_id JSON_ARRAY MATCH_FIELD MATCH_VALUE ID_FIELD
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
# Fixed 2026-09-10: this used to match VCENTER_SERVER (a bare hostname, e.g.
# vc-01.example.com) against item['server_spec']['server_name'] or
# item['display_name'] - neither field exists on this Connection Server's
# real /rest/monitor/v2/virtual-centers response (confirmed on a real run,
# the first time this script actually reached this call). What IS present
# is 'name', holding the full vCenter SDK URL, e.g.
# "https://vc-01.example.com:443/sdk" - so this now does a
# substring match of VCENTER_SERVER against 'name' (falling back to
# display_name/server_spec.server_name too, in case a different Horizon
# version populates those instead) rather than an exact match against
# fields that may not exist.
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
  # Horizon's filter query-param syntax for this endpoint varies by version
  # and isn't reliable enough to depend on here, so pull the full pool list
  # and match client-side instead - desktop pool counts per Connection
  # Server are small enough that this is cheap either way.
  # Matches against TARGET_NAME, not HORIZON_POOL directly - the confirmation
  # prompt above may have overridden it to a different pool name.
  POOL_LIST="$(api GET "/rest/inventory/v1/desktop-pools")"
  POOL_ID="$(json_get_id "$POOL_LIST" "name" "$TARGET_NAME" "id")"
  if [ -z "$POOL_ID" ]; then
    echo "Could not find a desktop pool named '$TARGET_NAME'." >&2
    echo "Raw response: $POOL_LIST" >&2
    exit 1
  fi
  echo "    pool=$POOL_ID ($TARGET_NAME)"

  echo "==> Scheduling the desktop pool push-image operation"
  # logoff_policy WAIT_FOR_LOGOFF (not FORCE_LOGOFF) and stop_on_first_error
  # true are the conservative choices - recompose waits for each user to log
  # off on their own rather than kicking them, and the whole operation halts
  # on the first machine that fails instead of plowing through the rest of
  # the pool. Omitting start_time schedules it immediately rather than for a
  # specific maintenance window - add "'start_time': <epoch-ms>," below if
  # you'd rather schedule this for later instead of right now.
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
  # RDS farm workflow - see this script's "Pool vs farm" header comment for
  # where /rest/inventory/v2/farms + schedule-maintenance came from.
  # Matches against TARGET_NAME, not HORIZON_FARM directly - the confirmation
  # prompt above may have overridden it to a different farm name.
  FARM_LIST="$(api GET "/rest/inventory/v2/farms")"
  FARM_ID="$(json_get_id "$FARM_LIST" "name" "$TARGET_NAME" "id")"
  if [ -z "$FARM_ID" ]; then
    echo "Could not find an RDS farm named '$TARGET_NAME'." >&2
    echo "Raw response: $FARM_LIST" >&2
    exit 1
  fi
  echo "    farm=$FARM_ID ($TARGET_NAME)"

  echo "==> Scheduling the farm maintenance/push-image operation"
  # Same conservative choices as the pool path above (WAIT_FOR_LOGOFF,
  # stop_on_first_error true). maintenance_mode IMMEDIATE (rather than
  # setting next_scheduled_time) starts this right away instead of at a
  # scheduled time - no add_virtual_tpm key here, unlike the pool body
  # above: it isn't part of either reference script's farm-side request, so
  # it's left out rather than guessed at. See this script's "Pool vs farm"
  # header comment before trusting this body shape against a real farm.
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
