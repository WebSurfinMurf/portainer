#!/bin/bash
set -e

echo "🚀 Deploying Portainer with OAuth2"
echo "===================================="
echo ""

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Environment file
ENV_FILE="$HOME/projects/secrets/portainer.env"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- Pre-deployment Checks ---
echo "🔍 Pre-deployment checks..."

# Check environment file
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Environment file not found: $ENV_FILE${NC}"
    echo "Run ./create-keycloak-client.sh first"
    exit 1
fi
echo -e "${GREEN}✅ Environment file exists${NC}"

# Validate cookie secret length (must be 32 bytes)
COOKIE_SECRET=$(grep "^OAUTH2_PROXY_COOKIE_SECRET=" "$ENV_FILE" | cut -d= -f2)
if [ ${#COOKIE_SECRET} -ne 32 ]; then
    echo -e "${YELLOW}⚠️  Fixing cookie secret length (must be 32 bytes)...${NC}"
    NEW_SECRET=$(openssl rand -hex 16)
    sed -i "s/^OAUTH2_PROXY_COOKIE_SECRET=.*/OAUTH2_PROXY_COOKIE_SECRET=${NEW_SECRET}/" "$ENV_FILE"
    echo -e "${GREEN}✅ Cookie secret fixed${NC}"
fi

# Check if networks exist
for network in traefik-net keycloak-net; do
    if ! docker network inspect "$network" &>/dev/null; then
        echo -e "${RED}❌ $network network not found${NC}"
        echo "Run: /home/administrator/projects/infrastructure/setup-networks.sh"
        exit 1
    fi
done
echo -e "${GREEN}✅ All required networks exist${NC}"

# Create data directory
if [ ! -d "/home/administrator/projects/data/portainer" ]; then
    echo "Creating Portainer data directory..."
    mkdir -p /home/administrator/projects/data/portainer
fi
echo -e "${GREEN}✅ Portainer data directory ready${NC}"

# Validate docker-compose.yml syntax
echo ""
echo "✅ Validating docker-compose.yml..."
if ! docker compose config > /dev/null 2>&1; then
    echo -e "${RED}❌ docker-compose.yml validation failed${NC}"
    docker compose config
    exit 1
fi
echo -e "${GREEN}✅ docker-compose.yml is valid${NC}"

# --- Deployment ---
echo ""
echo "🚀 Deploying Portainer..."
docker compose up -d --remove-orphans

# --- Post-deployment Validation ---
echo ""
echo "⏳ Waiting for Portainer to be ready..."
timeout 30 bash -c 'until docker logs portainer 2>&1 | grep -q "starting HTTP server"; do sleep 2; done' || {
    echo -e "${RED}❌ Portainer failed to start${NC}"
    docker logs portainer --tail 30
    exit 1
}
echo -e "${GREEN}✅ Portainer is ready${NC}"

echo ""
echo "⏳ Waiting for OAuth2 proxy to be ready..."
timeout 30 bash -c 'until docker logs portainer-auth-proxy 2>&1 | grep -q "OAuthProxy configured"; do sleep 2; done' || {
    echo -e "${RED}❌ OAuth2 proxy failed to start${NC}"
    docker logs portainer-auth-proxy --tail 30
    exit 1
}
echo -e "${GREEN}✅ OAuth2 proxy is ready${NC}"

# --- Summary ---
echo ""
echo "=========================================="
echo "✅ Portainer Deployment Summary"
echo "=========================================="
echo "Containers: portainer, portainer-auth-proxy"
echo "Image: portainer/portainer-ce:latest"
echo "Networks: traefik-net, keycloak-net"
echo ""
echo "Access:"
echo "  - External (SSO): https://portainer.ai-servicers.com"
echo "  - Local (bypass): http://localhost:9001"
echo ""
echo "Authentication:"
echo "  - SSO: Click 'Sign in with Keycloak SSO'"
echo "  - Users must exist in Keycloak"
echo ""
echo "=========================================="
echo ""
echo "📊 View logs:"
echo "   docker logs portainer -f"
echo "   docker logs portainer-auth-proxy -f"
echo ""
echo "✅ Deployment complete!"
