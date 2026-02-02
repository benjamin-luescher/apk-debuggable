#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
KEYSTORE_NAME="debug-resign.keystore"
KEYSTORE_ALIAS="debug_key"
KEYSTORE_PASS="debugpass123"
WORK_DIR="apk-disassembled"
TRUST_USER_CERTS=false

print_step() {
    echo -e "${GREEN}==>${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}Warning:${NC} $1"
}

print_error() {
    echo -e "${RED}Error:${NC} $1"
}

# Find Android Studio installation and SDK tools
find_android_tools() {
    print_step "Searching for Android SDK tools..."

    # Common Android Studio/SDK locations on macOS
    local sdk_locations=(
        "$HOME/Library/Android/sdk"
        "/Users/$USER/Library/Android/sdk"
        "$ANDROID_HOME"
        "$ANDROID_SDK_ROOT"
    )

    # Find SDK path
    for loc in "${sdk_locations[@]}"; do
        if [[ -n "$loc" && -d "$loc/build-tools" ]]; then
            ANDROID_SDK="$loc"
            break
        fi
    done

    if [[ -z "$ANDROID_SDK" ]]; then
        print_error "Could not find Android SDK. Please set ANDROID_HOME or ANDROID_SDK_ROOT environment variable."
        exit 1
    fi

    print_step "Found Android SDK at: $ANDROID_SDK"

    # Find latest build-tools version (remove trailing slash)
    BUILD_TOOLS_DIR=$(ls -d "$ANDROID_SDK/build-tools"/*/ 2>/dev/null | sort -V | tail -n 1 | sed 's:/*$::')
    if [[ -z "$BUILD_TOOLS_DIR" ]]; then
        print_error "Could not find build-tools in Android SDK"
        exit 1
    fi

    APKSIGNER="$BUILD_TOOLS_DIR/apksigner"
    if [[ ! -f "$APKSIGNER" ]]; then
        print_error "apksigner not found at $APKSIGNER"
        exit 1
    fi
    print_step "Found apksigner: $APKSIGNER"

    # Find Java from Android Studio's bundled JDK or system
    local jdk_locations=(
        "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
        "/Applications/Android Studio.app/Contents/jre/Contents/Home"
        "$JAVA_HOME"
        "$(/usr/libexec/java_home 2>/dev/null)"
    )

    for loc in "${jdk_locations[@]}"; do
        if [[ -n "$loc" && -x "$loc/bin/java" ]]; then
            JAVA_BIN="$loc/bin/java"
            KEYTOOL="$loc/bin/keytool"
            break
        fi
    done

    # Fallback to system java/keytool
    if [[ -z "$JAVA_BIN" ]]; then
        if command -v java &> /dev/null; then
            JAVA_BIN="$(which java)"
            KEYTOOL="$(which keytool)"
        else
            print_error "Could not find Java. Please ensure Android Studio or JDK is installed."
            exit 1
        fi
    fi
    print_step "Found Java: $JAVA_BIN"
    print_step "Found keytool: $KEYTOOL"

    # Check for apktool.jar in current directory or common locations
    local apktool_jar_locations=(
        "./apktool.jar"
        "$HOME/apktool/apktool.jar"
        "/usr/local/bin/apktool.jar"
    )

    APKTOOL_JAR=""
    for loc in "${apktool_jar_locations[@]}"; do
        if [[ -f "$loc" ]]; then
            APKTOOL_JAR="$loc"
            break
        fi
    done

    if [[ -n "$APKTOOL_JAR" ]]; then
        APKTOOL="$JAVA_BIN -jar $APKTOOL_JAR"
        print_step "Found apktool: $APKTOOL_JAR (using bundled Java)"
    elif command -v apktool &> /dev/null; then
        # Use system apktool but override JAVA_HOME
        export JAVA_HOME="${JAVA_BIN%/bin/java}"
        APKTOOL="apktool"
        print_step "Found apktool: apktool (system, using JAVA_HOME=$JAVA_HOME)"
    else
        print_error "apktool not found. Please either:"
        echo "  1. Download apktool.jar to the current directory from https://apktool.org/"
        echo "  2. Or run: brew install apktool"
        exit 1
    fi
}

# Generate keystore if needed
ensure_keystore() {
    if [[ ! -f "$KEYSTORE_NAME" ]]; then
        print_step "Generating debug keystore..."
        "$KEYTOOL" -genkey -v \
            -keystore "$KEYSTORE_NAME" \
            -alias "$KEYSTORE_ALIAS" \
            -keyalg RSA \
            -keysize 2048 \
            -validity 10000 \
            -storepass "$KEYSTORE_PASS" \
            -keypass "$KEYSTORE_PASS" \
            -dname "CN=Debug, OU=Debug, O=Debug, L=Debug, ST=Debug, C=US"
    else
        print_step "Using existing keystore: $KEYSTORE_NAME"
    fi
}

# Sign an APK
sign_apk() {
    local apk="$1"
    print_step "Signing: $apk"
    "$APKSIGNER" sign \
        --ks "$KEYSTORE_NAME" \
        --ks-key-alias "$KEYSTORE_ALIAS" \
        --ks-pass "pass:$KEYSTORE_PASS" \
        --key-pass "pass:$KEYSTORE_PASS" \
        "$apk"
}

# Show usage
usage() {
    echo "Usage: $0 <path-to-apk-or-directory> [output] [--trust-user-certs]"
    echo ""
    echo "Makes an APK debuggable by:"
    echo "  1. Disassembling the APK"
    echo "  2. Adding android:debuggable=\"true\" to AndroidManifest.xml"
    echo "  3. Reassembling the APK"
    echo "  4. Signing with a debug keystore"
    echo ""
    echo "Arguments:"
    echo "  path-to-apk-or-directory"
    echo "      - Single APK file: processes that APK"
    echo "      - Directory with split APKs: processes base.apk and re-signs all splits"
    echo "  output    (Optional) Output path (default: <input>_debuggable.apk or <dir>_debuggable/)"
    echo ""
    echo "Options:"
    echo "  --trust-user-certs  Inject network_security_config.xml to trust user-installed"
    echo "                      CA certificates (required for HTTPS interception on API 24+)"
    echo ""
    echo "Split APK Support:"
    echo "  If you have a split APK bundle (base.apk + split_*.apk), put all APKs in a"
    echo "  directory and pass the directory path. The script will:"
    echo "    - Make base.apk debuggable"
    echo "    - Re-sign ALL APKs with the same keystore"
    echo "    - Output install command for adb install-multiple"
    exit 1
}

# Inject network_security_config.xml to trust user-installed CA certs
inject_network_security_config() {
    print_step "Injecting network_security_config.xml to trust user CA certificates..."

    MANIFEST="$WORK_DIR/AndroidManifest.xml"

    local config_content='<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <base-config>
        <trust-anchors>
            <certificates src="system" />
            <certificates src="user" />
        </trust-anchors>
    </base-config>
</network-security-config>'

    if grep -q 'android:networkSecurityConfig' "$MANIFEST"; then
        # App already has a network security config — find the referenced file and overwrite it
        local ref
        ref=$(sed -n 's/.*android:networkSecurityConfig="@xml\/\([^"]*\)".*/\1/p' "$MANIFEST" | head -n 1)
        if [[ -n "$ref" ]]; then
            print_step "Overwriting existing res/xml/${ref}.xml to trust user CAs"
            mkdir -p "$WORK_DIR/res/xml"
            echo "$config_content" > "$WORK_DIR/res/xml/${ref}.xml"
        else
            print_warning "Could not parse existing networkSecurityConfig reference — adding our own"
            mkdir -p "$WORK_DIR/res/xml"
            echo "$config_content" > "$WORK_DIR/res/xml/network_security_config.xml"
        fi
    else
        # No existing config — create file and add manifest attribute
        mkdir -p "$WORK_DIR/res/xml"
        echo "$config_content" > "$WORK_DIR/res/xml/network_security_config.xml"
        sed -i '' 's/<application/<application android:networkSecurityConfig="@xml\/network_security_config"/' "$MANIFEST"
        print_step "Added android:networkSecurityConfig to AndroidManifest.xml"
    fi
}

# Process a single APK (make debuggable)
process_single_apk() {
    local input_apk="$1"
    local output_apk="$2"

    # Clean up previous work directory
    if [[ -d "$WORK_DIR" ]]; then
        print_step "Cleaning up previous work directory..."
        rm -rf "$WORK_DIR"
    fi

    # Step 1: Disassemble
    print_step "Disassembling APK..."
    $APKTOOL d -f -o "$WORK_DIR" "$input_apk"

    # Step 2: Make debuggable
    print_step "Making APK debuggable..."
    MANIFEST="$WORK_DIR/AndroidManifest.xml"

    if [[ ! -f "$MANIFEST" ]]; then
        print_error "AndroidManifest.xml not found in disassembled APK"
        exit 1
    fi

    # Check if already debuggable
    if grep -q 'android:debuggable="true"' "$MANIFEST"; then
        print_warning "APK is already debuggable"
    else
        # Add debuggable attribute to <application> tag
        if grep -q 'android:debuggable="false"' "$MANIFEST"; then
            # Replace false with true
            sed -i '' 's/android:debuggable="false"/android:debuggable="true"/g' "$MANIFEST"
        else
            # Add debuggable attribute after <application
            sed -i '' 's/<application/<application android:debuggable="true"/g' "$MANIFEST"
        fi
        print_step "Added android:debuggable=\"true\" to AndroidManifest.xml"
    fi

    # Step 2b: Inject network security config (if requested)
    if [[ "$TRUST_USER_CERTS" == true ]]; then
        inject_network_security_config
    fi

    # Step 2c: Remove AGP-generated locale config if present
    # Android Gradle Plugin generates _generated_res_locale_config.xml with attributes
    # (e.g. android:defaultLocale) that older aapt2 versions bundled with apktool don't
    # support. The file is not needed for the app to function.
    local generated_locale="$WORK_DIR/res/xml/_generated_res_locale_config.xml"
    if [[ -f "$generated_locale" ]]; then
        print_step "Removing _generated_res_locale_config.xml (unsupported by apktool's aapt2)..."
        rm "$generated_locale"
        # Strip the manifest reference so aapt2 doesn't expect the resource
        sed -i '' 's/ android:localeConfig="@xml\/_generated_res_locale_config"//' "$MANIFEST"
        # Remove the public.xml resource ID declaration so aapt2 doesn't expect the file
        sed -i '' '/_generated_res_locale_config/d' "$WORK_DIR/res/values/public.xml"
    fi

    # Step 3: Reassemble
    print_step "Reassembling APK..."
    $APKTOOL b -f -o "$output_apk" "$WORK_DIR"

    # Clean up work directory
    rm -rf "$WORK_DIR"
}

# Process split APKs directory
process_split_apks() {
    local input_dir="$1"
    local output_dir="$2"

    # Find base.apk
    local base_apk=""
    if [[ -f "$input_dir/base.apk" ]]; then
        base_apk="$input_dir/base.apk"
    else
        # Look for any APK that might be the base (not starting with split_)
        for apk in "$input_dir"/*.apk; do
            if [[ -f "$apk" ]] && ! [[ "$(basename "$apk")" =~ ^split_ ]]; then
                base_apk="$apk"
                break
            fi
        done
    fi

    if [[ -z "$base_apk" ]]; then
        print_error "Could not find base.apk in directory: $input_dir"
        exit 1
    fi

    print_step "Found base APK: $base_apk"

    # Create output directory
    mkdir -p "$output_dir"

    # Process base APK (make debuggable)
    local base_name=$(basename "$base_apk")
    process_single_apk "$base_apk" "$output_dir/$base_name"

    # Ensure keystore exists
    ensure_keystore

    # Sign base APK
    sign_apk "$output_dir/$base_name"

    # Copy and sign all split APKs
    for apk in "$input_dir"/*.apk; do
        if [[ -f "$apk" ]] && [[ "$apk" != "$base_apk" ]]; then
            local apk_name=$(basename "$apk")
            print_step "Copying split APK: $apk_name"
            cp "$apk" "$output_dir/$apk_name"
            sign_apk "$output_dir/$apk_name"
        fi
    done

    # Verify signatures
    print_step "Verifying signatures..."
    for apk in "$output_dir"/*.apk; do
        "$APKSIGNER" verify "$apk"
    done

    echo ""
    echo -e "${GREEN}Success!${NC} Debuggable APKs created in: $output_dir"
    echo ""
    echo "Install with:"
    echo "  adb install-multiple $output_dir/*.apk"
}

# Main script
main() {
    # Parse arguments: extract --trust-user-certs, treat rest as positional
    local positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --trust-user-certs)
                TRUST_USER_CERTS=true
                shift
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    if [[ ${#positional[@]} -lt 1 ]]; then
        usage
    fi

    INPUT="${positional[0]}"
    OUTPUT_ARG="${positional[1]:-}"

    # Find tools first
    find_android_tools

    if [[ -d "$INPUT" ]]; then
        # Directory mode - split APKs
        print_step "Directory mode: Processing split APKs"

        # Count APKs
        apk_count=$(ls -1 "$INPUT"/*.apk 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$apk_count" -eq 0 ]]; then
            print_error "No APK files found in directory: $INPUT"
            exit 1
        fi
        print_step "Found $apk_count APK(s) in directory"

        # Determine output directory
        if [[ -n "$OUTPUT_ARG" ]]; then
            OUTPUT_DIR="$OUTPUT_ARG"
        else
            OUTPUT_DIR="${INPUT%/}_debuggable"
        fi

        process_split_apks "$INPUT" "$OUTPUT_DIR"

    elif [[ -f "$INPUT" ]]; then
        # Single APK mode
        print_step "Single APK mode"

        if [[ ! "$INPUT" =~ \.apk$ ]]; then
            print_error "Input file must be an APK: $INPUT"
            exit 1
        fi

        # Determine output APK name
        if [[ -n "$OUTPUT_ARG" ]]; then
            OUTPUT_APK="$OUTPUT_ARG"
        else
            local basename="${INPUT%.apk}"
            OUTPUT_APK="${basename}_debuggable.apk"
        fi

        print_step "Input APK: $INPUT"
        print_step "Output APK: $OUTPUT_APK"

        process_single_apk "$INPUT" "$OUTPUT_APK"

        # Ensure keystore and sign
        ensure_keystore
        sign_apk "$OUTPUT_APK"

        # Verify signature
        print_step "Verifying signature..."
        "$APKSIGNER" verify "$OUTPUT_APK"

        echo ""
        echo -e "${GREEN}Success!${NC} Debuggable APK created: $OUTPUT_APK"
        echo ""
        echo "Install with: adb install \"$OUTPUT_APK\""

    else
        print_error "Input not found: $INPUT"
        exit 1
    fi
}

main "$@"
