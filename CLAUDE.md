# Portainer - Docker Management Interface

## Project Overview
Portainer provides a web-based interface for managing Docker containers, images, networks, and volumes with Keycloak SSO integration.

## Current Status
- **Status**: ✅ RUNNING
- **Containers**: portainer-app, portainer-auth-proxy
- **Port**: 9001 (local), 9000 (internal)
- **Network**: traefik-net
- **External URL**: https://portainer.ai-servicers.com (with OAuth2)
- **Last Updated**: 2025-09-30

## Architecture
```
User → Traefik (HTTPS)
    ↓
OAuth2 Proxy → Keycloak SSO
    ↓
Portainer Application
    ↓
Docker Socket (/var/run/docker.sock)
```

## Deployment Modes

### 1. Production (with OAuth2/Keycloak SSO)
**Script**: `deploy-with-oauth2.sh`
- **External URL**: https://portainer.ai-servicers.com
- **Authentication**: Keycloak SSO (administrators group)
- **Access**: Internet-facing with SSO protection

### 2. Simple (Basic Authentication)
**Script**: `deploy-simple.sh`
- **Local Port**: 9001
- **Authentication**: Portainer native login
- **Access**: Local network only

### 3. Standard (Docker Compose)
**Script**: `deploy.sh`
- Uses docker-compose.yml
- Configurable deployment options

## Files & Paths
- **Deploy Scripts**:
  - `/home/administrator/projects/portainer/deploy-with-oauth2.sh` (Production SSO)
  - `/home/administrator/projects/portainer/deploy-simple.sh` (Simple mode)
  - `/home/administrator/projects/portainer/deploy.sh` (Standard)
- **Configuration**: `/home/administrator/projects/portainer/docker-compose.yml`
- **Secrets**: `$HOME/projects/secrets/portainer.env`
- **Data Volume**: `/home/administrator/data/portainer`

## Keycloak SSO Configuration

### OAuth2 Proxy Settings
Located in `$HOME/projects/secrets/portainer.env`:
- **Client ID**: portainer
- **Client Secret**: Generated during setup
- **Redirect URI**: https://portainer.ai-servicers.com/oauth2/callback
- **Cookie Secret**: Auto-generated (32 bytes)
- **Group Restriction**: administrators

### Network Configuration
- **Login URL**: https://keycloak.ai-servicers.com (external for browser)
- **Token/JWKS URLs**: http://keycloak:8080 (internal for container)
- **Skip OIDC Discovery**: Enabled due to URL mismatch

## Access Methods

### Production (SSO)
```bash
cd /home/administrator/projects/portainer
./deploy-with-oauth2.sh
# Access: https://portainer.ai-servicers.com
```

### Simple Mode
```bash
cd /home/administrator/projects/portainer
./deploy-simple.sh
# Access: http://localhost:9001
```

## Common Commands
```bash
# Check status
docker ps | grep portainer

# View logs (application)
docker logs portainer-app --tail 50

# View logs (OAuth proxy)
docker logs portainer-auth-proxy --tail 50

# Restart
docker restart portainer-app portainer-auth-proxy

# Deploy with SSO
cd /home/administrator/projects/portainer
./deploy-with-oauth2.sh

# Deploy simple mode
./deploy-simple.sh
```

## Features
- ✅ **Container Management**: Start, stop, restart, remove containers
- ✅ **Image Management**: Pull, build, tag, remove images
- ✅ **Network Management**: Create, inspect, remove networks
- ✅ **Volume Management**: Create, browse, remove volumes
- ✅ **Stack Deployment**: Deploy docker-compose stacks
- ✅ **Console Access**: Attach to container terminals
- ✅ **Log Viewing**: Real-time container logs
- ✅ **Resource Monitoring**: CPU, memory, network stats

## Security Notes
- OAuth2 proxy restricts access to administrators group
- Direct container access (port 9000) not exposed externally
- Docker socket mounted (full Docker control)
- HTTPS enforced via Traefik
- Cookie secret auto-generated (32 bytes)

## Troubleshooting

### OAuth2 Forbidden After Login
- **Cause**: User not in administrators group
- **Solution**: Add user to /administrators group in Keycloak

### Cookie Secret Error
- **Cause**: Cookie secret not 32 bytes
- **Solution**: Script auto-fixes on deployment

### Container Can't Reach Keycloak
- **Cause**: External URL used for internal communication
- **Solution**: Use http://keycloak:8080 for token/JWKS endpoints

### Issuer Mismatch
- **Cause**: Keycloak reports external URL, proxy connects internally
- **Solution**: Set OAUTH2_PROXY_SKIP_OIDC_DISCOVERY=true

## Non-Standard Scripts Explained

### deploy-with-oauth2.sh
**Purpose**: Production deployment with Keycloak SSO integration
- Deploys OAuth2 proxy for authentication
- Configures Traefik routing
- Restricts access to administrators group
- **Keep**: Required for SSO functionality

### deploy-simple.sh
**Purpose**: Quick local deployment without SSO
- No authentication proxy
- Direct container access on port 9001
- Useful for testing or local development
- **Keep**: Provides alternative deployment option

## Data Persistence
- **Volume**: /home/administrator/data/portainer
- **Contents**:
  - Portainer database (SQLite)
  - User settings
  - Environment configurations
  - Stack definitions

## Integration with Infrastructure
- **Docker Socket**: Full Docker API access
- **Networks**: Connected to traefik-net
- **Monitoring**: Can view all containers across all networks
- **Stacks**: Can deploy any docker-compose configuration

## Related Documentation
- OAuth2 Proxy: https://oauth2-proxy.github.io/oauth2-proxy/
- Portainer Docs: https://docs.portainer.io/
- Keycloak Integration: `/home/administrator/projects/keycloak/CLAUDE.md`

---
*Created: 2025-09-30 by Claude*
*Status: Running with OAuth2/Keycloak SSO integration*
