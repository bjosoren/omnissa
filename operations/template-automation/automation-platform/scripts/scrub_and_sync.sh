#!/usr/bin/env bash
# scripts/scrub_and_sync.sh - clean the change-history comments out of
# production (~/golden-images) and copy the result into the git clone
# (~/omnissa-repo). Never commits or pushes - that's push_to_github.sh.
#
#   scripts/scrub_and_sync.sh                  dry run: what would be scrubbed and copied
#   scripts/scrub_and_sync.sh --apply          backup, scrub, copy
#   scripts/scrub_and_sync.sh --apply --no-scrub   only copy (sync_to_repo.sh, all images)
#
# Steps with --apply:
#   1. refuses to run while a packer build is running (it edits files a build reads)
#   2. backup of production (~/backup-golden-images.sh if present, else a tar)
#   3. scripts/scrub_comments.py --apply - see that script for what is removed
#      and how each file is checked to still do exactly the same
#   4. scripts/sync_to_repo.sh --apply <every image> - copies to the repo, but
#      only if its leak scan is clean
#   5. scripts/repo_compare.sh - production and repo should now match
set -euo pipefail
SRC="${SRC:-$HOME/golden-images}"
REPO="${REPO:-$HOME/omnissa-repo}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLY=false; SCRUB=true
for a in "$@"; do
  case "$a" in
    --apply) APPLY=true ;;
    --no-scrub) SCRUB=false ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $a" >&2; exit 1 ;;
  esac
done
say() { printf '\n==> %s\n' "$*"; }

[ -d "$SRC/images" ] || { echo "No production tree at $SRC" >&2; exit 1; }
[ -d "$REPO/.git" ] || { echo "$REPO is not a git clone" >&2; exit 1; }
[ -f "$HOME/ansible-venv/bin/activate" ] && source "$HOME/ansible-venv/bin/activate"   # PyYAML

if $APPLY && pgrep -x packer >/dev/null; then
  echo "A packer build is running - wait for it to finish (this edits files the build reads)." >&2
  exit 1
fi

mapfile -t KEYS < <(for d in "$SRC"/images/*/; do ls "$d"*.pkr.hcl >/dev/null 2>&1 && basename "$d"; done)
echo "Images: ${KEYS[*]}"

if $APPLY; then
  say "1/4 Backup of $SRC"
  if [ -x "$HOME/backup-golden-images.sh" ]; then
    "$HOME/backup-golden-images.sh"
  else
    mkdir -p "$HOME/backups/golden-images"; chmod 700 "$HOME/backups/golden-images"
    tar -czf "$HOME/backups/golden-images/golden-images-$(date +%Y%m%d-%H%M%S)-prescrub.tar.gz" \
        -C "$HOME" --exclude='golden-images/images/*/logs' --exclude='golden-images/images/*/build_logs' \
        golden-images
    echo "    $(ls -t "$HOME"/backups/golden-images/*.tar.gz | head -1)"
  fi
fi

if $SCRUB; then
  say "2/4 Scrub change-history comments in production"
  if $APPLY; then
    python3 "$HERE/scrub_comments.py" --root "$SRC" --apply \
      || { echo "Some files were skipped (see SKIPPED above) - the rest were scrubbed." >&2; }
  else
    python3 "$HERE/scrub_comments.py" --root "$SRC"
  fi
fi

say "3/4 Copy to $REPO"
if $APPLY; then
  SRC="$SRC" REPO="$REPO" bash "$HERE/sync_to_repo.sh" --apply "${KEYS[@]}"
else
  SRC="$SRC" REPO="$REPO" bash "$HERE/sync_to_repo.sh" "${KEYS[@]}" || true
  $SCRUB && echo "    (dry run: this list is from before scrubbing)"
fi

if $APPLY; then
  say "4/4 Check: production vs repo after the copy (the first two lists should be empty)"
  SRC="$SRC" REPO="$REPO" bash "$HERE/repo_compare.sh" >/dev/null
  sed -n '/Changed in production/,$p' "$HOME/repo-compare/report.txt"
  say "Ready to commit in $REPO"
  git -C "$REPO" status --short -- operations/template-automation
  echo
  echo "Next: build once from production to confirm, then  scripts/push_to_github.sh"
else
  echo
  echo "Dry run only - re-run with --apply."
fi
