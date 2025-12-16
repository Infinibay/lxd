#!/usr/bin/env bash

################################################################################
# Health Checks Library
#
# Purpose: Post-update verification for all Infinibay services
# Usage: Source this file and call run_all_health_checks()
# Returns: 0 if all checks pass, 1 if any check fails
# Note: Color constants (GREEN, YELLOW, RED, BLUE, NC) provided by run.sh
################################################################################

# Timeout constant (seconds per check)
readonly HEALTH_CHECK_TIMEOUT=30

################################################################################
# check_postgres_health
#
# Verifies PostgreSQL database is responding to queries
# Returns: 0 if healthy, 1 if failed
################################################################################
check_postgres_health() {
    local start_time=$(date +%s)
    echo -e "${BLUE}[check_postgres_health]${NC} Checking PostgreSQL database..."

    local result=0
    timeout ${HEALTH_CHECK_TIMEOUT} sg lxd -c "lxc exec infinibay-postgres -- su - postgres -c \"psql -c 'SELECT 1'\"" >/dev/null 2>&1 || result=$?

    local duration=$(($(date +%s) - start_time))

    if [ $result -eq 0 ]; then
        echo -e "${GREEN}[check_postgres_health]${NC} ✓ PostgreSQL is healthy (${duration}s)"
        return 0
    else
        echo -e "${RED}[check_postgres_health]${NC} ✗ PostgreSQL health check failed"
        echo -e "${YELLOW}[check_postgres_health]${NC} Hint: Check PostgreSQL logs with:"
        echo -e "${YELLOW}[check_postgres_health]${NC}   lxc exec infinibay-postgres -- journalctl -u postgresql -n 50"
        return 1
    fi
}

################################################################################
# check_redis_health
#
# Verifies Redis cache is responding to commands
# Returns: 0 if healthy, 1 if failed
################################################################################
check_redis_health() {
    local start_time=$(date +%s)
    echo -e "${BLUE}[check_redis_health]${NC} Checking Redis cache..."

    local response=""
    local result=0
    response=$(timeout ${HEALTH_CHECK_TIMEOUT} sg lxd -c "lxc exec infinibay-redis -- redis-cli ping" 2>/dev/null) || result=$?

    local duration=$(($(date +%s) - start_time))

    if [ $result -eq 0 ] && [ "$response" = "PONG" ]; then
        echo -e "${GREEN}[check_redis_health]${NC} ✓ Redis is healthy (${duration}s)"
        return 0
    else
        echo -e "${RED}[check_redis_health]${NC} ✗ Redis health check failed"
        echo -e "${YELLOW}[check_redis_health]${NC} Hint: Check Redis logs with:"
        echo -e "${YELLOW}[check_redis_health]${NC}   lxc exec infinibay-redis -- journalctl -u redis -n 50"
        return 1
    fi
}

################################################################################
# check_backend_health
#
# Verifies backend service is running and GraphQL endpoint is responding
# Returns: 0 if healthy, 1 if failed
################################################################################
check_backend_health() {
    local start_time=$(date +%s)
    echo -e "${BLUE}[check_backend_health]${NC} Checking backend service..."

    # Step 1: Check systemd service status
    local systemd_result=0
    timeout ${HEALTH_CHECK_TIMEOUT} sg lxd -c "lxc exec infinibay-backend -- systemctl is-active infinibay-backend" >/dev/null 2>&1 || systemd_result=$?

    if [ $systemd_result -ne 0 ]; then
        echo -e "${RED}[check_backend_health]${NC} ✗ Backend systemd service is not active"
        echo -e "${YELLOW}[check_backend_health]${NC} Hint: Check backend logs with:"
        echo -e "${YELLOW}[check_backend_health]${NC}   lxc exec infinibay-backend -- journalctl -u infinibay-backend -n 50"
        return 1
    fi

    # Step 2: Check GraphQL endpoint
    local graphql_response=""
    local curl_result=0
    graphql_response=$(timeout ${HEALTH_CHECK_TIMEOUT} sg lxd -c "lxc exec infinibay-backend -- curl -s -X POST http://localhost:4000/graphql -H 'Content-Type: application/json' -d '{\"query\":\"{__typename}\"}'" 2>/dev/null) || curl_result=$?

    local duration=$(($(date +%s) - start_time))

    if [ $curl_result -eq 0 ] && echo "$graphql_response" | grep -q '"data"'; then
        echo -e "${GREEN}[check_backend_health]${NC} ✓ Backend is healthy (systemd + GraphQL) (${duration}s)"
        return 0
    else
        echo -e "${RED}[check_backend_health]${NC} ✗ Backend GraphQL endpoint is not responding"
        echo -e "${YELLOW}[check_backend_health]${NC} Hint: Check GraphQL endpoint manually with:"
        echo -e "${YELLOW}[check_backend_health]${NC}   curl http://localhost:4000/graphql"
        echo -e "${YELLOW}[check_backend_health]${NC} Or check backend logs with:"
        echo -e "${YELLOW}[check_backend_health]${NC}   lxc exec infinibay-backend -- journalctl -u infinibay-backend -n 50"
        return 1
    fi
}

################################################################################
# check_frontend_health
#
# Verifies frontend service is running and homepage loads
# Returns: 0 if healthy, 1 if failed
################################################################################
check_frontend_health() {
    local start_time=$(date +%s)
    echo -e "${BLUE}[check_frontend_health]${NC} Checking frontend service..."

    # Step 1: Check systemd service status
    local systemd_result=0
    timeout ${HEALTH_CHECK_TIMEOUT} sg lxd -c "lxc exec infinibay-frontend -- systemctl is-active infinibay-frontend" >/dev/null 2>&1 || systemd_result=$?

    if [ $systemd_result -ne 0 ]; then
        echo -e "${RED}[check_frontend_health]${NC} ✗ Frontend systemd service is not active"
        echo -e "${YELLOW}[check_frontend_health]${NC} Hint: Check frontend logs with:"
        echo -e "${YELLOW}[check_frontend_health]${NC}   lxc exec infinibay-frontend -- journalctl -u infinibay-frontend -n 50"
        return 1
    fi

    # Step 2: Check HTTP endpoint
    local http_code=""
    local curl_result=0
    http_code=$(timeout ${HEALTH_CHECK_TIMEOUT} sg lxd -c "lxc exec infinibay-frontend -- curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/" 2>/dev/null) || curl_result=$?

    local duration=$(($(date +%s) - start_time))

    if [ $curl_result -eq 0 ] && [ "$http_code" = "200" ]; then
        echo -e "${GREEN}[check_frontend_health]${NC} ✓ Frontend is healthy (systemd + HTTP 200) (${duration}s)"
        return 0
    else
        echo -e "${RED}[check_frontend_health]${NC} ✗ Frontend homepage is not responding (HTTP: ${http_code:-N/A})"
        echo -e "${YELLOW}[check_frontend_health]${NC} Hint: Check frontend manually with:"
        echo -e "${YELLOW}[check_frontend_health]${NC}   curl http://localhost:3000"
        echo -e "${YELLOW}[check_frontend_health]${NC} Or check frontend logs with:"
        echo -e "${YELLOW}[check_frontend_health]${NC}   lxc exec infinibay-frontend -- journalctl -u infinibay-frontend -n 50"
        return 1
    fi
}

################################################################################
# run_all_health_checks
#
# Master orchestrator: executes all health checks in dependency order
# Returns: 0 if all pass, 1 if any fail
################################################################################
run_all_health_checks() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}Running post-update health checks...${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    local failed_checks=0
    local failed_check_names=()

    # Run checks in dependency order: PostgreSQL → Redis → Backend → Frontend
    set +e

    if ! check_postgres_health; then
        ((failed_checks++))
        failed_check_names+=("PostgreSQL")
    fi
    echo ""

    if ! check_redis_health; then
        ((failed_checks++))
        failed_check_names+=("Redis")
    fi
    echo ""

    if ! check_backend_health; then
        ((failed_checks++))
        failed_check_names+=("Backend")
    fi
    echo ""

    if ! check_frontend_health; then
        ((failed_checks++))
        failed_check_names+=("Frontend")
    fi
    echo ""

    set -e

    # Print summary
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    if [ $failed_checks -eq 0 ]; then
        echo -e "${GREEN}✓ All health checks passed (4/4)${NC}"
        echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
        return 0
    else
        echo -e "${RED}✗ Health checks failed: ${failed_checks}/4 check(s) failed${NC}"
        echo -e "${RED}  Failed checks: ${failed_check_names[*]}${NC}"
        echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
        return 1
    fi
}
