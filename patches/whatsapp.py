#!/usr/bin/env python3
"""
WhatsApp / WA Business Smali patcher — version-resilient.

Locates SecurePendingIntent throw sites by string anchor (not class name),
walks method structure to derive return type, replaces the
const-string..throw span with an appropriate return instruction.

Usage:
  patches/whatsapp.py <clone_dir> <orig_pkg> <new_pkg>   # apply
  patches/whatsapp.py --probe <clone_dir>                # diagnostic only
"""
import os, re, subprocess, sys
import xml.etree.ElementTree as ET
from collections import Counter

ANCHORS = [
    "Please set reporter for SecurePendingIntent library",
    "Must generate PendingIntent based on an explicit intent.",
]

CONST_STRING_RE = re.compile(r'^(\s*)const-string\s+(v\d+),\s*"(.+)"\s*$')
THROW_RE        = re.compile(r'^\s*throw\s+(v\d+)\s*$')
METHOD_RE       = re.compile(r'\.method\b.*?(\S+)\(([^)]*)\)(\S+)\s*$')
IF_NEZ_RE       = re.compile(r'^(\s*)if-nez\s+(v\d+),\s*(:cond_\w+)\s*$')
COND_LABEL_RE   = re.compile(r'^\s*(:cond_\w+)\s*$')
TRY_MARKER_RE   = re.compile(r'^\s*:(try_start_|try_end_|catchall_|catch_)\w+\s*$')
CATCH_DIR_RE    = re.compile(r'^\s*\.catch(all)?\b')
END_METHOD_RE   = re.compile(r'^\s*\.end\s+method\s*$')
RETURN_OBJECT_RE = re.compile(r'^\s*return-object\s+(v\d+)\s*$')

ANDROID_NS = "{http://schemas.android.com/apk/res/android}"


def _read_apktool_yml(clone_dir):
    """Extract versionName/versionCode from apktool.yml — apktool strips these from manifest."""
    path = os.path.join(clone_dir, "apktool.yml")
    vn = vc = "unknown"
    try:
        for line in open(path):
            m = re.match(r'\s*versionName:\s*(\S+)', line)
            if m:
                vn = m.group(1).strip("'\"")
            m = re.match(r'\s*versionCode:\s*(\S+)', line)
            if m:
                vc = m.group(1).strip("'\"")
    except Exception:
        pass
    return vn, vc


def read_manifest_meta(clone_dir):
    """Return (package, versionName, versionCode). Falls back to 'unknown' on any failure."""
    pkg = vn = vc = "unknown"
    try:
        root = ET.parse(os.path.join(clone_dir, "AndroidManifest.xml")).getroot()
        pkg = root.attrib.get("package", "unknown")
        vn  = root.attrib.get(f"{ANDROID_NS}versionName", "unknown")
        vc  = root.attrib.get(f"{ANDROID_NS}versionCode", "unknown")
    except Exception:
        pass
    if vn == "unknown" or vc == "unknown":
        yvn, yvc = _read_apktool_yml(clone_dir)
        if vn == "unknown":
            vn = yvn
        if vc == "unknown":
            vc = yvc
    return pkg, vn, vc


def print_header(clone_dir, mode):
    pkg, vn, vc = read_manifest_meta(clone_dir)
    print(f"[whatsapp.py] target: {pkg} {vn} (build {vc})")
    print(f"[whatsapp.py] mode: {mode}")
    sys.stdout.flush()


def find_candidate_files(clone_dir):
    """grep -rlF for any anchor across smali* trees only (excludes res/ by extension)."""
    found = set()
    for anchor in ANCHORS:
        try:
            out = subprocess.check_output(
                ["grep", "-rlF", "--include=*.smali", anchor, clone_dir],
                stderr=subprocess.DEVNULL,
            )
            found.update(out.decode().splitlines())
        except subprocess.CalledProcessError:
            pass
    return sorted(found)


def find_anchor_sites(lines):
    sites = []
    for i, line in enumerate(lines):
        m = CONST_STRING_RE.match(line)
        if not m:
            continue
        indent, reg, literal = m.groups()
        if literal in ANCHORS:
            sites.append((i, indent, reg, literal))
    return sites


def find_enclosing_method(lines, idx):
    """Return (line_idx, name, params, return_type, is_static) for method enclosing idx."""
    for j in range(idx, -1, -1):
        line = lines[j]
        m = METHOD_RE.search(line)
        if m:
            name, params, ret = m.groups()
            header = line[:line.index('(')]
            is_static = bool(re.search(r'\bstatic\b', header))
            return j, name, params, ret, is_static
    return None, None, None, None, None


def find_throw_after(lines, idx, max_scan=50):
    for j in range(idx + 1, min(idx + 1 + max_scan, len(lines))):
        m = THROW_RE.match(lines[j])
        if m:
            return j, m.group(1)
    return None, None


def find_ifnez_before(lines, anchor_idx, method_idx, max_scan=30):
    """Walk backward from anchor to find nearest `if-nez vR, :cond_X` within current method.
    Returns (line_idx, indent, register, target_label) or (None, None, None, None)."""
    floor = max(method_idx if method_idx is not None else 0, anchor_idx - max_scan)
    for j in range(anchor_idx - 1, floor - 1, -1):
        m = IF_NEZ_RE.match(lines[j])
        if m:
            return j, m.group(1), m.group(2), m.group(3)
    return None, None, None, None


def find_success_label_after(lines, throw_idx, max_scan=80):
    """Walk forward from throw to next plain `:cond_N` label (success-side basic block).
    Skips .line markers, blanks, .catch directives, and try/catch labels.
    Stops at .end method or next .method header. Returns (label_name, line_idx) or (None, None)."""
    end = min(len(lines), throw_idx + 1 + max_scan)
    for j in range(throw_idx + 1, end):
        line = lines[j]
        if END_METHOD_RE.match(line) or METHOD_RE.search(line):
            return None, None
        if CATCH_DIR_RE.match(line) or TRY_MARKER_RE.match(line):
            continue
        m = COND_LABEL_RE.match(line)
        if m:
            return m.group(1), j
    return None, None


def find_method_end(lines, method_idx):
    """Return line idx of the .end method line closing the method that starts at method_idx."""
    for j in range(method_idx + 1, len(lines)):
        if END_METHOD_RE.match(lines[j]):
            return j
    return len(lines)


def dominant_return_register(lines, method_start, method_end):
    """Tally return-object registers across the method body.
    Returns (best_reg, count, distribution_str). Tie-break: lower reg number wins."""
    counts = Counter()
    for j in range(method_start + 1, method_end):
        m = RETURN_OBJECT_RE.match(lines[j])
        if m:
            counts[m.group(1)] += 1
    if not counts:
        return None, 0, ""
    best = max(counts.items(), key=lambda kv: (kv[1], -int(kv[0][1:])))
    distribution = ", ".join(
        f"{r} ({c}x)" for r, c in sorted(counts.items(), key=lambda kv: (-kv[1], int(kv[0][1:])))
    )
    return best[0], best[1], distribution


def validate_flip_target(lines, label_line, method_end, dominant_reg):
    """Decide whether the candidate :cond_N label at label_line is a legit success target.
    Reject if the label's first real instruction is another anchor const-string (cascading throw block).
    Reject if no `return-object <dominant_reg>` is reachable before .end method.
    Returns (valid: bool, reason: str)."""
    # Anti-pattern: label immediately precedes another anchor literal
    for j in range(label_line + 1, min(label_line + 12, method_end)):
        line = lines[j]
        stripped = line.strip()
        if not stripped or stripped.startswith('.line') or COND_LABEL_RE.match(line):
            continue
        m = CONST_STRING_RE.match(line)
        if m and m.group(3) in ANCHORS:
            return False, "label immediately precedes another anchor (would loop into own throw)"
        break
    if dominant_reg is None:
        return False, "no dominant return-object register in method"
    for j in range(label_line + 1, method_end):
        m = RETURN_OBJECT_RE.match(lines[j])
        if m and m.group(1) == dominant_reg:
            return True, f"leads to return-object {dominant_reg} at line {j + 1}"
    return False, f"no return-object {dominant_reg} reachable before .end method"


def parse_params(params_str):
    """Split smali param descriptor string into list of individual types.
    Examples: 'Landroid/content/Intent;ILjava/lang/String;' -> ['Landroid/content/Intent;', 'I', 'Ljava/lang/String;']
    Wide types (J, D) are kept as single entries — register layout handled separately."""
    types = []
    i = 0
    while i < len(params_str):
        c = params_str[i]
        if c == 'L':
            end = params_str.index(';', i) + 1
            types.append(params_str[i:end])
            i = end
        elif c == '[':
            j = i
            while j < len(params_str) and params_str[j] == '[':
                j += 1
            if j < len(params_str) and params_str[j] == 'L':
                end = params_str.index(';', j) + 1
                types.append(params_str[i:end])
                i = end
            else:
                types.append(params_str[i:j + 1])
                i = j + 1
        else:
            types.append(c)
            i += 1
    return types


def find_param_register(params_str, target_type, is_static):
    """Walk param types tracking p-register indices. Wide types (J/D) consume 2 slots.
    Instance methods reserve p0=this. Returns 'pN' for first matching type, else None."""
    types = parse_params(params_str)
    reg_idx = 0 if is_static else 1
    for t in types:
        if t == target_type:
            return f"p{reg_idx}"
        reg_idx += 2 if t in ('J', 'D') else 1
    return None


def build_return(ret_type, indent, scratch_reg, params_str, is_static, dominant_reg=None):
    """Generate replacement smali + a mode label.
    For object/array returns, prefer (in order):
      1. Dominant return-object register from method body — returns the actual constructed object
      2. Passthrough of a same-typed param register
      3. Null + warn (defensive last resort)"""
    if ret_type == "V":
        return [f"{indent}return-void"], "void"
    if ret_type in ("J", "D"):
        return ([f"{indent}const-wide/16 {scratch_reg}, 0x0",
                 f"{indent}return-wide {scratch_reg}"], "zero-wide")
    if ret_type in ("Z", "B", "S", "C", "I", "F"):
        return ([f"{indent}const/4 {scratch_reg}, 0x0",
                 f"{indent}return {scratch_reg}"], "zero")
    if dominant_reg is not None:
        return ([f"{indent}return-object {dominant_reg}"], f"return-object({dominant_reg})")
    pass_reg = find_param_register(params_str, ret_type, is_static)
    if pass_reg is not None:
        return ([f"{indent}return-object {pass_reg}"], f"passthrough({pass_reg})")
    return ([f"{indent}const/4 {scratch_reg}, 0x0",
             f"{indent}return-object {scratch_reg}"], "null")


def process_file(path, clone_dir, apply, log):
    try:
        lines = open(path).read().splitlines()
    except Exception:
        return []
    sites = find_anchor_sites(lines)
    if not sites:
        return []
    rel = os.path.relpath(path, clone_dir)
    records = []
    edits = []
    for anchor_idx, indent, reg, literal in sites:
        m_idx, m_name, m_params, ret_type, m_static = find_enclosing_method(lines, anchor_idx)
        m_end = find_method_end(lines, m_idx) if m_idx is not None else len(lines)
        t_idx, _ = find_throw_after(lines, anchor_idx)

        # Foundational: scan method for dominant return-object register.
        dom_reg, dom_count, dom_dist = dominant_return_register(
            lines, m_idx if m_idx is not None else 0, m_end
        )

        # Bypass replacement (always emitted defensively).
        repl, mode = build_return(
            ret_type or "V", indent, reg, m_params or "", m_static or False, dom_reg
        )

        # Optional structural flip on top.
        if_idx, if_indent, if_reg, if_old_target = find_ifnez_before(lines, anchor_idx, m_idx)
        flip_target = None
        flip_line_new = None
        succ_label = None
        succ_line = None
        if if_idx is None:
            flip_status = "no preceding if-nez within scan window"
        elif t_idx is None:
            flip_status = "no throw found, cannot anchor flip"
        else:
            cand_label, cand_line = find_success_label_after(lines, t_idx, max_scan=80)
            if cand_label is None:
                flip_status = "no candidate :cond_N label before .end method"
            else:
                ok, reason = validate_flip_target(lines, cand_line, m_end, dom_reg)
                if ok:
                    flip_target = cand_label
                    succ_label, succ_line = cand_label, cand_line
                    flip_line_new = f"{if_indent}if-eqz {if_reg}, {flip_target}"
                    flip_status = f"target valid: {reason}"
                else:
                    flip_status = f"rejected: {cand_label} — {reason}"

        # Warn if bypass falls all the way back to null for an object return.
        if (
            mode == "null"
            and ret_type
            and (ret_type.startswith("L") or ret_type.startswith("["))
        ):
            sys.stderr.write(
                f"  [warn] {rel}:{m_name} no dominant return-object register and "
                f"no matching param of type {ret_type}; bypass falls back to null — caller may NPE\n"
            )

        if apply and t_idx is not None:
            if flip_line_new is not None:
                edits.append((if_idx, if_idx, [flip_line_new]))
            edits.append((anchor_idx, t_idx, repl))

        records.append({
            "rel": rel,
            "anchor_line": anchor_idx + 1,
            "method": m_name or "<unknown>",
            "return_type": ret_type or "<unknown>",
            "throw_line": (t_idx + 1) if t_idx is not None else None,
            "literal": literal,
            "return_mode": mode,
            "dominant_reg": dom_reg,
            "dominant_distribution": dom_dist,
            "flip_line": (if_idx + 1) if if_idx is not None else None,
            "flip_old": (
                f"if-nez {if_reg}, {if_old_target}" if if_idx is not None else None
            ),
            "flip_new": flip_line_new.lstrip() if flip_line_new else None,
            "flip_status": flip_status,
            "success_label": succ_label,
            "success_label_line": (succ_line + 1) if succ_line is not None else None,
        })
    if apply and edits:
        for start, end, repl in sorted(edits, reverse=True):
            lines[start:end + 1] = repl
        open(path, "w").write("\n".join(lines) + "\n")
        log(f"  Patched {len(edits)} site(s) in {rel}")
    return records


def scan(clone_dir, apply, log):
    records = []
    for f in find_candidate_files(clone_dir):
        records.extend(process_file(f, clone_dir, apply=apply, log=log))
    return records


def _bypass_phrase(mode):
    """Render the return-mode label as a smali-shaped phrase for probe output."""
    if mode.startswith("return-object("):
        return f"return-object {mode[len('return-object('):-1]}"
    if mode.startswith("passthrough("):
        return f"return-object {mode[len('passthrough('):-1]} (param passthrough)"
    if mode == "null":
        return "const/4 + return-object null (defensive)"
    if mode == "void":
        return "return-void"
    if mode == "zero":
        return "const/4 + return"
    if mode == "zero-wide":
        return "const-wide/16 + return-wide"
    return mode


def probe(clone_dir):
    print_header(clone_dir, "probe")
    records = scan(clone_dir, apply=False, log=lambda *_: None)
    print(f"Found {len(records)} SecurePendingIntent anchors:")
    for r in records:
        throw_span = (
            f"lines {r['anchor_line']}-{r['throw_line']}"
            if r['throw_line'] else f"line {r['anchor_line']} (no throw found)"
        )
        print(f"  [anchor] {r['rel']}:{r['anchor_line']}  "
              f"method {r['method']}  returns {r['return_type']}")
        if r['dominant_reg']:
            print(f"    [scan] return-object registers in method: "
                  f"{r['dominant_distribution']} — dominant: {r['dominant_reg']}")
        else:
            print(f"    [scan] no return-object instructions in method")
        if r['flip_new']:
            print(f"    [flip] line {r['flip_line']}: {r['flip_old']} → {r['flip_new']}  "
                  f"({r['flip_status']})")
        else:
            print(f"    [flip] {r['flip_status']}")
        print(f"    [bypass] {throw_span}: throw block → {_bypass_phrase(r['return_mode'])}")
    return 0 if records else 1


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "--probe":
        sys.exit(probe(sys.argv[2]))
    if len(sys.argv) < 4:
        print("Usage:")
        print("  whatsapp.py <clone_dir> <orig_pkg> <new_pkg>")
        print("  whatsapp.py --probe <clone_dir>")
        sys.exit(2)
    clone_dir = sys.argv[1]
    print_header(clone_dir, "apply")
    # orig_pkg / new_pkg accepted for contract compat; not used by current patches
    records = scan(clone_dir, apply=True, log=print)
    if not records:
        print("  [warn] No SecurePendingIntent anchors found — nothing patched")
    sys.exit(0)


if __name__ == "__main__":
    main()
