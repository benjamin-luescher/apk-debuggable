# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Three Bash scripts for making Android APKs debuggable and intercepting traffic:
- **`apk-debuggable.sh`** — End-to-end automation that handles device selection, APK extraction, patching (via `lib/make-debuggable.sh`), and reinstallation. Forwards `--trust-user-certs` to `lib/make-debuggable.sh`.
- **`lib/make-debuggable.sh`** — Core tool that converts release APKs into debuggable versions. It disassembles the APK, patches `AndroidManifest.xml` to set `android:debuggable="true"`, reassembles, and re-signs with a debug keystore. Optionally injects `network_security_config.xml` to trust user CA certs (`--trust-user-certs`).
- **`lib/proxy-setup.sh`** — Starts mitmproxy in Docker, restarts a running Android emulator with HTTP proxy enabled, and installs the mitmproxy CA certificate.

## Usage

```bash
# Automated end-to-end (device → extract → patch → reinstall)
./apk-debuggable.sh <app-name> [--device <serial>] [--keep] [--trust-user-certs] [--proxy]

# Single APK
./lib/make-debuggable.sh <path-to-apk> [output-apk] [--trust-user-certs]

# Split APK directory (contains base.apk + split APKs)
./lib/make-debuggable.sh <directory> [output-directory] [--trust-user-certs]

# Start mitmproxy and restart emulator with proxy
./lib/proxy-setup.sh

# Stop mitmproxy
./lib/proxy-setup.sh --stop
```

There are no build, test, or lint commands.

## Script Architecture

`lib/make-debuggable.sh` is organized into these key functions:

- **`find_android_tools()`** — Auto-discovers Android SDK, apksigner, Java/JDK, keytool, and apktool from standard macOS paths and environment variables (`ANDROID_HOME`, `ANDROID_SDK_ROOT`, `JAVA_HOME`)
- **`ensure_keystore()`** — Generates a debug keystore (`debug-resign.keystore`) if one doesn't exist
- **`sign_apk()`** — Signs an APK using apksigner with the debug keystore
- **`inject_network_security_config()`** — Creates `res/xml/network_security_config.xml` trusting system + user CAs, patches manifest to reference it. Called when `--trust-user-certs` is set.
- **`process_single_apk()`** — Disassembles APK via apktool, patches the manifest with `sed`, optionally injects network security config, reassembles, signs, and verifies
- **`process_split_apks()`** — Handles split APK bundles by processing `base.apk` then signing all splits
- **`main()`** — Entry point that parses `--trust-user-certs` flag, detects input type (file vs directory), and routes accordingly

### `apk-debuggable.sh` Architecture

Automation wrapper that orchestrates the full device-to-device workflow. Each function sets globals consumed by subsequent steps:

- **`parse_args()`** — Parses positional `APP_NAME` + optional `--device`, `--keep`, `--trust-user-certs`, `--proxy` flags (`--proxy` implies `--trust-user-certs`)
- **`find_adb()`** — Discovers `adb` from SDK locations or PATH (same pattern as `find_android_tools()`)
- **`select_device()`** — Parses `adb devices`, skips unauthorized; auto-selects if one device, interactive numbered menu if multiple. Fetches `ro.product.model` for display.
- **`select_package()`** — Runs `adb shell pm list packages | grep -i <name>`; auto-selects if one match, interactive menu if multiple
- **`pull_apks()`** — Gets paths via `adb shell pm path`, pulls each to `apks_<package>/` directory
- **`make_debuggable()`** — Delegates to `./lib/make-debuggable.sh <pull-dir>` (directory mode), forwarding `--trust-user-certs` if set. Output lands in `<pull-dir>_debuggable/`.
- **`install_apks()`** — Uninstalls existing package (non-fatal), then `adb install` or `adb install-multiple` depending on APK count
- **`cleanup()`** — Removes temp directories unless `--keep` flag was set
- **`start_proxy()`** — (when `--proxy`) Starts mitmproxy Docker container with `--set web_password`, pushes CA cert to device, waits for web UI. Always restarts the container fresh to avoid stale state.

Proxy globals: `CONTAINER_NAME="mitmproxy-android"`, `PROXY_PORT=8080`, `WEB_PORT=8081`, `PROXY_PASSWORD="proxy"`, `MITMPROXY_DIR="$HOME/.mitmproxy"`.

Key conventions: all `adb` commands use `-s "$DEVICE_SERIAL"`, all `adb shell` output stripped of `\r` with `tr -d '\r'`, `grep` calls that may match zero use `|| true` to avoid `set -e` abort.

### `lib/proxy-setup.sh` Architecture

Sets up mitmproxy in Docker and configures an Android emulator to route traffic through it:

- **`parse_args()`** — Parses `--stop` and `--port <port>` flags
- **`find_tools()`** — Discovers `adb`, `emulator` binary, and checks Docker availability
- **`stop_proxy()`** — Stops the `mitmproxy-android` Docker container (used with `--stop`)
- **`start_mitmproxy()`** — Runs mitmproxy Docker container (detached, `--rm`, named `mitmproxy-android`), volume-mounts `~/.mitmproxy` for cert persistence. Polls for CA cert file to appear.
- **`find_emulator()`** — Finds running emulators from `adb devices` (entries matching `emulator-*`). Gets AVD name via `adb emu avd name`. Interactive menu if multiple.
- **`restart_emulator()`** — Kills running emulator, waits for it to disappear, relaunches with `-http-proxy http://127.0.0.1:$PROXY_PORT`, waits for boot via `sys.boot_completed`.
- **`install_cert()`** — Pushes `~/.mitmproxy/mitmproxy-ca-cert.cer` to emulator, attempts automated cert install via intent, prints manual fallback instructions.
- **`print_summary()`** — Displays proxy URL, web UI URL, device info, and usage tips.

Key details: Docker container uses `--rm` for auto-cleanup, `~/.mitmproxy` volume persists certs across runs, emulator launched in background with `&`.

## Platform Notes

- **macOS-specific**: Uses `sed -i ''` (BSD sed syntax) and searches macOS paths like `/Applications/Android Studio.app` for bundled JDK
- Requires: Android SDK (build-tools), apktool (`brew install apktool` or jar), Java/JDK
- `lib/proxy-setup.sh` additionally requires Docker and an Android emulator

## Hardcoded Configuration

Keystore credentials are intentionally hardcoded for debug use:
- Keystore: `debug-resign.keystore`, alias: `debug_key`, password: `debugpass123`
- Work directory: `apk-disassembled` (cleaned up after processing)