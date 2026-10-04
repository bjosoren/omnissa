#!/usr/bin/env bash
# scripts/repo_compare.sh - what does production (~/golden-images) have that the
# git clone (~/omnissa-repo) doesn't? Read-only on both.
#
#   scripts/repo_compare.sh
#
# Report: ~/repo-compare/report.txt (+ full.diff). Lists changed files, files
# only in production, files only in the repo, and scans the changed/new files
# for site data (~/.sync_to_repo.patterns + private IPs; file:line only).
# Site files (*.local.yml, hosts.ini, all.yml, vault), configs/, logs, caches
# and backup/editor leftovers (*.bak*, *.orig, *.old, *~, ...) are never compared.
set -uo pipefail
GI="${SRC:-$HOME/golden-images}"
REPO_ROOT="${REPO:-$HOME/omnissa-repo}"
TA="$REPO_ROOT/operations/template-automation"
OUT="${OUT:-$HOME/repo-compare}"
command -v rsync >/dev/null || { echo "rsync missing: sudo apt install -y rsync" >&2; exit 1; }
[ -d "$TA/automation-platform" ] || { echo "No repo layout under $TA" >&2; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT/gi" "$OUT/repo"
R="$OUT/report.txt"; : > "$R"
sec() { printf '\n==================== %s\n' "$*" | tee -a "$R"; }

EX=(--exclude '/inventory/hosts.ini' --exclude '/inventory/group_vars/all.yml'
    --exclude '/inventory/group_vars/all/' --exclude '*.local.yml'
    --exclude 'logs/' --exclude 'build_logs/' --exclude 'packer_cache/' --exclude 'files/'
    --exclude '.packer_vars.json' --exclude '.preflight_check.json'
    --exclude '__pycache__/' --exclude '/configs/' --exclude '.git/')

# Lay both trees out the repo way: automation-platform/ + <image>/
copy() { rsync -a "${EX[@]}" "$1" "$2"; }
copy "$TA/automation-platform/" "$OUT/repo/automation-platform/"
copy "$GI/" "$OUT/gi/automation-platform/"
rm -rf "$OUT/gi/automation-platform/images"
for d in "$TA"/*/; do
  key="$(basename "$d")"; [ "$key" = automation-platform ] && continue
  copy "$d" "$OUT/repo/$key/"
  [ -d "$GI/images/$key" ] && copy "$GI/images/$key/" "$OUT/gi/$key/"
done
for d in "$GI"/images/*/; do
  key="$(basename "$d")"; [ -d "$OUT/gi/$key" ] || copy "$d" "$OUT/gi/$key/"
done
# Backup / editor leftovers never count (same list in scrub_comments.py,
# sync_to_repo.sh, the pre-commit hook and .gitignore).
BACKUP_GLOBS=('*.bak*' '*.orig' '*.old' '*.save' '*.pre-*' '*.new-*' '*~' '.*.sw?' '*.rej' '*.tmp' '*.part')
FIND_ARGS=(); for g in "${BACKUP_GLOBS[@]}"; do FIND_ARGS+=(-o -name "$g"); done
find "$OUT/gi" "$OUT/repo" -type f \( "${FIND_ARGS[@]:1}" \) -delete

sec "Repo state"
git -C "$REPO_ROOT" log --oneline -3 | tee -a "$R"
git -C "$REPO_ROOT" status -sb -- operations/template-automation | tee -a "$R"

sec "Changed in production (would be pushed)"
diff -rq "$OUT/repo" "$OUT/gi" | grep '^Files' | sed -E "s#Files $OUT/repo/([^ ]+) and .*#\1#" \
  | tee "$OUT/changed.txt" | tee -a "$R"

sec "Only in production (new files - commit them, or move them out of production)"
diff -rq "$OUT/repo" "$OUT/gi" | grep "^Only in $OUT/gi" \
  | sed -E "s#^Only in $OUT/gi/?##; s#^: ##; s#: #/#" | tee "$OUT/new.txt" | tee -a "$R"

sec "Only in the repo (expected: *.example templates, READMEs)"
diff -rq "$OUT/repo" "$OUT/gi" | grep "^Only in $OUT/repo" \
  | sed -E "s#^Only in $OUT/repo/?##; s#^: ##; s#: #/#" | tee -a "$R"

sec "Site-data scan of changed + new files (file:line only, values not printed)"
# Your site names (regexes, one per line) live outside the repo in
# ~/.sync_to_repo.patterns - same file sync_to_repo.sh and the pre-commit hook use.
PAT="$OUT/patterns.txt"
{ [ -f "${PATTERNS_FILE:-$HOME/.sync_to_repo.patterns}" ] \
    && grep -v '^\s*#' "${PATTERNS_FILE:-$HOME/.sync_to_repo.patterns}" | sed '/^\s*$/d'
  echo '\b(10\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]{1,3}\.[0-9]{1,3}\b'; } > "$PAT"
[ "$(wc -l < "$PAT")" -gt 1 ] || echo "    NOTE: no ~/.sync_to_repo.patterns - only private IPs are checked" | tee -a "$R"
hits=0
while read -r f; do
  [ -n "$f" ] || continue
  p="$OUT/gi/$f"; [ -d "$p" ] && p="$p/"
  while IFS= read -r m; do echo "    LEAK? $m" | sed "s#$OUT/gi/##" | tee -a "$R"; hits=1; done \
    < <(grep -HrnIoiE -f "$PAT" "$p" 2>/dev/null | cut -d: -f1,2 | sort -u)
done < <(cat "$OUT/changed.txt" "$OUT/new.txt")
[ $hits -eq 0 ] && echo "    none" | tee -a "$R"

diff -ru "$OUT/repo" "$OUT/gi" | sed "s#$OUT/repo/#repo:#; s#$OUT/gi/#prod:#" > "$OUT/full.diff"
echo
echo "Report:    $R"
echo "Full diff: $OUT/full.diff  ($(wc -l < "$OUT/full.diff") lines)"
