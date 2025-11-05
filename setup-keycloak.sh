#!/bin/bash
set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== Keycloak Client Setup for Portainer ===${NC}"
echo ""

# Check if Keycloak is running
if ! docker ps | grep -q keycloak; then
    echo -e "${RED}Error: Keycloak container is not running${NC}"
    exit 1
fi

# Get Keycloak admin password
KEYCLOAK_ADMIN_PASSWORD="Admin2025!"
echo -e "${YELLOW}Using configured admin password...${NC}"

# Get Keycloak URL
KEYCLOAK_URL="https://keycloak.ai-servicers.com"

# Authenticate and get access token
echo -e "${YELLOW}Authenticating with Keycloak...${NC}"
TOKEN=$(curl -k -s -X POST \
  "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin" \
  -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)

if [ -z "$TOKEN" ]; then
    echo -e "${RED}Failed to authenticate with Keycloak${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Authenticated successfully${NC}"

# Create Portainer client
echo -e "${YELLOW}Creating Portainer client...${NC}"
CLIENT_CONFIG=$(cat <<EOF
{
  "clientId": "portainer",
  "name": "Portainer CE",
  "description": "Docker management interface",
  "rootUrl": "https://portainer.ai-servicers.com",
  "adminUrl": "https://portainer.ai-servicers.com",
  "baseUrl": "https://portainer.ai-servicers.com",
  "surrogateAuthRequired": false,
  "enabled": true,
  "alwaysDisplayInConsole": false,
  "clientAuthenticatorType": "client-secret",
  "secret": "",
  "redirectUris": [
    "https://portainer.ai-servicers.com/*"
  ],
  "webOrigins": [
    "https://portainer.ai-servicers.com"
  ],
  "notBefore": 0,
  "bearerOnly": false,
  "consentRequired": false,
  "standardFlowEnabled": true,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": true,
  "serviceAccountsEnabled": false,
  "publicClient": false,
  "frontchannelLogout": false,
  "protocol": "openid-connect",
  "attributes": {
    "saml.force.post.binding": "false",
    "saml.multivalued.roles": "false",
    "oauth2.device.authorization.grant.enabled": "false",
    "backchannel.logout.revoke.offline.tokens": "false",
    "saml.server.signature.keyinfo.ext": "false",
    "use.refresh.tokens": "true",
    "oidc.ciba.grant.enabled": "false",
    "backchannel.logout.session.required": "true",
    "client_credentials.use_refresh_token": "false",
    "require.pushed.authorization.requests": "false",
    "saml.client.signature": "false",
    "id.token.as.detached.signature": "false",
    "saml.assertion.signature": "false",
    "saml.encrypt": "false",
    "saml.server.signature": "false",
    "exclude.session.state.from.auth.response": "false",
    "saml.artifact.binding": "false",
    "saml_force_name_id_format": "false",
    "acr.loa.map": "{}",
    "tls.client.certificate.bound.access.tokens": "false",
    "saml.authnstatement": "false",
    "display.on.consent.screen": "false",
    "token.response.type.bearer.lower-case": "false",
    "saml.onetimeuse.condition": "false"
  },
  "authenticationFlowBindingOverrides": {},
  "fullScopeAllowed": true,
  "nodeReRegistrationTimeout": -1,
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
}
EOF
)

# Check if client already exists
EXISTING_CLIENT=$(curl -k -s \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  "${KEYCLOAK_URL}/admin/realms/master/clients" | grep -o '"clientId":"portainer"' || true)

if [ ! -z "$EXISTING_CLIENT" ]; then
    echo -e "${YELLOW}Portainer client already exists, updating...${NC}"
    # Get client ID
    CLIENT_ID=$(curl -k -s \
      -H "Authorization: Bearer ${TOKEN}" \
      "${KEYCLOAK_URL}/admin/realms/master/clients" | \
      grep -o '"id":"[^"]*","clientId":"portainer"' | \
      sed 's/.*"id":"\([^"]*\)".*/\1/')
    
    # Delete existing client
    curl -k -s -X DELETE \
      -H "Authorization: Bearer ${TOKEN}" \
      "${KEYCLOAK_URL}/admin/realms/master/clients/${CLIENT_ID}"
fi

# Create the client
curl -k -s -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${CLIENT_CONFIG}" \
  "${KEYCLOAK_URL}/admin/realms/master/clients"

echo -e "${GREEN}✓ Portainer client created${NC}"

# Get the client ID and secret
echo -e "${YELLOW}Retrieving client credentials...${NC}"
CLIENT_ID=$(curl -k -s \
  -H "Authorization: Bearer ${TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/master/clients" | \
  grep -o '"id":"[^"]*","clientId":"portainer"' | \
  sed 's/.*"id":"\([^"]*\)".*/\1/')

# Get client secret
CLIENT_SECRET=$(curl -k -s \
  -H "Authorization: Bearer ${TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/master/clients/${CLIENT_ID}/client-secret" | \
  grep -o '"value":"[^"]*' | cut -d'"' -f4)

if [ -z "$CLIENT_SECRET" ]; then
    # Generate new secret if none exists
    curl -k -s -X POST \
      -H "Authorization: Bearer ${TOKEN}" \
      "${KEYCLOAK_URL}/admin/realms/master/clients/${CLIENT_ID}/client-secret"
    
    CLIENT_SECRET=$(curl -k -s \
      -H "Authorization: Bearer ${TOKEN}" \
      "${KEYCLOAK_URL}/admin/realms/master/clients/${CLIENT_ID}/client-secret" | \
      grep -o '"value":"[^"]*' | cut -d'"' -f4)
fi

echo -e "${GREEN}✓ Client secret retrieved${NC}"

# Update environment file with the client secret
echo -e "${YELLOW}Updating environment file with client secret...${NC}"
sed -i "s/OAUTH2_PROXY_CLIENT_SECRET=.*/OAUTH2_PROXY_CLIENT_SECRET=${CLIENT_SECRET}/" $HOME/projects/secrets/portainer.env

# Generate cookie secret if needed
if grep -q "OAUTH2_PROXY_COOKIE_SECRET=\$(openssl" $HOME/projects/secrets/portainer.env; then
    COOKIE_SECRET=$(openssl rand -hex 32)
    sed -i "s/OAUTH2_PROXY_COOKIE_SECRET=.*/OAUTH2_PROXY_COOKIE_SECRET=${COOKIE_SECRET}/" $HOME/projects/secrets/portainer.env
fi

echo -e "${GREEN}✓ Environment file updated${NC}"
echo ""
echo -e "${GREEN}=== Keycloak Setup Complete ===${NC}"
echo ""
echo -e "${BLUE}Client Details:${NC}"
echo "  Client ID: portainer"
echo "  Client Secret: ${CLIENT_SECRET:0:20}..."
echo "  Redirect URI: https://portainer.ai-servicers.com/oauth2/callback"
echo ""
echo -e "${YELLOW}Next step:${NC} Run ./deploy.sh to deploy Portainer with OAuth2"