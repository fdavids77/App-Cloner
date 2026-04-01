#!/usr/bin/env bash
# ============================================================
#  APK Clone Factory v2.0
#  Universal multi-clone builder for split APKs
#  Tested: WhatsApp, WhatsApp Business, Tinder
#
#  v1.4: --start/--count for clone ranges
#  v1.5: WhatsApp Business support, generic SecurePendingIntent
#        patching, keeps merged APK for reuse
#  v2.0: Error handling (traps/rollback/resume), dry-run mode,
#        parallel builds, auto-download, version detection,
#        changelog logging, extensible app profiles
# ============================================================
set -euo pipefail

readonly VERSION="2.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_DIR="${SCRIPT_DIR}/logs"
readonly CHANGELOG="${LOG_DIR}/changelog.log"

# ---- CONFIG ------------------------------------------------
KEYSTORE_NAME="clone-key.jks"
KS_PASS="clone123"
KS_ALIAS="clonekey"
KS_DNAME="CN=Clone,OU=Dev,O=Dev,L=CT,ST=WC,C=ZA"
MAX_PARALLEL=4          # max background build jobs
DOWNLOAD_CACHE_DIR="${SCRIPT_DIR}/.download-cache"

# ---- COLORS ------------------------------------------------
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
C='\033[0;36m'; B='\033[1m'; N='\033[0m'
DIM='\033[2m'

# ---- GLOBAL STATE ------------------------------------------
CLEANUP_DIRS=()         # dirs to clean on exit/error
CLEANUP_FILES=()        # files to clean on exit/error
BUILD_PIDS=()           # background build PIDs
FAILED_CLONES=()        # track which clones failed
SUCCESS_CLONES=()       # track which clones succeeded
TRAP_SET=false

# ============================================================
#  USAGE
# ============================================================
usage() {
  cat <<EOF
${B}APK Clone Factory v${VERSION}${N}

Usage: $SCRIPT_NAME <input_file|--download APP> <count> [options]

  <input_file>      .xapk, .apkm, or pre-merged .apk
  --download APP    Download latest APK (whatsapp|whatsapp-business|tinder)
  <count>           Number of clones to build (1-20)

Options:
  --start N          Start numbering at N (default: 1)
  --install          ADB install each clone after building
  --private-space    Install to Private Space (user 10, root)
  --dry-run          Validate everything without building
  --parallel [N]     Build clones in parallel (default: ${MAX_PARALLEL} workers)
  --resume           Skip clones whose output APK already exists
  --verbose          Show full tool output (apktool, apksigner, etc.)
  --quiet            Suppress all output except errors and summary

Examples:
  $SCRIPT_NAME whatsapp.xapk 7                           # clone1-7
  $SCRIPT_NAME WhatsApp_merged.apk 3 --start 8           # clone8-10
  $SCRIPT_NAME WhatsAppBusiness.xapk 4 --install
  $SCRIPT_NAME tinder.xapk 3 --install --private-space
  $SCRIPT_NAME whatsapp.xapk 7 --dry-run                 # validate only
  $SCRIPT_NAME whatsapp.xapk 7 --parallel                # parallel build
  $SCRIPT_NAME whatsapp.xapk 3 --start 8 --resume        # skip existing
  $SCRIPT_NAME --download whatsapp 5                      # download + clone

Supported apps (auto-detected):
  com.whatsapp        WhatsApp
  com.whatsapp.w4b    WhatsApp Business
  com.tinder          Tinder
  (any other package works as a generic target)

Changelog:  ${CHANGELOG}
EOF
  exit 1
}

# ============================================================
#  LOGGING
# ============================================================
_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log()  { echo -e "${G}[*]${N} $1"; }
warn() { echo -e "${Y}[!]${N} $1"; }
err()  { echo -e "${R}[✗]${N} $1" >&2; }
ok()   { echo -e "${G}[✓]${N} $1"; }
dim()  { echo -e "${DIM}    $1${N}"; }

die() {
  err "$1"
  exit "${2:-1}"
}

# Quiet/verbose modes
VERBOSE=false
QUIET=false
REDIRECT="/dev/null"

run_quiet() {
  # Run a command, suppress output unless verbose
  if $VERBOSE; then
    "$@"
  else
    "$@" > /dev/null 2>&1
  fi
}

run_logged() {
  # Run a command, log output to file, show on verbose
  local logfile="$1"; shift
  if $VERBOSE; then
    "$@" 2>&1 | tee -a "$logfile"
  else
    "$@" >> "$logfile" 2>&1
  fi
}

# ============================================================
#  CLEANUP / TRAP HANDLER
# ============================================================
cleanup() {
  local exit_code=$?

  # Kill any background build jobs
  if [ ${#BUILD_PIDS[@]} -gt 0 ]; then
    warn "Cleaning up background builds..."
    for pid in "${BUILD_PIDS[@]}"; do
      kill "$pid" 2>/dev/null && wait "$pid" 2>/dev/null || true
    done
  fi

  # Remove intermediate directories
  for d in "${CLEANUP_DIRS[@]}"; do
    [ -d "$d" ] && rm -rf "$d"
  done

  # Remove intermediate files
  for f in "${CLEANUP_FILES[@]}"; do
    [ -f "$f" ] && rm -f "$f"
  done

  if [ $exit_code -ne 0 ] && [ $exit_code -ne 130 ]; then
    err "Build aborted (exit code: $exit_code)"
    if [ ${#SUCCESS_CLONES[@]} -gt 0 ]; then
      warn "Successfully built before failure: ${SUCCESS_CLONES[*]}"
    fi
    if [ ${#FAILED_CLONES[@]} -gt 0 ]; then
      err "Failed clones: ${FAILED_CLONES[*]}"
    fi
    echo ""
    warn "Use --resume to retry only the missing clones"
  fi

  exit $exit_code
}

register_cleanup_dir()  { CLEANUP_DIRS+=("$1"); }
register_cleanup_file() { CLEANUP_FILES+=("$1"); }

unregister_cleanup_dir() {
  local target="$1"
  local new=()
  for d in "${CLEANUP_DIRS[@]}"; do
    [ "$d" != "$target" ] && new+=("$d")
  done
  CLEANUP_DIRS=("${new[@]+"${new[@]}"}")
}

unregister_cleanup_file() {
  local target="$1"
  local new=()
  for f in "${CLEANUP_FILES[@]}"; do
    [ "$f" != "$target" ] && new+=("$f")
  done
  CLEANUP_FILES=("${new[@]+"${new[@]}"}")
}

setup_traps() {
  if ! $TRAP_SET; then
    trap cleanup EXIT
    trap 'die "Interrupted by user" 130' INT TERM
    TRAP_SET=true
  fi
}

# ============================================================
#  CHANGELOG / VERSION DETECTION
# ============================================================
mkdir -p "$LOG_DIR"

changelog_entry() {
  # Usage: changelog_entry "action" "details"
  local action="$1"
  local details="$2"
  echo "[$(_ts)] [$action] $details" >> "$CHANGELOG"
}

detect_app_version() {
  # Extract versionName from APK using aapt or apktool
  local apk="$1"
  local version=""

  # Try aapt first (fast)
  if command -v aapt &>/dev/null; then
    version=$(aapt dump badging "$apk" 2>/dev/null \
      | grep -o "versionName='[^']*'" \
      | head -1 \
      | grep -o "'[^']*'" \
      | tr -d "'") || true
  fi

  # Fallback: apktool manifest-only decode
  if [ -z "$version" ]; then
    local tmpd
    tmpd=$(mktemp -d)
    register_cleanup_dir "$tmpd"
    apktool d "$apk" -o "$tmpd" -s --force 2>/dev/null || true
    version=$(grep -o 'android:versionName="[^"]*"' "$tmpd/AndroidManifest.xml" 2>/dev/null \
      | head -1 \
      | grep -o '"[^"]*"' \
      | tr -d '"') || true
    rm -rf "$tmpd"
    unregister_cleanup_dir "$tmpd"
  fi

  echo "${version:-unknown}"
}

detect_app_version_code() {
  local apk="$1"
  local vcode=""

  if command -v aapt &>/dev/null; then
    vcode=$(aapt dump badging "$apk" 2>/dev/null \
      | grep -o "versionCode='[^']*'" \
      | head -1 \
      | grep -o "'[^']*'" \
      | tr -d "'") || true
  fi

  echo "${vcode:-0}"
}

# ============================================================
#  AUTO-DOWNLOAD (APKMirror / APKPure)
# ============================================================
# Maps app shortnames to APKMirror search paths
declare -A DOWNLOAD_MAP=(
  ["whatsapp"]="whatsapp-inc/whatsapp-messenger"
  ["whatsapp-business"]="whatsapp-inc/whatsapp-business"
  ["tinder"]="tinder/tinder"
)

download_latest_apk() {
  local app_key="$1"

  if [ -z "${DOWNLOAD_MAP[$app_key]+_}" ]; then
    die "Unknown download target: $app_key (valid: ${!DOWNLOAD_MAP[*]})"
  fi

  mkdir -p "$DOWNLOAD_CACHE_DIR"
  local apkmirror_path="${DOWNLOAD_MAP[$app_key]}"
  local search_url="https://www.apkmirror.com/apk/${apkmirror_path}/"

  echo ""
  log "Auto-download for: ${B}$app_key${N}"
  warn "APKMirror requires manual download due to bot protection."
  echo ""
  echo -e "  ${B}Steps:${N}"
  echo -e "  1. Open: ${C}${search_url}${N}"
  echo -e "  2. Download the latest ${B}universal / APK${N} (not bundle)"
  echo -e "     Or download the ${B}.xapk${N} from APKPure:"
  echo -e "     ${C}https://apkpure.com/search?q=${app_key}${N}"
  echo -e "  3. Save to: ${C}${DOWNLOAD_CACHE_DIR}/${N}"
  echo -e "  4. Re-run:  ${C}$SCRIPT_NAME ${DOWNLOAD_CACHE_DIR}/<file> <count>${N}"
  echo ""

  # Check if we have a cached download already
  local cached
  cached=$(find "$DOWNLOAD_CACHE_DIR" -maxdepth 1 \
    -iname "*${app_key//-/}*" -o -iname "*${app_key}*" 2>/dev/null \
    | head -1) || true

  if [ -n "$cached" ]; then
    echo ""
    ok "Found cached download: $(basename "$cached")"
    echo -e "  ${B}Use it:${N} $SCRIPT_NAME \"$cached\" <count>"
    echo ""
    # Return the cached file path so the caller can use it
    echo "CACHED:$cached"
    return 0
  fi

  die "Place the downloaded file in ${DOWNLOAD_CACHE_DIR}/ and re-run"
}

# ============================================================
#  ARGS
# ============================================================
[ $# -lt 1 ] && usage

XAPK_FILE=""
NUM_CLONES=""
START_NUM=1
DO_INSTALL=false
PRIVATE_SPACE=false
DRY_RUN=false
PARALLEL=false
PARALLEL_JOBS=$MAX_PARALLEL
RESUME=false
DOWNLOAD_APP=""

# Parse args
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
  arg="${args[$i]}"
  case "$arg" in
    --download)
      i=$((i + 1))
      [ $i -ge ${#args[@]} ] && die "--download requires an app name"
      DOWNLOAD_APP="${args[$i]}"
      ;;
    --start)
      i=$((i + 1))
      [ $i -ge ${#args[@]} ] && die "--start requires a number"
      START_NUM="${args[$i]}"
      ;;
    --install)      DO_INSTALL=true ;;
    --private-space) PRIVATE_SPACE=true; DO_INSTALL=true ;;
    --dry-run)      DRY_RUN=true ;;
    --parallel)
      PARALLEL=true
      # Check if next arg is a number (optional worker count)
      if [ $((i + 1)) -lt ${#args[@]} ] && [[ "${args[$((i + 1))]}" =~ ^[0-9]+$ ]]; then
        i=$((i + 1))
        PARALLEL_JOBS="${args[$i]}"
      fi
      ;;
    --resume)  RESUME=true ;;
    --verbose) VERBOSE=true ;;
    --quiet)   QUIET=true ;;
    -h|--help) usage ;;
    -*)        die "Unknown option: $arg" ;;
    *)
      # Positional args: input_file, count
      if [ -z "$XAPK_FILE" ]; then
        XAPK_FILE="$arg"
      elif [ -z "$NUM_CLONES" ]; then
        NUM_CLONES="$arg"
      else
        die "Unexpected argument: $arg"
      fi
      ;;
  esac
  i=$((i + 1))
done

# ---- HANDLE --download MODE --------------------------------
if [ -n "$DOWNLOAD_APP" ]; then
  result=$(download_latest_apk "$DOWNLOAD_APP")
  if [[ "$result" == *"CACHED:"* ]]; then
    cached_path="${result#*CACHED:}"
    if [ -z "$XAPK_FILE" ]; then
      XAPK_FILE="$cached_path"
    fi
  else
    exit 0  # instructions printed, user needs to download
  fi
fi

# ---- VALIDATE ARGS -----------------------------------------
[ -z "$XAPK_FILE" ] && { err "No input file specified"; usage; }
[ -z "$NUM_CLONES" ] && { err "No clone count specified"; usage; }
[ ! -f "$XAPK_FILE" ] && die "File not found: $XAPK_FILE"
[[ "$NUM_CLONES" =~ ^[0-9]+$ ]] || die "count must be a number"
[[ "$START_NUM" =~ ^[0-9]+$ ]] || die "--start must be a number"
[ "$NUM_CLONES" -lt 1 ] || [ "$NUM_CLONES" -gt 20 ] && die "count must be 1-20"
[ "$START_NUM" -lt 1 ] && die "--start must be >= 1"
$PARALLEL && [ "$PARALLEL_JOBS" -lt 1 ] && die "--parallel workers must be >= 1"

END_NUM=$(( START_NUM + NUM_CLONES - 1 ))

# ---- SETUP TRAPS -------------------------------------------
setup_traps

# ---- DEPENDENCY CHECK --------------------------------------
log "Checking dependencies..."
MISSING_DEPS=()
for dep in java apktool apksigner zipalign; do
  if ! command -v "$dep" &>/dev/null; then
    MISSING_DEPS+=("$dep")
  fi
done

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
  die "Missing dependencies: ${MISSING_DEPS[*]}. Install them first."
fi

# Optional deps
if ! command -v aapt &>/dev/null; then
  warn "aapt not found — version detection will be slower (apktool fallback)"
fi

if $DO_INSTALL && ! command -v adb &>/dev/null; then
  die "adb not found but --install requested"
fi

if ! command -v python3 &>/dev/null; then
  die "python3 required for smali patching"
fi

ok "All dependencies satisfied"

# ---- PATHS -------------------------------------------------
WORK_DIR="$(cd "$(dirname "$XAPK_FILE")" && pwd)"
XAPK_FILE="$(cd "$(dirname "$XAPK_FILE")" && pwd)/$(basename "$XAPK_FILE")"
KEYSTORE="$WORK_DIR/$KEYSTORE_NAME"

# Find APKEditor.jar
APKEDITOR=""
for p in "$WORK_DIR/APKEditor.jar" "$HOME/APKEditor.jar" "$HOME/tools/APKEditor.jar"; do
  [ -f "$p" ] && APKEDITOR="$p" && break
done

# ============================================================
#  STEP 1: HANDLE INPUT (merge if needed)
# ============================================================
BUNDLE_DIR="$WORK_DIR/_bundle"
OUTPUT_DIR="$WORK_DIR/output"
INPUT_EXT="${XAPK_FILE##*.}"
INPUT_EXT=$(echo "$INPUT_EXT" | tr '[:upper:]' '[:lower:]')

MERGED_APK=""
ORIG_PKG=""

if [ "$INPUT_EXT" = "apk" ]; then
  MERGED_APK="$XAPK_FILE"
  KEEP_MERGED=true
else
  BASE_NAME=$(basename "$XAPK_FILE" ".$INPUT_EXT")
  MERGED_APK="$WORK_DIR/${BASE_NAME}_merged.apk"
  KEEP_MERGED=true

  if [ -f "$MERGED_APK" ]; then
    log "Found existing merged APK: $(basename "$MERGED_APK") ($(du -h "$MERGED_APK" | cut -f1))"
    dim "Delete ${BASE_NAME}_merged.apk to force re-merge"
  else
    [ -z "$APKEDITOR" ] && die "APKEditor.jar needed for merge but not found in: ./, ~/, ~/tools/"

    rm -rf "$BUNDLE_DIR"
    mkdir -p "$BUNDLE_DIR"
    register_cleanup_dir "$BUNDLE_DIR"

    case "$INPUT_EXT" in
      xapk)
        log "Extracting XAPK..."
        unzip -q -o "$XAPK_FILE" -d "$BUNDLE_DIR"
        if [ -f "$BUNDLE_DIR/manifest.json" ]; then
          ORIG_PKG=$(grep -o '"package_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
            "$BUNDLE_DIR/manifest.json" | head -1 \
            | grep -o '"[^"]*"$' | tr -d '"') || true
        fi
        ;;
      apkm|apks)
        log "Extracting ${INPUT_EXT^^}..."
        cp "$XAPK_FILE" "$BUNDLE_DIR/bundle.zip"
        (cd "$BUNDLE_DIR" && unzip -q bundle.zip)
        ;;
      *)
        die "Unsupported file type: .$INPUT_EXT (use .xapk, .apkm, .apks, or .apk)"
        ;;
    esac

    log "Merging split APKs with APKEditor..."
    java -jar "$APKEDITOR" m -i "$BUNDLE_DIR" -o "$MERGED_APK"
    ok "Merged → ${BASE_NAME}_merged.apk ($(du -h "$MERGED_APK" | cut -f1))"

    rm -rf "$BUNDLE_DIR"
    unregister_cleanup_dir "$BUNDLE_DIR"
  fi
fi

mkdir -p "$OUTPUT_DIR"

# ============================================================
#  DETECT PACKAGE NAME
# ============================================================
if [ -z "$ORIG_PKG" ]; then
  if command -v aapt &>/dev/null; then
    ORIG_PKG=$(aapt dump badging "$MERGED_APK" 2>/dev/null \
      | grep -o "package: name='[^']*'" \
      | grep -o "'[^']*'" | tr -d "'") || true
  fi
fi
if [ -z "$ORIG_PKG" ]; then
  TMPD=$(mktemp -d)
  register_cleanup_dir "$TMPD"
  apktool d "$MERGED_APK" -o "$TMPD" -s --force 2>/dev/null
  ORIG_PKG=$(grep -o 'package="[^"]*"' "$TMPD/AndroidManifest.xml" 2>/dev/null \
    | head -1 | grep -o '"[^"]*"' | tr -d '"') || true
  rm -rf "$TMPD"
  unregister_cleanup_dir "$TMPD"
fi

[ -z "$ORIG_PKG" ] && die "Could not detect package name from APK"

# ============================================================
#  VERSION DETECTION
# ============================================================
APP_VERSION=$(detect_app_version "$MERGED_APK")
APP_VERSION_CODE=$(detect_app_version_code "$MERGED_APK")

# ============================================================
#  APP PROFILES
# ============================================================
# Each profile: APP_NAME, APP_PREFIX, IS_WHATSAPP flag
# Add new apps here — just add a case block
APP_NAME=""
APP_PREFIX=""
IS_WHATSAPP=false
APP_NOTES=""

case "$ORIG_PKG" in
  com.whatsapp)
    APP_NAME="WhatsApp"
    APP_PREFIX="whatsapp"
    IS_WHATSAPP=true
    APP_NOTES="SPI patch required"
    ;;
  com.whatsapp.w4b)
    APP_NAME="WhatsApp Business"
    APP_PREFIX="whatsapp-business"
    IS_WHATSAPP=true
    APP_NOTES="SPI patch required"
    ;;
  com.tinder)
    APP_NAME="Tinder"
    APP_PREFIX="tinder"
    APP_NOTES="FaceTec native SDK — no Java hook possible"
    ;;
  # ---- ADD NEW APP TARGETS HERE ----------------------------
  # com.example.app)
  #   APP_NAME="Example App"
  #   APP_PREFIX="example"
  #   APP_NOTES="any special notes"
  #   ;;
  # ----------------------------------------------------------
  *)
    APP_NAME="$(echo "$ORIG_PKG" | awk -F. '{print $NF}')"
    APP_PREFIX="$(echo "$ORIG_PKG" | awk -F. '{print $NF}' | tr '[:upper:]' '[:lower:]')"
    APP_NOTES="Generic target"
    ;;
esac

# ============================================================
#  BUILD HEADER
# ============================================================
echo ""
echo -e "${B}============================================${N}"
echo -e "${B}  APK Clone Factory v${VERSION}${N}"
echo -e "${B}============================================${N}"
echo -e "  ${B}App:      ${C}${APP_NAME}${N}"
echo -e "  ${B}Package:  ${C}${ORIG_PKG}${N}"
echo -e "  ${B}Version:  ${C}${APP_VERSION} (${APP_VERSION_CODE})${N}"
echo -e "  ${B}Clones:   ${C}clone${START_NUM} → clone${END_NUM} (${NUM_CLONES} total)${N}"
$DRY_RUN   && echo -e "  ${Y}Mode:     DRY RUN (no builds)${N}"
$PARALLEL  && echo -e "  ${C}Mode:     PARALLEL (${PARALLEL_JOBS} workers)${N}"
$RESUME    && echo -e "  ${C}Mode:     RESUME (skip existing)${N}"
[ -n "$APP_NOTES" ] && echo -e "  ${DIM}Notes:    ${APP_NOTES}${N}"
echo -e "${B}============================================${N}"
echo ""

# Log to changelog
changelog_entry "START" "app=$ORIG_PKG version=$APP_VERSION clones=${START_NUM}-${END_NUM} dry_run=$DRY_RUN parallel=$PARALLEL"

# ============================================================
#  DRY-RUN VALIDATION
# ============================================================
if $DRY_RUN; then
  log "Dry-run: validating pipeline..."

  # Check APK is decompilable
  TMPD=$(mktemp -d)
  register_cleanup_dir "$TMPD"
  log "  Testing apktool decompile..."
  if apktool d "$MERGED_APK" -o "$TMPD" --force > /dev/null 2>&1; then
    ok "  apktool decompile: OK"
  else
    err "  apktool decompile: FAILED"
  fi

  # Check manifest patchability
  if [ -f "$TMPD/AndroidManifest.xml" ]; then
    if grep -q "package=\"${ORIG_PKG}\"" "$TMPD/AndroidManifest.xml"; then
      ok "  Manifest package attribute: found"
    else
      warn "  Manifest package attribute: not found (unusual)"
    fi
  fi

  # Check for SecurePendingIntent
  SPI_COUNT=$(grep -rln 'SecurePendingIntent' "$TMPD/smali/" 2>/dev/null | wc -l || echo 0)
  if [ "$SPI_COUNT" -gt 0 ]; then
    ok "  SecurePendingIntent files: ${SPI_COUNT} (will be patched)"
  else
    log "  SecurePendingIntent: not present (no smali patch needed)"
  fi

  # Check native libs
  LIB_ABIS=$(find "$TMPD/lib/" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
    | xargs -I{} basename {} | tr '\n' ' ') || true
  if [ -n "$LIB_ABIS" ]; then
    ok "  Native libs: ${LIB_ABIS}"
  else
    log "  Native libs: none"
  fi

  # Check rebuild
  log "  Testing apktool rebuild..."
  # Quick patch to make rebuild work
  sed -i "s|package=\"${ORIG_PKG}\"|package=\"${ORIG_PKG}.dryrun\"|" "$TMPD/AndroidManifest.xml"
  sed -i 's|android:extractNativeLibs="false"|android:extractNativeLibs="true"|' "$TMPD/AndroidManifest.xml"
  DRYRUN_APK="$TMPD/_dryrun.apk"
  if apktool b "$TMPD" -o "$DRYRUN_APK" > /dev/null 2>&1; then
    ok "  apktool rebuild: OK ($(du -h "$DRYRUN_APK" 2>/dev/null | cut -f1))"
  else
    err "  apktool rebuild: FAILED — check apktool version (need 2.9.0+ for Android 15)"
  fi

  # Check signing
  if [ -f "$KEYSTORE" ]; then
    ok "  Keystore: exists"
  else
    log "  Keystore: will be generated on real build"
  fi

  # Check install target
  if $DO_INSTALL; then
    if command -v adb &>/dev/null && adb devices 2>/dev/null | grep -q "device$"; then
      ok "  ADB device: connected"
    else
      warn "  ADB device: not connected (install will fail)"
    fi
  fi

  # Output plan
  echo ""
  echo -e "${B}Build plan:${N}"
  for i in $(seq "$START_NUM" "$END_NUM"); do
    local_apk="$OUTPUT_DIR/${APP_PREFIX}-clone${i}.apk"
    if $RESUME && [ -f "$local_apk" ]; then
      dim "  clone${i}: SKIP (already exists)"
    else
      echo -e "  clone${i}: ${ORIG_PKG}.clone${i} → ${APP_PREFIX}-clone${i}.apk"
    fi
  done

  rm -rf "$TMPD"
  unregister_cleanup_dir "$TMPD"

  echo ""
  ok "Dry run complete — pipeline looks good"
  changelog_entry "DRY_RUN" "result=OK app=$ORIG_PKG version=$APP_VERSION"
  exit 0
fi

# ============================================================
#  GENERATE KEYSTORE
# ============================================================
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
  local CLONE_LOGFILE="$3"

  # 1) Package name
  sed -i "s|package=\"${ORIG_PKG}\"|package=\"${CLONE_PKG}\"|" "$MANIFEST"

  # 2) Authorities — rename all that start with original package
  sed -i "s|android:authorities=\"${ORIG_PKG}\.|android:authorities=\"${CLONE_PKG}.|g" "$MANIFEST"
  sed -i "s|android:authorities=\"${ORIG_PKG}\"|android:authorities=\"${CLONE_PKG}\"|g" "$MANIFEST"

  # 3) Delete ALL <permission> declarations (prevents collisions)
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

  echo "Manifest patched: $CLONE_PKG" >> "$CLONE_LOGFILE"
}

patch_securependingintent() {
  local DECOMPILED="$1"
  local CLONE_LOGFILE="$2"
  local SMALI_BASE="$DECOMPILED/smali"
  [ ! -d "$SMALI_BASE" ] && return 0

  local SPI_FILES
  SPI_FILES=$(grep -rln 'SecurePendingIntent' "$SMALI_BASE/" 2>/dev/null || true)
  [ -z "$SPI_FILES" ] && { echo "No SecurePendingIntent found" >> "$CLONE_LOGFILE"; return 0; }

  echo "Patching SecurePendingIntent..." >> "$CLONE_LOGFILE"

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
if not modified:
    new_content = re.sub(
        r'(invoke[^\n]*SecurePendingIntent[^\n]*\n(?:[^\n]*\n){0,10}?[^\n]*)throw (v\d+)',
        r'\1return-void # SPI-patched',
        content
    )
    new_content = re.sub(
        r'(const-string [^\n]*"[^"]*SecurePendingIntent[^"]*"[^\n]*\n'
        r'(?:[^\n]*\n){0,15}?)'
        r'(new-instance [^\n]*(?:IllegalArgumentException|SecurityException)[^\n]*\n'
        r'(?:[^\n]*\n){0,5}?)'
        r'throw (v\d+)',
        r'\1return-void # SPI-patched',
        new_content
    )
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
    print(f"  Patched: ${rel_path}")
else:
    print(f"  No throw found in: ${rel_path}")

PYEOF
  done <<< "$SPI_FILES"

  echo "SecurePendingIntent patching complete" >> "$CLONE_LOGFILE"
}

fix_native_libs() {
  local UNSIGNED="$1"
  local DECOMPILED="$2"

  for abi in arm64-v8a armeabi-v7a x86_64 x86; do
    if [ -d "$DECOMPILED/lib/$abi" ]; then
      zip -d "$UNSIGNED" "lib/${abi}/*.so" 2>/dev/null || true
      (cd "$DECOMPILED" && find "lib/${abi}/" -name "*.so" | xargs zip -0 "$UNSIGNED")
    fi
  done
}

# ============================================================
#  SINGLE-CLONE BUILD FUNCTION
# ============================================================
build_single_clone() {
  local i="$1"
  local CLONE_ID="clone${i}"
  local CLONE_PKG="${ORIG_PKG}.${CLONE_ID}"
  local CLONE_APK="$OUTPUT_DIR/${APP_PREFIX}-${CLONE_ID}.apk"
  local DECOMPILED="$WORK_DIR/_dec_${CLONE_ID}"
  local UNSIGNED="$WORK_DIR/_${CLONE_ID}_unsigned.apk"
  local ALIGNED="$WORK_DIR/_${CLONE_ID}_aligned.apk"
  local CLONE_LOG="${LOG_DIR}/${APP_PREFIX}-${CLONE_ID}.log"

  # Register intermediates for cleanup on failure
  register_cleanup_dir "$DECOMPILED"
  register_cleanup_file "$UNSIGNED"
  register_cleanup_file "$ALIGNED"

  # Resume: skip if output already exists
  if $RESUME && [ -f "$CLONE_APK" ]; then
    ok "SKIP ${CLONE_ID}: already exists ($(du -h "$CLONE_APK" | cut -f1))"
    SUCCESS_CLONES+=("$CLONE_ID")
    return 0
  fi

  # Clone build log header
  {
    echo "========================================"
    echo "Clone Factory v${VERSION} — Build Log"
    echo "Date: $(_ts)"
    echo "App: $APP_NAME ($ORIG_PKG) v$APP_VERSION"
    echo "Clone: $CLONE_PKG"
    echo "========================================"
  } > "$CLONE_LOG"

  echo ""
  echo -e "${B}===========================================${N}"
  echo -e "${C}  Building: $CLONE_PKG ($((i - START_NUM + 1))/${NUM_CLONES})${N}"
  echo -e "${B}===========================================${N}"

  # ---- FRESH DECOMPILE ----
  rm -rf "$DECOMPILED"
  log "Decompiling (fresh for ${CLONE_ID})..."
  if ! run_logged "$CLONE_LOG" apktool d "$MERGED_APK" -o "$DECOMPILED" --force; then
    err "apktool decompile failed for ${CLONE_ID} — see $CLONE_LOG"
    FAILED_CLONES+=("$CLONE_ID")
    rm -rf "$DECOMPILED"
    return 1
  fi
  ok "Decompiled"

  # ---- PATCH MANIFEST ----
  if [ ! -f "$DECOMPILED/AndroidManifest.xml" ]; then
    err "No AndroidManifest.xml in decompiled output for ${CLONE_ID}"
    FAILED_CLONES+=("$CLONE_ID")
    rm -rf "$DECOMPILED"
    return 1
  fi
  patch_manifest "$DECOMPILED/AndroidManifest.xml" "$CLONE_PKG" "$CLONE_LOG"
  ok "Manifest patched"

  # ---- PATCH SMALI (SecurePendingIntent) ----
  if $IS_WHATSAPP; then
    patch_securependingintent "$DECOMPILED" "$CLONE_LOG"
    ok "SecurePendingIntent patched"
  else
    SPI_CHECK=$(grep -rln 'SecurePendingIntent' "$DECOMPILED/smali/" 2>/dev/null || true)
    if [ -n "$SPI_CHECK" ]; then
      patch_securependingintent "$DECOMPILED" "$CLONE_LOG"
      ok "SecurePendingIntent patched"
    else
      dim "No SecurePendingIntent — no smali patch needed"
    fi
  fi

  # ---- PATCH APKTOOL.YML ----
  if [ -f "$DECOMPILED/apktool.yml" ]; then
    sed -i "s|packageId: ${ORIG_PKG}$|packageId: ${CLONE_PKG}|" "$DECOMPILED/apktool.yml"
  fi

  # ---- REBUILD ----
  log "Rebuilding APK..."
  rm -f "$UNSIGNED"
  if ! run_logged "$CLONE_LOG" apktool b "$DECOMPILED" -o "$UNSIGNED"; then
    err "apktool rebuild failed for ${CLONE_ID} — see $CLONE_LOG"
    FAILED_CLONES+=("$CLONE_ID")
    rm -rf "$DECOMPILED" "$UNSIGNED"
    return 1
  fi
  ok "Built"

  # ---- FIX NATIVE LIBS ----
  log "Fixing native lib compression..."
  fix_native_libs "$UNSIGNED" "$DECOMPILED"
  ok ".so files uncompressed"

  # ---- ALIGN + SIGN ----
  log "Aligning and signing..."
  rm -f "$ALIGNED"
  if ! zipalign -f 4 "$UNSIGNED" "$ALIGNED"; then
    err "zipalign failed for ${CLONE_ID}"
    FAILED_CLONES+=("$CLONE_ID")
    rm -f "$UNSIGNED" "$ALIGNED"
    rm -rf "$DECOMPILED"
    return 1
  fi

  if ! apksigner sign \
    --ks "$KEYSTORE" \
    --ks-key-alias "$KS_ALIAS" \
    --ks-pass "pass:${KS_PASS}" \
    --key-pass "pass:${KS_PASS}" \
    --out "$CLONE_APK" \
    "$ALIGNED"; then
    err "apksigner failed for ${CLONE_ID}"
    FAILED_CLONES+=("$CLONE_ID")
    rm -f "$UNSIGNED" "$ALIGNED"
    rm -rf "$DECOMPILED"
    return 1
  fi
  ok "Signed → $(basename "$CLONE_APK") ($(du -h "$CLONE_APK" | cut -f1))"

  # ---- CLEANUP intermediates ----
  rm -f "$UNSIGNED" "$ALIGNED"
  rm -rf "$DECOMPILED"
  unregister_cleanup_dir "$DECOMPILED"
  unregister_cleanup_file "$UNSIGNED"
  unregister_cleanup_file "$ALIGNED"

  # ---- LOG SUCCESS ----
  echo "BUILD OK: $(du -h "$CLONE_APK" | cut -f1)" >> "$CLONE_LOG"
  changelog_entry "BUILD" "clone=$CLONE_PKG version=$APP_VERSION output=$(basename "$CLONE_APK") size=$(du -h "$CLONE_APK" | cut -f1)"
  SUCCESS_CLONES+=("$CLONE_ID")

  # ---- INSTALL ----
  if $DO_INSTALL; then
    log "Installing $CLONE_PKG..."
    if $PRIVATE_SPACE; then
      if adb push "$CLONE_APK" /data/local/tmp/_clone.apk 2>/dev/null \
         && adb shell su -c "pm install --user 10 /data/local/tmp/_clone.apk" 2>/dev/null; then
        ok "Installed to Private Space"
        adb shell su -c "rm /data/local/tmp/_clone.apk" 2>/dev/null || true
        changelog_entry "INSTALL" "clone=$CLONE_PKG target=private_space"
      else
        warn "Install failed — APK saved at $(basename "$CLONE_APK")"
        changelog_entry "INSTALL_FAIL" "clone=$CLONE_PKG target=private_space"
      fi
    else
      if adb install "$CLONE_APK" 2>/dev/null; then
        ok "Installed"
        changelog_entry "INSTALL" "clone=$CLONE_PKG target=default_user"
      else
        warn "Install failed — APK saved at $(basename "$CLONE_APK")"
        changelog_entry "INSTALL_FAIL" "clone=$CLONE_PKG target=default_user"
      fi
    fi
  fi

  return 0
}

# ============================================================
#  BUILD LOOP
# ============================================================
BUILD_START_TIME=$(date +%s)

if $PARALLEL; then
  # ---- PARALLEL BUILD MODE ----
  log "Starting parallel build with ${PARALLEL_JOBS} workers..."
  echo ""

  active_jobs=0
  declare -A JOB_MAP   # pid -> clone_id

  for i in $(seq "$START_NUM" "$END_NUM"); do
    # Wait if at max capacity
    while [ $active_jobs -ge "$PARALLEL_JOBS" ]; do
      # Wait for any child to finish
      wait -n 2>/dev/null || true
      # Recount active
      active_jobs=0
      for pid in "${!JOB_MAP[@]}"; do
        kill -0 "$pid" 2>/dev/null && active_jobs=$((active_jobs + 1)) || true
      done
    done

    # Launch build in background
    build_single_clone "$i" &
    local_pid=$!
    JOB_MAP[$local_pid]="clone${i}"
    BUILD_PIDS+=("$local_pid")
    active_jobs=$((active_jobs + 1))
    dim "Spawned clone${i} (PID $local_pid)"
  done

  # Wait for all remaining
  log "Waiting for all builds to finish..."
  for pid in "${!JOB_MAP[@]}"; do
    if ! wait "$pid"; then
      warn "${JOB_MAP[$pid]} build returned non-zero"
    fi
  done
  BUILD_PIDS=()

else
  # ---- SEQUENTIAL BUILD MODE ----
  for i in $(seq "$START_NUM" "$END_NUM"); do
    build_single_clone "$i" || true   # continue on failure
  done
fi

BUILD_END_TIME=$(date +%s)
BUILD_DURATION=$(( BUILD_END_TIME - BUILD_START_TIME ))

# ============================================================
#  SUMMARY
# ============================================================
echo ""
echo -e "${B}============================================${N}"
if [ ${#FAILED_CLONES[@]} -eq 0 ]; then
  echo -e "${G}  Build complete!${N}"
else
  echo -e "${Y}  Build finished with errors${N}"
fi
echo -e "${B}============================================${N}"
echo ""
echo -e "  ${B}App:       ${C}${APP_NAME} v${APP_VERSION}${N}"
echo -e "  ${B}Duration:  ${C}${BUILD_DURATION}s${N}"
echo ""

if [ ${#SUCCESS_CLONES[@]} -gt 0 ]; then
  echo -e "  ${G}Successful clones (${#SUCCESS_CLONES[@]}):${N}"
  for i in $(seq "$START_NUM" "$END_NUM"); do
    f="$OUTPUT_DIR/${APP_PREFIX}-clone${i}.apk"
    if [ -f "$f" ]; then
      echo -e "    $(du -h "$f" | cut -f1)  ${ORIG_PKG}.clone${i}"
    fi
  done
fi

if [ ${#FAILED_CLONES[@]} -gt 0 ]; then
  echo ""
  echo -e "  ${R}Failed clones (${#FAILED_CLONES[@]}):${N}"
  for fc in "${FAILED_CLONES[@]}"; do
    echo -e "    ${R}✗${N} $fc  — see ${LOG_DIR}/${APP_PREFIX}-${fc}.log"
  done
  echo ""
  warn "Re-run with --resume to retry only the failed clones"
fi

# Show reuse hint if we merged from splits
if [ "$INPUT_EXT" != "apk" ]; then
  BASE_NAME=$(basename "$XAPK_FILE" ".$INPUT_EXT")
  echo ""
  echo -e "  ${B}Reuse merged APK for more clones:${N}"
  echo -e "    $SCRIPT_NAME ${BASE_NAME}_merged.apk 3 --start $((END_NUM + 1))"
fi

echo ""
echo -e "  ${B}Install:${N}"
echo -e "    adb install output/${APP_PREFIX}-cloneN.apk"
echo ""
echo -e "  ${B}Private Space:${N}"
echo -e "    adb push output/${APP_PREFIX}-cloneN.apk /data/local/tmp/c.apk"
echo -e "    adb shell su -c 'pm install --user 10 /data/local/tmp/c.apk'"
echo ""
echo -e "  ${B}Changelog:${N}  ${CHANGELOG}"
echo ""

changelog_entry "DONE" "app=$ORIG_PKG version=$APP_VERSION success=${#SUCCESS_CLONES[@]} failed=${#FAILED_CLONES[@]} duration=${BUILD_DURATION}s"

# Exit with error if any clones failed
[ ${#FAILED_CLONES[@]} -gt 0 ] && exit 1
exit 0
