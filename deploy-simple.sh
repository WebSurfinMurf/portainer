#!/bin/bash
set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== Simple Portainer Deployment with Traefik ===${NC}"

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

# Deploy Portainer with Traefik labels directly
echo -e "${GREEN}Deploying Portainer with Traefik...${NC}"
docker run -d \
  --name portainer \
  --restart unless-stopped \
  --network traefik-net \
  -p 9000:9000 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /home/administrator/projects/data/portainer:/data \
  --label "traefik.enable=true" \
  --label "traefik.docker.network=traefik-net" \
  --label "traefik.http.routers.portainer.rule=Host(\`portainer.ai-servicers.com\`)" \
  --label "traefik.http.routers.portainer.entrypoints=websecure" \
  --label "traefik.http.routers.portainer.tls=true" \
  --label "traefik.http.routers.portainer.tls.certresolver=letsencrypt" \
  --label "traefik.http.services.portainer.loadbalancer.server.port=9000" \
  portainer/portainer-ce:latest

# Wait for Portainer to be ready
echo -e "${YELLOW}Waiting for Portainer to be ready...${NC}"
sleep 10

# Check if Portainer is running
if docker ps | grep -q portainer; then
    echo -e "${GREEN}✓ Portainer deployment complete!${NC}"
    echo ""
    echo -e "${YELLOW}Access Portainer at:${NC}"
    echo "  - External: https://portainer.ai-servicers.com"
    echo "  - Internal: http://linuxserver.lan:9000"
    echo ""
    echo -e "${YELLOW}Note:${NC} This is a simple deployment without OAuth2."
    echo "Use Portainer's built-in authentication for now."
else
    echo -e "${RED}✗ Portainer deployment failed${NC}"
    docker logs portainer --tail 20
    exit 1
fi