# Helper Scripts

These scripts can be used standalone for more control over individual steps. For the automated end-to-end flow, see the [root README](../README.md).

## Requirements

| Tool | Purpose | Install |
|------|---------|---------|
| [Android SDK](https://developer.android.com/studio) | `adb`, `apksigner` | Included with [Android Studio](https://developer.android.com/studio) |
| [Java / JDK](https://adoptium.net/) | `keytool` | Bundled with Android Studio, or `brew install --cask temurin` |
| [apktool](https://apktool.org/) | APK disassembly / reassembly | `brew install apktool` |
| [Docker](https://www.docker.com/products/docker-desktop/) | mitmproxy container (`proxy-setup.sh` only) | [Docker Desktop](https://www.docker.com/products/docker-desktop/) |
| [Android Emulator](https://developer.android.com/studio/run/emulator) | `proxy-setup.sh` only | Included with [Android Studio](https://developer.android.com/studio) |

## `make-debuggable.sh`

Converts release APKs into debuggable versions by disassembling, patching `AndroidManifest.xml`, reassembling, and re-signing with a debug keystore.

### Usage

```bash
# Single APK
./lib/make-debuggable.sh <path-to-apk> [output-apk] [--trust-user-certs]

# Split APK directory (contains base.apk + split APKs)
./lib/make-debuggable.sh <directory> [output-directory] [--trust-user-certs]
```

### Single APK Mode

```bash
./lib/make-debuggable.sh app.apk
# Output: app_debuggable.apk

adb install app_debuggable.apk
```

### Split APK Mode

For apps distributed as split APKs, put all APKs in a directory and pass the directory path:

```bash
./lib/make-debuggable.sh ./my-app-apks
# Output: ./my-app-apks_debuggable/

adb install-multiple ./my-app-apks_debuggable/*.apk
```

The script will:
1. Disassemble `base.apk` with `apktool`
2. Add `android:debuggable="true"` to `AndroidManifest.xml`
3. Reassemble with `apktool`
4. Re-sign all APKs with a debug keystore

### `--trust-user-certs`

Android API 24+ apps only trust system CA certificates by default. This flag injects a `network_security_config.xml` that tells the app to also trust user-installed certificates (like the mitmproxy CA).

```bash
./lib/make-debuggable.sh ./my-app-apks --trust-user-certs
```

## `proxy-setup.sh`

Starts mitmproxy in Docker, restarts a running Android emulator with HTTP proxy enabled, and installs the mitmproxy CA certificate.

### Usage

```bash
# Start proxy and restart emulator with proxy enabled
./lib/proxy-setup.sh

# Use a custom proxy port
./lib/proxy-setup.sh --port 9090

# Stop the proxy
./lib/proxy-setup.sh --stop
```

### Workflow

For a typical interception setup using `proxy-setup.sh` separately:

```bash
# Start proxy and restart emulator with proxy enabled
./lib/proxy-setup.sh

# Make the app trust user-installed CA certs and install it
./apk-debuggable.sh myapp --trust-user-certs

# When done, stop the proxy
./lib/proxy-setup.sh --stop
```

## Troubleshooting

### INSTALL_FAILED_MISSING_SPLIT
The APK requires split APKs. Pull all APKs from the device and use directory mode.

### Signature mismatch
Uninstall the original app before installing the debuggable version:
```bash
adb uninstall <package-id>
```

### apktool not found
```bash
brew install apktool
# or download apktool.jar to the script directory
```
