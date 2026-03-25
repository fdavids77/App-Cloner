#!/bin/bash
# ============================================================
#  APK Clone Factory v1.5
#  Universal multi-clone builder for split APKs
#  Tested: WhatsApp, WhatsApp Business, Tinder
#
#  v1.4: --start/--count for clone ranges
#  v1.5: WhatsApp Business support, generic SecurePendingIntent
#        patching, keeps merged APK for reuse
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
  echo -e "${B}APK Clone Factory v1.5${N}"
  echo ""
  echo "Usage: $0 <input_file> <count> [options]"
  echo ""
  echo "  <input_file>      .xapk, .apkm, or pre-merged .apk"
  echo "  <count>           Number of clones to build (1-20)"
  echo ""
  echo "Options:"
  echo "  --start N          Start numbering at N (default: 1)"
  echo "  --install          ADB install each clone after building"
  echo "  --private-space    Install to Private Space (user 10, root)"
  echo ""
  echo "Examples:"
  echo "  $0 whatsapp.xapk 7                           # clone1-7"
  echo "  $0 WhatsApp_merged.apk 3 --start 8           # clone8-10"
  echo "  $0 WhatsAppBusiness.xapk 4 --install"
  echo "  $0 tinder.xapk 3 --install --private-space"
  echo ""
  echo "Supported apps (auto-detected):"
  echo "  com.whatsapp        WhatsApp"
  echo "  com.whatsapp.w4b    WhatsApp Business"
  echo "  com.tinder          Tinder"
  echo "  (any other package works too)"
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
    --start) shift; START_NUM="$1" ;;
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
for dep in java apktool apksigner zipalign; do
  command -v "$dep" &>/dev/null || err "$dep not found. Install it first."
done

# ---- PATHS -------------------------------------------------
WORK_DIR="$(cd "$(dirname "$XAPK_FILE")" && pwd)"
XAPK_FILE="$(cd "$(dirname "$XAPK_FILE")" && pwd)/$(basename "$XAPK_FILE")"
KEYSTORE="$WORK_DIR/$KEYSTORE_NAME"

# Find APKEditor.jar
APKEDITOR=""
for p in "$WORK_DIR/APKEditor.jar" "$HOME/APKEditor.jar" "$HOME/tools/APKEditor.jar"; do
  [ -f "$p" ] && APKEDITOR="$p" && break
done

# ---- STEP 1: HANDLE INPUT ----------------------------------
BUNDLE_DIR="$WORK_DIR/_bundle"
OUTPUT_DIR="$WORK_DIR/output"
INPUT_EXT="${XAPK_FILE##*.}"

# Determine merged APK name/path
# If input is already .apk, use it directly
# If input is .xapk/.apkm, check for existing merged APK first
MERGED_APK=""
ORIG_PKG=""

if [ "$INPUT_EXT" = "apk" ]; then
  # Direct APK input — use as-is, don't delete later
  MERGED_APK="$XAPK_FILE"
  KEEP_MERGED=true

else
  # Split APK — check if we already have a merged version
  BASE_NAME=$(basename "$XAPK_FILE" ".$INPUT_EXT")
  MERGED_APK="$WORK_DIR/${BASE_NAME}_merged.apk"
  KEEP_MERGED=true  # always keep merged APK for reuse

  if [ -f "$MERGED_APK" ]; then
    log "Found existing merged APK: $(basename "$MERGED_APK") ($(du -h "$MERGED_APK" | cut -f1))"
    log "Skipping merge — delete ${BASE_NAME}_merged.apk to force re-merge"
  else
    [ -z "$APKEDITOR" ] && err "APKEditor.jar needed for merge but not found"

    rm -rf "$BUNDLE_DIR"
    mkdir -p "$BUNDLE_DIR"

    if [ "$INPUT_EXT" = "xapk" ]; then
      log "Extracting XAPK..."
      unzip -q -o "$XAPK_FILE" -d "$BUNDLE_DIR"

      # Get package name from manifest.json
      if [ -f "$BUNDLE_DIR/manifest.json" ]; then
        ORIG_PKG=$(grep -o '"package_name"[[:space:]]*:[[:space:]]*"[^"]*"' "$BUNDLE_DIR/manifest.json" | head -1 | grep -o '"[^"]*"$' | tr -d '"')
      fi

    elif [ "$INPUT_EXT" = "apkm" ]; then
      log "Extracting APKM..."
      cp "$XAPK_FILE" "$BUNDLE_DIR/bundle.zip"
      cd "$BUNDLE_DIR" && unzip -q bundle.zip && cd "$WORK_DIR"
    else
      err "Unsupported file type: .$INPUT_EXT (use .xapk, .apkm, or .apk)"
    fi

    log "Merging split APKs..."
    java -jar "$APKEDITOR" m -i "$BUNDLE_DIR" -o "$MERGED_APK"
    ok "Merged → ${BASE_NAME}_merged.apk ($(du -h "$MERGED_APK" | cut -f1))"
    rm -rf "$BUNDLE_DIR"
  fi
fi

mkdir -p "$OUTPUT_DIR"

# ---- DETECT PACKAGE NAME -----------------------------------
if [ -z "$ORIG_PKG" ]; then
  # Try aapt
  ORIG_PKG=$(aapt dump badging "$MERGED_APK" 2>/dev/null | grep -o "package: name='[^']*'" | grep -o "'[^']*'" | tr -d "'" || true)
fi
if [ -z "$ORIG_PKG" ]; then
  # Fallback: quick apktool decode of manifest only
  TMPD=$(mktemp -d)
  apktool d "$MERGED_APK" -o "$TMPD" -s --force 2>/dev/null
  ORIG_PKG=$(grep -o 'package="[^"]*"' "$TMPD/AndroidManifest.xml" 2>/dev/null | head -1 | grep -o '"[^"]*"' | tr -d '"')
  rm -rf "$TMPD"
fi

[ -z "$ORIG_PKG" ] && err "Could not detect package name"

# ---- APP PROFILES ------------------------------------------
# Each app profile defines: display name, output prefix,
# and any app-specific behavior flags
APP_NAME=""
APP_PREFIX=""
IS_WHATSAPP=false

case "$ORIG_PKG" in
  com.whatsapp)
    APP_NAME="WhatsApp"
    APP_PREFIX="whatsapp"
    IS_WHATSAPP=true
    ;;
  com.whatsapp.w4b)
    APP_NAME="WhatsApp Business"
    APP_PREFIX="whatsapp-business"
    IS_WHATSAPP=true
    ;;
  com.tinder)
    APP_NAME="Tinder"
    APP_PREFIX="tinder"
    ;;
  *)
    APP_NAME="$(echo "$ORIG_PKG" | awk -F. '{print $NF}')"
    APP_PREFIX="$(echo "$ORIG_PKG" | awk -F. '{print $NF}' | tr '[:upper:]' '[:lower:]')"
    ;;
esac

echo ""
echo -e "${B}========================================${N}"
echo -e "${B}  App:     ${C}$APP_NAME${N}"
echo -e "${B}  Package: ${C}$ORIG_PKG${N}"
echo -e "${B}  Clones:  ${C}clone${START_NUM} → clone${END_NUM} (${NUM_CLONES} total)${N}"
echo -e "${B}========================================${N}"
echo ""

# ---- GENERATE KEYSTORE -------------------------------------
if [ ! -f "$KEYSTORE" ]; then
  log "Generating signing keystore..."
  keytool -genkey -v -keystore "$KEYSTORE" \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -alias "$KS_ALIAS" -storepass "$KS_PASS" -keypass "$KS_PASS" \
    -dname "$KS_DNAME" 2>/dev/null
  ok "Keystore created"
fi

# ============================================================
#  PATCHING FUNCTIONS
# ============================================================

patch_manifest() {
  local MANIFEST="$1"
  local CLONE_PKG="$2"

  # 1) Package name
  sed -i "s|package=\"${ORIG_PKG}\"|package=\"${CLONE_PKG}\"|" "$MANIFEST"

  # 2) Authorities — rename all that start with original package
  sed -i "s|android:authorities=\"${ORIG_PKG}\.|android:authorities=\"${CLONE_PKG}.|g" "$MANIFEST"
  sed -i "s|android:authorities=\"${ORIG_PKG}\"|android:authorities=\"${CLONE_PKG}\"|g" "$MANIFEST"

  # 3) Delete ALL <permission> declarations (prevents collisions
  #    between original app and clones, and between clones)
  sed -i '/<permission /d' "$MANIFEST"

  # 4) Rename remaining permission references
  sed -i "s|${ORIG_PKG}\.permission\.|${CLONE_PKG}.permission.|g" "$MANIFEST"
  sed -i "s|${ORIG_PKG}\.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION|${CLONE_PKG}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION|g" "$MANIFEST"

  # 5) extractNativeLibs=true (required for merged split APKs)
  sed -i 's|android:extractNativeLibs="false"|android:extractNativeLibs="true"|' "$MANIFEST"

  # 6) Remove split type attributes (leftover from app bundles)
  sed -i 's|android:requiredSplitTypes="[^"]*"||g' "$MANIFEST"
  sed -i 's|android:splitTypes="[^"]*"||g' "$MANIFEST"

  # 7) Samsung multiwindow cleanup
  sed -i '/com.sec.android.app.multiwindow/d' "$MANIFEST"
  sed -i '/<package android:name="com.samsung.android.mapsagent"/d' "$MANIFEST"
  sed -i '/com\.samsung\.android\.mapsagent\.permission\.READ_APP_INFO/d' "$MANIFEST"
}

patch_securependingintent() {
  local DECOMPILED="$1"
  local SMALI_BASE="$DECOMPILED/smali"
  [ ! -d "$SMALI_BASE" ] && return 0

  # Find ALL files containing SecurePendingIntent
  local SPI_FILES
  SPI_FILES=$(grep -rln 'SecurePendingIntent' "$SMALI_BASE/" 2>/dev/null || true)
  [ -z "$SPI_FILES" ] && { log "No SecurePendingIntent found — skipping"; return 0; }

  log "Patching SecurePendingIntent..."

  while IFS= read -r sf; do
    [ -z "$sf" ] && continue
    local rel_path="${sf#$DECOMPILED/}"

    python3 << PYEOF
import re, sys

path = '${sf}'
try:
    content = open(path).read()
except FileNotFoundError:
    sys.exit(0)

modified = False

# --- PATCH STRATEGY ---
# 1. Known WhatsApp pattern: exact string matches from X/1Dy.smali
wa_patches = [
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

for i, (old, new) in enumerate(wa_patches):
    if old in content:
        content = content.replace(old, new, 1)
        print(f"  Exact patch {i+1}: APPLIED")
        modified = True

# 2. Generic fallback: neutralize throw near SecurePendingIntent strings
#    Catches WhatsApp Business and future obfuscation changes
if not modified:
    # Pattern A: throw after SecurePendingIntent-related invoke
    new_content = re.sub(
        r'(invoke[^\n]*SecurePendingIntent[^\n]*\n(?:[^\n]*\n){0,10}?[^\n]*)throw (v\d+)',
        r'\1return-void # SPI-patched',
        content
    )

    # Pattern B: IllegalArgumentException/SecurityException throw blocks
    #            after const-string referencing SecurePendingIntent or PendingIntent
    new_content = re.sub(
        r'(const-string [^\n]*"[^"]*SecurePendingIntent[^"]*"[^\n]*\n'
        r'(?:[^\n]*\n){0,15}?)'
        r'(new-instance [^\n]*(?:IllegalArgumentException|SecurityException)[^\n]*\n'
        r'(?:[^\n]*\n){0,5}?)'
        r'throw (v\d+)',
        r'\1return-void # SPI-patched',
        new_content
    )

    # Pattern C: throw blocks after "Must generate PendingIntent"
    new_content = re.sub(
        r'(const-string [^\n]*"Must generate PendingIntent[^"]*"[^\n]*\n'
        r'(?:[^\n]*\n){0,10}?)'
        r'throw (v\d+)',
        r'\1return-void # SPI-patched',
        new_content
    )

    if new_content != content:
        content = new_content
        modified = True
        print(f"  Generic patch: APPLIED")

if modified:
    open(path, 'w').write(content)
    print(f"  ✓ Patched: ${rel_path}")
else:
    print(f"  ○ No throw found in: ${rel_path}")

PYEOF
  done <<< "$SPI_FILES"

  ok "SecurePendingIntent patching complete"
}

fix_native_libs() {
  local UNSIGNED="$1"
  local DECOMPILED="$2"

  for abi in arm64-v8a armeabi-v7a x86_64 x86; do
    if [ -d "$DECOMPILED/lib/$abi" ]; then
      zip -d "$UNSIGNED" "lib/${abi}/*.so" 2>/dev/null || true
      cd "$DECOMPILED"
      find "lib/${abi}/" -name "*.so" | xargs zip -0 "$UNSIGNED"
      cd "$WORK_DIR"
    fi
  done
}

# ============================================================
#  BUILD LOOP
# ============================================================
for i in $(seq "$START_NUM" "$END_NUM"); do
  CLONE_ID="clone${i}"
  CLONE_PKG="${ORIG_PKG}.${CLONE_ID}"
  CLONE_APK="$OUTPUT_DIR/${APP_PREFIX}-${CLONE_ID}.apk"
  DECOMPILED="$WORK_DIR/_dec_${CLONE_ID}"
  UNSIGNED="$WORK_DIR/_${CLONE_ID}_unsigned.apk"
  ALIGNED="$WORK_DIR/_${CLONE_ID}_aligned.apk"

  echo ""
  echo -e "${B}===========================================${N}"
  echo -e "${C}  Building: $CLONE_PKG ($((i - START_NUM + 1))/${NUM_CLONES})${N}"
  echo -e "${B}===========================================${N}"

  # ---- FRESH DECOMPILE ----
  rm -rf "$DECOMPILED"
  log "Decompiling (fresh for clone${i})..."
  apktool d "$MERGED_APK" -o "$DECOMPILED" --force
  ok "Decompiled"

  # ---- PATCH MANIFEST ----
  patch_manifest "$DECOMPILED/AndroidManifest.xml" "$CLONE_PKG"
  ok "Manifest patched"

  # ---- PATCH SMALI (SecurePendingIntent) ----
  if $IS_WHATSAPP; then
    patch_securependingintent "$DECOMPILED"
  else
    # For non-WhatsApp apps, still check for SecurePendingIntent
    SPI_CHECK=$(grep -rln 'SecurePendingIntent' "$DECOMPILED/smali/" 2>/dev/null || true)
    if [ -n "$SPI_CHECK" ]; then
      patch_securependingintent "$DECOMPILED"
    else
      log "No SecurePendingIntent — no smali patch needed"
    fi
  fi

  # ---- PATCH APKTOOL.YML ----
  if [ -f "$DECOMPILED/apktool.yml" ]; then
    sed -i "s|packageId: ${ORIG_PKG}$|packageId: ${CLONE_PKG}|" "$DECOMPILED/apktool.yml"
  fi

  # ---- REBUILD ----
  log "Rebuilding APK..."
  rm -f "$UNSIGNED"
  apktool b "$DECOMPILED" -o "$UNSIGNED"
  ok "Built"

  # ---- FIX NATIVE LIBS ----
  log "Fixing native lib compression..."
  fix_native_libs "$UNSIGNED" "$DECOMPILED"
  ok ".so files uncompressed"

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
  rm -rf "$DECOMPILED"

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

done

# ============================================================
#  SUMMARY
# ============================================================
echo ""
echo -e "${B}========================================${N}"
echo -e "${G}  Build complete!${N}"
echo -e "${B}========================================${N}"
echo ""
echo -e "  ${B}Clones built:${N}"
for i in $(seq "$START_NUM" "$END_NUM"); do
  f="$OUTPUT_DIR/${APP_PREFIX}-clone${i}.apk"
  [ -f "$f" ] && echo -e "    $(du -h "$f" | cut -f1)  ${ORIG_PKG}.clone${i}"
done

# Show reuse hint if we merged from splits
if [ "$INPUT_EXT" != "apk" ]; then
  BASE_NAME=$(basename "$XAPK_FILE" ".$INPUT_EXT")
  echo ""
  echo -e "  ${B}Reuse merged APK for more clones:${N}"
  echo -e "    $0 ${BASE_NAME}_merged.apk 3 --start $((END_NUM + 1))"
fi

echo ""
echo -e "  ${B}Install:${N}"
echo -e "    adb install output/${APP_PREFIX}-cloneN.apk"
echo ""
echo -e "  ${B}Private Space:${N}"
echo -e "    adb push output/${APP_PREFIX}-cloneN.apk /data/local/tmp/c.apk"
echo -e "    adb shell su -c 'pm install --user 10 /data/local/tmp/c.apk'"
echo ""
