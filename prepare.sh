#!/bin/bash
# prepare.sh — Clone Factory environment setup
#
# v2.2 hardening:
#   - APKEditor.jar download is verified with `unzip -t` after wget
#   - wget runs with --show-progress instead of -q so download failures are visible
#   - Corrupt JARs (e.g. partial wget) are detected and re-downloaded automatically

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY_PASS="${1:-yourpassword}"

echo "╔══════════════════════════════════════════╗"
echo "║   Clone Factory — Prepare              ║"
echo "╚══════════════════════════════════════════╝"

echo "[1/5] System packages..."
sudo apt update -qq && sudo apt install -y default-jdk zipalign wget unzip python3 aapt 2>/dev/null || true
echo "  ✓ Done"

echo "[2/5] apktool..."
if ! command -v apktool &>/dev/null; then
  sudo wget -q https://github.com/iBotPeaches/Apktool/releases/latest/download/apktool.jar \
    -O /usr/local/bin/apktool.jar
  sudo wget -q https://raw.githubusercontent.com/iBotPeaches/Apktool/master/scripts/linux/apktool \
    -O /usr/local/bin/apktool
  sudo chmod +x /usr/local/bin/apktool
fi
grep -q "Xmx" /usr/local/bin/apktool 2>/dev/null || \
  sudo sed -i 's/exec java /exec java -Xmx2g /' /usr/local/bin/apktool
echo "  ✓ apktool $(apktool --version 2>/dev/null)"

echo "[3/5] APKEditor..."
APK_EDITOR="$SCRIPT_DIR/APKEditor.jar"
# v2.2: re-download if the JAR is missing OR fails archive validation.
# wget interruptions or transient 502s used to leave a corrupt file on disk
# that the file-exists check happily accepted, blowing up later mid-merge.
if [ ! -f "$APK_EDITOR" ] || ! unzip -t "$APK_EDITOR" &>/dev/null; then
  [ -f "$APK_EDITOR" ] && {
    echo "  ! Existing APKEditor.jar is corrupt ($(du -h "$APK_EDITOR" | cut -f1)) — re-downloading"
    rm -f "$APK_EDITOR"
  }
  wget --show-progress -q \
    https://github.com/REAndroid/APKEditor/releases/latest/download/APKEditor.jar \
    -O "$APK_EDITOR" || {
      echo "  ✗ Download failed. Check connectivity and rerun."
      exit 1
    }
  unzip -t "$APK_EDITOR" &>/dev/null || {
    echo "  ✗ Downloaded APKEditor.jar failed integrity check. Delete it and rerun."
    exit 1
  }
fi
echo "  ✓ APKEditor ready ($(du -h "$APK_EDITOR" | cut -f1))"

echo "[4/5] Keystore..."
KEYSTORE="$SCRIPT_DIR/my.keystore"
if [ ! -f "$KEYSTORE" ]; then
  keytool -genkey -v \
    -keystore "$KEYSTORE" \
    -alias wakey \
    -keyalg RSA \
    -keysize 2048 \
    -validity 10000 \
    -storepass "$KEY_PASS" \
    -keypass "$KEY_PASS" \
    -dname "CN=CloneFactory,OU=Personal,O=Personal,L=CPT,S=WC,C=ZA" 2>/dev/null
  echo "  ✓ Keystore generated"
else
  echo "  ✓ Keystore already exists"
fi

echo "[5/5] Directories..."
mkdir -p "$SCRIPT_DIR/work" "$SCRIPT_DIR/output" "$SCRIPT_DIR/patches"
echo "  ✓ Done"

echo ""
echo "✅ Ready!"
echo ""
echo "Update KEY_PASS in clone-factory.sh to match: $KEY_PASS"
echo ""
echo "Usage:"
echo "  ./clone-factory.sh --app whatsapp --input WhatsApp.apkm --count 7 --install --private-space 10"
echo "  ./clone-factory.sh --app tinder   --input tinder.xapk    --count 3 --install --private-space 10"
