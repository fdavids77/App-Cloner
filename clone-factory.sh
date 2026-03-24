#!/bin/bash
# ============================================================
#  APK Clone Factory v1.0
#  Universal multi-clone builder for split APKs (XAPK)
#  Tested: WhatsApp, Tinder
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
  echo -e "${B}APK Clone Factory${N}"
  echo ""
  echo "Usage: $0 <xapk_file> <num_clones> [--install] [--private-space]"
  echo ""
  echo "  <xapk_file>       Path to .xapk file"
  echo "  <num_clones>      Number of clones to build (1-10)"
  echo "  --install          ADB install each clone after building"
  echo "  --private-space    Install to Private Space (user 10, requires root)"
  echo ""
  echo "Examples:"
  echo "  $0 whatsapp.xapk 3"
  echo "  $0 tinder.xapk 2 --install"
  echo "  $0 whatsapp.xapk 4 --install --private-space"
  exit 1
}

# ---- ARGS --------------------------------------------------
[ $# -lt 2 ] && usage
XAPK_FILE="$1"
NUM_CLONES="$2"
DO_INSTALL=false
PRIVATE_SPACE=false

shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    --install) DO_INSTALL=true ;;
    --private-space) PRIVATE_SPACE=true; DO_INSTALL=true ;;
    *) echo -e "${R}Unknown arg: $1${N}"; usage ;;
  esac
  shift
done

[ ! -f "$XAPK_FILE" ] && echo -e "${R}File not found: $XAPK_FILE${N}" && exit 1
[[ "$NUM_CLONES" =~ ^[0-9]+$ ]] || { echo -e "${R}num_clones must be a number${N}"; exit 1; }
[ "$NUM_CLONES" -lt 1 ] || [ "$NUM_CLONES" -gt 10 ] && echo -e "${R}num_clones must be 1-10${N}" && exit 1

# ---- PATHS -------------------------------------------------
WORK_DIR="$(cd "$(dirname "$XAPK_FILE")" && pwd)"
XAPK_FILE="$(cd "$(dirname "$XAPK_FILE")" && pwd)/$(basename "$XAPK_FILE")"
KEYSTORE="$WORK_DIR/$KEYSTORE_NAME"

# Find APKEditor.jar
APKEDITOR=""
for p in "$WORK_DIR/APKEditor.jar" "$HOME/APKEditor.jar" "$HOME/tools/APKEditor.jar"; do
  [ -f "$p" ] && APKEDITOR="$p" && break
done
[ -z "$APKEDITOR" ] && echo -e "${R}APKEditor.jar not found in $WORK_DIR, ~/, or ~/tools/${N}" && exit 1

echo -e "${C}Using APKEditor: $APKEDITOR${N}"

# ---- DETECT APP --------------------------------------------
log() { echo -e "${G}[*]${N} $1"; }
warn() { echo -e "${Y}[!]${N} $1"; }
err() { echo -e "${R}[✗]${N} $1"; exit 1; }
ok() { echo -e "${G}[✓]${N} $1"; }

# ---- STEP 1: UNZIP XAPK ------------------------------------
SPLITS_DIR="$WORK_DIR/_splits"
DECOMPILED="$WORK_DIR/_decompiled"
MERGED_APK="$WORK_DIR/_merged.apk"
OUTPUT_DIR="$WORK_DIR/output"

rm -rf "$SPLITS_DIR" "$DECOMPILED" "$MERGED_APK"
mkdir -p "$SPLITS_DIR" "$OUTPUT_DIR"

log "Extracting XAPK..."
unzip -q -o "$XAPK_FILE" -d "$SPLITS_DIR"

# Detect package name from manifest.json in XAPK
ORIG_PKG=""
if [ -f "$SPLITS_DIR/manifest.json" ]; then
  ORIG_PKG=$(grep -o '"package_name"[[:space:]]*:[[:space:]]*"[^"]*"' "$SPLITS_DIR/manifest.json" | head -1 | grep -o '"[^"]*"$' | tr -d '"')
fi

# Fallback: detect from base APK filename
if [ -z "$ORIG_PKG" ]; then
  for f in "$SPLITS_DIR"/*.apk; do
    base=$(basename "$f" .apk)
    if [[ "$base" == com.* ]]; then
      ORIG_PKG="$base"
      break
    fi
  done
fi

[ -z "$ORIG_PKG" ] && err "Could not detect package name from XAPK"

# Derive app name for display
APP_NAME=""
case "$ORIG_PKG" in
  com.whatsapp) APP_NAME="WhatsApp" ;;
  com.tinder)   APP_NAME="Tinder" ;;
  *)            APP_NAME="$ORIG_PKG" ;;
esac

echo ""
echo -e "${B}========================================${N}"
echo -e "${B}  App:     ${C}$APP_NAME${N}"
echo -e "${B}  Package: ${C}$ORIG_PKG${N}"
echo -e "${B}  Clones:  ${C}$NUM_CLONES${N}"
echo -e "${B}========================================${N}"
echo ""

# ---- STEP 2: MERGE -----------------------------------------
log "Merging split APKs..."
java -jar "$APKEDITOR" m -i "$SPLITS_DIR" -o "$MERGED_APK"
ok "Merged"

# ---- STEP 3: DECOMPILE -------------------------------------
log "Decompiling..."
rm -rf "$DECOMPILED"
java -jar "$APKEDITOR" d -i "$MERGED_APK" -o "$DECOMPILED"
ok "Decompiled"

# ---- STEP 4: FIND SMALI DIR --------------------------------
SMALI_DIR=""
if [ -d "$DECOMPILED/smali" ]; then
  SMALI_DIR="$DECOMPILED/smali"
elif [ -d "$DECOMPILED/root/smali" ]; then
  SMALI_DIR="$DECOMPILED/root/smali"
fi

# ---- STEP 5: DETECT APP-SPECIFIC PATCHES -------------------
# SecurePendingIntent (WhatsApp and others)
SECURE_PENDING_FILES=()
if [ -n "$SMALI_DIR" ]; then
  while IFS= read -r line; do
    SECURE_PENDING_FILES+=("$line")
  done < <(grep -rln 'SecurePendingIntent' "$SMALI_DIR/" 2>/dev/null || true)
fi

if [ ${#SECURE_PENDING_FILES[@]} -gt 0 ]; then
  warn "SecurePendingIntent found in ${#SECURE_PENDING_FILES[@]} file(s) — will patch"
fi

# Backup original manifest + smali
cp "$DECOMPILED/AndroidManifest.xml" "$DECOMPILED/AndroidManifest.xml.bak"
for sf in "${SECURE_PENDING_FILES[@]}"; do
  cp "$sf" "${sf}.bak"
done

# ---- STEP 6: GENERATE KEYSTORE -----------------------------
if [ ! -f "$KEYSTORE" ]; then
  log "Generating signing keystore..."
  keytool -genkey -v -keystore "$KEYSTORE" \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -alias "$KS_ALIAS" -storepass "$KS_PASS" -keypass "$KS_PASS" \
    -dname "$KS_DNAME" 2>/dev/null
  ok "Keystore created"
fi

# ---- STEP 7: BUILD CLONES ----------------------------------
ESCAPED_PKG=$(echo "$ORIG_PKG" | sed 's/\./\\./g')

for i in $(seq 1 "$NUM_CLONES"); do
  CLONE_ID="clone${i}"
  CLONE_PKG="${ORIG_PKG}.${CLONE_ID}"
  CLONE_APK="$OUTPUT_DIR/${APP_NAME,,}-${CLONE_ID}.apk"

  echo ""
  echo -e "${B}------------------------------------------${N}"
  echo -e "${C}  Building: $CLONE_PKG ($i/$NUM_CLONES)${N}"
  echo -e "${B}------------------------------------------${N}"

  # Restore clean manifest
  cp "$DECOMPILED/AndroidManifest.xml.bak" "$DECOMPILED/AndroidManifest.xml"

  # Restore smali backups
  for sf in "${SECURE_PENDING_FILES[@]}"; do
    cp "${sf}.bak" "$sf"
  done

  # --- MANIFEST PATCHES ---

  # 1) Package name
  sed -i "s|package=\"${ORIG_PKG}\"|package=\"${CLONE_PKG}\"|" "$DECOMPILED/AndroidManifest.xml"

  # 2) Authorities (com.tinder.X → com.tinder.clone1.X)
  sed -i "s|android:authorities=\"${ORIG_PKG}\.|android:authorities=\"${CLONE_PKG}.|g" "$DECOMPILED/AndroidManifest.xml"
  # Also catch authorities that are exactly the package name (no suffix)
  sed -i "s|android:authorities=\"${ORIG_PKG}\"|android:authorities=\"${CLONE_PKG}\"|g" "$DECOMPILED/AndroidManifest.xml"

  # 3) Custom permissions
  sed -i "s|${ORIG_PKG}\.permission\.|${CLONE_PKG}.permission.|g" "$DECOMPILED/AndroidManifest.xml"
  sed -i "s|${ORIG_PKG}\.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION|${CLONE_PKG}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION|g" "$DECOMPILED/AndroidManifest.xml"

  # 4) extractNativeLibs=true
  sed -i 's|android:extractNativeLibs="false"|android:extractNativeLibs="true"|' "$DECOMPILED/AndroidManifest.xml"

  # 5) Samsung multiwindow cleanup
  sed -i '/<package android:name="com.samsung.android.mapsagent"/d' "$DECOMPILED/AndroidManifest.xml"
  sed -i '/com\.samsung\.android\.mapsagent\.permission\.READ_APP_INFO/d' "$DECOMPILED/AndroidManifest.xml"

  # 6) Any other custom permissions matching original package (catch-all)
  sed -i "s|android:name=\"${ORIG_PKG}\.\([A-Z_]*PERMISSION[A-Z_]*\)\"|android:name=\"${CLONE_PKG}.\1\"|g" "$DECOMPILED/AndroidManifest.xml"

  ok "Manifest patched"

  # --- SMALI PATCHES ---

  # SecurePendingIntent: replace throw with return-void
  for sf in "${SECURE_PENDING_FILES[@]}"; do
    if grep -q 'throw ' "$sf"; then
      # Find throw instructions near SecurePendingIntent and replace with return-void
      sed -i '/SecurePendingIntent/{n;s/throw .*/return-void/}' "$sf"
      # Also handle cases where throw is a few lines after
      python3 -c "
import re
with open('$sf', 'r') as f:
    content = f.read()
# Pattern: find 'throw vX' after invoke.*SecurePendingIntent within ~10 lines
content = re.sub(r'(invoke[^\n]*SecurePendingIntent[^\n]*\n(?:[^\n]*\n){0,10}?[^\n]*)throw (v\d+)', r'\1return-void #patched \2', content)
with open('$sf', 'w') as f:
    f.write(content)
" 2>/dev/null || true
      ok "SecurePendingIntent patched in $(basename "$sf")"
    fi
  done

  # --- REBUILD ---
  log "Rebuilding APK..."
  UNSIGNED="$WORK_DIR/_${CLONE_ID}-unsigned.apk"
  rm -f "$UNSIGNED"
  java -jar "$APKEDITOR" b -i "$DECOMPILED" -o "$UNSIGNED"

  # --- UNCOMPRESSED .so INJECTION ---
  log "Injecting uncompressed .so files..."
  TMPSO=$(mktemp -d)
  unzip -o "$UNSIGNED" 'lib/*' -d "$TMPSO" 2>/dev/null || true
  if [ -d "$TMPSO/lib" ]; then
    cd "$TMPSO"
    find lib -name '*.so' -exec zip -0 "$UNSIGNED" {} \; 2>/dev/null || true
    cd "$WORK_DIR"
  fi
  rm -rf "$TMPSO"
  ok ".so files injected"

  # --- SIGN ---
  log "Signing..."
  apksigner sign --ks "$KEYSTORE" --ks-pass "pass:${KS_PASS}" \
    --ks-key-alias "$KS_ALIAS" "$UNSIGNED" 2>/dev/null
  mv "$UNSIGNED" "$CLONE_APK"
  ok "Signed → $(basename "$CLONE_APK")"

  # --- INSTALL ---
  if $DO_INSTALL; then
    log "Installing..."
    if $PRIVATE_SPACE; then
      adb push "$CLONE_APK" /data/local/tmp/_clone.apk
      adb shell su -c "pm install --user 10 /data/local/tmp/_clone.apk" && ok "Installed to Private Space" || warn "Install failed"
      adb shell su -c "rm /data/local/tmp/_clone.apk"
    else
      adb install "$CLONE_APK" && ok "Installed" || warn "Install failed"
    fi
  fi

done

# ---- CLEANUP ------------------------------------------------
cp "$DECOMPILED/AndroidManifest.xml.bak" "$DECOMPILED/AndroidManifest.xml"
for sf in "${SECURE_PENDING_FILES[@]}"; do
  cp "${sf}.bak" "$sf"
done
rm -f "$MERGED_APK"

echo ""
echo -e "${B}========================================${N}"
echo -e "${G}  Build complete!${N}"
echo -e "${B}========================================${N}"
echo ""
echo -e "  ${B}Clones:${N}"
ls -lh "$OUTPUT_DIR/"*.apk 2>/dev/null | while read -r line; do
  echo -e "    $line"
done
echo ""
echo -e "  ${B}Manual install:${N}"
echo -e "    adb install output/<name>.apk"
echo ""
echo -e "  ${B}Private Space:${N}"
echo -e "    adb push output/<name>.apk /data/local/tmp/c.apk"
echo -e "    adb shell su -c 'pm install --user 10 /data/local/tmp/c.apk'"
echo ""
