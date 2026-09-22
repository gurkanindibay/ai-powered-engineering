#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITEPULSE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ANDROID_PROJECT_DIR="$SITEPULSE_ROOT/android"
APK_PATH="$ANDROID_PROJECT_DIR/app/build/outputs/apk/debug/app-debug.apk"
PACKAGE_NAME="com.sitepulse.app"
MAIN_ACTIVITY="com.sitepulse.app/.MainActivity"

# Discover Android SDK and ADB
if [ -z "$ANDROID_HOME" ]; then
    if [ -d "$HOME/Android/Sdk" ]; then
        export ANDROID_HOME="$HOME/Android/Sdk"
    fi
fi

if [ -n "$ANDROID_HOME" ]; then
    export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
fi

ADB_CMD="$(command -v adb || echo "$HOME/Android/Sdk/platform-tools/adb")"
if [ ! -x "$ADB_CMD" ]; then
    echo "❌ Error: 'adb' executable could not be found."
    echo "Please set ANDROID_HOME or ensure adb is on your PATH."
    exit 1
fi

echo "========================================================================"
echo "                   SITEPULSE ANDROID RUNNER                             "
echo "  Native Jetpack Compose App (Papara Fintech M3 Dual-Theme)             "
echo "========================================================================"
echo ""

# Parse CLI options
LAUNCH_VIEWER=false
TAKE_SCREENSHOT=false
SKIP_BUILD=false

for arg in "$@"; do
    case "$arg" in
        --viewer|-v|-w)
            LAUNCH_VIEWER=true
            ;;
        --screenshot|-s)
            TAKE_SCREENSHOT=true
            ;;
        --skip-build)
            SKIP_BUILD=true
            ;;
        --help|-h)
            echo "Usage: ./run-android.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --viewer, -v, -w    Launch interactive Web Live Viewer on http://localhost:9090"
            echo "  --screenshot, -s    Capture a screenshot of the app after launch"
            echo "  --skip-build        Skip Gradle build and use existing APK"
            echo "  --help, -h          Show this help message"
            echo ""
            exit 0
            ;;
    esac
done

# Step 1: Check running device or emulator
echo "▶ [1/4] Checking connected Android devices or emulators..."
DEVICE_COUNT="$("$ADB_CMD" devices | awk 'NR>1 && $2=="device" {count++} END {print count+0}')"

if [ "$DEVICE_COUNT" -eq 0 ]; then
    echo "  No running device found. Starting emulator 'medium_phone'..."
    if command -v android >/dev/null 2>&1; then
        android emulator start medium_phone
    elif [ -x "$ANDROID_HOME/emulator/emulator" ]; then
        "$ANDROID_HOME/emulator/emulator" -avd medium_phone -no-snapshot-load -gpu host &
        echo "  Waiting for emulator to complete boot..."
        "$ADB_CMD" wait-for-device
        while [ "$("$ADB_CMD" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; do
            sleep 2
        done
    else
        echo "❌ Error: No Android emulator found. Please start an emulator or connect a device via adb."
        exit 1
    fi
fi

DEVICE_ID="$("$ADB_CMD" devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
echo "  ✔ Connected device: $DEVICE_ID"
echo ""

# Step 2: Build Android App (Assemble Debug)
if [ "$SKIP_BUILD" = false ] || [ ! -f "$APK_PATH" ]; then
    echo "▶ [2/4] Compiling Android app with Gradle (:app:assembleDebug)..."
    (
        cd "$ANDROID_PROJECT_DIR"
        ./gradlew assembleDebug --quiet
    )
    echo "  ✔ Build successful: $APK_PATH"
else
    echo "▶ [2/4] Skipping build (using existing APK: $APK_PATH)..."
fi
echo ""

# Step 3: Install APK onto device
echo "▶ [3/4] Installing APK on device ($DEVICE_ID)..."
"$ADB_CMD" -s "$DEVICE_ID" install -r -d "$APK_PATH"
echo "  ✔ Application installed successfully."
echo ""

# Step 4: Unlock & Launch Main Activity
echo "▶ [4/4] Launching SitePulse ($MAIN_ACTIVITY)..."
# Wake device and unlock screen if asleep
"$ADB_CMD" -s "$DEVICE_ID" shell input keyevent KEYCODE_WAKEUP 2>/dev/null || true
"$ADB_CMD" -s "$DEVICE_ID" shell input keyevent 82 2>/dev/null || true
"$ADB_CMD" -s "$DEVICE_ID" shell am start -n "$MAIN_ACTIVITY"
echo "  ✔ Application started."
echo ""

# Optional screenshot
if [ "$TAKE_SCREENSHOT" = true ]; then
    sleep 2
    SCREENSHOT_OUT="$SITEPULSE_ROOT/screenshot_$(date +%s).png"
    echo "📸 Capturing screen to: $SCREENSHOT_OUT"
    "$ADB_CMD" -s "$DEVICE_ID" exec-out screencap -p > "$SCREENSHOT_OUT"
    echo "  ✔ Screenshot saved."
    echo ""
fi

# Optional live viewer
if [ "$LAUNCH_VIEWER" = true ]; then
    VIEWER_SCRIPT="$SCRIPT_DIR/live_android_viewer.py"
    if [ -f "$VIEWER_SCRIPT" ]; then
        echo "🌐 Starting Interactive Live Web Viewer on http://localhost:9090 ..."
        echo "Press Ctrl+C to stop viewer."
        python3 "$VIEWER_SCRIPT"
    fi
fi

echo "========================================================================"
echo "  ✔ SITEPULSE ANDROID APP IS RUNNING SUCCESSFULLY ON $DEVICE_ID!"
echo "========================================================================"
