#!/usr/bin/env python3
import sys, os, glob

clone_dir = sys.argv[1]
orig_pkg  = sys.argv[2]
new_pkg   = sys.argv[3]

def patch_file(path, patches):
    if not os.path.exists(path):
        return 0
    content = open(path).read()
    n = 0
    for old, new in patches:
        if old in content:
            content = content.replace(old, new, 1)
            n += 1
    open(path, "w").write(content)
    return n

patches = [
    (
        "    if-nez v0, :cond_0\n    .line 155\n    .line 156\n    const-string v1, \"Please set reporter for SecurePendingIntent library\"",
        "    if-eqz v0, :cond_5\n    .line 155\n    .line 156\n    const-string v1, \"Please set reporter for SecurePendingIntent library\""
    ),
    (
        "    :cond_8\n    const-string v1, \"Please set reporter for SecurePendingIntent library\"",
        "    :cond_8\n    return-object v2"
    ),
    (
        "    :cond_9\n    const-string v1, \"Must generate PendingIntent based on an explicit intent.\"",
        "    :cond_9\n    return-object v2"
    ),
]

found = False
for smali_name in ["1E7.smali", "1Dy.smali"]:
    smali = os.path.join(clone_dir, "smali", "X", smali_name)
    if os.path.exists(smali):
        print(f"  Found: smali/X/{smali_name}")
        n = patch_file(smali, patches)
        print(f"  Patches applied: {n}/3")
        found = True
        break

if not found:
    for f in glob.glob(os.path.join(clone_dir, "smali*", "**", "*.smali"), recursive=True):
        try:
            if "Please set reporter" in open(f).read():
                print(f"  Found in: {f} — add to patches")
                break
        except:
            pass
