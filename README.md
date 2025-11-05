# Portainer Deployment

## Current Status
✅ **DEPLOYED** - Portainer is running with Traefik integration

## Access URLs
- **External (HTTPS)**: https://portainer.ai-servicers.com
- **Internal (HTTP)**: http://linuxserver.lan:9000

## Architecture
```
Internet → Traefik (443) → Portainer (9000)
              ↓
         SSL/TLS (Let's Encrypt)
```

## Current Authentication
Using Portainer's built-in authentication system. First-time setup requires creating an admin account.

## Deployment Scripts

### 1. Simple Deployment (Currently Active)
```bash
./deploy-simple.sh
```
- Direct Traefik integration
- Exposed on port 9000 for internal access
- SSL/TLS via Traefik
- No OAuth2 proxy (uses Portainer's built-in auth)

### 2. OAuth2 Deployment (Ready but not active)
```bash
# First create Keycloak client
./create-keycloak-client.sh

# Then deploy with OAuth2
./deploy-with-oauth2.sh
```
- Requires Keycloak authentication
- OAuth2 Proxy in front of Portainer
- Single Sign-On (SSO) integration

## Directory Structure
```
/home/administrator/projects/portainer/
├── deploy-simple.sh           # Current active deployment
├── deploy-with-oauth2.sh      # OAuth2 protected deployment (future)
├── create-keycloak-client.sh  # Keycloak client setup
├── README.md                  # This file
└── setup-keycloak.sh          # Legacy setup script

/home/administrator/data/portainer/
└── [Portainer persistent data]

$HOME/projects/secrets/
└── portainer.env              # OAuth2 environment variables
```

## Features
- ✅ Docker container management
- ✅ Docker Compose deployment
- ✅ Container logs and console access
- ✅ Image management
- ✅ Network management
- ✅ Volume management
- ✅ Stack deployment (docker-compose)
- ✅ User access control (built-in)

## Container Details
- **Image**: portainer/portainer-ce:latest
- **Network**: traefik-net
- **Volumes**: 
  - `/var/run/docker.sock:/var/run/docker.sock` (Docker API access)
  - `/home/administrator/data/portainer:/data` (Persistent storage)

## Traefik Labels
```yaml
traefik.enable: true
traefik.docker.network: traefik-net
traefik.http.routers.portainer.rule: Host(`portainer.ai-servicers.com`)
traefik.http.routers.portainer.entrypoints: websecure
traefik.http.routers.portainer.tls: true
traefik.http.routers.portainer.tls.certresolver: letsencrypt
traefik.http.services.portainer.loadbalancer.server.port: 9000
```

## Future OAuth2 Integration
When Keycloak admin access is restored, OAuth2 can be enabled:

1. Fix Keycloak admin password issue
2. Run `./create-keycloak-client.sh` to create OAuth2 client
3. Deploy with `./deploy-with-oauth2.sh`
4. Access will then require Keycloak authentication

### OAuth2 Configuration (When Ready)
```bash
# Environment variables in $HOME/projects/secrets/portainer.env
OAUTH2_PROXY_CLIENT_ID=portainer
OAUTH2_PROXY_CLIENT_SECRET=[from-keycloak]
OAUTH2_PROXY_PROVIDER=keycloak-oidc
OAUTH2_PROXY_OIDC_ISSUER_URL=https://keycloak.ai-servicers.com/realms/master
OAUTH2_PROXY_REDIRECT_URL=https://portainer.ai-servicers.com/oauth2/callback
```

## Troubleshooting

### Check Status
```bash
docker ps | grep portainer
docker logs portainer --tail 50
```

### Restart Portainer
```bash
docker restart portainer
```

### Redeploy
```bash
./deploy-simple.sh
```

### Test Access
```bash
# External
curl -k -I https://portainer.ai-servicers.com

# Internal
curl -I http://linuxserver.lan:9000
```

## Security Notes
1. Docker socket access gives full control over the Docker daemon
2. Always use strong passwords for Portainer admin accounts
3. Consider network segmentation for production use
4. OAuth2 integration provides better security through SSO

## Backup
Portainer data is stored in `/home/administrator/data/portainer/`. Include this directory in regular backups.

---
*Last Updated: 2025-08-27*
*Status: Production Ready (without OAuth2)*