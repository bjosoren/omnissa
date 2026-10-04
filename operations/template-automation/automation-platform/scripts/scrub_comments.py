#!/usr/bin/env python3
"""
scripts/scrub_comments.py - remove change-history comments from the platform's
source files without changing what any file does.

  scripts/scrub_comments.py                 dry run: summary + ~/scrub-preview.diff
  scripts/scrub_comments.py --apply         edit the files in place
  scripts/scrub_comments.py --show FILE     print what would go from one file
  options: --root DIR (default: the tree this script is in)

Removed: whole-line comment paragraphs that read like a changelog - a date
(2026-09-14), a marker such as ADDED / CHANGED / FIXED / REWRITTEN, or "per
the user's request". A paragraph is a run of comment lines, split at blank
lines and at bare '#' lines, so a file's short description stays when only
the history under it goes. Code, end-of-line comments, shebangs and tool
directives (shellcheck, noqa, ...) are never touched.

Scope: images/*/, scripts/, inventory/group_vars/<image>*.yml.
Never touched: *.local.yml, hosts.ini, all.yml, the vault, configs/, logs,
backup/editor leftovers (*.bak*, *.orig, *.old, *.save, *~, ...),
and files rendered into the guest or that can't be verified here:
*.pkrtpl.hcl (autounattend / user-data), *.j2, *.xml, *.ps1, *.md.

Each edited file is checked before it is written, and left alone if the
check fails:
  YAML    parsed data identical before and after
  Python  syntax tree identical before and after
  shell   bash -n, and bash's own comment-free view of the code identical
  HCL     nothing inside strings/heredocs/block comments is removed;
          packer fmt must still parse it (when packer is installed)
"""
import argparse
import fnmatch
import ast
import difflib
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile
import tokenize
from pathlib import Path

MARKER = re.compile(
    r"\b20\d\d-\d\d-\d\d\b"
    r"|\b(ADDED|CHANGED|UPDATED|FIXED|REWRITTEN|REMOVED|MOVED|CLONED|REVERTED|RESTORED"
    r"|SPLIT INTO|CONFIRMED|RESULT of|HISTORY|NEW ROLE|FIRST FIX|CURRENT FIX|STILL OPEN|FLAGGED)\b"
    r"|per the user|the user's (own|explicit)|user-provided|on a real build|a real build")
DIRECTIVE = re.compile(r"^\s*(#!|#\s*(shellcheck|noqa|type:|pylint|-\*-|yaml-language-server|vim:|fmt:))")
SKIP_SUFFIX = (".pkrtpl.hcl", ".j2", ".xml", ".ps1", ".md", ".local.yml")
SKIP_NAMES = {"hosts.ini", "all.yml", "vault.yml"}
# Backup / editor leftovers - same list as sync_to_repo.sh, repo_compare.sh,
# the pre-commit hook and .gitignore.
BACKUP_GLOBS = ['*.bak*', '*.orig', '*.old', '*.save', '*.pre-*', '*.new-*', '*~', '.*.sw?', '*.rej', '*.tmp', '*.part']
SKIP_DIRS = {"logs", "build_logs", "packer_cache", "configs", "files", "__pycache__", ".git", "all"}


# ---------------------------------------------------------------- file types
def kind_of(path: Path):
    n = path.name
    if n in SKIP_NAMES or n.endswith(SKIP_SUFFIX) or any(fnmatch.fnmatch(n, g) for g in BACKUP_GLOBS):
        return None
    if n.endswith((".yml", ".yaml")):
        return "yaml"
    if n.endswith(".py"):
        return "python"
    if n.endswith(".pkr.hcl"):
        return "hcl"
    if n.endswith(".sh") or n == "image.conf":
        return "shell"
    try:
        first = path.open(encoding="utf-8", errors="replace").readline()
    except OSError:
        return None
    if first.startswith("#!") and "python" in first:
        return "python"
    if first.startswith("#!") and re.search(r"\b(ba)?sh\b", first):
        return "shell"
    return None


def scope(root: Path):
    keys = sorted(p.name for p in (root / "images").glob("*") if p.is_dir())
    roots = [root / "images" / k for k in keys] + [root / "scripts"]
    files = []
    for r in roots:
        for dp, dns, fns in os.walk(r):
            dns[:] = sorted(d for d in dns if d not in SKIP_DIRS)
            files += [Path(dp) / f for f in sorted(fns)]
    gv = root / "inventory" / "group_vars"
    for k in keys:
        files += sorted(p for p in gv.glob(f"{k}*.yml") if not p.name.endswith(".local.yml"))
    return [f for f in files if f.is_file() and not f.is_symlink() and kind_of(f)]


# ------------------------------------------------- which lines are comments?
# Each scanner returns, per line: "c" = whole-line comment that may be removed,
# "b" = blank line outside any string (may be collapsed), "x" = anything else.

def scan_yaml(lines):
    out, block_indent = [], None
    for ln in lines:
        s = ln.strip()
        ind = len(ln) - len(ln.lstrip(" "))
        if block_indent is not None:
            if s == "" or ind > block_indent:
                out.append("x")
                continue
            block_indent = None
        if s == "":
            out.append("b")
        elif s.startswith("#"):
            out.append("c")
        else:
            out.append("x")
            code = re.sub(r"\s+#.*$", "", ln.rstrip())
            if re.search(r"(:|^\s*-)\s+[|>][-+0-9]*\s*$", code):
                block_indent = ind
    return out


def scan_python(text, lines):
    out = ["x"] * len(lines)
    in_string = set()
    try:
        toks = list(tokenize.generate_tokens(io.StringIO(text).readline))
    except (tokenize.TokenError, SyntaxError):
        return out
    for t in toks:
        if t.type == tokenize.STRING and t.end[0] > t.start[0]:
            in_string.update(range(t.start[0], t.end[0] + 1))
    for t in toks:
        if t.type == tokenize.COMMENT and lines[t.start[0] - 1][: t.start[1]].strip() == "":
            out[t.start[0] - 1] = "c"
    for i, ln in enumerate(lines):
        if ln.strip() == "" and (i + 1) not in in_string:
            out[i] = "b"
    return out


def scan_shell(lines):
    # Context stack: "'" , '"' , "$(" or "(" - a line is only a removable
    # comment when it starts with an empty stack and outside any heredoc.
    out, stack, heredocs, cur = [], [], [], None
    for ln in lines:
        if cur:  # inside a heredoc body
            delim, strip_tabs = cur
            body = ln.lstrip("\t") if strip_tabs else ln
            if body.rstrip("\n") == delim:
                cur = heredocs.pop(0) if heredocs else None
            out.append("x")
            continue
        s = ln.strip()
        if not stack and s == "":
            out.append("b")
            continue
        if not stack and s.startswith("#"):
            out.append("c")
            continue
        out.append("x")
        i, n = 0, len(ln)
        while i < n:
            ch, top = ln[i], (stack[-1] if stack else None)
            if top == "'":
                if ch == "'":
                    stack.pop()
            elif top == '"':
                if ch == "\\":
                    i += 1
                elif ch == '"':
                    stack.pop()
                elif ln.startswith("$(", i):
                    stack.append("$(")
                    i += 1
            else:  # unquoted, or inside $( ) / ( )
                if ch == "\\":
                    i += 1
                elif ch in "'\"":
                    stack.append(ch)
                elif ln.startswith("$(", i):
                    stack.append("$(")
                    i += 1
                elif ch == "(":
                    stack.append("(")
                elif ch == ")" and top in ("$(", "("):
                    stack.pop()
                elif ch == "#" and (i == 0 or ln[i - 1] in " \t;|&()"):
                    break
                elif ln.startswith("<<", i) and not ln.startswith("<<<", i):
                    m = re.match(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2", ln[i:])
                    if m:
                        heredocs.append((m.group(3), m.group(1) == "-"))
                        i += m.end() - 1
            i += 1
        if heredocs and not cur:
            cur = heredocs.pop(0)
    return out


def scan_hcl(lines):
    out, quote, cur, block = [], False, None, False
    for ln in lines:
        if cur:
            if ln.strip() == cur:
                cur = None
            out.append("x")
            continue
        if block:
            out.append("x")
            if "*/" in ln:
                block = False
            continue
        s = ln.strip()
        if not quote and s == "":
            out.append("b")
            continue
        if not quote and (s.startswith("#") or s.startswith("//")):
            out.append("c")
            continue
        out.append("x")
        i, n = 0, len(ln)
        while i < n:
            ch = ln[i]
            if quote:
                if ch == "\\":
                    i += 1
                elif ch == '"':
                    quote = False
            elif ch == '"':
                quote = True
            elif ch == "#" or ln.startswith("//", i):
                break
            elif ln.startswith("/*", i):
                end = ln.find("*/", i + 2)
                if end < 0:
                    block = True
                    break
                i = end + 1
            elif ln.startswith("<<", i):
                m = re.match(r"<<-?\s*([A-Za-z_][A-Za-z0-9_]*)\s*$", ln[i:].rstrip())
                if m:
                    cur = m.group(1)
                    break
            i += 1
    return out


# ------------------------------------------------------------ the scrubbing
def bare(line):
    return line.strip() in ("#", "//")


def scrub(text, kind):
    lines = text.splitlines(keepends=True)
    tags = {"yaml": lambda: scan_yaml(lines), "python": lambda: scan_python(text, lines),
            "shell": lambda: scan_shell(lines), "hcl": lambda: scan_hcl(lines)}[kind]()
    drop, removed = set(), []
    i = 0
    while i < len(lines):
        if tags[i] != "c":
            i += 1
            continue
        j = i
        while j < len(lines) and tags[j] == "c":
            j += 1
        # paragraphs inside comment run [i, j), split at bare '#' lines
        para = []
        for k in range(i, j + 1):
            if k == j or bare(lines[k]):
                if para and any(MARKER.search(lines[p]) for p in para):
                    gone = [p for p in para if not DIRECTIVE.match(lines[p])]
                    drop.update(gone)
                    removed.append("".join(lines[p] for p in gone))
                    if k < j and bare(lines[k]):
                        drop.add(k)  # separator after a removed paragraph
                para = []
            else:
                para.append(k)
        # a run left with only bare separators goes too
        if all(k in drop or bare(lines[k]) for k in range(i, j)):
            drop.update(range(i, j))
        i = j
    if not drop:
        return text, []
    kept = [(ln, tags[k]) for k, ln in enumerate(lines) if k not in drop]
    # collapse blank runs we created; never touch blanks inside strings
    res, prev_blank = [], False
    for ln, t in kept:
        if t == "b":
            if prev_blank:
                continue
            prev_blank = True
        else:
            prev_blank = False
        res.append(ln)
    while res and res[0].strip() == "" and lines[0].strip() != "":
        res.pop(0)
    return "".join(res), removed


# ------------------------------------------------------------- verification
def bash_normalized(text):
    """bash's own view of the code, comments dropped: wrap it in a function,
    source that (defines it, runs nothing) and print it with declare -f."""
    with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as f:
        f.write("__scrub_f() {\n" + text + "\n}\n")
    try:
        r = subprocess.run(["bash", "-c", f'source "{f.name}" && declare -f __scrub_f'],
                           capture_output=True, text=True, timeout=20)
        return r.stdout if r.returncode == 0 else None
    finally:
        os.unlink(f.name)


def verify(kind, old, new, path):
    if kind == "yaml":
        import yaml
        try:
            a = list(yaml.safe_load_all(old))
        except yaml.YAMLError:
            return "original file does not parse as YAML - left alone"
        return None if a == list(yaml.safe_load_all(new)) else "parsed YAML differs"
    if kind == "python":
        try:
            return None if ast.dump(ast.parse(old)) == ast.dump(ast.parse(new)) else "syntax tree differs"
        except SyntaxError as e:
            return f"syntax error: {e}"
    if kind == "shell":
        r = subprocess.run(["bash", "-n"], input=new, text=True, capture_output=True)
        if r.returncode:
            return "bash -n: " + r.stderr.strip()
        a, b = bash_normalized(old), bash_normalized(new)
        if a is None:
            return None  # bash -n passed; file can't be wrapped for the deeper check
        return None if a == b else "bash sees different code"
    if kind == "hcl":
        if not shutil.which("packer"):
            return None
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / path.name
            f.write_text(new)
            r = subprocess.run(["packer", "fmt", "-check", str(f)], capture_output=True, text=True)
            # 0 = formatted, 3 = would reformat; anything else = parse error
            return None if r.returncode in (0, 3) else "packer fmt: " + (r.stderr or r.stdout).strip()
    return "unknown type"


# ---------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--show", metavar="FILE")
    ap.add_argument("--diff", default=str(Path.home() / "scrub-preview.diff"))
    a = ap.parse_args()
    root = Path(a.root).resolve()

    if a.show:
        p = Path(a.show).resolve()
        k = kind_of(p)
        if not k:
            sys.exit(f"{p}: not a file this script edits")
        _, removed = scrub(p.read_text(encoding="utf-8"), k)
        for r in removed:
            print(r + "-" * 60)
        print(f"{len(removed)} paragraph(s) would be removed from {p}")
        return

    changed, failed, diff = [], [], []
    for p in scope(root):
        k = kind_of(p)
        try:
            old = p.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        new, removed = scrub(old, k)
        if not removed:
            continue
        err = verify(k, old, new, p)
        rel = p.relative_to(root)
        if err:
            failed.append((rel, err))
            continue
        changed.append((p, rel, new, len(old.splitlines()) - len(new.splitlines()), len(removed)))
        diff += difflib.unified_diff(old.splitlines(True), new.splitlines(True), f"a/{rel}", f"b/{rel}")

    for _, rel, _, nl, npara in changed:
        print(f"  {nl:5d} lines  {npara:3d} paragraph(s)  {rel}")
    for rel, err in failed:
        print(f"  SKIPPED  {rel}: {err}")
    total = sum(c[3] for c in changed)
    print(f"==> {len(changed)} file(s), {total} comment lines" + (" removed." if a.apply else " would be removed."))
    if not changed:
        return
    Path(a.diff).write_text("".join(diff))
    print(f"    Review: less {a.diff}")
    if not a.apply:
        print("    Dry run - re-run with --apply to edit the files.")
        return
    for p, _, new, _, _ in changed:
        mode = p.stat().st_mode
        p.write_text(new, encoding="utf-8")
        os.chmod(p, mode)
    if failed:
        sys.exit(2)


if __name__ == "__main__":
    main()
