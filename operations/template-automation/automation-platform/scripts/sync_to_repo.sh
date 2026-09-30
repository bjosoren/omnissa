#!/usr/bin/env bash
# scripts/sync_to_repo.sh - copy ~/golden-images into the clean git clone
# (~/omnissa-repo, the sparse clone from the platform post) without site-specific data. Never commits or pushes.
#
#   scripts/sync_to_repo.sh [image_key ...]          dry run (default image: w11_24h2_tpl)
#   scripts/sync_to_repo.sh --apply [image_key ...]  copy, only if the leak scan is clean
#
# Copies images/<key>/, inventory/group_vars/<key>*.yml (+ .local.yml.example),
# scripts/*.sh|*.py and ansible.cfg. Never copies *.local.yml, hosts.ini,
# all.yml or the vault (the repo only has their *.example templates),
# configs/, logs, build output or installers. A new image gets a placeholder
# group in the repo's hosts.ini.example. The leak scan blocks on private IPs in values, pinned VMware
# MACs, private keys, plaintext secrets and any regex listed in
# ~/.sync_to_repo.patterns (your domain/lab names - kept outside the repo).
set -euo pipefail

SRC="${SRC:-$HOME/golden-images}"
REPO="${REPO:-$HOME/omnissa-repo}"
DST="$REPO/operations/template-automation"

PATTERNS_FILE="${PATTERNS_FILE:-$HOME/.sync_to_repo.patterns}"
LEAK_PATTERNS=""
if [ -f "$PATTERNS_FILE" ]; then
  LEAK_PATTERNS="$(grep -v '^[[:space:]]*\(#\|$\)' "$PATTERNS_FILE" | paste -sd'|' -)"
fi

APPLY=false
FORCE=false
KEYS=()
for a in "$@"; do
  case "$a" in
    --apply) APPLY=true ;;
    --force) FORCE=true ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) KEYS+=("$a") ;;
  esac
done
[ "${#KEYS[@]}" -gt 0 ] || KEYS=(w11_24h2_tpl)

[ -d "$SRC" ]  || { echo "No working copy at $SRC" >&2; exit 1; }
[ -d "$REPO/.git" ] || { echo "$REPO is not a git clone" >&2; exit 1; }
[ -d "$DST/automation-platform" ] || { echo "Unexpected repo layout under $DST" >&2; exit 1; }

EXCLUDES=(
  --exclude='*.local.yml' --exclude='logs/' --exclude='build_logs/' --exclude='files/'
  --exclude='packer_cache/' --exclude='.packer_cache/' --exclude='.packer_vars.json'
  --exclude='.preflight_check.json' --exclude='*.bak' --exclude='*.orig' --exclude='*.log'
  --exclude='*.zip' --exclude='*.iso' --exclude='*.exe' --exclude='*.msi' --exclude='__pycache__/'
)

PAIRS=()
for key in "${KEYS[@]}"; do
  [ -d "$SRC/images/$key" ] || { echo "No image dir $SRC/images/$key" >&2; exit 1; }
  PAIRS+=("$SRC/images/$key/|$DST/$key/")
done
for key in "${KEYS[@]}"; do
  for f in "$SRC"/inventory/group_vars/"$key".yml "$SRC"/inventory/group_vars/"$key"_*.yml \
           "$SRC"/inventory/group_vars/"$key".local.yml.example; do
    [ -f "$f" ] && PAIRS+=("$f|$DST/automation-platform/inventory/group_vars/")
  done
done
for f in "$SRC"/scripts/*.sh "$SRC"/scripts/*.py; do
  [ -f "$f" ] && PAIRS+=("$f|$DST/automation-platform/scripts/")
done
[ -f "$SRC/ansible.cfg" ] && PAIRS+=("$SRC/ansible.cfg|$DST/automation-platform/")

LIST="$(mktemp)"; PAIRS_FILE="$(mktemp)"; trap 'rm -f "$LIST" "$PAIRS_FILE"' EXIT
printf '%s\n' "${PAIRS[@]}" > "$PAIRS_FILE"
python3 - "$PAIRS_FILE" "${EXCLUDES[@]}" > "$LIST" <<'PYEOF'
import filecmp, fnmatch, os, sys
pairs_file = sys.argv[1]
pats = [a.split('=', 1)[1] for a in sys.argv[2:]]
dir_pats = [p.rstrip('/') for p in pats if p.endswith('/')]
file_pats = [p for p in pats if not p.endswith('/')]
def skip_file(name): return any(fnmatch.fnmatch(name, p) for p in file_pats)
def emit(src, dst):
    if skip_file(os.path.basename(src)):
        return
    if not os.path.exists(dst) or not filecmp.cmp(src, dst, shallow=False):
        print(f"{src}|{dst}")
for line in open(pairs_file):
    line = line.rstrip('\n')
    if not line:
        continue
    src, dst = line.split('|', 1)
    if os.path.isdir(src):
        for root, dirs, files in os.walk(src):
            dirs[:] = sorted(d for d in dirs if not any(fnmatch.fnmatch(d, p) for p in dir_pats))
            for f in sorted(files):
                sp = os.path.join(root, f)
                emit(sp, os.path.join(dst, os.path.relpath(sp, src)))
    else:
        emit(src, os.path.join(dst, os.path.basename(src)))
PYEOF

if [ ! -s "$LIST" ]; then
  echo "==> Nothing to sync - $REPO already matches $SRC for: ${KEYS[*]} + scripts."
  exit 0
fi

echo "==> Files that would be copied into $REPO:"
sed "s#|.*##; s#^$SRC/#    #" "$LIST"

echo ""
echo "==> Leak scan"
if [ -z "$LEAK_PATTERNS" ]; then
  echo "    NOTE: no site-name patterns in $PATTERNS_FILE - only IPs/MACs/keys/secrets"
  echo "    are checked. Add your domain/lab names there (one regex per line)."
fi
HITS="$(python3 - "$LIST" "$LEAK_PATTERNS" <<'PYEOF'
import re, sys
listfile, site = sys.argv[1], sys.argv[2]
priv = re.compile(r'\b(10\.\d{1,3}\.\d{1,3}\.\d{1,3}|172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3})\b')
site_re = re.compile(site, re.I) if site else None
key_re = re.compile(r'-----BEGIN [A-Z ]*PRIVATE KEY-----')
pw_re = re.compile(r'^\s*[\w.-]*(password|passwd|secret|token)[\w.-]*\s*:\s*(?P<v>.+)$', re.I)
mac_re = re.compile(r'\b00:50:56:[0-3][0-9a-f]:[0-9a-f]{2}:[0-9a-f]{2}\b', re.I)
hits, warns = [], []
for line in open(listfile):
    path = line.split('|', 1)[0].strip()
    try:
        text = open(path, encoding='utf-8', errors='replace').read()
    except OSError:
        continue
    if text.startswith('$ANSIBLE_VAULT'):
        continue
    commentable = path.endswith(('.yml', '.yaml', '.sh', '.py', '.ini', '.cfg', '.hcl', '.conf', '.j2'))
    for n, l in enumerate(text.splitlines(), 1):
        s = l.lstrip()
        is_comment = commentable and (s.startswith('#') or s.startswith('//'))
        code = '' if is_comment else (l.split(' #', 1)[0] if commentable else l)
        block, warn = [], []
        if priv.search(code): block.append('private IP')
        elif priv.search(l): warn.append('private IP in a comment')
        if site_re and site_re.search(l): block.append('site name')
        if key_re.search(l): block.append('private key')
        if mac_re.search(code): block.append('pinned MAC')
        m = pw_re.match(code)
        if m:
            v = m.group('v').strip().strip('"\'')
            if v and not v.startswith('{{') and not v.startswith('$') and 'CHANGEME' not in v \
               and 'REPLACE' not in v and v not in ('""', "''", 'null', '~'):
                block.append('plaintext secret?')
        if block:
            hits.append(f"    BLOCK {path}:{n}: [{', '.join(block)}] {l.strip()[:110]}")
        elif warn:
            warns.append(f"    warn  {path}:{n}: [{', '.join(warn)}] {l.strip()[:110]}")
out = hits + warns
if hits:
    out.append('__BLOCK__')
print('\n'.join(out))
PYEOF
)"
if [ -n "$HITS" ]; then
  echo "$HITS" | grep -v '^__BLOCK__$' || true
  echo ""
fi
if printf '%s\n' "$HITS" | grep -q '^__BLOCK__$'; then
  if [ "$FORCE" != true ]; then
    echo "Leak scan found possible site-specific data (above) - nothing copied." >&2
    echo "Move those values into <key>.local.yml in $SRC and re-run." >&2
    exit 1
  fi
  echo "--force given - copying despite the BLOCK hits above."
elif [ -z "$HITS" ]; then
  echo "    clean"
else
  echo "    only warnings (comments) - review them, not blocking"
fi

if [ "$APPLY" != true ]; then
  echo ""
  echo "Dry run only. Re-run with --apply to copy."
  exit 0
fi

while IFS='|' read -r s d; do
  mkdir -p "$(dirname "$d")"
  cp -p "$s" "$d"
done < "$LIST"

REPO_HOSTS="$DST/automation-platform/inventory/hosts.ini.example"
n=180
for key in "${KEYS[@]}"; do
  if ! grep -q "^\[$key\]" "$REPO_HOSTS"; then
    while grep -q "198\.51\.100\.$n\b" "$REPO_HOSTS"; do n=$((n+1)); done
    printf '\n[%s]\n%s ansible_host=198.51.100.%s\n' "$key" "$key" "$n" >> "$REPO_HOSTS"
    echo "==> Added [$key] to repo hosts.ini.example with placeholder 198.51.100.$n (TEST-NET-2)"
  fi
done

echo ""
echo "==> Copied. Review, then commit and push yourself:"
echo "    cd $REPO && git status && git diff"
echo "    git add -A operations/template-automation && git commit -m '...' && git push"
( cd "$REPO" && git status --short -- operations/template-automation )
