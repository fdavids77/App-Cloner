# APK Clone Factory

Universal APK clone builder — creates multiple uniquely-packaged copies of any Android app so they can be installed side-by-side on the same device. Built for rooted Pixel devices with Private Space support.

Tested with **WhatsApp**, **WhatsApp Business**, and **Tinder**. Works with any split APK (XAPK/APKM/APKS) or pre-merged APK.

## Features

- **Multi-format input** — `.xapk`, `.apkm`, `.apks`, or pre-merged `.apk`
- **Batch cloning** — build 1–20 clones in a single run with `--start`/`--count` ranges
- **Parallel builds** — `--parallel` for concurrent clone builds (configurable worker count)
- **Resume on failure** — `--resume` skips clones that already exist
- **Dry-run validation** — `--dry-run` tests the full pipeline without building
- **Version detection** — extracts and logs `versionName`/`versionCode` from the source APK
- **Changelog** — persistent build log at `logs/changelog.log`
- **Auto-download helper** — `--download` gives you direct APKMirror/APKPure links with a local cache
- **Error handling** — trap-based cleanup, per-clone error isolation, per-clone build logs
- **Private Space install** — `--private-space` pushes to user 10 via root

## Requirements

```bash
# Core (all required)
sudo apt install default-jdk apktool zipalign apksigner python3

# Optional
sudo apt install aapt    # faster version detection (apktool fallback otherwise)
sudo apt install adb     # only needed with --install / --private-space
```

[APKEditor.jar](https://github.com/nicowcow/APKEditor-Desktop/releases) must be placed in one of:
- Same directory as `clone-factory.sh`
- `~/APKEditor.jar`
- `~/tools/APKEditor.jar`

Only needed when input is a split APK (`.xapk`/`.apkm`/`.apks`). Not needed for pre-merged `.apk` input.

## Usage

```
./clone-factory.sh <input_file|--download APP> <count> [options]
```

### Options

| Flag | Description |
|------|-------------|
| `--start N` | Start clone numbering at N (default: 1) |
| `--install` | ADB install each clone after building |
| `--private-space` | Install to Private Space (user 10, requires root) |
| `--dry-run` | Validate the pipeline without building |
| `--parallel [N]` | Build clones concurrently (default: 4 workers) |
| `--resume` | Skip clones whose output APK already exists |
| `--verbose` | Show full apktool/apksigner output |
| `--quiet` | Suppress all output except errors and summary |
| `--download APP` | Show download links for `whatsapp`, `whatsapp-business`, `tinder` |

### Examples

```bash
# Basic: 7 WhatsApp clones
./clone-factory.sh whatsapp.xapk 7

# Continue from clone8 using existing merged APK
./clone-factory.sh WhatsApp_merged.apk 3 --start 8

# WhatsApp Business with auto-install
./clone-factory.sh WhatsAppBusiness.xapk 4 --install

# Tinder to Private Space
./clone-factory.sh tinder.xapk 3 --install --private-space

# Validate before building
./clone-factory.sh whatsapp.xapk 7 --dry-run

# Parallel build (4 workers)
./clone-factory.sh whatsapp.xapk 7 --parallel

# Retry only failed/missing clones
./clone-factory.sh whatsapp.xapk 7 --resume

# Download helper
./clone-factory.sh --download whatsapp 5
```

## How It Works

1. **Merges split APKs** via APKEditor (skipped for `.apk` input; reuses `*_merged.apk` if present)
2. **Decompiles** with `apktool d` (fresh decompile per clone)
3. **Patches AndroidManifest.xml:**
   - Renames `package` attribute to `com.original.clone1`
   - Renames all `android:authorities` to match
   - Deletes `<permission>` declarations (prevents `INSTALL_FAILED_DUPLICATE_PERMISSION`)
   - Renames remaining permission references
   - Sets `android:extractNativeLibs="true"` (required for merged split APKs)
   - Removes `requiredSplitTypes`/`splitTypes` attributes
   - Strips Samsung multiwindow library/permission declarations
4. **Patches Smali** — auto-detects and neutralises `SecurePendingIntent` throws
5. **Rebuilds** with `apktool b`
6. **Injects `.so` files uncompressed** via `zip -0` (pairs with `extractNativeLibs`)
7. **Aligns and signs** with `zipalign` + `apksigner` (keystore auto-generated on first run)
8. **Optionally installs** via ADB to main profile or Private Space

## Private Space Install (Rooted Pixel)

```bash
# Via script
./clone-factory.sh whatsapp.xapk 3 --install --private-space

# Manual
adb push output/whatsapp-clone1.apk /data/local/tmp/c.apk
adb shell su -c 'pm install --user 10 /data/local/tmp/c.apk'
```

## Adding New App Targets

The script auto-detects any package name and works generically. To add a first-class target with a custom display name and output prefix, edit the `APP PROFILES` section in `clone-factory.sh`:

```bash
# ---- ADD NEW APP TARGETS HERE ----------------------------
com.example.app)
  APP_NAME="Example App"
  APP_PREFIX="example"
  APP_NOTES="any special notes"
  ;;
# ----------------------------------------------------------
```

## App-Specific Notes

### WhatsApp / WhatsApp Business
- SecurePendingIntent patch applied automatically (exact WhatsApp patterns + generic regex fallback)
- Smali class references are **not** renamed — only the manifest package name changes
- Each clone gets its own registration — use a different phone number per clone

### Tinder
- No SecurePendingIntent issues
- Google Sign-In will not work on clones (OAuth client ID is bound to `com.tinder` + Tinder's release signing key) — use phone/email login
- FaceTec liveness SDK uses native C++ — cannot be hooked via Java/Xposed
- Add cloned package names to Magisk DenyList if on a rooted device

### General
- **Never rename Smali class references** — Android uses the manifest package for identity, internal code references the original package
- First test `clone1` manually for any new app before batch-building
- Push notifications won't work on clones (Firebase `google_app_id` is tied to original package)
- Watch for: certificate pinning, Firebase init crashes, GMS `app_id` checks

## Output Structure

```
.
├── clone-factory.sh
├── clone-key.jks                    # auto-generated signing keystore
├── WhatsApp_merged.apk              # kept for reuse (from .xapk/.apkm input)
├── output/
│   ├── whatsapp-clone1.apk
│   ├── whatsapp-clone2.apk
│   └── ...
├── logs/
│   ├── changelog.log                # persistent build history
│   ├── whatsapp-clone1.log          # per-clone build log
│   └── ...
└── .download-cache/                 # cached APK downloads
```

## Version History

| Version | Changes |
|---------|---------|
| v2.0 | Error handling (traps/rollback/resume), dry-run, parallel builds, auto-download helper, version detection, changelog logging, extensible app profiles |
| v1.5 | WhatsApp Business support, generic SecurePendingIntent patching, merged APK reuse |
| v1.4 | `--start`/`--count` for building specific clone ranges |
| v1.3 | Switch to apktool for decompile/rebuild (APKEditor merge only) |
| v1.2 | Samsung multiwindow cleanup, duplicate permission removal |
| v1.1 | `.so` injection with `zip -0` |
| v1.0 | Basic clone: manifest patch + rebuild |

## Related Projects

- [whatsapp-clone-builder](https://github.com/fdavids77/whatsapp-clone-builder) — WhatsApp-specific clone builder (predecessor)
- [PrivateSpaceUnlock](https://github.com/fdavids77/PrivateSpaceUnlock) — Quick Settings tile to unlock Private Space
- [PSLabelHider](https://github.com/fdavids77/PSLabelHider) — LSPosed module to hide Private Space UI elements

## License

MIT
