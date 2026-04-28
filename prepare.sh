#!/bin/bash
set -e
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
if [ ! -f "$SCRIPT_DIR/APKEditor.jar" ]; then
  wget -q https://github.com/REAndroid/APKEditor/releases/latest/download/APKEditor.jar \
    -O "$SCRIPT_DIR/APKEditor.jar"
fi
echo "  ✓ APKEditor ready"

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
