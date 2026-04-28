#!/usr/bin/env python3
import sys, os, glob

clone_dir = sys.argv[1]
orig_pkg  = sys.argv[2]
new_pkg   = sys.argv[3]

def patch_file(path, patches):
    if not os.path.exists(path):
        print(f"  [skip] not found: {path}")
        return 0
    content = open(path).read()
    n = 0
    for old, new in patches:
        if old in content:
            content = content.replace(old, new, 1)
            n += 1
        else:
            print(f"  [miss] pattern not found")
    open(path, "w").write(content)
    return n

found = False
for smali_name in ["1E7.smali", "1Dy.smali"]:
    smali = os.path.join(clone_dir, "smali", "X", smali_name)
    if os.path.exists(smali):
        print(f"  Found: smali/X/{smali_name}")
        content = open(smali).read()

        # Patch 1
        p1_old = '    if-nez v0, :cond_0\n\n    .line 155\n    .line 156\n    const-string v1, "Please set reporter for SecurePendingIntent library"'
        p1_new = '    if-eqz v0, :cond_5\n\n    .line 155\n    .line 156\n    const-string v1, "Please set reporter for SecurePendingIntent library"'
        if p1_old in content:
            content = content.replace(p1_old, p1_new, 1)
            print("  Patch 1: APPLIED")
        else:
            print("  Patch 1: NOT FOUND")

        # Patch 2 - cond_8 block
        p2_old = '    :cond_8\n    const-string v1, "Please set reporter for SecurePendingIntent library"\n\n    .line 217\n    .line 218\n    new-instance v0, Ljava/lang/IllegalArgumentException;\n\n    .line 219\n    .line 220\n    invoke-direct {v0, v1}, Ljava/lang/IllegalArgumentException;-><init>(Ljava/lang/String;)V\n\n    .line 221\n    .line 222\n    .line 223\n    throw v0'
        p2_new = '    :cond_8\n    return-object v2'
        if p2_old in content:
            content = content.replace(p2_old, p2_new, 1)
            print("  Patch 2: APPLIED")
        else:
            print("  Patch 2: NOT FOUND")

        # Patch 3 - cond_9 block
        p3_old = '    :cond_9\n    const-string v1, "Must generate PendingIntent based on an explicit intent."\n\n    .line 225\n    .line 226\n    new-instance v0, Ljava/lang/SecurityException;\n\n    .line 227\n    .line 228\n    invoke-direct {v0, v1}, Ljava/lang/SecurityException;-><init>(Ljava/lang/String;)V\n\n    .line 229\n    .line 230\n    .line 231\n    throw v0\n.end method'
        p3_new = '    :cond_9\n    return-object v2\n.end method'
        if p3_old in content:
            content = content.replace(p3_old, p3_new, 1)
            print("  Patch 3: APPLIED")
        else:
            print("  Patch 3: NOT FOUND")

        open(smali, "w").write(content)
        found = True
        break

if not found:
    for f in glob.glob(os.path.join(clone_dir, "smali*", "**", "*.smali"), recursive=True):
        try:
            if "Please set reporter" in open(f).read():
                print(f"  Found in: {f}")
                break
        except:
            pass
