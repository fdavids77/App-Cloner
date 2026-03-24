# App Cloner (clone-factory.sh)

Universal APK clone factory — builds multiple uniquely-packaged clones from a single XAPK file so they can be installed side-by-side on the same device.

Tested with **WhatsApp** and **Tinder**. Works with any split APK (XAPK) downloaded from APKPure, APKMirror, etc.

## Requirements

- **Java** (JDK 8+)
- **[APKEditor](https://github.com/nicedayzhu/APKEditor/releases)** — `APKEditor.jar` in the same directory or `~/` or `~/tools/`
- **apksigner** — from Android SDK build-tools (`sudo apt install apksigner` on Debian/Kali)
- **keytool** — bundled with Java
- **adb** — for optional install step

## Usage

```bash
chmod +x clone-factory.sh

# Basic: build 3 clones of WhatsApp
./clone-factory.sh whatsapp.xapk 3

# Build 2 Tinder clones and auto-install via ADB
./clone-factory.sh tinder.xapk 2 --install

# Build 4 clones and install to Android Private Space (root required)
./clone-factory.sh whatsapp.xapk 4 --install --private-space
```

Output APKs land in `./output/`.

## What It Does

For each clone (1 through N), the script automatically:

1. **Extracts** the XAPK and **merges** split APKs via APKEditor
2. **Detects** the original package name from `manifest.json`
3. **Patches the manifest** per clone:
   - Renames `package=` attribute (e.g. `com.tinder` → `com.tinder.clone1`)
   - Renames all `android:authorities` to avoid provider conflicts
   - Renames custom permissions (`DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`, `*.permission.*`)
   - Sets `android:extractNativeLibs="true"` (required for merged split APKs)
   - Removes Samsung multiwindow library/permission declarations
4. **Patches Smali** — auto-detects and neutralises `SecurePendingIntent` throws (WhatsApp, GMS-dependent apps)
5. **Injects `.so` files uncompressed** via `zip -0` (pairs with extractNativeLibs)
6. **Signs** with a shared self-signed keystore (auto-generated on first run)
7. **Optionally installs** via ADB to main profile or Private Space (user 10)

## Private Space Install (Rooted Pixel)

```bash
# Push and install to user 10
adb push output/whatsapp-clone1.apk /data/local/tmp/c.apk
adb shell su -c 'pm install --user 10 /data/local/tmp/c.apk'
```

## App-Specific Notes

### WhatsApp
- SecurePendingIntent patch applied automatically
- Smali class refs (`X/1Dy.smali` or similar) are **not** renamed — only manifest package name changes

### Tinder
- No SecurePendingIntent issues
- Add cloned package names to Magisk DenyList / Play Integrity Fix if on a rooted device
- Push notifications won't work on clones (expected — Firebase `google_app_id` is tied to original package)

### General
- **Do NOT rename Smali class references** — internal code uses the original package name, Android uses the manifest package for identity/isolation
- First test `clone1` manually for any new app before batch-building
- Watch for: certificate pinning, Firebase init crashes, GMS `app_id` checks

## License

MIT
