#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Globals set by functions
APP_NAME=""
DEVICE_SERIAL=""
KEEP_FILES=false
TRUST_USER_CERTS=false
PROXY_MODE=false
ADB=""
PACKAGE_NAME=""
PULL_DIR=""
DEBUGGABLE_DIR=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Proxy configuration
CONTAINER_NAME="mitmproxy-android"
PROXY_PORT=8080
WEB_PORT=8081
PROXY_PASSWORD="proxy"
MITMPROXY_DIR="$HOME/.mitmproxy"

print_step() {
    echo -e "${GREEN}==>${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}Warning:${NC} $1"
}

print_error() {
    echo -e "${RED}Error:${NC} $1"
}

print_info() {
    echo -e "${BLUE}::${NC} $1"
}

usage() {
    echo "Usage: $0 <app-name> [--device <serial>] [--keep] [--trust-user-certs] [--proxy]"
    echo ""
    echo "Automated end-to-end APK debugging: extracts APKs from a connected"
    echo "Android device, makes them debuggable, and reinstalls."
    echo ""
    echo "Arguments:"
    echo "  app-name            Search term to find the package (e.g., 'myapp')"
    echo ""
    echo "Options:"
    echo "  --device <serial>   Use a specific device (from 'adb devices')"
    echo "  --keep              Keep intermediate files (pulled APKs and patched APKs)"
    echo "  --trust-user-certs  Trust user-installed CA certificates (for HTTPS interception)"
    echo "  --proxy             Start mitmproxy in Docker for HTTPS traffic interception"
    echo "                      (implies --trust-user-certs, requires Docker)"
    echo "  --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 chrome"
    echo "  $0 myapp --device emulator-5554"
    echo "  $0 myapp --keep"
    echo "  $0 myapp --trust-user-certs"
    echo "  $0 myapp --proxy"
    exit 0
}

parse_args() {
    if [[ $# -lt 1 ]]; then
        usage
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                usage
                ;;
            --device)
                if [[ -z "$2" || "$2" == --* ]]; then
                    print_error "--device requires a serial number argument"
                    exit 1
                fi
                DEVICE_SERIAL="$2"
                shift 2
                ;;
            --keep)
                KEEP_FILES=true
                shift
                ;;
            --trust-user-certs)
                TRUST_USER_CERTS=true
                shift
                ;;
            --proxy)
                PROXY_MODE=true
                TRUST_USER_CERTS=true
                shift
                ;;
            -*)
                print_error "Unknown option: $1"
                exit 1
                ;;
            *)
                if [[ -z "$APP_NAME" ]]; then
                    APP_NAME="$1"
                else
                    print_error "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$APP_NAME" ]]; then
        print_error "App name is required"
        exit 1
    fi
}

find_adb() {
    print_step "Searching for adb..."

    local sdk_locations=(
        "$HOME/Library/Android/sdk"
        "/Users/$USER/Library/Android/sdk"
        "$ANDROID_HOME"
        "$ANDROID_SDK_ROOT"
    )

    for loc in "${sdk_locations[@]}"; do
        if [[ -n "$loc" && -x "$loc/platform-tools/adb" ]]; then
            ADB="$loc/platform-tools/adb"
            break
        fi
    done

    if [[ -z "$ADB" ]]; then
        if command -v adb &> /dev/null; then
            ADB="$(command -v adb)"
        else
            print_error "Could not find adb. Please ensure Android SDK is installed and ANDROID_HOME is set."
            exit 1
        fi
    fi

    print_step "Found adb: $ADB"
}

select_device() {
    print_step "Looking for connected devices..."

    local devices_output
    devices_output=$("$ADB" devices 2>&1)

    # Parse device lines: serial<tab>state
    local serials=()
    local models=()
    while IFS= read -r line; do
        line=$(echo "$line" | tr -d '\r')
        # Skip header and empty lines
        if [[ "$line" == "List of devices attached" ]] || [[ -z "$line" ]]; then
            continue
        fi
        local serial state
        serial=$(echo "$line" | awk '{print $1}')
        state=$(echo "$line" | awk '{print $2}')
        if [[ "$state" == "device" ]]; then
            serials+=("$serial")
            local model
            model=$("$ADB" -s "$serial" shell getprop ro.product.model 2>/dev/null | tr -d '\r' || echo "unknown")
            models+=("$model")
        elif [[ "$state" == "unauthorized" ]]; then
            print_warning "Device $serial is unauthorized — please accept the USB debugging prompt"
        fi
    done <<< "$devices_output"

    if [[ ${#serials[@]} -eq 0 ]]; then
        print_error "No authorized devices found. Connect a device and enable USB debugging."
        exit 1
    fi

    # If --device was specified, validate it
    if [[ -n "$DEVICE_SERIAL" ]]; then
        local found=false
        for s in "${serials[@]}"; do
            if [[ "$s" == "$DEVICE_SERIAL" ]]; then
                found=true
                break
            fi
        done
        if [[ "$found" == false ]]; then
            print_error "Device '$DEVICE_SERIAL' not found or not authorized."
            echo "Available devices:"
            for i in "${!serials[@]}"; do
                echo "  ${serials[$i]}  (${models[$i]})"
            done
            exit 1
        fi
        local model
        model=$("$ADB" -s "$DEVICE_SERIAL" shell getprop ro.product.model 2>/dev/null | tr -d '\r' || echo "unknown")
        print_step "Using specified device: $DEVICE_SERIAL ($model)"
        return
    fi

    # Auto-select if only one device
    if [[ ${#serials[@]} -eq 1 ]]; then
        DEVICE_SERIAL="${serials[0]}"
        print_step "Using device: $DEVICE_SERIAL (${models[0]})"
        return
    fi

    # Interactive menu for multiple devices
    echo ""
    echo "Multiple devices found:"
    for i in "${!serials[@]}"; do
        echo "  $((i + 1))) ${serials[$i]}  (${models[$i]})"
    done
    echo ""
    while true; do
        read -rp "Select device [1-${#serials[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#serials[@]} ]]; then
            DEVICE_SERIAL="${serials[$((choice - 1))]}"
            print_step "Using device: $DEVICE_SERIAL (${models[$((choice - 1))]})"
            return
        fi
        echo "Invalid selection. Enter a number between 1 and ${#serials[@]}."
    done
}

select_package() {
    print_step "Searching for packages matching '$APP_NAME'..."

    local packages_raw
    packages_raw=$("$ADB" -s "$DEVICE_SERIAL" shell pm list packages 2>&1 | tr -d '\r')

    local matches=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && matches+=("$line")
    done < <(echo "$packages_raw" | grep -i "$APP_NAME" | sed 's/^package://' || true)

    if [[ ${#matches[@]} -eq 0 ]]; then
        print_error "No packages found matching '$APP_NAME'"
        echo "Try a broader search term, or list all packages with:"
        echo "  adb -s $DEVICE_SERIAL shell pm list packages"
        exit 1
    fi

    # Auto-select if only one match
    if [[ ${#matches[@]} -eq 1 ]]; then
        PACKAGE_NAME="${matches[0]}"
        print_step "Found package: $PACKAGE_NAME"
        return
    fi

    # Interactive menu for multiple matches
    echo ""
    echo "Multiple packages found:"
    for i in "${!matches[@]}"; do
        echo "  $((i + 1))) ${matches[$i]}"
    done
    echo ""
    while true; do
        read -rp "Select package [1-${#matches[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#matches[@]} ]]; then
            PACKAGE_NAME="${matches[$((choice - 1))]}"
            print_step "Selected package: $PACKAGE_NAME"
            return
        fi
        echo "Invalid selection. Enter a number between 1 and ${#matches[@]}."
    done
}

pull_apks() {
    print_step "Getting APK paths for $PACKAGE_NAME..."

    local paths_raw
    paths_raw=$("$ADB" -s "$DEVICE_SERIAL" shell pm path "$PACKAGE_NAME" 2>&1 | tr -d '\r')

    local apk_paths=()
    while IFS= read -r line; do
        local path
        path=$(echo "$line" | sed 's/^package://')
        [[ -n "$path" ]] && apk_paths+=("$path")
    done <<< "$paths_raw"

    if [[ ${#apk_paths[@]} -eq 0 ]]; then
        print_error "Could not find APK paths for $PACKAGE_NAME"
        exit 1
    fi

    print_step "Found ${#apk_paths[@]} APK(s)"

    PULL_DIR="apks_${PACKAGE_NAME}"
    rm -rf "$PULL_DIR"
    mkdir -p "$PULL_DIR"

    for apk_path in "${apk_paths[@]}"; do
        local apk_name
        apk_name=$(basename "$apk_path")
        print_info "Pulling $apk_name..."
        "$ADB" -s "$DEVICE_SERIAL" pull "$apk_path" "$PULL_DIR/$apk_name"
    done

    print_step "APKs pulled to $PULL_DIR/"
}

make_debuggable() {
    print_step "Making APKs debuggable..."

    local make_debuggable_script="$SCRIPT_DIR/lib/make-debuggable.sh"
    if [[ ! -x "$make_debuggable_script" ]]; then
        print_error "make-debuggable.sh not found or not executable at: $make_debuggable_script"
        exit 1
    fi

    DEBUGGABLE_DIR="${PULL_DIR}_debuggable"

    local args=("$PULL_DIR")
    [[ "$TRUST_USER_CERTS" == true ]] && args+=("--trust-user-certs")
    "$make_debuggable_script" "${args[@]}"

    if [[ ! -d "$DEBUGGABLE_DIR" ]]; then
        print_error "Expected output directory not found: $DEBUGGABLE_DIR"
        exit 1
    fi

    print_step "Debuggable APKs ready in $DEBUGGABLE_DIR/"
}

install_apks() {
    print_step "Uninstalling existing $PACKAGE_NAME..."
    "$ADB" -s "$DEVICE_SERIAL" uninstall "$PACKAGE_NAME" || print_warning "Uninstall failed (app may not be installed) — continuing"

    local apk_files=("$DEBUGGABLE_DIR"/*.apk)
    local apk_count=${#apk_files[@]}

    if [[ "$apk_count" -eq 0 ]]; then
        print_error "No APK files found in $DEBUGGABLE_DIR"
        exit 1
    fi

    if [[ "$apk_count" -eq 1 ]]; then
        print_step "Installing single APK..."
        "$ADB" -s "$DEVICE_SERIAL" install "${apk_files[0]}"
    else
        print_step "Installing $apk_count APKs..."
        "$ADB" -s "$DEVICE_SERIAL" install-multiple "${apk_files[@]}"
    fi

    print_step "Installation complete"
}

cleanup() {
    if [[ "$KEEP_FILES" == true ]]; then
        print_info "Keeping intermediate files (--keep):"
        [[ -d "$PULL_DIR" ]] && print_info "  Pulled APKs: $PULL_DIR/"
        [[ -d "$DEBUGGABLE_DIR" ]] && print_info "  Debuggable APKs: $DEBUGGABLE_DIR/"
        return
    fi

    print_step "Cleaning up temporary files..."
    [[ -n "$PULL_DIR" && -d "$PULL_DIR" ]] && rm -rf "$PULL_DIR"
    [[ -n "$DEBUGGABLE_DIR" && -d "$DEBUGGABLE_DIR" ]] && rm -rf "$DEBUGGABLE_DIR"
}

start_proxy() {
    print_step "Starting mitmproxy..."

    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed or not in PATH."
        exit 1
    fi

    if ! docker info &> /dev/null; then
        print_error "Docker is not running. Please start Docker and try again."
        exit 1
    fi

    # Stop any existing container to ensure clean state
    if docker ps -q --filter "name=$CONTAINER_NAME" | grep -q .; then
        print_step "Stopping existing mitmproxy container..."
        docker stop "$CONTAINER_NAME" &> /dev/null || true
        sleep 1
    fi

    # Remove stopped container with same name if exists
    if docker ps -aq --filter "name=$CONTAINER_NAME" | grep -q .; then
        docker rm "$CONTAINER_NAME" &> /dev/null || true
    fi

    mkdir -p "$MITMPROXY_DIR"

    docker run --rm -d \
        --name "$CONTAINER_NAME" \
        -p "$PROXY_PORT:8080" \
        -p "127.0.0.1:$WEB_PORT:8081" \
        -v "$MITMPROXY_DIR:/home/mitmproxy/.mitmproxy" \
        mitmproxy/mitmproxy \
        mitmweb --web-host 0.0.0.0 --set web_password="$PROXY_PASSWORD"

    print_step "mitmproxy container started"

    # Wait for cert to be generated and push to device
    local cert_file="$MITMPROXY_DIR/mitmproxy-ca-cert.cer"
    local waited=0
    while [[ ! -f "$cert_file" ]]; do
        if [[ "$waited" -ge 10 ]]; then
            print_warning "Timed out waiting for mitmproxy CA certificate"
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    if [[ -f "$cert_file" ]]; then
        "$ADB" -s "$DEVICE_SERIAL" push "$cert_file" /sdcard/mitmproxy-ca-cert.cer
        print_step "CA certificate pushed to device"
    fi

    # Wait for web UI to be ready
    waited=0
    while ! curl -s -o /dev/null "http://localhost:$WEB_PORT" 2>/dev/null; do
        if [[ "$waited" -ge 10 ]]; then
            print_warning "Timed out waiting for mitmproxy web UI"
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
}

main() {
    parse_args "$@"

    echo ""
    echo -e "${GREEN}=== Auto Debug APK ===${NC}"
    echo ""

    find_adb
    select_device
    select_package
    pull_apks
    make_debuggable
    install_apks
    cleanup

    if [[ "$PROXY_MODE" == true ]]; then
        echo ""
        start_proxy
    fi

    echo ""
    echo -e "${GREEN}=== Done! ===${NC}"
    echo ""
    echo -e "  $PACKAGE_NAME is now debuggable on $DEVICE_SERIAL"

    if [[ "$PROXY_MODE" == true ]]; then
        echo ""
        echo -e "  ${GREEN}Proxy:${NC}      http://127.0.0.1:$PROXY_PORT"
        echo -e "  ${GREEN}Web UI:${NC}     http://localhost:$WEB_PORT"
        echo -e "  ${GREEN}Password:${NC}   $PROXY_PASSWORD"
        echo ""
        echo -e "  ${YELLOW}Install the mitmproxy CA certificate on the device:${NC}"
        echo "    1. Open Settings → search \"certificate\""
        echo "    2. Tap \"Install a certificate\" → \"CA certificate\""
        echo "    3. Tap \"Install anyway\""
        echo "    4. Select \"mitmproxy-ca-cert.cer\" from internal storage"
        echo ""
        echo "  Configure your device to use proxy 10.0.2.2:$PROXY_PORT"
        echo "  (for emulators, 10.0.2.2 is the host machine)"
        echo ""
        echo "  Stop proxy:  docker stop $CONTAINER_NAME"
    else
        echo ""
        echo "  To attach a debugger:"
        echo "    Android Studio → Run → Attach Debugger to Android Process → $PACKAGE_NAME"
    fi
}

main "$@"
