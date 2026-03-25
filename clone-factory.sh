#!/bin/bash
# ============================================================
#  APK Clone Factory v1.2
#  Universal multi-clone builder for split APKs (XAPK)
#  Tested: WhatsApp, Tinder
#
#  v1.1: Fresh decompile per clone
#  v1.2: Raw dex mode — avoids APKEditor smali compiler bugs.
#        SecurePendingIntent patched via baksmali/smali on
#        targeted dex only.
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
  echo -e "${B}APK Clone Factory v1.2${N}"
  echo ""
  echo "Usage: $0 <xapk_file> <num_clones> [--install] [--private-space]"
  echo ""
  echo "  <xapk_file>       Path to .xapk or .apk file"
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

# ---- HELPERS -----------------------------------------------
log() { echo -e "${G}[*]${N} $1"; }
warn() { echo -e "${Y}[!]${N} $1"; }
err() { echo -e "${R}[✗]${N} $1"; exit 1; }
ok() { echo -e "${G}[✓]${N} $1"; }

# ---- PATHS -------------------------------------------------
WORK_DIR="$(cd "$(dirname "$XAPK_FILE")" && pwd)"
XAPK_FILE="$(cd "$(dirname "$XAPK_FILE")" && pwd)/$(basename "$XAPK_FILE")"
KEYSTORE="$WORK_DIR/$KEYSTORE_NAME"

# Find APKEditor.jar
APKEDITOR=""
for p in "$WORK_DIR/APKEditor.jar" "$HOME/APKEditor.jar" "$HOME/tools/APKEditor.jar"; do
  [ -f "$p" ] && APKEDITOR="$p" && break
done
[ -z "$APKEDITOR" ] && err "APKEditor.jar not found in $WORK_DIR, ~/, or ~/tools/"

# Find baksmali.jar and smali.jar (optional, for SecurePendingIntent)
BAKSMALI=""
SMALI=""
for p in "$WORK_DIR/baksmali.jar" "$HOME/baksmali.jar" "$HOME/tools/baksmali.jar"; do
  [ -f "$p" ] && BAKSMALI="$p" && break
done
for p in "$WORK_DIR/smali.jar" "$HOME/smali.jar" "$HOME/tools/smali.jar"; do
  [ -f "$p" ] && SMALI="$p" && break
done

echo -e "${C}APKEditor: $APKEDITOR${N}"
[ -n "$BAKSMALI" ] && echo -e "${C}baksmali:  $BAKSMALI${N}" || echo -e "${Y}baksmali:  not found (SecurePendingIntent patching unavailable)${N}"

# ---- STEP 1: HANDLE INPUT (XAPK or APK) --------------------
SPLITS_DIR="$WORK_DIR/_splits"
MERGED_APK="$WORK_DIR/_merged.apk"
OUTPUT_DIR="$WORK_DIR/output"

rm -rf "$SPLITS_DIR" "$MERGED_APK"
mkdir -p "$SPLITS_DIR" "$OUTPUT_DIR"

INPUT_EXT="${XAPK_FILE##*.}"

if [ "$INPUT_EXT" = "xapk" ]; then
  log "Extracting XAPK..."
  unzip -q -o "$XAPK_FILE" -d "$SPLITS_DIR"

  # Detect package name from manifest.json
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

  # Merge splits
  log "Merging split APKs..."
  java -jar "$APKEDITOR" m -i "$SPLITS_DIR" -o "$MERGED_APK"
  ok "Merged → $(du -h "$MERGED_APK" | cut -f1)"

elif [ "$INPUT_EXT" = "apk" ]; then
  cp "$XAPK_FILE" "$MERGED_APK"
  # Detect package from APK via aapt or APKEditor
  ORIG_PKG=$(java -jar "$APKEDITOR" info -i "$MERGED_APK" 2>/dev/null | grep -o 'package="[^"]*"' | head -1 | grep -o '"[^"]*"' | tr -d '"' || true)
  ok "Using APK directly → $(du -h "$MERGED_APK" | cut -f1)"
else
  err "Unsupported file type: .$INPUT_EXT (use .xapk or .apk)"
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
echo -e "${B}  Clones:  ${C}$NUM_CLONES${N}"
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
for i in $(seq 1 "$NUM_CLONES"); do
  CLONE_ID="clone${i}"
  CLONE_PKG="${ORIG_PKG}.${CLONE_ID}"
  CLONE_APK="$OUTPUT_DIR/${APP_NAME,,}-${CLONE_ID}.apk"
  DECOMPILED="$WORK_DIR/_decompiled_${CLONE_ID}"

  echo ""
  echo -e "${B}===========================================${N}"
  echo -e "${C}  Building: $CLONE_PKG ($i/$NUM_CLONES)${N}"
  echo -e "${B}===========================================${N}"

  # ---- FRESH DECOMPILE (raw dex mode) ----
  rm -rf "$DECOMPILED"
  log "Decompiling (raw mode, fresh for clone${i})..."
  java -jar "$APKEDITOR" d -t raw -i "$MERGED_APK" -o "$DECOMPILED"
  ok "Decompiled"

  # ---- MANIFEST PATCHES ----

  # 1) Package name
  sed -i "s|package=\"${ORIG_PKG}\"|package=\"${CLONE_PKG}\"|" "$DECOMPILED/AndroidManifest.xml"

  # 2) Authorities
  sed -i "s|android:authorities=\"${ORIG_PKG}\.|android:authorities=\"${CLONE_PKG}.|g" "$DECOMPILED/AndroidManifest.xml"
  sed -i "s|android:authorities=\"${ORIG_PKG}\"|android:authorities=\"${CLONE_PKG}\"|g" "$DECOMPILED/AndroidManifest.xml"

  # 3) Custom permissions
  sed -i "s|${ORIG_PKG}\.permission\.|${CLONE_PKG}.permission.|g" "$DECOMPILED/AndroidManifest.xml"
  sed -i "s|${ORIG_PKG}\.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION|${CLONE_PKG}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION|g" "$DECOMPILED/AndroidManifest.xml"

  # 4) Catch-all for any other custom permissions
  sed -i "s|android:name=\"${ORIG_PKG}\.\([A-Z_]*PERMISSION[A-Z_]*\)\"|android:name=\"${CLONE_PKG}.\1\"|g" "$DECOMPILED/AndroidManifest.xml"

  # 5) extractNativeLibs=true
  sed -i 's|android:extractNativeLibs="false"|android:extractNativeLibs="true"|' "$DECOMPILED/AndroidManifest.xml"

  # 6) Samsung multiwindow cleanup
  sed -i '/<package android:name="com.samsung.android.mapsagent"/d' "$DECOMPILED/AndroidManifest.xml"
  sed -i '/com\.samsung\.android\.mapsagent\.permission\.READ_APP_INFO/d' "$DECOMPILED/AndroidManifest.xml"

  ok "Manifest patched"

  # ---- SECUREPENDINGINTENT PATCH (via baksmali/smali) ----
  # In raw mode, dex files are at root/classes*.dex
  # We find which dex has SecurePendingIntent, decompile just that one,
  # patch it, recompile, and swap it back
  if [ -n "$BAKSMALI" ] && [ -n "$SMALI" ]; then
    DEX_DIR="$DECOMPILED/root"
    [ ! -d "$DEX_DIR" ] && DEX_DIR="$DECOMPILED"

    PATCHED_ANY=false
    for dex_file in "$DEX_DIR"/classes*.dex; do
      [ ! -f "$dex_file" ] && continue

      # Quick check: does this dex contain SecurePendingIntent?
      if strings "$dex_file" 2>/dev/null | grep -q 'SecurePendingIntent'; then
        DEX_NAME=$(basename "$dex_file")
        SMALI_TMP="$WORK_DIR/_smali_tmp_${CLONE_ID}"
        rm -rf "$SMALI_TMP"

        log "Patching SecurePendingIntent in $DEX_NAME..."

        # Decompile just this dex
        java -jar "$BAKSMALI" d "$dex_file" -o "$SMALI_TMP" 2>/dev/null

        # Find and patch throw → return-void
        SECURE_FILES=$(grep -rln 'SecurePendingIntent' "$SMALI_TMP/" 2>/dev/null || true)
        if [ -n "$SECURE_FILES" ]; then
          while IFS= read -r sf; do
            if grep -q 'throw ' "$sf"; then
              python3 -c "
import re
with open('$sf', 'r') as f:
    content = f.read()
content = re.sub(
    r'(invoke[^\n]*SecurePendingIntent[^\n]*\n(?:[^\n]*\n){0,10}?[^\n]*)throw (v\d+)',
    r'\1return-void #patched \2',
    content
)
with open('$sf', 'w') as f:
    f.write(content)
" 2>/dev/null || true
              ok "Patched $(basename "$sf")"
              PATCHED_ANY=true
            fi
          done <<< "$SECURE_FILES"

          # Recompile just this dex and swap it back
          java -jar "$SMALI" a "$SMALI_TMP" -o "$dex_file" 2>/dev/null
          ok "Recompiled $DEX_NAME"
        fi
        rm -rf "$SMALI_TMP"
      fi
    done

    if ! $PATCHED_ANY; then
      log "No SecurePendingIntent found — skipping smali patch"
    fi
  else
    # Check if patching would be needed
    DEX_DIR="$DECOMPILED/root"
    [ ! -d "$DEX_DIR" ] && DEX_DIR="$DECOMPILED"
    NEEDS_PATCH=false
    for dex_file in "$DEX_DIR"/classes*.dex; do
      [ ! -f "$dex_file" ] && continue
      if strings "$dex_file" 2>/dev/null | grep -q 'SecurePendingIntent'; then
        NEEDS_PATCH=true
        break
      fi
    done
    if $NEEDS_PATCH; then
      warn "SecurePendingIntent found but baksmali.jar/smali.jar not available"
      warn "Download from: https://bitbucket.org/JesusFreke/smali/downloads/"
      warn "Place baksmali.jar and smali.jar in $WORK_DIR"
    fi
  fi

  # ---- REBUILD ----
  log "Rebuilding APK..."
  UNSIGNED="$WORK_DIR/_${CLONE_ID}-unsigned.apk"
  rm -f "$UNSIGNED"
  java -jar "$APKEDITOR" b -i "$DECOMPILED" -o "$UNSIGNED"
  ok "Built"

  # ---- UNCOMPRESSED .so INJECTION ----
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

  # ---- SIGN ----
  log "Signing..."
  apksigner sign --ks "$KEYSTORE" --ks-pass "pass:${KS_PASS}" \
    --ks-key-alias "$KS_ALIAS" "$UNSIGNED" 2>/dev/null
  mv "$UNSIGNED" "$CLONE_APK"
  ok "Signed → $(basename "$CLONE_APK") ($(du -h "$CLONE_APK" | cut -f1))"

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
rm -rf "$SPLITS_DIR"

echo ""
echo -e "${B}========================================${N}"
echo -e "${G}  Build complete!${N}"
echo -e "${B}========================================${N}"
echo ""
echo -e "  ${B}Clones:${N}"
ls -lh "$OUTPUT_DIR/"*.apk 2>/dev/null | awk '{print "    " $5 "  " $NF}'
echo ""
echo -e "  ${B}Manual install:${N}"
echo -e "    adb install output/${APP_NAME,,}-cloneN.apk"
echo ""
echo -e "  ${B}Private Space:${N}"
echo -e "    adb push output/${APP_NAME,,}-cloneN.apk /data/local/tmp/c.apk"
echo -e "    adb shell su -c 'pm install --user 10 /data/local/tmp/c.apk'"
echo ""
