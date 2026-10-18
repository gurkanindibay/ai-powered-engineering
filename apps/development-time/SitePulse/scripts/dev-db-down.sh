#!/usr/bin/env bash
# Stop SitePulse PostgreSQL development environment
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="${SCRIPT_DIR}/../backend"

DOCKER_CMD="docker"
if ! docker info > /dev/null 2>&1; then
    if [ "$EUID" -ne 0 ]; then
        DOCKER_CMD="sudo docker"
    fi
fi

echo "🛑 Stopping SitePulse database containers..."
cd "${BACKEND_DIR}"
$DOCKER_CMD compose down

echo "✅ Environment stopped cleanly."
