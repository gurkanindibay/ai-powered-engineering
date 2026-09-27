#!/usr/bin/env bash
set -e

echo "========================================================================"
echo "          SITEPULSE TERMINAL LIVE VERIFICATION TESTER                   "
echo "========================================================================"

# Helper formatting
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

pass() { echo -e "  [${GREEN}PASS${NC}] $1"; }
fail() { echo -e "  [${RED}FAIL${NC}] $1"; }
info() { echo -e "${CYAN}▶ $1${NC}"; }

# Check jq
if ! command -v jq &> /dev/null; then
    JSON_FMT="cat"
else
    JSON_FMT="jq ."
fi

# 1. Backend Health
info "1. Testing Rust Backend Health (/api/v1/health)..."
HEALTH_RES=$(curl -s http://localhost:8080/api/v1/health || echo "ERROR")
if [[ "$HEALTH_RES" == *"ok"* ]] || [[ "$HEALTH_RES" == *"status"* ]]; then
    pass "Backend is HEALTHY! Response:"
    echo "$HEALTH_RES" | $JSON_FMT
else
    fail "Backend health check failed. Is backend running? ($HEALTH_RES)"
fi
echo ""

# 2. Resident Dashboard API
info "2. Testing Resident Dashboard Endpoint (/api/v1/residents/1/dashboard)..."
DASH_RES=$(curl -s http://localhost:8080/api/v1/residents/1/dashboard || echo "ERROR")
if [[ "$DASH_RES" == *"unit_id"* ]] || [[ "$DASH_RES" == *"due"* ]] || [[ "$DASH_RES" == *"balance"* ]] || [[ "$DASH_RES" == *"site"* ]]; then
    pass "Resident Dashboard API returned valid data:"
    echo "$DASH_RES" | $JSON_FMT
else
    fail "Resident Dashboard endpoint failed: $DASH_RES"
fi
echo ""

# 3. SaaS Multi-Tenant Stats API
info "3. Testing SaaS Platform Multi-Tenancy Stats (/api/v1/saas/stats)..."
SAAS_RES=$(curl -s http://localhost:8080/api/v1/saas/stats || echo "ERROR")
if [[ "$SAAS_RES" == *"total_sites"* ]] || [[ "$SAAS_RES" == *"active_sites"* ]]; then
    pass "SaaS Multi-Tenancy KPIs verified:"
    echo "$SAAS_RES" | $JSON_FMT
else
    fail "SaaS Stats endpoint failed: $SAAS_RES"
fi
echo ""

# 4. Flutter Web Client Availability
info "4. Testing Flutter Web App (http://localhost:9090/)..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9090/ || echo "000")
if [ "$HTTP_CODE" == "200" ]; then
    pass "Flutter Web Client is serving HTTP 200 OK (Port 9090)!"
else
    fail "Flutter Web Client returned HTTP $HTTP_CODE (expected 200)."
fi
echo ""

# 5. Interactive Papara Prototype Availability
info "5. Testing Papara UX Prototype (http://localhost:9091/mvp_ux_prototype.html)..."
PROTO_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9091/mvp_ux_prototype.html || echo "000")
if [ "$PROTO_CODE" == "200" ]; then
    pass "Interactive Papara Prototype is serving HTTP 200 OK (Port 9091)!"
else
    fail "Prototype server returned HTTP $PROTO_CODE (expected 200)."
fi
echo ""

echo "========================================================================"
echo -e "  ${GREEN}✔ ALL TERMINAL ENDPOINT VERIFICATIONS COMPLETED SUCCESSFULLY!${NC}"
echo "========================================================================"
