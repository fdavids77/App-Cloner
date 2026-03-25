#!/bin/bash
# ============================================================
#  APK Clone Factory v1.4
#  Universal multi-clone builder for split APKs (XAPK/APKM)
#  Tested: WhatsApp, Tinder
#
#  v1.3: apktool for decompile/rebuild, APKEditor for merge
#  v1.4: --start N and --count N flags for building specific
#        clone ranges (e.g. --start 8 --count 3 → clone8-10)
# ============================================================
set -e

# ---- CONFIG ------------------------------------------------
KEYSTORE_NAME="clone-key.jks"
KS_PASS="clone123"
KS_ALIAS="clonekey"
KS_DNAME="CN=Clone,OU=Dev,O=Dev,L=CT,ST=WC,C=ZA"

# ---- COLORS ------------------------------------------------
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
C='\033[0;36m'; B='\033[1m'; N='\033[0m'

# ---- USAGE -------------------------------------------------
usage() {
  echo -e "${B}APK Clone Factory v1.4${N}"
  echo ""
  echo "Usage: $0 <input_file> <count> [options]"
  echo ""
  echo "  <input_file>      Path to .xapk, .apkm, or .apk (pre-merged) file"
  echo "  <count>           Number of clones to build (1-20)"
  echo ""
  echo "Options:"
  echo "  --start N          Start numbering at N (default: 1)"
  echo "                     e.g. --start 8 with count 3 → clone8, clone9, clone10"
  echo "  --install          ADB install each clone after building"
  echo "  --private-space    Install to Private Space (user 10, requires root)"
  echo ""
  echo "Examples:"
  echo "  $0 whatsapp.xapk 3                          # clone1, clone2, clone3"
  echo "  $0 WhatsApp_merged.apk 3 --start 8          # clone8, clone9, clone10"
  echo "  $0 tinder.xapk 2 --install                  # clone1, clone2 + install"
  echo "  $0 whatsapp.apkm 4 --start 5 --private-space"
  exit 1
}

# ---- ARGS --------------------------------------------------
[ $# -lt 2 ] && usage
XAPK_FILE="$1"
NUM_CLONES="$2"
START_NUM=1
DO_INSTALL=false
PRIVATE_SPACE=false

shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    --start)
      shift
      START_NUM="$1"
      ;;
    --install) DO_INSTALL=true ;;
    --private-space) PRIVATE_SPACE=true; DO_INSTALL=true ;;
    *) echo -e "${R}Unknown arg: $1${N}"; usage ;;
  esac
  shift
done

[ ! -f "$XAPK_FILE" ] && echo -e "${R}File not found: $XAPK_FILE${N}" && exit 1
[[ "$NUM_CLONES" =~ ^[0-9]+$ ]] || { echo -e "${R}count must be a number${N}"; exit 1; }
[[ "$START_NUM" =~ ^[0-9]+$ ]] || { echo -e "${R}--start must be a number${N}"; exit 1; }
[ "$NUM_CLONES" -lt 1 ] || [ "$NUM_CLONES" -gt 20 ] && echo -e "${R}count must be 1-20${N}" && exit 1
[ "$START_NUM" -lt 1 ] && echo -e "${R}--start must be >= 1${N}" && exit 1

END_NUM=$(( START_NUM + NUM_CLONES - 1 ))

# ---- HELPERS -----------------------------------------------
log() { echo -e "${G}[*]${N} $1"; }
warn() { echo -e "${Y}[!]${N} $1"; }
err() { echo -e "${R}[✗]${N} $1"; exit 1; }
ok() { echo -e "${G}[✓]${N} $1"; }

# ---- DEPENDENCY CHECK --------------------------------------
check_dep() {
  command -v "$1" &>/dev/null || { echo -e "${R}Missing: $1 — install it first${N}"; return 1; }
}

check_dep java || exit 1
check_dep apktool || err "apktool not found. Install: sudo apt install apktool"
check_dep apksigner || err "apksigner not found. Install: sudo apt install apksigner"
check_dep zipalign || err "zipalign not found. Install: sudo apt install zipalign"

# ---- PATHS -------------------------------------------------
WORK_DIR="$(cd "$(dirname "$XAPK_FILE")" && pwd)"
XAPK_FILE="$(cd "$(dirname "$XAPK_FILE")" && pwd)/$(basename "$XAPK_FILE")"
KEYSTORE="$WORK_DIR/$KEYSTORE_NAME"

# Find APKEditor.jar (only needed for split APKs)
APKEDITOR=""
for p in "$WORK_DIR/APKEditor.jar" "$HOME/APKEditor.jar" "$HOME/tools/APKEditor.jar"; do
  [ -f "$p" ] && APKEDITOR="$p" && break
done

# ---- STEP 1: HANDLE INPUT ----------------------------------
BUNDLE_DIR="$WORK_DIR/_bundle"
MERGED_APK="$WORK_DIR/_merged.apk"
OUTPUT_DIR="$WORK_DIR/output"

rm -rf "$BUNDLE_DIR" "$MERGED_APK"
mkdir -p "$BUNDLE_DIR" "$OUTPUT_DIR"

INPUT_EXT="${XAPK_FILE##*.}"
NEEDS_MERGE=false

if [ "$INPUT_EXT" = "xapk" ]; then
  NEEDS_MERGE=true
  log "Extracting XAPK..."
  unzip -q -o "$XAPK_FILE" -d "$BUNDLE_DIR"

  ORIG_PKG=""
  if [ -f "$BUNDLE_DIR/manifest.json" ]; then
    ORIG_PKG=$(grep -o '"package_name"[[:space:]]*:[[:space:]]*"[^"]*"' "$BUNDLE_DIR/manifest.json" | head -1 | grep -o '"[^"]*"$' | tr -d '"')
  fi
  if [ -z "$ORIG_PKG" ]; then
    for f in "$BUNDLE_DIR"/*.apk; do
      base=$(basename "$f" .apk)
      [[ "$base" == com.* ]] && ORIG_PKG="$base" && break
    done
  fi

elif [ "$INPUT_EXT" = "apkm" ]; then
  NEEDS_MERGE=true
  log "Extracting APKM..."
  cp "$XAPK_FILE" "$BUNDLE_DIR/bundle.zip"
  cd "$BUNDLE_DIR" && unzip -q bundle.zip && cd "$WORK_DIR"

  ORIG_PKG=""
  for f in "$BUNDLE_DIR"/*.apk; do
    base=$(basename "$f" .apk)
    [[ "$base" == com.* ]] && ORIG_PKG="$base" && break
  done

elif [ "$INPUT_EXT" = "apk" ]; then
  cp "$XAPK_FILE" "$MERGED_APK"
  ORIG_PKG=""
  ok "Using pre-merged APK → $(du -h "$MERGED_APK" | cut -f1)"

else
  err "Unsupported file type: .$INPUT_EXT (use .xapk, .apkm, or .apk)"
fi

# Merge if needed
if $NEEDS_MERGE; then
  [ -z "$APKEDITOR" ] && err "APKEditor.jar needed for merge but not found"
  log "Merging split APKs..."
  java -jar "$APKEDITOR" m -i "$BUNDLE_DIR" -o "$MERGED_APK"
  ok "Merged → $(du -h "$MERGED_APK" | cut -f1)"
fi

# Detect package from merged APK if not found yet
if [ -z "$ORIG_PKG" ]; then
  ORIG_PKG=$(aapt dump badging "$MERGED_APK" 2>/dev/null | grep -o "package: name='[^']*'" | grep -o "'[^']*'" | tr -d "'" || true)
fi
if [ -z "$ORIG_PKG" ]; then
  TMPD=$(mktemp -d)
  apktool d "$MERGED_APK" -o "$TMPD" -s --force 2>/dev/null
  ORIG_PKG=$(grep -o 'package="[^"]*"' "$TMPD/AndroidManifest.xml" 2>/dev/null | head -1 | grep -o '"[^"]*"' | tr -d '"')
  rm -rf "$TMPD"
fi

[ -z "$ORIG_PKG" ] && err "Could not detect package name"

# Derive app name
APP_NAME=""
case "$ORIG_PKG" in
  com.whatsapp)  APP_NAME="WhatsApp" ;;
  com.tinder)    APP_NAME="Tinder" ;;
  *)             APP_NAME="$(echo "$ORIG_PKG" | awk -F. '{print $NF}')" ;;
esac

echo ""
echo -e "${B}========================================${N}"
echo -e "${B}  App:     ${C}$APP_NAME${N}"
echo -e "${B}  Package: ${C}$ORIG_PKG${N}"
echo -e "${B}  Clones:  ${C}clone${START_NUM} → clone${END_NUM} (${NUM_CLONES} total)${N}"
echo -e "${B}========================================${N}"
echo ""

# ---- STEP 2: GENERATE KEYSTORE -----------------------------
if [ ! -f "$KEYSTORE" ]; then
  log "Generating signing keystore..."
  keytool -genkey -v -keystore "$KEYSTORE" \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -alias "$KS_ALIAS" -storepass "$KS_PASS" -keypass "$KS_PASS" \
    -dname "$KS_DNAME" 2>/dev/null
  ok "Keystore created"
fi

# ---- STEP 3: BUILD EACH CLONE ------------------------------
for i in $(seq "$START_NUM" "$END_NUM"); do
  CLONE_ID="clone${i}"
  CLONE_PKG="${ORIG_PKG}.${CLONE_ID}"
  CLONE_APK="$OUTPUT_DIR/${APP_NAME,,}-${CLONE_ID}.apk"
  DECOMPILED="$WORK_DIR/_dec_${CLONE_ID}"
  UNSIGNED="$WORK_DIR/_${CLONE_ID}_unsigned.apk"
  ALIGNED="$WORK_DIR/_${CLONE_ID}_aligned.apk"

  echo ""
  echo -e "${B}===========================================${N}"
  echo -e "${C}  Building: $CLONE_PKG (clone${i}, $((i - START_NUM + 1))/${NUM_CLONES})${N}"
  echo -e "${B}===========================================${N}"

  # ---- FRESH DECOMPILE via apktool ----
  rm -rf "$DECOMPILED"
  log "Decompiling (apktool, fresh for clone${i})..."
  apktool d "$MERGED_APK" -o "$DECOMPILED" --force
  ok "Decompiled"

  MANIFEST="$DECOMPILED/AndroidManifest.xml"

  # ---- MANIFEST PATCHES ----

  # 1) Package name
  sed -i "s|package=\"${ORIG_PKG}\"|package=\"${CLONE_PKG}\"|" "$MANIFEST"

  # 2) Authorities
  sed -i "s|android:authorities=\"${ORIG_PKG}\.|android:authorities=\"${CLONE_PKG}.|g" "$MANIFEST"
  sed -i "s|android:authorities=\"${ORIG_PKG}\"|android:authorities=\"${CLONE_PKG}\"|g" "$MANIFEST"

  # 3) Delete ALL <permission> declarations (avoids collisions)
  sed -i '/<permission /d' "$MANIFEST"

  # 4) Rename permission references in <uses-permission>
  sed -i "s|${ORIG_PKG}\.permission\.|${CLONE_PKG}.permission.|g" "$MANIFEST"
  sed -i "s|${ORIG_PKG}\.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION|${CLONE_PKG}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION|g" "$MANIFEST"

  # 5) extractNativeLibs=true
  sed -i 's|android:extractNativeLibs="false"|android:extractNativeLibs="true"|' "$MANIFEST"

  # 6) Remove split type attributes (from merged bundles)
  sed -i 's|android:requiredSplitTypes="[^"]*"||g' "$MANIFEST"
  sed -i 's|android:splitTypes="[^"]*"||g' "$MANIFEST"

  # 7) Samsung multiwindow cleanup
  sed -i '/com.sec.android.app.multiwindow/d' "$MANIFEST"
  sed -i '/<package android:name="com.samsung.android.mapsagent"/d' "$MANIFEST"
  sed -i '/com\.samsung\.android\.mapsagent\.permission\.READ_APP_INFO/d' "$MANIFEST"

  ok "Manifest patched"

  # ---- SMALI PATCHES ----

  # SecurePendingIntent (WhatsApp: X/1Dy.smali)
  SMALI_FILE="$DECOMPILED/smali/X/1Dy.smali"
  if [ -f "$SMALI_FILE" ]; then
    log "Patching SecurePendingIntent (X/1Dy.smali)..."
    python3 << PYEOF
import sys
path = '${SMALI_FILE}'
try:
    content = open(path).read()
except FileNotFoundError:
    print("  Smali file not found - skipping")
    sys.exit(0)

patches = [
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
]
for idx, (old, new) in enumerate(patches):
    if old in content:
        content = content.replace(old, new, 1)
        print(f"  Patch {idx+1}: APPLIED")
    else:
        print(f"  Patch {idx+1}: NOT FOUND (may differ in this version)")
open(path, 'w').write(content)
PYEOF
    ok "SecurePendingIntent patched"
  else
    # Generic fallback: search for SecurePendingIntent in any smali
    SPI_FILES=$(grep -rln 'SecurePendingIntent' "$DECOMPILED/smali/" 2>/dev/null || true)
    if [ -n "$SPI_FILES" ]; then
      warn "SecurePendingIntent found but not in expected path (X/1Dy.smali)"
      warn "Files: $(echo "$SPI_FILES" | tr '\n' ' ')"
      warn "May need manual patching if clone crashes"
    else
      log "No SecurePendingIntent found — no smali patch needed"
    fi
  fi

  # ---- APKTOOL.YML PATCH ----
  if [ -f "$DECOMPILED/apktool.yml" ]; then
    sed -i "s|packageId: ${ORIG_PKG}$|packageId: ${CLONE_PKG}|" "$DECOMPILED/apktool.yml"
  fi

  # ---- REBUILD via apktool ----
  log "Rebuilding APK..."
  rm -f "$UNSIGNED"
  apktool b "$DECOMPILED" -o "$UNSIGNED"
  ok "Built"

  # ---- FIX NATIVE LIB COMPRESSION ----
  log "Fixing native lib compression..."
  # Detect which ABI dirs exist
  for abi in arm64-v8a armeabi-v7a x86_64 x86; do
    if [ -d "$DECOMPILED/lib/$abi" ]; then
      zip -d "$UNSIGNED" "lib/${abi}/*.so" 2>/dev/null || true
      cd "$DECOMPILED"
      find "lib/${abi}/" -name "*.so" | xargs zip -0 "$UNSIGNED"
      cd "$WORK_DIR"
    fi
  done
  ok ".so files injected uncompressed"

  # ---- ALIGN + SIGN ----
  log "Aligning and signing..."
  rm -f "$ALIGNED"
  zipalign -f 4 "$UNSIGNED" "$ALIGNED"
  apksigner sign \
    --ks "$KEYSTORE" \
    --ks-key-alias "$KS_ALIAS" \
    --ks-pass "pass:${KS_PASS}" \
    --key-pass "pass:${KS_PASS}" \
    --out "$CLONE_APK" \
    "$ALIGNED"
  ok "Signed → $(basename "$CLONE_APK") ($(du -h "$CLONE_APK" | cut -f1))"

  # ---- CLEANUP intermediates ----
  rm -f "$UNSIGNED" "$ALIGNED"

  # ---- INSTALL ----
  if $DO_INSTALL; then
    log "Installing $CLONE_PKG..."
    if $PRIVATE_SPACE; then
      adb push "$CLONE_APK" /data/local/tmp/_clone.apk
      adb shell su -c "pm install --user 10 /data/local/tmp/_clone.apk" && ok "Installed to Private Space" || warn "Install failed"
      adb shell su -c "rm /data/local/tmp/_clone.apk"
    else
      adb install "$CLONE_APK" && ok "Installed" || warn "Install failed"
    fi
  fi

  # ---- CLEANUP decompiled dir ----
  rm -rf "$DECOMPILED"

done

# ---- FINAL CLEANUP ------------------------------------------
rm -f "$MERGED_APK"
rm -rf "$BUNDLE_DIR"

echo ""
echo -e "${B}========================================${N}"
echo -e "${G}  Build complete!${N}"
echo -e "${B}========================================${N}"
echo ""
echo -e "  ${B}Clones built:${N}"
for i in $(seq "$START_NUM" "$END_NUM"); do
  f="$OUTPUT_DIR/${APP_NAME,,}-clone${i}.apk"
  [ -f "$f" ] && echo -e "    $(du -h "$f" | cut -f1)  ${ORIG_PKG}.clone${i}  →  $(basename "$f")"
done
echo ""
echo -e "  ${B}Manual install:${N}"
echo -e "    adb install output/${APP_NAME,,}-cloneN.apk"
echo ""
echo -e "  ${B}Private Space:${N}"
echo -e "    adb push output/${APP_NAME,,}-cloneN.apk /data/local/tmp/c.apk"
echo -e "    adb shell su -c 'pm install --user 10 /data/local/tmp/c.apk'"
echo ""
