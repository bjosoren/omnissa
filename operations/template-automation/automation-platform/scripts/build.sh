#!/usr/bin/env bash
# scripts/build.sh
# Multi-image dispatcher. Builds any Omnissa golden image under images/
# end to end and pushes it live: resolves that image's group_vars + the
# shared platform vars through Ansible (so this script never has to parse
# Jinja itself), checks whether that image's reusable build VM is already
# sitting in vCenter from a previous run (prompting to delete it if so),
# runs Packer to install and configure that VM, clones it to a fresh,
# uniquely named VM and snapshots the clone for Horizon, pushes that
# snapshot to whichever pool or farm that image's own group_vars names via
# scripts/publish_to_pool.sh (which still stops for its own human
# confirmation before touching anything live - see that script's own
# "Pool vs farm" header comment for how it decides which of the two this
# is), then offers to delete the now-finished-with build VM. See the "VM
# naming" comment below for why the build happens on one VM but a separate
# clone is what actually gets published, and publish_to_pool.sh's own
# header for the reference-pool vs. production-pool distinction.
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
# Every run's full output (this script's own echoes, the resolve_vars.yml
# play, packer init/validate/build, the post-build snapshot play, and the
# publish_to_pool.sh push) is tee'd to a timestamped transcript under that
# image's own logs/ - see "Transcript logging" below - so a failed build
# can be reviewed or handed to someone else for troubleshooting without
# having to reproduce it.
#
# Run from anywhere - it cd's to the project root itself. Interactive: it
# will stop and wait for a y/N answer at up to three points (pre-flight
# delete, publish_to_pool.sh's own pool-name confirmation, and the final
# delete-the-build-VM prompt), plus the image-selection prompt when no
# image is given on the command line - don't run this from a context with
# no attached terminal (cron, CI) without also passing <image_key>.
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

case "${1:-}" in
  --list)
    printf '%s\n' "${IMAGES[@]}"
    exit 0
    ;;
  -h|--help)
    echo "Usage: scripts/build.sh [image_key|--list]"
    echo ""
    echo "Available images:"
    printf '  %s\n' "${IMAGES[@]}"
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

# ---- Local, untracked overrides (ADDED 2026-09-17) ----
# inventory/group_vars/${IMAGE_KEY}.yml is committed to this repo, which is
# public - per the user's explicit request, real site-specific values that
# shouldn't be public (guest_ip_cidr/guest_gateway/guest_dns_servers today;
# see that file's own comment on those three for the incident this came
# from - a real internal /24 briefly ended up committed) live instead in
# inventory/group_vars/${IMAGE_KEY}.local.yml, which is .gitignore'd (see
# inventory/group_vars/.gitignore) and only ever exists locally on each
# control node, never in git. Entirely optional: if it's not present, every
# ansible-playbook call below behaves exactly as it did before this change,
# using only the committed (placeholder-safe) group_vars file. When it IS
# present, it's loaded via its own -e "@..." AFTER $GROUP_VARS_FILE, so its
# values win over the committed placeholders (later -e flags take
# precedence in Ansible) without editing or overriding the whole file.
# GROUP_VARS_ARGS is built once here and reused by every ansible-playbook
# call in this script (and the equivalent block in publish_to_pool.sh),
# rather than repeating the same "if local file exists" check five times.
LOCAL_VARS_FILE="$PROJECT_ROOT/inventory/group_vars/${IMAGE_KEY}.local.yml"
GROUP_VARS_ARGS=(-e "@$GROUP_VARS_FILE")
if [ -f "$LOCAL_VARS_FILE" ]; then
  echo "==> Using local overrides from $LOCAL_VARS_FILE (not tracked in git)"
  GROUP_VARS_ARGS+=(-e "@$LOCAL_VARS_FILE")
fi

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
# PUBLISHED_VM_NAME is what actually gets handed to Horizon: the post-build
# step below clones VM_NAME to a new VM under this name (vCenter assigns
# it its own fresh MAC - see post_build_snapshot.yml) and snapshots that
# clone instead of VM_NAME directly, so the reusable build VM's identity
# never ends up duplicated onto whatever's currently published. Built from
# PUBLISHED_VM_PREFIX (from image.conf) plus a down-to-the-second
# timestamp, since this project gets rebuilt more than once a day while
# iterating and a date-only name would collide outright on a same-day
# re-run.
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
# it doesn't touch $?, so `set -e` still works normally.
LOG_DIR="$IMAGE_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/${PUBLISHED_VM_NAME}.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "==> Transcript: $LOG_FILE"

if [ ! -f "$VAULT_PASS_FILE" ]; then
  echo "Vault password file not found at $VAULT_PASS_FILE - see the platform post's" >&2
  echo "'Credentials the platform needs' section." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$HOME/ansible-venv/bin/activate"

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
# publish_to_pool.sh keeps its own "type the pool/farm name to confirm"
# prompt before it touches anything live (recomposing every desktop/RDSH
# host provisioned from it, per that script's own header comment) - that's
# unchanged; you just see it as part of this same run now instead of
# running the script separately afterward. Called via `if` rather than a
# bare invocation so `set -e` doesn't immediately kill this whole script on
# a failed/declined push - a failed push should leave $VM_NAME in place for
# retry/troubleshooting (see below), not also cost you the one VM you'd
# want for that.
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
if bash "$PROJECT_ROOT/scripts/publish_to_pool.sh" "$IMAGE_KEY" "$PUBLISHED_VM_NAME"; then
  PUBLISH_OK=true
else
  PUBLISH_OK=false
fi

echo ""
echo "==================== Build summary ===================="
echo "Image:         $IMAGE_KEY"
echo "Build VM:      $VM_NAME (rebuilt this run)"
echo "Published VM:  $PUBLISHED_VM_NAME (snapshot: $PUBLISHED_VM_NAME)"
if [ "$PUBLISH_OK" = true ]; then
  echo "Pool/farm push: requested successfully"
else
  echo "Pool/farm push: FAILED or declined - see output above."
  echo "               $VM_NAME has been left in place so you can retry"
  echo "               (scripts/publish_to_pool.sh $IMAGE_KEY $PUBLISHED_VM_NAME)"
  echo "               or troubleshoot, without rebuilding from scratch."
fi
echo "=========================================================="
echo ""

if [ "$PUBLISH_OK" != true ]; then
  exit 1
fi

# Only offered once the new image is actually live in the pool - $VM_NAME
# has done its job for this run at that point (it's not a vSphere template,
# just a normal reused VM). Declining here just leaves it in place, same as
# declining the pre-flight prompt earlier - keeping it isn't required
# either way, it's only there so a fresh build has a fixed identity
# (MAC/IP/AD computer object) to build onto - see variables.pkr.hcl's
# vm_name comment.
read -r -p "Delete $VM_NAME now? [y/N] " REPLY
case "$REPLY" in
  [yY]|[yY][eE][sS])
    echo "==> Deleting $VM_NAME"
    ansible-playbook \
      --vault-password-file "$VAULT_PASS_FILE" \
      -e "@$PROJECT_ROOT/inventory/group_vars/all.yml" \
      -e "@$PROJECT_ROOT/inventory/group_vars/all/vault.yml" \
      "${GROUP_VARS_ARGS[@]}" \
      -e "vm_name=$VM_NAME" \
      "$IMAGE_DIR/delete_vm.yml"
    echo "==> Done: $VM_NAME deleted."
    ;;
  *)
    echo "Leaving $VM_NAME in place."
    ;;
esac
