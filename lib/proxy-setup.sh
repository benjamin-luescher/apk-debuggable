#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CONTAINER_NAME="mitmproxy-android"
PROXY_PORT=8080
WEB_PORT=8081
PROXY_PASSWORD="proxy"
MITMPROXY_DIR="$HOME/.mitmproxy"
ADB=""
EMULATOR_BIN=""
DEVICE_SERIAL=""
AVD_NAME=""
STOP_MODE=false

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
    echo "Usage: $0 [--stop] [--port <port>]"
    echo ""
    echo "Starts mitmproxy in Docker, restarts a running Android emulator with"
    echo "HTTP proxy enabled, and installs the mitmproxy CA certificate."
    echo ""
    echo "Options:"
    echo "  --stop          Stop the mitmproxy container and exit"
    echo "  --port <port>   Proxy port (default: 8080)"
    echo "  --help          Show this help message"
    echo ""
    echo "Prerequisites:"
    echo "  - Docker running"
    echo "  - An Android emulator currently running"
    echo ""
    echo "Examples:"
    echo "  $0                  # Start proxy and restart emulator"
    echo "  $0 --port 9090      # Use a custom proxy port"
    echo "  $0 --stop           # Stop the proxy container"
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                usage
                ;;
            --stop)
                STOP_MODE=true
                shift
                ;;
            --port)
                if [[ -z "$2" || "$2" == --* ]]; then
                    print_error "--port requires a port number argument"
                    exit 1
                fi
                PROXY_PORT="$2"
                shift 2
                ;;
            -*)
                print_error "Unknown option: $1"
                exit 1
                ;;
            *)
                print_error "Unexpected argument: $1"
                exit 1
                ;;
        esac
    done
}

find_tools() {
    print_step "Searching for required tools..."

    # Find adb
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

    # Find emulator binary
    for loc in "${sdk_locations[@]}"; do
        if [[ -n "$loc" && -x "$loc/emulator/emulator" ]]; then
            EMULATOR_BIN="$loc/emulator/emulator"
            break
        fi
    done

    if [[ -z "$EMULATOR_BIN" ]]; then
        if command -v emulator &> /dev/null; then
            EMULATOR_BIN="$(command -v emulator)"
        else
            print_error "Could not find Android emulator binary. Please ensure Android SDK is installed."
            exit 1
        fi
    fi
    print_step "Found emulator: $EMULATOR_BIN"

    # Check Docker
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed or not in PATH."
        exit 1
    fi

    if ! docker info &> /dev/null; then
        print_error "Docker is not running. Please start Docker and try again."
        exit 1
    fi
    print_step "Docker is available"
}

stop_proxy() {
    print_step "Stopping mitmproxy container..."
    if docker ps -q --filter "name=$CONTAINER_NAME" | grep -q .; then
        docker stop "$CONTAINER_NAME"
        print_step "mitmproxy container stopped"
    else
        print_warning "Container '$CONTAINER_NAME' is not running"
    fi
}

start_mitmproxy() {
    print_step "Starting mitmproxy..."

    # Check if already running
    if docker ps -q --filter "name=$CONTAINER_NAME" | grep -q .; then
        print_step "mitmproxy container is already running"
        return
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

    # Wait for cert file to be generated
    print_step "Waiting for mitmproxy CA certificate..."
    local cert_file="$MITMPROXY_DIR/mitmproxy-ca-cert.cer"
    local waited=0
    while [[ ! -f "$cert_file" ]]; do
        if [[ "$waited" -ge 10 ]]; then
            print_error "Timed out waiting for mitmproxy certificate at $cert_file"
            exit 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    print_step "CA certificate ready: $cert_file"
}

find_emulator() {
    print_step "Looking for running emulators..."

    local devices_output
    devices_output=$("$ADB" devices 2>&1)

    local serials=()
    while IFS= read -r line; do
        line=$(echo "$line" | tr -d '\r')
        if [[ "$line" == "List of devices attached" ]] || [[ -z "$line" ]]; then
            continue
        fi
        local serial state
        serial=$(echo "$line" | awk '{print $1}')
        state=$(echo "$line" | awk '{print $2}')
        if [[ "$state" == "device" ]] && [[ "$serial" == emulator-* ]]; then
            serials+=("$serial")
        fi
    done <<< "$devices_output"

    if [[ ${#serials[@]} -eq 0 ]]; then
        print_error "No running emulator found."
        echo "Please start an emulator first:"
        echo "  emulator -list-avds          # list available AVDs"
        echo "  emulator -avd <avd-name> &   # start an emulator"
        exit 1
    fi

    # Auto-select if only one emulator
    if [[ ${#serials[@]} -eq 1 ]]; then
        DEVICE_SERIAL="${serials[0]}"
    else
        echo ""
        echo "Multiple emulators found:"
        for i in "${!serials[@]}"; do
            echo "  $((i + 1))) ${serials[$i]}"
        done
        echo ""
        while true; do
            read -rp "Select emulator [1-${#serials[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#serials[@]} ]]; then
                DEVICE_SERIAL="${serials[$((choice - 1))]}"
                break
            fi
            echo "Invalid selection. Enter a number between 1 and ${#serials[@]}."
        done
    fi

    print_step "Using emulator: $DEVICE_SERIAL"

    # Get AVD name
    AVD_NAME=$("$ADB" -s "$DEVICE_SERIAL" emu avd name 2>/dev/null | head -n 1 | tr -d '\r' || true)
    if [[ -z "$AVD_NAME" ]]; then
        print_error "Could not determine AVD name for $DEVICE_SERIAL"
        exit 1
    fi
    print_step "AVD name: $AVD_NAME"
}

restart_emulator() {
    print_step "Restarting emulator with HTTP proxy..."

    # Kill running emulator
    print_info "Shutting down emulator $DEVICE_SERIAL..."
    "$ADB" -s "$DEVICE_SERIAL" emu kill 2>/dev/null || true

    # Wait for emulator to disappear from adb devices
    local waited=0
    while "$ADB" devices 2>&1 | grep -q "$DEVICE_SERIAL"; do
        if [[ "$waited" -ge 30 ]]; then
            print_error "Timed out waiting for emulator to shut down"
            exit 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    print_step "Emulator stopped"

    # Launch emulator with proxy
    print_info "Starting emulator '$AVD_NAME' with -http-proxy http://127.0.0.1:$PROXY_PORT..."
    "$EMULATOR_BIN" -avd "$AVD_NAME" -http-proxy "http://127.0.0.1:$PROXY_PORT" &

    # Wait for device to come online
    print_info "Waiting for emulator to boot..."
    "$ADB" wait-for-device

    # Poll for boot completion
    waited=0
    while true; do
        local boot_completed
        boot_completed=$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)
        if [[ "$boot_completed" == "1" ]]; then
            break
        fi
        if [[ "$waited" -ge 120 ]]; then
            print_error "Timed out waiting for emulator to boot"
            exit 1
        fi
        sleep 2
        waited=$((waited + 2))
    done

    # Update DEVICE_SERIAL to the new emulator instance
    DEVICE_SERIAL=$("$ADB" devices 2>&1 | grep 'emulator-' | grep 'device' | awk '{print $1}' | head -n 1 | tr -d '\r')
    print_step "Emulator booted: $DEVICE_SERIAL"
}

install_cert() {
    print_step "Installing mitmproxy CA certificate..."

    local cert_file="$MITMPROXY_DIR/mitmproxy-ca-cert.cer"
    if [[ ! -f "$cert_file" ]]; then
        print_error "Certificate file not found: $cert_file"
        exit 1
    fi

    "$ADB" -s "$DEVICE_SERIAL" push "$cert_file" /sdcard/mitmproxy-ca-cert.cer
    print_step "Certificate pushed to /sdcard/mitmproxy-ca-cert.cer"

    # Attempt automated install via cert installer intent
    "$ADB" -s "$DEVICE_SERIAL" shell am start \
        -n com.android.certinstaller/.CertInstallerMain \
        -a android.intent.action.VIEW \
        -t application/x-x509-ca-cert \
        -d file:///sdcard/mitmproxy-ca-cert.cer 2>/dev/null || true

    echo ""
    print_warning "If the certificate installer did not open automatically:"
    echo "  1. Open Settings → search \"certificate\""
    echo "  2. Tap \"Install a certificate\" → \"CA certificate\""
    echo "  3. Tap \"Install anyway\""
    echo "  4. Select \"mitmproxy-ca-cert.cer\" from internal storage"
}

print_summary() {
    echo ""
    echo -e "${GREEN}=== Proxy Setup Complete ===${NC}"
    echo ""
    echo "  Proxy:          http://127.0.0.1:$PROXY_PORT"
    echo "  Web UI:         http://localhost:$WEB_PORT"
    echo "  Password:       $PROXY_PASSWORD"
    echo "  Emulator:       $DEVICE_SERIAL ($AVD_NAME)"
    echo ""
    echo "  The emulator is configured to route traffic through mitmproxy."
    echo "  Open the Web UI to inspect HTTP/HTTPS traffic."
    echo ""
    echo -e "  ${YELLOW}Tip:${NC} To intercept HTTPS from apps targeting API 24+, use:"
    echo "    ./lib/make-debuggable.sh <apk-or-dir> --trust-user-certs"
    echo "    ./apk-debuggable.sh <app-name> --trust-user-certs"
    echo ""
    echo "  To stop the proxy:"
    echo "    ./lib/proxy-setup.sh --stop"
}

main() {
    parse_args "$@"

    if [[ "$STOP_MODE" == true ]]; then
        stop_proxy
        exit 0
    fi

    echo ""
    echo -e "${GREEN}=== Proxy Setup ===${NC}"
    echo ""

    find_tools
    start_mitmproxy
    find_emulator
    restart_emulator
    install_cert
    print_summary
}

main "$@"
