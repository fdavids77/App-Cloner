#!/usr/bin/env python3
"""
Smali const-string literal rewriter — opt-in via clone-factory.sh --rewrite-string-literals.

Why this exists
---------------
WhatsApp 2.26.20.72 added code that uses Intent.setPackage("com.whatsapp")
inside the EULA "Agree and Continue" handler. After cloning to
com.whatsapp.cloneN, the explicit Intent still targets the original
com.whatsapp package — a different UID — so Android throws:

  SecurityException: Permission Denial: starting Intent {cmp=com.whatsapp/...}
  from ProcessRecord{... com.whatsapp.cloneN/u0aXXX} not exported from uid YYYY

Rewriting com.whatsapp.cloneN's package attribute in AndroidManifest.xml is
not enough — the explicit string literal in compiled smali still routes the
intent to the original package's component. This script rewrites the literal
*only* where it's the package argument of a package-targeting API.

Conservative heuristic — REWRITE / KEEP
---------------------------------------
We match `const-string vN, "com.whatsapp"` (exact 13-char literal, not
prefixes like "com.whatsapp.provider"). For each match we scan forward up
to MAX_SCAN non-skip instructions looking for the first instruction that
USES register vN. We rewrite only if that instruction is one of:

  Intent.setPackage(String)
  Intent.setClassName(String, String)
  ComponentName.<init>(String, String)
  Context.grantUriPermission(String, Uri, int)
  PackageManager.clearPackagePreferredActivities(String)
  PackageManager.getApplicationIcon(String)

Everything else (StringBuilder.append, Uri.Builder, NDEF AAR, Account
constructor, JSON, Map.put, String.equals against getPackageName, account
type for AccountManager, OAuth-shaped helpers, URL query params) is left
untouched. Critical: Account.<init>(name, type) has the same shape as
ComponentName.<init>(pkg, cls) — we disambiguate on the owning class FQN.

Skip-during-lookahead list (these don't end the basic block and don't
consume the register): blank lines, .line / .local / .restart / .end local /
.prologue / .parameter directives, plain labels :foo, and goto* jumps.
We also skip OTHER const* loads that don't touch our register, because
setClassName / ComponentName.<init> patterns commonly load pkg + class
back-to-back before the invoke.

Usage:
  patches/rewrite_string_literals.py <clone_dir> <orig_pkg> <new_pkg>
  patches/rewrite_string_literals.py --probe <clone_dir> <orig_pkg>
"""
import os, re, sys

# ── Patterns ────────────────────────────────────────────────────────────────
CONST_STR_RE = re.compile(
    r'^(\s*)const-string(?:/jumbo)?\s+([vp]\d+),\s*"([^"]*)"\s*$'
)
# Lines we skip past while scanning for the next real use of our register.
SKIP_RE = re.compile(
    r'^\s*('
    r'\.line\b|\.local\b|\.restart\b|\.end\s+local\b|'
    r'\.prologue\b|\.parameter\b|\.param\b|\.source\b|'
    r':[\w$]+\s*$|'
    r'goto\b|goto/16\b|goto/32\b|nop\b'
    r')'
)
# Hard stops: we don't look past these — basic block ended.
STOP_RE = re.compile(r'^\s*(\.end\s+method|return\b|throw\b)')
INVOKE_RE = re.compile(
    r'^\s*invoke-\w+(?:/range)?\s+\{([^}]*)\},\s*(\S+)'
)

# Method signatures that take a package name in the rewritable position.
# Each entry: (owner_class, method_name, descriptor).
REWRITE_SIGS = {
    ("Landroid/content/Intent;",
     "setPackage", "(Ljava/lang/String;)Landroid/content/Intent;"),
    ("Landroid/content/Intent;",
     "setClassName", "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;"),
    # NOTE: Account.<init>(String name, String type) is the same shape but
    # different owner — we must NOT match it. Account type stays "com.whatsapp"
    # or AccountManager.getAccountsByType breaks the contact sync provider.
    ("Landroid/content/ComponentName;",
     "<init>", "(Ljava/lang/String;Ljava/lang/String;)V"),
    ("Landroid/content/Context;",
     "grantUriPermission", "(Ljava/lang/String;Landroid/net/Uri;I)V"),
    ("Landroid/content/pm/PackageManager;",
     "clearPackagePreferredActivities", "(Ljava/lang/String;)V"),
    ("Landroid/content/pm/PackageManager;",
     "getApplicationIcon", "(Ljava/lang/String;)Landroid/graphics/drawable/Drawable;"),
}

MAX_SCAN = 20  # instructions of lookahead — basic-block-ish window


def parse_invoke(line):
    """Return (arg_regs_list, owner_class, method_name, descriptor) or None."""
    m = INVOKE_RE.match(line)
    if not m:
        return None
    args = [a.strip() for a in m.group(1).split(',') if a.strip()]
    target = m.group(2)
    # target looks like Lpkg/Cls;->method(args)Ret
    tm = re.match(r'^(L[^;]+;)->([^()]+)(\([^)]*\)\S+)$', target)
    if not tm:
        return None
    return args, tm.group(1), tm.group(2), tm.group(3)


def first_use_of_register(lines, start, reg):
    """Scan forward from start+1; return (idx, line, parsed_invoke_or_None)
    for the first instruction that references reg. Skips SKIP_RE lines and
    other const*/move* that don't reference reg. Returns (None, None, None)
    if we hit STOP_RE or run past MAX_SCAN without finding a use."""
    reg_re = re.compile(rf'(?<![\w/$]){re.escape(reg)}(?![\w/$])')
    seen = 0
    for j in range(start + 1, len(lines)):
        line = lines[j]
        stripped = line.strip()
        if not stripped:
            continue
        if SKIP_RE.match(line):
            continue
        if STOP_RE.match(line):
            return None, None, None
        seen += 1
        if seen > MAX_SCAN:
            return None, None, None
        if reg_re.search(stripped):
            parsed = parse_invoke(stripped) if stripped.startswith('invoke-') else None
            return j, stripped, parsed
    return None, None, None


def classify(use_line, parsed, reg):
    """Return ('rewrite', sig_label) or ('keep', reason)."""
    if parsed is None:
        # The use is something other than an invoke (move, iput, aput,
        # equals, etc.) — never rewrite.
        return 'keep', f'non-invoke use: {use_line[:80]}'
    args, owner, method, desc = parsed
    sig = (owner, method, desc)
    if sig not in REWRITE_SIGS:
        return 'keep', f'invoke not in rewrite list: {owner}->{method}'
    if reg not in args:
        # Our register isn't actually passed — defensive guard.
        return 'keep', f'reg {reg} not in invoke args {args}'
    return 'rewrite', f'{owner}->{method}'


def process_file(path, orig_pkg, new_pkg, apply, records):
    """Scan one .smali file. Append (path, line_no, decision, reason) per
    bare-literal const-string. Write changes back if apply=True."""
    try:
        lines = open(path).read().splitlines()
    except Exception:
        return
    changed = False
    for i, line in enumerate(lines):
        m = CONST_STR_RE.match(line)
        if not m:
            continue
        indent, reg, literal = m.groups()
        if literal != orig_pkg:
            continue
        use_idx, use_line, parsed = first_use_of_register(lines, i, reg)
        if use_idx is None:
            records.append((path, i + 1, 'keep', 'no use found within scan window'))
            continue
        decision, reason = classify(use_line, parsed, reg)
        records.append((path, i + 1, decision, reason))
        if apply and decision == 'rewrite':
            # Preserve const-string vs const-string/jumbo form to be safe.
            kind = 'const-string/jumbo' if '/jumbo' in line else 'const-string'
            lines[i] = f'{indent}{kind} {reg}, "{new_pkg}"'
            changed = True
    if apply and changed:
        open(path, 'w').write('\n'.join(lines) + '\n')


def walk(clone_dir):
    for dirpath, _, files in os.walk(clone_dir):
        base = os.path.basename(dirpath.rstrip(os.sep))
        # Only descend into smali / smali_classesN trees (and their subdirs).
        rel = os.path.relpath(dirpath, clone_dir)
        if rel == '.':
            continue
        top = rel.split(os.sep)[0]
        if not top.startswith('smali'):
            continue
        for fn in files:
            if fn.endswith('.smali'):
                yield os.path.join(dirpath, fn)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == '--probe':
        clone_dir, orig_pkg = sys.argv[2], 'com.whatsapp'
        apply = False
    elif len(sys.argv) == 4 and sys.argv[1] == '--probe':
        clone_dir, orig_pkg = sys.argv[2], sys.argv[3]
        apply = False
    elif len(sys.argv) == 4:
        clone_dir, orig_pkg, new_pkg = sys.argv[1], sys.argv[2], sys.argv[3]
        apply = True
    else:
        print(__doc__.split('Usage:')[1])
        sys.exit(2)

    if not apply:
        new_pkg = orig_pkg + '.cloneN'

    records = []
    for path in walk(clone_dir):
        process_file(path, orig_pkg, new_pkg, apply, records)

    rewrites = [r for r in records if r[2] == 'rewrite']
    keeps    = [r for r in records if r[2] == 'keep']

    print(f"[rewrite-literals] target literal: {orig_pkg!r} → {new_pkg!r}")
    print(f"[rewrite-literals] scanned {len(records)} bare const-string occurrence(s)")
    print(f"[rewrite-literals]   REWRITE: {len(rewrites)}")
    print(f"[rewrite-literals]   KEEP:    {len(keeps)}")
    if apply:
        # Group rewrites by reason for a one-line summary
        by_sig = {}
        for path, ln, _, reason in rewrites:
            by_sig[reason] = by_sig.get(reason, 0) + 1
        for sig, n in sorted(by_sig.items(), key=lambda kv: -kv[1]):
            print(f"[rewrite-literals]     {n:4d}  {sig}")
    else:
        # In probe mode dump every decision so the user can audit.
        for path, ln, decision, reason in records:
            rel = os.path.relpath(path, clone_dir)
            print(f"  [{decision.upper():7s}] {rel}:{ln}  {reason}")


if __name__ == '__main__':
    main()
