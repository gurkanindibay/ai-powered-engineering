#!/usr/bin/env bash
# ============================================================================
# SitePulse Test Database Seeding Script (DEVELOPMENT & TEST ENVIRONMENTS ONLY)
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/add-test-data.sh" "$@"
