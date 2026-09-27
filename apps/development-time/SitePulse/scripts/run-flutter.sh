#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITEPULSE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FLUTTER_BIN="${FLUTTER_ROOT:-/home/gurkanindibay/flutter}/bin/flutter"
export ANDROID_HOME="/home/gurkanindibay/Android/Sdk"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"

TARGET="${1:-web}"

cd "$SITEPULSE_ROOT/flutter"

if [ "$TARGET" == "web" ]; then
    PORT=9090
    if lsof -ti :$PORT > /dev/null 2>&1; then
        echo "Port $PORT is currently in use. Stopping existing instance..."
        fuser -k -9 ${PORT}/tcp > /dev/null 2>&1 || true
        sleep 1
    fi
    echo "Starting Flutter Web Server on port 9090..."
    "$FLUTTER_BIN" run -d web-server --web-port 9090 --web-hostname 0.0.0.0
elif [ "$TARGET" == "chrome" ]; then
    echo "Starting Flutter on Google Chrome..."
    "$FLUTTER_BIN" run -d chrome
elif [ "$TARGET" == "android" ] || [ "$TARGET" == "emulator" ]; then
    echo "Launching Android emulator medium_phone..."
    "$FLUTTER_BIN" emulators --launch medium_phone || true
    echo "Running Flutter on Android..."
    "$FLUTTER_BIN" run -d android
else
    "$FLUTTER_BIN" run "$@"
fi
