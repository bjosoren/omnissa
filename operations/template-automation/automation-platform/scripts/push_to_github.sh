#!/usr/bin/env bash
# scripts/push_to_github.sh - commit what scrub_and_sync.sh / sync_to_repo.sh
# put into the git clone (~/omnissa-repo) and push it to GitHub.
#
#   scripts/push_to_github.sh                   preview: files, diffstat, leak check
#   scripts/push_to_github.sh -m "message"      commit, then ask before pushing
#   scripts/push_to_github.sh -m "message" -y   commit and push without asking
#   scripts/push_to_github.sh --push-only       push commits already made
#
# Only operations/template-automation is staged - nothing else in the clone.
# Stops if the clone is behind GitHub (git pull --rebase first), and makes
# sure the leak-scan pre-commit hook is active, so a commit with site data
# is refused before it exists. The preview runs that same hook.
set -euo pipefail
REPO="${REPO:-$HOME/omnissa-repo}"
TA=operations/template-automation
HOOKS="$TA/automation-platform/scripts/git-hooks"
MSG=""; YES=false; PUSH_ONLY=false
while [ $# -gt 0 ]; do
  case "$1" in
    -m) MSG="${2:?-m needs a message}"; shift ;;
    -y|--yes) YES=true ;;
    --push-only) PUSH_ONLY=true ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done
say() { printf '\n==> %s\n' "$*"; }
cd "$REPO"
[ -d .git ] || { echo "$REPO is not a git clone" >&2; exit 1; }

# ---- hook ----
if [ -x "$HOOKS/pre-commit" ] && [ "$(git config core.hooksPath || true)" != "$HOOKS" ]; then
  git config core.hooksPath "$HOOKS"
  echo "Enabled the leak-scan pre-commit hook (core.hooksPath=$HOOKS)."
fi
[ -x "$HOOKS/pre-commit" ] || echo "WARNING: $HOOKS/pre-commit missing or not executable - no leak check on commit." >&2

# ---- in step with GitHub? ----
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
[ -n "$UPSTREAM" ] || { echo "Branch $BRANCH has no upstream - set it with: git push -u origin $BRANCH" >&2; exit 1; }
git fetch --quiet
BEHIND="$(git rev-list --count HEAD.."$UPSTREAM")"
if [ "$BEHIND" -gt 0 ]; then
  echo "$BRANCH is $BEHIND commit(s) behind $UPSTREAM (changed on GitHub)." >&2
  echo "Run: git -C $REPO pull --rebase   then re-run this script." >&2
  exit 1
fi

OTHER="$(git status --porcelain | grep -v " $TA/" || true)"
[ -z "$OTHER" ] || { echo "Note - changes outside $TA are left alone:"; echo "$OTHER" | sed 's/^/    /'; }

push() {
  local ahead; ahead="$(git rev-list --count "$UPSTREAM"..HEAD)"
  if [ "$ahead" -eq 0 ]; then echo "Nothing to push."; return; fi
  say "Commits to push to $UPSTREAM"
  git log --oneline "$UPSTREAM"..HEAD
  if ! $YES; then
    read -r -p "Push $ahead commit(s) to $UPSTREAM? [y/N] " a
    case "$a" in [yY]*) ;; *) echo "Not pushed. Push later with: $0 --push-only"; return ;; esac
  fi
  git push
  say "Pushed: $(git remote get-url origin | sed -E 's#git@github.com:#https://github.com/#; s#\.git$##')/commit/$(git rev-parse HEAD)"
}

if $PUSH_ONLY; then push; exit 0; fi

CHANGES="$(git status --porcelain -- "$TA")"
if [ -z "$CHANGES" ]; then
  echo "No changes under $TA."
  push
  exit 0
fi

say "Changes under $TA"
echo "$CHANGES" | sed 's/^/    /'

# Preview in a throwaway index: diffstat + the same leak check the commit will run.
TMPIDX="$(mktemp)"; trap 'rm -f "$TMPIDX"' EXIT
cp "$(git rev-parse --git-path index)" "$TMPIDX"
GIT_INDEX_FILE="$TMPIDX" git add -A -- "$TA"
say "Diffstat"
GIT_INDEX_FILE="$TMPIDX" git diff --cached --stat | sed 's/^/    /'
say "Leak check (pre-commit hook)"
if [ -x "$HOOKS/pre-commit" ]; then
  if GIT_INDEX_FILE="$TMPIDX" "$HOOKS/pre-commit"; then echo "    clean"; else
    echo "Fix the lines above before committing." >&2; exit 1; fi
fi

if [ -z "$MSG" ]; then
  echo
  echo "Preview only. Full diff: git -C $REPO diff  (new files: git -C $REPO status)"
  echo "Commit and push:  $0 -m \"what changed\""
  exit 0
fi

say "Commit"
git add -A -- "$TA"
if ! git commit -m "$MSG"; then
  echo "Commit refused - the staged files are still staged. Fix and re-run, or unstage: git -C $REPO restore --staged $TA" >&2
  exit 1
fi
push
