#!/usr/bin/env python3
# WhatsApp-specific Smali patches
import sys, os

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
    open(path, 'w').write(content)
    return n

smali = os.path.join(clone_dir, 'smali', 'X', '1Dy.smali')
n = patch_file(smali, [
    (
        '    if-nez v0, :cond_0\n\n    .line 155\n    .line 156\n    const-string v1, "Please set reporter for SecurePendingIntent library"',
        '    if-eqz v0, :cond_5\n\n    .line 155\n    .line 156\n    const-string v1, "Please set reporter for SecurePendingIntent library"'
    ),
    (
        '    :cond_8\n    const-string v1, "Please set reporter for SecurePendingIntent library"\n\n    .line 217\n    .line 218\n    new-instance v0, Ljava/lang/IllegalArgumentException;\n\n    .line 219\n    .line 220\n    invoke-direct {v0, v1}, Ljava/lang/IllegalArgumentException;-><init>(Ljava/lang/String;)V\n\n    .line 221\n    .line 222\n    .line 223\n    throw v0',
        '    :cond_8\n    return-object v2'
    ),
    (
        '    :cond_9\n    const-string v1, "Must generate PendingIntent based on an explicit intent."\n\n    .line 225\n    .line 226\n    new-instance v0, Ljava/lang/SecurityException;\n\n    .line 227\n    .line 228\n    invoke-direct {v0, v1}, Ljava/lang/SecurityException;-><init>(Ljava/lang/String;)V\n\n    .line 229\n    .line 230\n    .line 231\n    throw v0\n.end method',
        '    :cond_9\n    return-object v2\n.end method'
    ),
])
print(f"  SecurePendingIntent: {n}/3 patches applied")
