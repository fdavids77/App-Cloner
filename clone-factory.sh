#!/bin/bash
# clone-factory.sh — Universal Android App Cloner v2.1
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME=""
INPUT_FILE=""
CLONE_COUNT=6
DO_INSTALL=false
PRIVATE_SPACE_USER=""
DRY_RUN=false
KEYSTORE="$SCRIPT_DIR/my.keystore"
KEY_ALIAS="wakey"
KEY_PASS="yourpassword"
WORK_DIR="$SCRIPT_DIR/work"
OUTPUT_DIR="$SCRIPT_DIR/output"
VERSIONS_FILE="$SCRIPT_DIR/versions.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${BLUE}[•]${NC} $*"; }
success() { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --app)           APP_NAME="$2"; shift 2 ;;
    --input)         INPUT_FILE="$(realpath "$2")"; shift 2 ;;
    --count)         CLONE_COUNT="$2"; shift 2 ;;
    --install)       DO_INSTALL=true; shift ;;
    --private-space) PRIVATE_SPACE_USER="$2"; shift 2 ;;
    --dry-run)       DRY_RUN=true; shift ;;
    --keystore)      KEYSTORE="$2"; shift 2 ;;
    --key-alias)     KEY_ALIAS="$2"; shift 2 ;;
    --key-pass)      KEY_PASS="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 --app <name> --input <file> --count <n> [--install] [--private-space <uid>] [--dry-run]"
      exit 0 ;;
    *) error "Unknown argument: $1" ;;
  esac
done

[ -z "$APP_NAME" ]     && error "Missing --app"
[ -z "$INPUT_FILE" ]   && error "Missing --input"
[ ! -f "$INPUT_FILE" ] && error "File not found: $INPUT_FILE"

BUNDLE_DIR="$WORK_DIR/$APP_NAME/bundle"
mkdir -p "$BUNDLE_DIR" "$OUTPUT_DIR/$APP_NAME"

# ── Extract ───────────────────────────────────────────────────────────────────
log "Extracting: $INPUT_FILE"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR"
unzip -o -q "$INPUT_FILE" -d "$BUNDLE_DIR"
APK_COUNT=$(find "$BUNDLE_DIR" -maxdepth 1 -name "*.apk" | wc -l)
log "APKs found: $APK_COUNT"
[ "$APK_COUNT" -eq 0 ] && cp "$INPUT_FILE" "$BUNDLE_DIR/base.apk"

# ── Get base APK ──────────────────────────────────────────────────────────────
BASE_APK="$BUNDLE_DIR/base.apk"
[ ! -f "$BASE_APK" ] && BASE_APK=$(find "$BUNDLE_DIR" -maxdepth 1 -name "*.apk" | grep -v "split_\|config\." | head -1)
[ ! -f "$BASE_APK" ] && BASE_APK=$(find "$BUNDLE_DIR" -maxdepth 1 -name "*.apk" | head -1)
[ -z "$BASE_APK" ] && error "No base APK found"

# ── Detect package + version ──────────────────────────────────────────────────
ORIG_PKG=$(aapt dump badging "$BASE_APK" 2>/dev/null | grep "^package:" | head -1 | grep -o "name='[^']*'" | head -1 | sed "s/name='//" | sed "s/'.*//")
VERSION=$(aapt dump badging "$BASE_APK" 2>/dev/null | grep "versionName" | sed "s/.*versionName='//" | sed "s/'.*//")
[ -z "$ORIG_PKG" ] && error "Could not detect package name from $BASE_APK"

# ── Merge ─────────────────────────────────────────────────────────────────────
MERGED_APK="$WORK_DIR/$APP_NAME/merged.apk"
APK_EDITOR="$SCRIPT_DIR/APKEditor.jar"
[ ! -f "$APK_EDITOR" ] && error "APKEditor.jar not found. Run prepare.sh first."

if [ "$APK_COUNT" -le 1 ]; then
  log "Single APK — no merge needed"
  cp "$BASE_APK" "$MERGED_APK"
else
  log "Merging $APK_COUNT splits..."
  java -jar "$APK_EDITOR" m -i "$BUNDLE_DIR/" -o "$MERGED_APK" 2>&1 | \
    grep -E "Merging|Saved|Error|Warning" || true
  success "Merged: $(du -sh "$MERGED_APK" | cut -f1)"
fi

# ── Build clone ───────────────────────────────────────────────────────────────
build_clone() {
  local num="$1"
  local new_pkg="${ORIG_PKG}.clone${num}"
  local clone_dir="$WORK_DIR/$APP_NAME/clone${num}"
  local unsigned="$OUTPUT_DIR/$APP_NAME/${APP_NAME}_clone${num}_unsigned.apk"
  local aligned="$OUTPUT_DIR/$APP_NAME/${APP_NAME}_clone${num}_aligned.apk"
  local out="$OUTPUT_DIR/$APP_NAME/${APP_NAME}_clone${num}_signed.apk"

  [ "$DRY_RUN" = true ] && warn "[DRY RUN] Would build: $new_pkg" && return 0

  log "Building clone $num → $new_pkg"
  rm -rf "$clone_dir"
  apktool d "$MERGED_APK" -o "$clone_dir" --force -q

  sed -i "s/package=\"${ORIG_PKG}\"/package=\"${new_pkg}\"/" "${clone_dir}/AndroidManifest.xml"
  sed -i "s/android:authorities=\"${ORIG_PKG}\./android:authorities=\"${new_pkg}./g" "${clone_dir}/AndroidManifest.xml"
  sed -i 's/android:extractNativeLibs="false"/android:extractNativeLibs="true"/' "${clone_dir}/AndroidManifest.xml"
  sed -i '/com.sec.android.app.multiwindow/d' "${clone_dir}/AndroidManifest.xml"
  sed -i '/<permission /d' "${clone_dir}/AndroidManifest.xml"
  sed -i 's/android:requiredSplitTypes="[^"]*"//g' "${clone_dir}/AndroidManifest.xml"
  sed -i 's/android:splitTypes="[^"]*"//g' "${clone_dir}/AndroidManifest.xml"
  sed -i "s/packageId: ${ORIG_PKG}$/packageId: ${new_pkg}/" "${clone_dir}/apktool.yml"

  local patch_file="$SCRIPT_DIR/patches/${APP_NAME}.py"
  if [ -f "$patch_file" ]; then
    log "  Applying patches/${APP_NAME}.py..."
    python3 "$patch_file" "$clone_dir" "$ORIG_PKG" "$new_pkg"
  fi

  apktool b "$clone_dir" -o "$unsigned" -q

  if unzip -l "$unsigned" 2>/dev/null | grep -q "lib/arm64-v8a/.*\.so"; then
    zip -d "$unsigned" "lib/arm64-v8a/*.so" 2>/dev/null || true
    cd "$clone_dir"
    find lib/arm64-v8a/ -name "*.so" 2>/dev/null | xargs zip -0 "$unsigned" 2>/dev/null || true
    cd "$SCRIPT_DIR"
  fi

  zipalign -f -v 4 "$unsigned" "$aligned" > /dev/null
  apksigner sign \
    --ks "$KEYSTORE" --ks-key-alias "$KEY_ALIAS" \
    --ks-pass "pass:${KEY_PASS}" --key-pass "pass:${KEY_PASS}" \
    --out "$out" "$aligned" 2>/dev/null
  rm -f "$unsigned" "$aligned"
  success "Clone $num → $(du -sh "$out" | cut -f1)"
}

# ── Install clone ─────────────────────────────────────────────────────────────
install_clone() {
  local apk="$1"
  local num="$2"
  local pkg="${ORIG_PKG}.clone${num}"

  adb uninstall "$pkg" 2>/dev/null || true

  if [ -n "$PRIVATE_SPACE_USER" ]; then
    local fname
    fname=$(basename "$apk")
    adb push "$apk" "/sdcard/$fname" > /dev/null 2>&1
    adb shell su -c "cp /sdcard/$fname /data/local/tmp/$fname && chmod 644 /data/local/tmp/$fname"
    adb shell pm install --user "$PRIVATE_SPACE_USER" "/data/local/tmp/$fname" 2>&1 | grep -q "Success" \
      && success "Clone $num → Private Space (user $PRIVATE_SPACE_USER)" \
      || warn "Clone $num install failed"
    adb shell su -c "rm -f /data/local/tmp/$fname" 2>/dev/null || true
    adb shell rm -f "/sdcard/$fname" 2>/dev/null || true
  else
    adb install --no-incremental "$apk" 2>&1 | grep -q "Success" \
      && success "Clone $num installed" \
      || warn "Clone $num install failed"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║       Clone Factory v2.1                ║"
echo "╚══════════════════════════════════════════╝"
echo "  App:     $APP_NAME"
echo "  Package: $ORIG_PKG"
echo "  Version: $VERSION"
echo "  Clones:  $CLONE_COUNT"
[ "$DO_INSTALL" = true ]    && echo "  Install: yes"
[ -n "$PRIVATE_SPACE_USER" ] && echo "  PS User: $PRIVATE_SPACE_USER"
[ "$DRY_RUN" = true ]       && echo "  Mode:    DRY RUN"
echo ""

log "Building $CLONE_COUNT clones..."
echo ""
for i in $(seq 1 "$CLONE_COUNT"); do
  build_clone "$i"
done

if [ "$DO_INSTALL" = true ]; then
  echo ""
  log "Installing..."
  if ! adb devices | grep -q "device$"; then
    warn "No device connected — skipping install"
  else
    for i in $(seq 1 "$CLONE_COUNT"); do
      local_apk="$OUTPUT_DIR/$APP_NAME/${APP_NAME}_clone${i}_signed.apk"
      [ -f "$local_apk" ] && install_clone "$local_apk" "$i"
    done
  fi
fi

# Save version
python3 -c "
import json, datetime
try: data = json.load(open('$VERSIONS_FILE'))
except: data = {}
data['$APP_NAME'] = {'version': '$VERSION', 'count': $CLONE_COUNT, 'built_at': str(datetime.datetime.now())}
json.dump(data, open('$VERSIONS_FILE', 'w'), indent=2)
" 2>/dev/null || true

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║         Build Complete ✅               ║"
echo "╚══════════════════════════════════════════╝"
echo "  $APP_NAME v$VERSION — $CLONE_COUNT clones"
echo "  Output: $OUTPUT_DIR/$APP_NAME/"
echo ""
ls -lh "$OUTPUT_DIR/$APP_NAME/"*_signed.apk 2>/dev/null | awk '{print "  "$NF" ("$5")"}'
echo ""
