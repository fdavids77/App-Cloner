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

ANCHORS = [
    "Please set reporter for SecurePendingIntent library",
    "Must generate PendingIntent based on an explicit intent.",
]

CONST_STRING_RE = re.compile(r'^(\s*)const-string\s+(v\d+),\s*"(.+)"\s*$')
THROW_RE        = re.compile(r'^\s*throw\s+(v\d+)\s*$')
METHOD_RE       = re.compile(r'\.method\b.*?(\S+)\(([^)]*)\)(\S+)\s*$')

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
    for j in range(idx, -1, -1):
        m = METHOD_RE.search(lines[j])
        if m:
            return j, m.group(1), m.group(3)
    return None, None, None


def find_throw_after(lines, idx, max_scan=50):
    for j in range(idx + 1, min(idx + 1 + max_scan, len(lines))):
        m = THROW_RE.match(lines[j])
        if m:
            return j, m.group(1)
    return None, None


def return_instr_for(ret_type, indent, scratch_reg):
    if ret_type == "V":
        return [f"{indent}return-void"]
    if ret_type in ("J", "D"):
        return [
            f"{indent}const-wide/16 {scratch_reg}, 0x0",
            f"{indent}return-wide {scratch_reg}",
        ]
    if ret_type in ("Z", "B", "S", "C", "I", "F"):
        return [
            f"{indent}const/4 {scratch_reg}, 0x0",
            f"{indent}return {scratch_reg}",
        ]
    return [
        f"{indent}const/4 {scratch_reg}, 0x0",
        f"{indent}return-object {scratch_reg}",
    ]


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
        _, m_name, ret_type = find_enclosing_method(lines, anchor_idx)
        t_idx, _ = find_throw_after(lines, anchor_idx)
        records.append({
            "rel": rel,
            "anchor_line": anchor_idx + 1,
            "method": m_name or "<unknown>",
            "return_type": ret_type or "<unknown>",
            "throw_line": (t_idx + 1) if t_idx is not None else None,
            "literal": literal,
        })
        if t_idx is not None and ret_type is not None:
            if ret_type.startswith("L") or ret_type.startswith("["):
                sys.stderr.write(
                    f"  [warn] {rel}:{m_name} returning null — caller may NPE; "
                    f"consider no-op PendingIntent fallback if crashes appear\n"
                )
            if apply:
                edits.append((anchor_idx, t_idx, return_instr_for(ret_type, indent, reg)))
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


def probe(clone_dir):
    print_header(clone_dir, "probe")
    records = scan(clone_dir, apply=False, log=lambda *_: None)
    print(f"Found {len(records)} SecurePendingIntent anchors:")
    for r in records:
        throw = f"line {r['throw_line']}" if r['throw_line'] else "<not found>"
        print(f"  {r['rel']}:{r['anchor_line']}  "
              f"method {r['method']}  returns {r['return_type']}  "
              f"throw at {throw}")
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
