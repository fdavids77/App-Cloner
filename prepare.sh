#!/bin/bash
set -e
KEY_PASS="${1:-yourpassword}"
echo "╔══════════════════════════════════════════╗"
echo "║   Clone Factory — Prepare              ║"
echo "╚══════════════════════════════════════════╝"

echo "[1/5] System packages..."
sudo apt update -qq && sudo apt install -y default-jdk zipalign wget unzip python3 aapt 2>/dev/null || true

echo "[2/5] apktool..."
if ! command -v apktool &>/dev/null; then
  sudo wget -q https://github.com/iBotPeaches/Apktool/releases/latest/download/apktool.jar -O /usr/local/bin/apktool.jar
  sudo wget -q https://raw.githubusercontent.com/iBotPeaches/Apktool/master/scripts/linux/apktool -O /usr/local/bin/apktool
  sudo chmod +x /usr/local/bin/apktool
fi
grep -q "Xmx" /usr/local/bin/apktool 2>/dev/null || sudo sed -i 's/exec java /exec java -Xmx2g /' /usr/local/bin/apktool
echo "  ✓ apktool $(apktool --version 2>/dev/null)"

echo "[3/5] APKEditor..."
[ ! -f "$(dirname "$0")/APKEditor.jar" ] && wget -q https://github.com/REAndroid/APKEditor/releases/latest/download/APKEditor.jar -O "$(dirname "$0")/APKEditor.jar"
echo "  ✓ APKEditor ready"

echo "[4/5] Keystore..."
KEYSTORE="$(dirname "$0")/my.keystore"
if [ ! -f "$KEYSTORE" ]; then
  keytool -genkey -v -keystore "$KEYSTORE" -alias wakey -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass "$KEY_PASS" -keypass "$KEY_PASS" \
    -dname "CN=CloneFactory,OU=Personal,O=Personal,L=CPT,S=WC,C=ZA" 2>/dev/null
  echo "  ✓ Keystore generated (pass: $KEY_PASS)"
else
  echo "  ✓ Keystore exists"
fi

echo "[5/5] Directories..."
mkdir -p "$(dirname "$0")/work" "$(dirname "$0")/output" "$(dirname "$0")/patches"
echo "  ✓ Done"

echo ""
echo "✅ Ready! Update KEY_PASS in clone-factory.sh to: $KEY_PASS"
echo ""
echo "Usage:"
echo "  ./clone-factory.sh --app whatsapp --input WhatsApp.xapk --count 6 --install --private-space 10"
