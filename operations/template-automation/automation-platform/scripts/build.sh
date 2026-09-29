#!/usr/bin/env bash
# scripts/build.sh
# Multi-image dispatcher. Builds any Omnissa golden image under images/
# end to end and pushes it live: resolves that image's group_vars + the
# shared platform vars through Ansible (so this script never has to parse
# Jinja itself), checks whether that image's reusable build VM is already
# sitting in vCenter from a previous run (prompting to delete it if so),
# runs Packer to install and configure that VM, then - unless you answered
# No to "Publish to Desktop-pool/Farm?" at the placement prompt below -
# clones it to a fresh, uniquely named VM, snapshots the clone for Horizon,
# and pushes that snapshot to whichever pool or farm that image's own
# group_vars names via scripts/publish_to_pool.sh (which still stops for
# its own human confirmation before touching anything live, UNLESS a
# target was preselected at the placement prompt below - see that script's
# own "Pool vs farm" and "Confirm before touching a live pool/farm" header
# comments for how it decides). Finally, deletes the now-finished-with
# build VM if you said to at the placement prompt. See the "VM naming"
# comment below for why the build happens on one VM but a separate clone
# is what actually gets published, and publish_to_pool.sh's own header for
# the reference-pool vs. production-pool distinction.
#
# Which image gets built:
#   scripts/build.sh                 - no image given: lists every image
#                                       discovered under images/ and prompts
#                                       for a number.
#   scripts/build.sh <image_key>     - builds that image directly, no
#                                       prompt (e.g. scripts/build.sh
#                                       ubt_2404_tpl).
#   scripts/build.sh --list          - prints the discovered image keys,
#                                       one per line, and exits without
#                                       building anything.
#
# An image is discovered automatically: any directory directly under
# images/ that contains at least one *.pkr.hcl file counts as a buildable
# image, keyed by that directory's own name. Nothing in this script needs
# editing to add a new image - see "Adding a new image" below for what
# each image directory needs to provide.
#
# ---- Unattended / scheduled builds (ADDED 2026-09-28) ----
#   scripts/build.sh <image_key> --placement NAME
#   scripts/build.sh --placement NAME <image_key>   (order doesn't matter)
#
# Skips the ENTIRE interactive placement/build-options picker below - no
# terminal needed, and no vCenter/Horizon call at that step - by loading a
# previously saved placement instead. A placement is saved by answering
# "y" to the picker's own "Save these settings for unattended/scheduled
# reruns?" prompt (see scripts/select_placement.py's docstring for the
# full mechanics and where saved placements live, under placements/).
# This is what makes a build genuinely safe to put on cron or a systemd
# timer: with --placement given, this script makes no interactive prompt
# of its own either (the pre-flight "VM already exists, delete it?" check
# still can, in principle, if a stale build VM is sitting there from a
# prior failed run - see that check below; a truly unattended schedule
# should expect that as a possible hang and either not reuse a
# still-in-progress build's VM_NAME concurrently, or monitor for it).
# Everything downstream (Ansible/Packer/publish) behaves exactly as it
# would for the same answers given interactively - a saved placement's
# PUBLISH_TO_POOL/HORIZON_TARGET_TYPE/HORIZON_TARGET_NAME flow through to
# publish_to_pool.sh exactly the same way, including that a preselected
# target there now skips ITS OWN confirmation prompt too (see that
# script's 2026-09-28 change) - so choose what you save deliberately: save
# one placement with "No - skip clone/snapshot/publish" for a build-and-
# snapshot-only unattended job, and a separate one with a real target for
# a job you're comfortable pushing all the way to a live pool/farm with no
# human in the loop at all.
#
#   scripts/build.sh --list-placements <image_key>
#                                     - prints the saved placement names
#                                       available for that image, one per
#                                       line, and exits.
#
# Without --placement, this remains exactly as interactive as before: it
# will stop and wait for a y/N answer at the pre-flight delete prompt and
# at publish_to_pool.sh's own pool-name confirmation (unless a target was
# picked live at the placement prompt - see above), plus the
# image-selection prompt when no image is given on the command line, plus
# the placement/build-options picker itself (cluster/host/datastore/
# portgroup/folder/collect-logs/publish/delete-after) which still runs on
# every build that doesn't pass --placement, up front, before anything
# else happens - don't run this from a context with no attached terminal
# (cron, CI) without also passing <image_key> --placement NAME, or expect
# it to hang there waiting for input.
#
# Every run's full output (this script's own echoes, the resolve_vars.yml
# play, packer init/validate/build, the post-build snapshot play, and the
# publish_to_pool.sh push) is tee'd to a timestamped transcript under that
# image's own logs/ - see "Transcript logging" below - so a failed build
# can be reviewed or handed to someone else for troubleshooting without
# having to reproduce it.
#
# Run from anywhere - it cd's to the project root itself.
#
# Adding a new image:
#   1. images/<key>/ - the Packer template (*.pkr.hcl is what makes this
#      directory discoverable) plus that image's resolve_vars.yml,
#      preflight_check_vm.yml, delete_vm.yml and post_build_snapshot.yml
#      playbooks (copy an existing image's as a starting point).
#   2. images/<key>/image.conf - defines VM_NAME and PUBLISHED_VM_PREFIX
#      for this image. See images/ubt_2404_tpl/image.conf's comments for
#      why these can't just be derived from <key> automatically.
#   3. inventory/group_vars/<key>.yml - this image's own vars, matching
#      <key> exactly (same convention resolve_vars.yml already relies on).

main() {

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAULT_PASS_FILE="$HOME/.vault_pass"

cd "$PROJECT_ROOT"

# ---- Image discovery ----
# Any images/*/ directory containing a *.pkr.hcl file is a buildable image,
# keyed by its own directory name - so adding an image is purely a matter
# of adding a new images/<key>/ directory (see "Adding a new image" above);
# this script never needs to change to pick it up.
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

# ---- Parse --placement NAME / --list-placements up front (ADDED
# 2026-09-28) ----
# Both may appear anywhere in the args, before or after <image_key>, so
# this strips them out of "$@" first and reassigns the remaining args back
# to "$@" - everything below (image_key/--list/--help handling) is
# completely unchanged either way this or the leftover args are ordered on
# the command line, e.g. both `build.sh rdsh_2025_tpl --placement nightly`
# and `build.sh --placement nightly rdsh_2025_tpl` work. See "Unattended /
# scheduled builds" above.
PLACEMENT_NAME=""
LIST_PLACEMENTS=false
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --placement)
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
  PLACEMENTS_DIR="$PROJECT_ROOT/placements"
  FOUND=false
  if [ -d "$PLACEMENTS_DIR" ]; then
    for f in "$PLACEMENTS_DIR/${IMAGE_KEY_FOR_LIST}__"*.control.sh; do
      [ -e "$f" ] || continue
      FOUND=true
      base="$(basename "$f" .control.sh)"
      echo "${base#${IMAGE_KEY_FOR_LIST}__}"
    done | sort
  fi
  if [ "$FOUND" != true ]; then
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

# shellcheck disable=SC1090
# Activated here - earlier than the rest of this script strictly needs it
# for its OWN ansible-playbook/packer calls - because the placement picker
# right below needs a python3 with pyyaml/pyvmomi on its path (both live in
# this venv, not system python3), and it has to run before GROUP_VARS_ARGS
# is built. Everything else that used to run before this line (image
# discovery/selection, image.conf sourcing) is plain bash with no python
# dependency, so moving this up is safe. Still needed even when
# --placement/PLACEMENT_NAME skips select_placement.py's interactive/
# vCenter path below - it still imports pyyaml at module load time either
# way (see that script's own --load path).
source "$HOME/ansible-venv/bin/activate"

# --- Placement/build-options picker (always runs, interactively unless
# --placement was given - see "Unattended / scheduled builds" above) ----
# Asks, in order: cluster, ESXi host, datastore, portgroup, VM folder,
# collect-install-logs, publish-to-pool-or-farm, delete-build-VM-after.
# Two files come out of it either way: PLACEMENT_OVERRIDE_FILE (the
# vCenter placement keys, fed into the Ansible/Packer pipeline below same
# as *_adv-vm-settings.yml) and PLACEMENT_CONTROL_FILE (plain KEY=value
# bash assignments for the answers - collect-logs, publish, delete, and
# the preselected Horizon target if any - that drive THIS script's own
# control flow, sourced directly below).
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

# shellcheck disable=SC1090
source "$PLACEMENT_CONTROL_FILE"
: "${COLLECT_BUILD_LOGS:?select_placement.py did not set COLLECT_BUILD_LOGS}"
: "${PUBLISH_TO_POOL:?select_placement.py did not set PUBLISH_TO_POOL}"
: "${DELETE_VM_AFTER:?select_placement.py did not set DELETE_VM_AFTER}"
# HORIZON_TARGET_TYPE/HORIZON_TARGET_NAME are legitimately empty whenever
# PUBLISH_TO_POOL=false (no pool/farm was picked) - select_placement.py
# always assigns them (to '' in that case), so `set -u` further down is
# still a safety net against a genuinely missing assignment; they're just
# not required to be NON-empty the way the three above are.

# GROUP_VARS_ARGS is built once here and reused by every ansible-playbook
# call in this script (and the equivalent block in publish_to_pool.sh),
# rather than repeating the same "if this file exists" check at every call
# site. Order matters: ${IMAGE_KEY}.local.yml is added near the end, and
# PLACEMENT_OVERRIDE_FILE last of all, so the interactive picks above win
# over a CHANGEME-* placeholder OR a real .local.yml value alike (later -e
# flags take precedence in Ansible).
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

# ---- Per-image naming (VM_NAME / PUBLISHED_VM_PREFIX) ----
# See images/ubt_2404_tpl/image.conf's own comments for why these two
# values are declared explicitly per image rather than derived from
# IMAGE_KEY.
IMAGE_CONF="$IMAGE_DIR/image.conf"
if [ ! -f "$IMAGE_CONF" ]; then
  echo "Missing $IMAGE_CONF - every image needs an image.conf defining" >&2
  echo "VM_NAME and PUBLISHED_VM_PREFIX (see images/ubt_2404_tpl/image.conf" >&2
  echo "for reference)." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$IMAGE_CONF"
: "${VM_NAME:?VM_NAME not set in $IMAGE_CONF}"
: "${PUBLISHED_VM_PREFIX:?PUBLISHED_VM_PREFIX not set in $IMAGE_CONF}"

# ---- VM naming ----
# Two different VMs, two different naming rules - this split is the fix for
# a real production failure (see this image's own .pkr.hcl header and
# variables.pkr.hcl's vm_name/mac_address comments for the full story): a
# published, Horizon-locked golden image VM was found to still be holding
# the exact pinned MAC/static IP the next build's own freshly-installed
# guest also tried to configure, and the two live VMs fighting over one
# network identity is what caused that run's intermittent SSH-after-reboot
# failures.
#
# VM_NAME (from image.conf) is the reusable automation VM Packer actually
# builds onto - fixed, not timestamped, so it keeps the SAME pinned
# MAC/IP/AD computer object/DNS record across every single run. packer
# build below is passed -force so it can destroy and recreate this
# same-named VM from scratch each time instead of erroring with "<name>
# already exists, you can use -force flag to destroy it" (the exact error
# a fixed name used to hit before -force was added).
#
# PUBLISHED_VM_NAME is what actually gets handed to Horizon, and is also
# used to name this run's transcript log below, whether or not a clone
# actually ends up happening (see "Publish to Desktop-pool/Farm?" further
# down) - it's just a name/timestamp at this point, computing it doesn't
# require a clone to exist yet. If PUBLISH_TO_POOL ends up true, the
# post-build step clones VM_NAME to a new VM under this name (vCenter
# assigns it its own fresh MAC - see post_build_snapshot.yml) and
# snapshots that clone instead of VM_NAME directly, so the reusable build
# VM's identity never ends up duplicated onto whatever's currently
# published. Built from PUBLISHED_VM_PREFIX (from image.conf) plus a
# down-to-the-second timestamp, since this project gets rebuilt more than
# once a day while iterating and a date-only name would collide outright
# on a same-day re-run.
PUBLISHED_VM_NAME="${PUBLISHED_VM_PREFIX}-$(date +%Y%m%d-%H%M%S)"

# ---- Transcript logging ----
# Logs live under this image's own logs/ (images/<key>/logs/), not a
# shared platform-wide location, so each image's build history stays next
# to the rest of that image's files. One file per run - PUBLISHED_VM_NAME
# (not VM_NAME, which is fixed across every run) carries its own
# down-to-the-second timestamp, so reusing it here both names the log after
# the exact build it belongs to and guarantees a re-run after a failure
# never clobbers the previous attempt's log.
# `exec > >(tee ...) 2>&1` redirects this shell's own stdout and stderr for
# the rest of the script - unlike piping the whole script through `| tee`,
# it doesn't touch $?, so `set -e` still works normally. Note this means
# the placement picker's own output above is NOT captured in this
# transcript - it can't run until PUBLISHED_VM_NAME exists, and that needs
# image.conf, which needs IMAGE_KEY. The "Build summary" block near the
# end restates the image and VM names, and the picker's three control
# answers, for the record.
LOG_DIR="$IMAGE_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/${PUBLISHED_VM_NAME}.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "==> Transcript: $LOG_FILE"

# ---- NTLM WinRM transport prerequisite check ----
# rdsh_2025_tpl.pkr.hcl's ansible provisioner sets ansible_winrm_transport=ntlm
# (added 2026-09-14, trying the Omnissa Community guide's own WinRM auth
# approach) - pywinrm needs the requests_ntlm package installed for that
# transport to work at all, and unlike the Basic path it replaces, this one
# isn't already guaranteed present. Checked here, not left to fail deep into
# the ansible provisioner's own run inside packer build - same "fail fast,
# not 20+ minutes in" reasoning as the DNS and installer checks below. Only
# rdsh_2025_tpl actually sets ansible_winrm_transport today, so this only
# blocks that image - ubt_2404_tpl (SSH, not WinRM) is unaffected either way.
if [ "$IMAGE_KEY" = "rdsh_2025_tpl" ]; then
  echo "==> Checking for requests_ntlm (needed for rdsh_2025_tpl's WinRM NTLM transport)"
  if ! python3 -c "import requests_ntlm" >/dev/null 2>&1; then
    echo "requests_ntlm is not installed in this control node's ansible-venv." >&2
    echo "rdsh_2025_tpl's ansible provisioner now connects via" >&2
    echo "ansible_winrm_transport=ntlm (see rdsh_2025_tpl.pkr.hcl), which needs it." >&2
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

get() {
  python3 -c "import json,sys; print(json.load(open('$VARS_FILE')).get('$1',''))"
}

# ---- Pre-flight: is $VM_NAME already sitting in vCenter from a prior run? ----
# packer build -force further down would happily destroy-and-recreate
# $VM_NAME on its own, silently, if it already exists there - that's exactly
# what -force means (see the VM naming comment above). This check exists
# purely to put a visible, human checkpoint in front of that instead of
# leaving it entirely automatic: look it up first, and if it's there, ask
# before touching it. Answering "no" aborts the whole build rather than
# silently letting -force destroy it anyway a few steps later - if you're
# not ready to lose that VM (mid-troubleshooting on it, say), this is the
# point to stop, not after packer build has already started.
#
# NOTE for --placement/unattended runs: this prompt is NOT skipped by
# --placement - it's a leftover-VM safety check, unrelated to placement
# choices. A stale VM_NAME from a previous failed run will still stop a
# scheduled build here waiting for input. If you're relying on this
# script for a fully unattended schedule, make sure the prior run's VM
# gets cleaned up (DELETE_VM_AFTER in the saved placement, or a failed
# run's VM removed before the next scheduled one starts) so this check
# never has anything to ask about.
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

# ---- DNS prerequisite check ----
# Packer's own HCL has no way to run a real pre-flight check before a source
# starts building - variable validation blocks can't make network calls, and
# provisioners (including shell-local) only run after vsphere-iso has already
# booted the ISO and finished the ~20-30 minute autoinstall. So this has to
# live here, gating the packer build/validate/init calls below, to actually
# fail fast instead of failing 30+ minutes in (typically at domain join, or
# with a guest that never gets network connectivity as expected). Checks that
# guest_hostname.domain_fqdn already has an A record - per the platform post's
# "reserve the IP and create a matching DNS A record first" step - and that
# it points at guest_ip_cidr, using dig against the platform's own DNS server
# directly so /etc/hosts or a stale local resolver cache can't mask a missing
# or wrong record.
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

# ---- Installer prerequisite check ----
# Same "fail fast before packer build, not 15+ minutes into it" reasoning as
# the DNS check above. horizon_agent_installer, dem_agent_installer, and
# appvolumes_agent_installer are all absolute paths on this control node's
# NFS mount (see inventory/group_vars/rdsh_2025_tpl.yml) - Packer/Ansible
# have no way to check them before Windows Setup has already finished its
# ~15-20 minute unattended install and WinRM is reachable, which is exactly
# when roles/horizon_agent (or later, roles/dem/roles/appvolumes) would
# otherwise discover a missing, stale, or unmounted installer and fail with
# "Could not find or access '...' on the Ansible Controller" - a real
# failure this hit once already, on horizon_agent_installer specifically.
# Checking here, from the same shell that will run ansible-playbook, sees
# exactly what Ansible would see (NFS mount included) instead of guessing.
echo "==> Checking installer prerequisites on this control node"
case "$IMAGE_KEY" in
  rdsh_2025_tpl)
    INSTALLER_VARS=(horizon_agent_installer dem_agent_installer appvolumes_agent_installer)
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
echo "==> Building $VM_NAME"

export PKR_VAR_vm_name="$VM_NAME"
export PKR_VAR_inventory_dir="$PROJECT_ROOT/inventory"

# Carries the placement picker's "Collect Install logs?" answer (see above)
# into rdsh_2025_tpl.pkr.hcl's `variable "collect_build_logs"`. Only set
# when relevant (rdsh_2025_tpl) - ubt_2404_tpl has no matching variable
# declared, and an unset/unreferenced PKR_VAR_* is harmless either way, but
# there's no reason to export it where it means nothing.
if [ "$IMAGE_KEY" = "rdsh_2025_tpl" ]; then
  export PKR_VAR_collect_build_logs="$COLLECT_BUILD_LOGS"
fi

# Every other PKR_VAR_* this image's variables.pkr.hcl needs comes from the
# image's own export_pkr_vars.sh, not from a shared block here. ubt_2404_tpl
# (SSH keys, NFS home dirs, a password hash for its autoinstall answer file)
# and rdsh_2025_tpl (WinRM plaintext password, KMS key, no SSH/NFS at all)
# have almost entirely different Packer variable schemas - trying to keep
# one shared export list here would mean either exporting vars an image
# doesn't declare (harmless but confusing) or, worse, silently leaving one
# it DOES need unexported. Each image owning its own get()-to-PKR_VAR_
# mapping is what actually stays correct as more images are added; get() and
# VARS_FILE above are already in scope for the sourced script to use.
# shellcheck disable=SC1090
source "$IMAGE_DIR/export_pkr_vars.sh"

# The resolved-vars file held vcenter_password and whatever the image's own
# vaulted build-account credential was (vault_local_admin_password for
# ubt_2404_tpl, vault_win_admin_password for rdsh_2025_tpl) in plaintext -
# it's done its job now.
shred -u "$VARS_FILE" 2>/dev/null || rm -f "$VARS_FILE"

cd "$IMAGE_DIR"
packer init .
packer validate .
# -force: VM_NAME is now a fixed, reused name (see the VM naming comment
# above) - without this, any run after the very first one fails immediately
# with "<name> already exists, you can use -force flag to destroy it",
# since vsphere-iso refuses to build onto/replace an existing VM by default.
packer build -on-error=cleanup -force .

# Done with the plaintext build password now that the ansible provisioner
# inside packer build has run - nothing after this point needs it.
unset PKR_VAR_build_password

# ---- Clone, snapshot, and publish - unless placement said not to ----
# PUBLISH_TO_POOL comes from the placement picker's "Publish to
# Desktop-pool/Farm?" question (interactively, or loaded from a saved
# placement via --placement). Answering/loading No skips ALL of this - no
# clone, no snapshot, no publish_to_pool.sh push - leaving only the
# rebuilt $VM_NAME itself: a deliberate "don't publish this run" isn't a
# failure, so PUBLISH_OK is left unset (neither true nor false) rather
# than false, and the summary/exit logic below treats "never attempted" as
# distinct from "attempted and failed".
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
  # publish_to_pool.sh keeps its own confirmation before it touches
  # anything live (recomposing every desktop/RDSH host provisioned from
  # it, per that script's own header comment) - UNLESS a target was
  # preselected below, in which case (as of 2026-09-28) it treats that
  # choice as already confirmed and skips its own prompt too; see that
  # script's "Confirm before touching a live pool/farm" comment. Called
  # via `if` rather than a bare invocation so `set -e` doesn't immediately
  # kill this whole script on a failed/declined push - a failed push
  # should leave $VM_NAME in place for retry/troubleshooting (see below),
  # not also cost you the one VM you'd want for that.
  #
  # Passes $IMAGE_KEY as well as $PUBLISHED_VM_NAME - publish_to_pool.sh uses
  # it to resolve the right image's group_vars (and therefore the right
  # horizon_pool_name/horizon_farm_name and REST workflow) instead of
  # guessing; see that script's own header comment for the real build this
  # fixed (it used to be hardcoded to one image and would silently resolve
  # the wrong image's vars for every other one).
  #
  # `bash "$PROJECT_ROOT/scripts/publish_to_pool.sh"`, not a direct
  # `"$PROJECT_ROOT/scripts/publish_to_pool.sh"` - a real run hit "Permission
  # denied" here because that file's executable bit didn't survive being
  # extracted from the delivered zip on this machine (zip itself records the
  # bit correctly; not every extraction method restores it). Invoking bash on
  # the file directly sidesteps needing the executable bit or the shebang at
  # all, so a lost +x here can't block the pipeline again - this matters more
  # than it would for a script you'd just re-chmod once, since this project
  # gets re-delivered as a fresh zip on every fix.
  #
  # When the placement picker's own live Horizon pool/farm step (step 8 of
  # the placement prompt) picked a specific target - or a saved placement
  # loaded via --placement carried one - pass it through as a 3rd/4th arg
  # so publish_to_pool.sh uses THAT target directly instead of re-deriving
  # one from horizon_pool_name/horizon_farm_name in group_vars. This is
  # what lets you publish to a different pool/farm than the one configured
  # there without editing group_vars first, and (as of 2026-09-28) is also
  # what lets publish_to_pool.sh skip its own confirmation prompt, since
  # picking - or loading - this target IS the confirmation.
  # HORIZON_TARGET_TYPE/HORIZON_TARGET_NAME are only ever both-empty or
  # both-set (see select_placement.py's pick_horizon_target()), so checking
  # just one is enough to decide which call to make.
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

# A publish that was actually attempted and failed (or was declined) always
# stops here, before the delete-VM step below - same safety net the old
# end-of-script delete prompt used to provide by simply never being reached
# on a failed run, now made explicit since that decision is answered up
# front instead. A publish that was never attempted (PUBLISH_TO_POOL=false)
# is not a failure, so it does NOT stop here - the DELETE_VM_AFTER answer
# below still applies normally in that case.
if [ "$PUBLISH_TO_POOL" = true ] && [ "$PUBLISH_OK" != true ]; then
  exit 1
fi

# ---- Delete the build VM? ----
# Answered up front at the placement prompt ("Delete template-vm after
# clone?"), not asked again here. By the time execution reaches this point,
# either publish was never attempted (PUBLISH_TO_POOL=false) or it was
# attempted and succeeded (the exit 1 above already caught the failed-or-
# declined case) - so it's always safe to just honor DELETE_VM_AFTER
# directly here, no further override needed.
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
