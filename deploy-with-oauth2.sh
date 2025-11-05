#!/bin/bash
set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== Portainer with OAuth2 Proxy Deployment ===${NC}"

# Load environment variables
ENV_FILE="$HOME/projects/secrets/portainer.env"
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}Error: Environment file not found at $ENV_FILE${NC}"
    echo "Run ./create-keycloak-client.sh first"
    exit 1
fi

# Validate cookie secret length (must be 32 bytes = 32 hex chars)
COOKIE_SECRET=$(grep "^OAUTH2_PROXY_COOKIE_SECRET=" "$ENV_FILE" | cut -d= -f2)
if [ ${#COOKIE_SECRET} -ne 32 ]; then
    echo -e "${YELLOW}Fixing cookie secret length (must be 32 bytes)...${NC}"
    NEW_SECRET=$(openssl rand -hex 16)
    sed -i "s/^OAUTH2_PROXY_COOKIE_SECRET=.*/OAUTH2_PROXY_COOKIE_SECRET=${NEW_SECRET}/" "$ENV_FILE"
    echo -e "${GREEN}✓ Cookie secret fixed${NC}"
fi

# Stop and remove existing containers
echo -e "${YELLOW}Stopping existing Portainer containers...${NC}"
docker stop portainer 2>/dev/null || true
docker rm portainer 2>/dev/null || true
docker stop portainer-app 2>/dev/null || true
docker rm portainer-app 2>/dev/null || true
docker stop portainer-auth-proxy 2>/dev/null || true
docker rm portainer-auth-proxy 2>/dev/null || true

# Create data directory
echo -e "${YELLOW}Creating Portainer data directory...${NC}"
mkdir -p /home/administrator/projects/data/portainer

# Deploy Portainer (internal only, no Traefik labels)
echo -e "${GREEN}Deploying Portainer application (internal)...${NC}"
docker run -d \
  --name portainer-app \
  --restart unless-stopped \
  --network traefik-net \
  --network-alias portainer-app \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /home/administrator/projects/data/portainer:/data \
  -p 9001:9000 \
  portainer/portainer-ce:latest \
  --http-enabled

# Wait for Portainer to be ready
echo -e "${YELLOW}Waiting for Portainer to be ready...${NC}"
sleep 10

# Deploy OAuth2 Proxy (with Traefik labels)
echo -e "${GREEN}Deploying OAuth2 Proxy for authentication...${NC}"
docker run -d \
  --name portainer-auth-proxy \
  --restart unless-stopped \
  --network traefik-net \
  --env-file "$ENV_FILE" \
  --label "traefik.enable=true" \
  --label "traefik.docker.network=traefik-net" \
  --label "traefik.http.routers.portainer.rule=Host(\`portainer.ai-servicers.com\`)" \
  --label "traefik.http.routers.portainer.entrypoints=websecure" \
  --label "traefik.http.routers.portainer.tls=true" \
  --label "traefik.http.routers.portainer.tls.certresolver=letsencrypt" \
  --label "traefik.http.services.portainer.loadbalancer.server.port=4180" \
  quay.io/oauth2-proxy/oauth2-proxy:latest

# Connect to keycloak network for authentication
echo -e "${YELLOW}Connecting OAuth2 proxy to Keycloak network...${NC}"
docker network connect keycloak-net portainer-auth-proxy 2>/dev/null || true

# Check deployment status
echo -e "${YELLOW}Checking deployment status...${NC}"
sleep 5

if docker ps | grep -q portainer-app && docker ps | grep -q portainer-auth-proxy; then
    echo -e "${GREEN}✓ Deployment successful!${NC}"
    echo ""
    echo -e "${GREEN}=== Portainer OAuth2 Deployment Complete ===${NC}"
    echo ""
    echo -e "${YELLOW}Access URLs:${NC}"
    echo "  - Protected (SSO): https://portainer.ai-servicers.com"
    echo "  - Direct (bypass): http://linuxserver.lan:9001"
    echo ""
    echo -e "${YELLOW}Authentication:${NC}"
    echo "  - Login via Keycloak SSO"
    echo "  - Users must exist in Keycloak"
    echo ""
    echo -e "${YELLOW}OAuth2 endpoints:${NC}"
    echo "  - User info: https://portainer.ai-servicers.com/oauth2/userinfo"
    echo "  - Sign out: https://portainer.ai-servicers.com/oauth2/sign_out"
else
    echo -e "${RED}✗ Deployment failed${NC}"
    echo "Check logs:"
    echo "  docker logs portainer-app"
    echo "  docker logs portainer-auth-proxy"
    exit 1
fi