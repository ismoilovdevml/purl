#!/bin/bash
# ============================================================
# Purl Auth Test Environment Setup
# ============================================================
# Sets up OpenLDAP + KeyCloak for testing LDAP/AD and SAML/SSO
#
# Usage:
#   ./scripts/auth-test-setup.sh start    # Start services
#   ./scripts/auth-test-setup.sh stop     # Stop services
#   ./scripts/auth-test-setup.sh status   # Check service status
#   ./scripts/auth-test-setup.sh test     # Test LDAP connection
#   ./scripts/auth-test-setup.sh clean    # Remove all data
# ============================================================

set -euo pipefail

COMPOSE_FILE="docker-compose.auth-test.yml"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Detect PURL_HOST — where is Purl running?
PURL_HOST="${PURL_HOST:-172.17.4.16}"
PURL_PORT="${PURL_PORT:-3000}"
PURL_URL="http://${PURL_HOST}:${PURL_PORT}"

# Where are auth test services running?
AUTH_HOST="${AUTH_HOST:-localhost}"

cmd_start() {
    info "Starting auth test environment..."
    cd "$PROJECT_DIR"

    docker compose -f "$COMPOSE_FILE" up -d

    info "Waiting for services to be healthy..."

    # Wait for OpenLDAP
    echo -n "  OpenLDAP: "
    for i in $(seq 1 30); do
        if docker compose -f "$COMPOSE_FILE" exec -T openldap \
            ldapsearch -x -H ldap://localhost -b "dc=purl,dc=test" \
            -D "cn=admin,dc=purl,dc=test" -w "admin_password" \
            "(objectClass=inetOrgPerson)" uid 2>/dev/null | grep -q "uid:"; then
            ok "Ready (${i}s)"
            break
        fi
        sleep 1
        echo -n "."
    done

    # Wait for KeyCloak
    echo -n "  KeyCloak: "
    for i in $(seq 1 90); do
        if curl -sf "http://${AUTH_HOST}:8080/health/ready" 2>/dev/null | grep -q "UP"; then
            ok "Ready (${i}s)"
            break
        fi
        sleep 1
        echo -n "."
    done

    echo ""
    echo "============================================================"
    echo -e "${GREEN}Auth Test Environment is Ready!${NC}"
    echo "============================================================"
    echo ""
    echo "LDAP Server:"
    echo "  URL:           ldap://${AUTH_HOST}:3389"
    echo "  Admin DN:      cn=admin,dc=purl,dc=test"
    echo "  Admin Pass:    admin_password"
    echo "  Search Base:   dc=purl,dc=test"
    echo "  phpLDAPadmin:  https://${AUTH_HOST}:6443"
    echo ""
    echo "KeyCloak (SAML IdP):"
    echo "  Admin Console: http://${AUTH_HOST}:8080"
    echo "  Admin User:    admin / admin"
    echo "  Realm:         purl"
    echo "  IdP Entity ID: http://${AUTH_HOST}:8080/realms/purl"
    echo "  IdP SSO URL:   http://${AUTH_HOST}:8080/realms/purl/protocol/saml"
    echo ""
    echo "Test Users (both LDAP & KeyCloak):"
    echo "  john.doe    / password123  (admins, developers)"
    echo "  jane.smith  / password123  (developers)"
    echo "  bob.wilson  / password123  (viewers)"
    echo ""
    echo "============================================================"
    echo -e "${YELLOW}Purl Settings Configuration:${NC}"
    echo "============================================================"
    echo ""
    echo "--- LDAP Settings (paste into Purl UI) ---"
    echo "  LDAP Server URL:   ldap://${AUTH_HOST}"
    echo "  Port:              3389"
    echo "  TLS Verify:        None"
    echo "  Use TLS/LDAPS:     Off"
    echo "  Bind DN:           cn=admin,dc=purl,dc=test"
    echo "  Bind Password:     admin_password"
    echo "  Search Base:       ou=users,dc=purl,dc=test"
    echo "  Mode:              OpenLDAP"
    echo "  Search Filter:     (uid={username})"
    echo ""
    echo "--- SAML/SSO Settings (paste into Purl UI) ---"
    echo "  IdP Entity ID:     http://${AUTH_HOST}:8080/realms/purl"
    echo "  IdP SSO URL:       http://${AUTH_HOST}:8080/realms/purl/protocol/saml"
    echo "  SP Entity ID:      ${PURL_URL}"
    echo "  ACS URL:           ${PURL_URL}/api/auth/sso/callback"
    echo "  NameID Format:     emailAddress"
    echo ""
    echo "  IdP Certificate:   Download from KeyCloak:"
    echo "    1. Go to http://${AUTH_HOST}:8080/admin"
    echo "    2. Select 'purl' realm"
    echo "    3. Realm Settings → Keys → RS256 → Certificate"
    echo "    4. Copy and wrap in BEGIN/END CERTIFICATE"
    echo "============================================================"
}

cmd_stop() {
    info "Stopping auth test environment..."
    cd "$PROJECT_DIR"
    docker compose -f "$COMPOSE_FILE" down
    ok "Services stopped"
}

cmd_status() {
    cd "$PROJECT_DIR"
    docker compose -f "$COMPOSE_FILE" ps
}

cmd_test() {
    info "Testing LDAP connection..."

    # Test admin bind
    echo -n "  Admin bind: "
    if docker compose -f "$COMPOSE_FILE" exec -T openldap \
        ldapsearch -x -H ldap://localhost \
        -D "cn=admin,dc=purl,dc=test" -w "admin_password" \
        -b "dc=purl,dc=test" "(objectClass=organization)" 2>/dev/null | grep -q "dn:"; then
        ok "Success"
    else
        error "Failed"
    fi

    # Test user search
    echo -n "  User search: "
    USERS=$(docker compose -f "$COMPOSE_FILE" exec -T openldap \
        ldapsearch -x -H ldap://localhost \
        -D "cn=admin,dc=purl,dc=test" -w "admin_password" \
        -b "ou=users,dc=purl,dc=test" "(objectClass=inetOrgPerson)" uid 2>/dev/null | grep "uid:" | wc -l)
    if [ "$USERS" -ge 3 ]; then
        ok "Found $USERS users"
    else
        error "Expected 3 users, found $USERS"
    fi

    # Test user bind (john.doe)
    echo -n "  User bind (john.doe): "
    if docker compose -f "$COMPOSE_FILE" exec -T openldap \
        ldapwhoami -x -H ldap://localhost \
        -D "uid=john.doe,ou=users,dc=purl,dc=test" -w "password123" 2>/dev/null | grep -q "dn:"; then
        ok "Success"
    else
        error "Failed"
    fi

    # Test groups
    echo -n "  Groups: "
    GROUPS=$(docker compose -f "$COMPOSE_FILE" exec -T openldap \
        ldapsearch -x -H ldap://localhost \
        -D "cn=admin,dc=purl,dc=test" -w "admin_password" \
        -b "ou=groups,dc=purl,dc=test" "(objectClass=groupOfNames)" cn 2>/dev/null | grep "cn:" | wc -l)
    ok "Found $GROUPS groups"

    echo ""
    info "Testing KeyCloak..."
    echo -n "  Health: "
    if curl -sf "http://${AUTH_HOST}:8080/health/ready" 2>/dev/null | grep -q "UP"; then
        ok "Healthy"
    else
        error "Not ready"
    fi

    echo -n "  Realm 'purl': "
    if curl -sf "http://${AUTH_HOST}:8080/realms/purl" 2>/dev/null | grep -q "purl"; then
        ok "Exists"
    else
        error "Not found"
    fi

    echo -n "  SAML descriptor: "
    if curl -sf "http://${AUTH_HOST}:8080/realms/purl/protocol/saml/descriptor" 2>/dev/null | grep -q "EntityDescriptor"; then
        ok "Available"
    else
        error "Not available"
    fi
}

cmd_clean() {
    warn "This will remove all auth test data!"
    read -p "Continue? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cd "$PROJECT_DIR"
        docker compose -f "$COMPOSE_FILE" down -v
        ok "All data removed"
    else
        info "Cancelled"
    fi
}

# ============================================================
# Main
# ============================================================
case "${1:-start}" in
    start)  cmd_start  ;;
    stop)   cmd_stop   ;;
    status) cmd_status ;;
    test)   cmd_test   ;;
    clean)  cmd_clean  ;;
    *)
        echo "Usage: $0 {start|stop|status|test|clean}"
        exit 1
        ;;
esac
