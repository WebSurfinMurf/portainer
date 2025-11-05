#!/bin/bash
set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== Creating Keycloak Client for Portainer ===${NC}"
echo ""

# Variables
KEYCLOAK_URL="https://keycloak.ai-servicers.com"
REALM="master"
CLIENT_ID="portainer"
ADMIN_USER="admin"
ADMIN_PASSWORD="Pass123lr!"

# Get access token
echo -e "${YELLOW}Authenticating with Keycloak...${NC}"
TOKEN_RESPONSE=$(curl -k -s -X POST \
  "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=${ADMIN_USER}" \
  -d "password=${ADMIN_PASSWORD}" \
  -d "grant_type=password" \
  -d "client_id=admin-cli")

TOKEN=$(echo $TOKEN_RESPONSE | python3 -c "import sys, json; print(json.load(sys.stdin).get('access_token', ''))" 2>/dev/null || echo "")

if [ -z "$TOKEN" ]; then
    echo -e "${RED}Failed to authenticate with Keycloak${NC}"
    echo "Response: $TOKEN_RESPONSE"
    exit 1
fi

echo -e "${GREEN}✓ Authenticated successfully${NC}"

# Check if client exists and get its ID
echo -e "${YELLOW}Checking for existing client...${NC}"
CLIENTS=$(curl -k -s \
  -H "Authorization: Bearer ${TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients")

CLIENT_UUID=$(echo $CLIENTS | python3 -c "
import sys, json
clients = json.load(sys.stdin)
for client in clients:
    if client.get('clientId') == '${CLIENT_ID}':
        print(client.get('id'))
        break
" 2>/dev/null || echo "")

# Delete existing client if found
if [ ! -z "$CLIENT_UUID" ]; then
    echo -e "${YELLOW}Removing existing client...${NC}"
    curl -k -s -X DELETE \
      -H "Authorization: Bearer ${TOKEN}" \
      "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}"
    echo -e "${GREEN}✓ Existing client removed${NC}"
fi

# Create new client
echo -e "${YELLOW}Creating new Portainer client...${NC}"
CLIENT_CONFIG='{
  "clientId": "portainer",
  "name": "Portainer CE",
  "description": "Docker management interface",
  "rootUrl": "https://portainer.ai-servicers.com",
  "adminUrl": "https://portainer.ai-servicers.com",
  "baseUrl": "https://portainer.ai-servicers.com",
  "enabled": true,
  "clientAuthenticatorType": "client-secret",
  "redirectUris": [
    "https://portainer.ai-servicers.com/oauth2/callback",
    "https://portainer.ai-servicers.com/*"
  ],
  "webOrigins": [
    "https://portainer.ai-servicers.com"
  ],
  "publicClient": false,
  "protocol": "openid-connect",
  "standardFlowEnabled": true,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": true,
  "serviceAccountsEnabled": false,
  "authorizationServicesEnabled": false,
  "fullScopeAllowed": true,
  "defaultClientScopes": [
    "web-origins",
    "profile",
    "roles",
    "email",
    "groups"
  ],
  "optionalClientScopes": [
    "address",
    "phone",
    "offline_access",
    "microprofile-jwt"
  ]
}'

curl -k -s -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${CLIENT_CONFIG}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients"

echo -e "${GREEN}✓ Client created${NC}"

# Get the new client ID
echo -e "${YELLOW}Retrieving client details...${NC}"
CLIENTS=$(curl -k -s \
  -H "Authorization: Bearer ${TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients")

CLIENT_UUID=$(echo $CLIENTS | python3 -c "
import sys, json
clients = json.load(sys.stdin)
for client in clients:
    if client.get('clientId') == '${CLIENT_ID}':
        print(client.get('id'))
        break
" 2>/dev/null || echo "")

if [ -z "$CLIENT_UUID" ]; then
    echo -e "${RED}Failed to create client${NC}"
    exit 1
fi

# Get client secret
echo -e "${YELLOW}Retrieving client secret...${NC}"
SECRET_RESPONSE=$(curl -k -s \
  -H "Authorization: Bearer ${TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}/client-secret")

CLIENT_SECRET=$(echo $SECRET_RESPONSE | python3 -c "import sys, json; print(json.load(sys.stdin).get('value', ''))" 2>/dev/null || echo "")

if [ -z "$CLIENT_SECRET" ]; then
    # Generate new secret
    curl -k -s -X POST \
      -H "Authorization: Bearer ${TOKEN}" \
      "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}/client-secret"
    
    SECRET_RESPONSE=$(curl -k -s \
      -H "Authorization: Bearer ${TOKEN}" \
      "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}/client-secret")
    
    CLIENT_SECRET=$(echo $SECRET_RESPONSE | python3 -c "import sys, json; print(json.load(sys.stdin).get('value', ''))" 2>/dev/null || echo "")
fi

echo -e "${GREEN}✓ Client secret retrieved${NC}"

# Create or update environment file
ENV_FILE="$HOME/projects/secrets/portainer.env"
echo -e "${YELLOW}Creating environment file...${NC}"

cat > ${ENV_FILE} << EOF
# Portainer OAuth2 Proxy Configuration
OAUTH2_PROXY_CLIENT_ID=portainer
OAUTH2_PROXY_CLIENT_SECRET=${CLIENT_SECRET}
OAUTH2_PROXY_COOKIE_SECRET=$(openssl rand -hex 16)
OAUTH2_PROXY_PROVIDER=keycloak-oidc
OAUTH2_PROXY_OIDC_ISSUER_URL=https://keycloak.ai-servicers.com/realms/master
OAUTH2_PROXY_REDIRECT_URL=https://portainer.ai-servicers.com/oauth2/callback
OAUTH2_PROXY_EMAIL_DOMAINS=*
OAUTH2_PROXY_COOKIE_SECURE=true
OAUTH2_PROXY_COOKIE_SAMESITE=lax
OAUTH2_PROXY_UPSTREAMS=http://portainer-app:9000/
OAUTH2_PROXY_PASS_HOST_HEADER=false
OAUTH2_PROXY_HTTP_ADDRESS=0.0.0.0:4180
OAUTH2_PROXY_REVERSE_PROXY=true
OAUTH2_PROXY_SKIP_PROVIDER_BUTTON=true
OAUTH2_PROXY_WHITELIST_DOMAINS=.ai-servicers.com
OAUTH2_PROXY_SCOPE=openid email profile groups
EOF

echo -e "${GREEN}✓ Environment file created${NC}"

echo ""
echo -e "${GREEN}=== Keycloak Client Setup Complete ===${NC}"
echo ""
echo -e "${BLUE}Client Details:${NC}"
echo "  Client ID: portainer"
echo "  Client Secret: ${CLIENT_SECRET:0:20}..."
echo "  Environment File: ${ENV_FILE}"
echo ""
echo -e "${YELLOW}Next step:${NC} Run ./deploy-with-oauth2.sh to deploy Portainer with OAuth2 protection"