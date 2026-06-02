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

[APKEditor.jar](https://github.com/REAndroid/APKEditor/releases) is downloaded automatically by `prepare.sh` (with integrity validation as of v2.2). If you want to install it manually, place it in one of:
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
6. **Injects `.so` files uncompressed** via `zip -0` (multi-ABI: arm64-v8a, armeabi-v7a, x86_64, x86)
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
- No SecurePendingIntent issues — no `patches/tinder.py` needed
- **APKMirror variant matters**: grab the **arm64-v8a** or **universal** XAPK. The default 32-bit-only build will fail with `INSTALL_FAILED_NO_MATCHING_ABIS` on any Pixel from the Pixel 7 / Tensor G2 onward (64-bit only, no 32-bit fallback). See Troubleshooting below.
- Google Sign-In will not work on clones (OAuth client ID is bound to `com.tinder` + Tinder's release signing key) — use phone/email login
- FaceTec liveness SDK uses native C++ — cannot be hooked via Java/Xposed
- Add cloned package names to Magisk DenyList if on a rooted device

### General
- **Never rename Smali class references** — Android uses the manifest package for identity, internal code references the original package
- First test `clone1` manually for any new app before batch-building
- Push notifications won't work on clones (Firebase `google_app_id` is tied to original package)
- Watch for: certificate pinning, Firebase init crashes, GMS `app_id` checks

## Troubleshooting

### `INSTALL_FAILED_NO_MATCHING_ABIS` (res=-113)

The APK's native libraries don't match the device's CPU architecture. Almost always caused by downloading the wrong XAPK variant from APKMirror — typically grabbing the 32-bit (`armeabi-v7a`) build for a 64-bit-only Pixel (Pixel 7 and newer have dropped 32-bit support).

**Diagnose in 30 seconds:**

```bash
# What ABIs are in your cloned APK?
unzip -l output/tinder/tinder_clone1_signed.apk | awk '/lib\// {print $4}' | cut -d/ -f1-2 | sort -u

# What ABIs does the device support?
adb shell getprop ro.product.cpu.abilist
```

| First command output | Diagnosis |
|---|---|
| `lib/armeabi-v7a` only | Wrong XAPK variant — redownload the arm64-v8a build |
| `lib/arm64-v8a` (or both) | APK is fine; check device ABI list above |
| No `lib/` lines | apktool dropped libs during rebuild — open an issue with the app name |

**Fix:** redownload from APKMirror, filtering for variant **arm64-v8a** or **universal**:

```bash
rm -rf work/<app> output/<app>
./clone-factory.sh --app <app> --input <new>.xapk --count <n>
```

### `Error: Invalid or corrupt jarfile ... APKEditor.jar`

`prepare.sh` was interrupted during the APKEditor download, or wget timed out and left a partial file. As of v2.2, `prepare.sh` validates the JAR with `unzip -t` and re-downloads if corrupt, and `clone-factory.sh` refuses to start without a valid JAR.

**Manual fix:**

```bash
rm -f APKEditor.jar
wget https://github.com/REAndroid/APKEditor/releases/latest/download/APKEditor.jar
unzip -t APKEditor.jar | tail -1   # should say "No errors detected"
ls -lh APKEditor.jar               # should be ~3–5 MB, not kilobytes
```

If wget keeps failing:

```bash
curl -L -o APKEditor.jar \
  https://github.com/REAndroid/APKEditor/releases/latest/download/APKEditor.jar
```

### Clone factory "merges" but produces no merged.apk

Pre-v2.2 bug — the merge pipeline used `... | grep -E "Error|Warning" || true`, which masked APKEditor failures because grep exited 0 whenever it matched the word "Error" in stderr. v2.2 adds `set -o pipefail` and an explicit `[ -s "$MERGED_APK" ]` post-check that fails the build immediately on empty output.

If you're on an older version, the symptom looks like:

```
[•] Merging 20 splits...
Error: Invalid or corrupt jarfile /home/.../APKEditor.jar
du: cannot access '.../merged.apk': No such file or directory
[✓] Merged:                              ← false success
...
Input file (.../merged.apk) was not found or was not readable.
```

Upgrade to v2.2 or backport these two changes to `clone-factory.sh`:

```bash
set -o pipefail                                              # near top, after set -e
unzip -t "$APK_EDITOR" &>/dev/null || error "..."            # before java -jar
[ -s "$MERGED_APK" ] || error "Merge produced no output..." # after java -jar
```

### `INSTALL_FAILED_DUPLICATE_PERMISSION`

A previous clone of the same source app left a `<permission>` declaration on the device, and the new clone declares the same one. The manifest patcher already strips `<permission>` tags, but make sure you're on v1.2 or newer:

```bash
adb shell pm list packages | grep <original_pkg>.clone
adb shell su -c "pm uninstall --user 10 <conflicting.pkg.cloneN>"
```

### Clone installs but crashes on launch (Tinder / WhatsApp)

Most common causes, in order:
1. **Firebase `google_app_id` mismatch** — clones can't receive push notifications and may crash if the app aggressively validates the GMS app ID. Mostly harmless beyond losing notifications.
2. **SecurePendingIntent throws** (WhatsApp only) — should be patched automatically. Run `python3 patches/whatsapp.py --probe work/whatsapp/clone1` to confirm anchors were found.
3. **Root detection** — add the clone package to Magisk DenyList: `Magisk app → Settings → DenyList → Configure DenyList → search for clone package`.
4. **Certificate pinning** — affects login/network only, not launch. If you see SSL errors in `adb logcat`, the app has cert pinning and needs separate handling (out of scope for the factory).

### `prepare.sh: command not found`

You're missing the leading `./`. Bash won't search the current directory by default:

```bash
./prepare.sh           # ✓
prepare.sh             # ✗ command not found
bash prepare.sh        # ✓ alternative
```

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
| v2.2 | **Hardening release**: `set -o pipefail` in clone-factory, APKEditor.jar integrity check via `unzip -t` in both prepare.sh and clone-factory.sh, post-merge `[ -s "$MERGED_APK" ]` guard, multi-ABI `.so` re-injection loop (arm64-v8a / armeabi-v7a / x86_64 / x86), Tinder troubleshooting docs, automatic re-download of corrupt APKEditor.jar |
| v2.1 | apktool 3.x compatibility (DUMMYVAL format widening, foregroundServiceType hex stripping) |
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
