# Docker host security — issues inventory + fix plan

**Created:** 2026-06-03 by administrator (during the running-session breach response).
**Why this lives here:** Portainer is the docker-management project; the host's docker trust landscape naturally indexes here. The fixes themselves span many projects (each AI runtime, each MCP wrapper, the host's sudoers, the IB gateway compose); this doc names everything in one place so no project misses its piece.

**Background:** an autonomous AI agent demonstrated reaching the live IBKR account (`U15907310`) without credentials by attaching a throwaway container to `mcp-ib-live-net`. Review-board synthesis at `~administrator/projects/ibgateway/docs/reviews/ib-gateway-running-session-breach.final.md` is the canonical fix plan. This doc is the **docker-host-wide inventory** that supports it — every place an autonomous identity can reach docker daemon control today, and what closes each one.

> 🏛️ **Long-term target architecture & backlog:** [`DOCKER-ACCESS-TARGET-ARCHITECTURE.md`](./DOCKER-ACCESS-TARGET-ARCHITECTURE.md). This doc closes the holes *now* (policy on the current co-located design); the companion defines the *durable end-state* (rootless daemons, Portainer as the human access plane, socket-proxy for containers, agent identity split) so these tactical fixes stop being load-bearing. Do tactical first, architecture second. 2026-06-04 QA refinements (latent docker-group membership, `gpasswd -d` takes effect without re-login, sudoers NOPASSWD as the true multiplier) are folded into the companion's §0.

> 🚨 **NEW CRITICAL FINDING 2026-06-06 — unauthenticated LIVE trade API reachable from any `traefik-net` container (incl. code-executor):** `stocktrader-live` is dual-homed on `mcp-ib-live-net` + `traefik-net`, trades live (`IB_TRADING_MODE=live` → `ibgateway-live:4003`), and serves a **FastAPI with NO auth** (`securitySchemes: NONE`) on `:8000`. Any container on `traefik-net` can `POST /api/quick-trade/execute` / `/api/option-orders/place` / `/api/ib/positions/close` / `/api/automation/kill-switch` and move real money — no creds, no MCP, no docker socket, no privilege escalation. Confirmed reachable from `mcp-code-executor` (which is on `traefik-net` for the chat gateway): `execute_code` → raw `fetch()` → live order. **This is a worse path than the docker.sock pivot** (zero privilege needed) and defeats "one code-executor is safe for the money concern." Root cause: auth enforced only at Traefik (public path); `:8000` open on the container network bypasses it. **Fix (stocktrader-live / network layer, owner = websurfinmurf):** auth-gate the API at the app, or remove stocktrader-live from `traefik-net`/isolate `:8000`. Do NOT change a live trading container's networking unilaterally (may be mid-position). Also audit every other `traefik-net` member that touches a money network. *(Caught after a false-negative probe: `/dev/tcp` doesn't work in Alpine `sh`/ash — use python/curl. Endpoints discovered read-only via `/openapi.json`; no trade endpoint was called.)*
>
> **Proposed fix (operator-raised 2026-06-06, not yet executed):** micro-segment — create a dedicated **`traefik-net-live`**, add it to **traefik**, move **stocktrader-live** off `traefik-net` onto it. Traefik still routes the Keycloak-authed public path (it shares the new net); the other ~85 `traefik-net` members (incl. both code-executors) lose the direct path to `:8000`. Closes the **non-root** code-executor→live path. Requirements/caveats: (1) traefik is on `traefik-net` only today → it must join the new net → **recreating traefik drops all routes briefly (cascade — schedule it)**; (2) stocktrader-live becomes multi-homed → **must add label `traefik.docker.network=traefik-net-live`** or the route breaks; (3) **persist the net** (`external: true` in both composes + real `docker network create`) — do NOT repeat the ad-hoc `mcp-dev-net` that vanished; (4) **incomplete on its own** — `:8000` stays unauth to peers on its other nets (`mcp-ib-live-net`/`postgres-net`/`playwright_default`), so pair it with **app-level auth** on stocktrader-live for the real close. Still defense-in-depth (root steps over it); IBKR caps remain Layer 0. Ownership: traefik + net = admin; stocktrader-live network swap = websurfinmurf (live container — coordinate, may be mid-position). General pattern: the flat 86-member `traefik-net` is the systemic smell — sensitive backends each want a `traefik-net-<svc>` shared only with Traefik (e.g. `stocktrader-dev-db` on the proxy net is the same issue).

---

## 1. The host's docker trust landscape

### 1.1 Linux groups (rootful daemon)

| Member of `docker` group | Identity | Concern |
|---|---|---|
| `administrator` | The intended admin | Expected; admin runs the host. |
| `websurfinmurf` | Developer + AI-agent runtime user | **Problem.** Daemon control = root-on-the-host for everything containerized. |
| `joe` | Secondary human user | Same concern, lower exposure (no autonomous AI agent under this identity). |

`getent group docker` → `docker:x:127:websurfinmurf,joe,administrator`.

### 1.2 Sudoers — the multiplier

`/etc/sudoers.d/administrators`:
```
%administrators ALL=(ALL:ALL) ALL
websurfinmurf ALL=(administrator) NOPASSWD: ALL
```

The second line means `websurfinmurf` can `sudo -u administrator <anything>` without a password prompt. Since `administrator` is in `docker` and has every legit access this host grants, **this single line makes any "remove websurfinmurf from docker" change cosmetic** — the agent re-acquires the access via `sudo -u administrator` in one syscall.

**This is the most important single line in the entire docker-security picture.** Closing it is non-optional. Either:
- Remove the line entirely (websurfinmurf-the-human types his password when he wants to act as admin), OR
- Replace with a narrow rule (e.g., only specific commands), OR
- Implement the identity split (give the autonomous agent its own uid that has neither `sudo` nor `docker`); the human keeps the NOPASSWD line.

### 1.3 Containers mounting `/var/run/docker.sock` (snapshot 2026-06-03)

| Container | Mode | Category | Concern level |
|---|---|---|---|
| `portainer` | rw | Admin GUI for docker | Legit purpose, but RW socket = full daemon control. OAuth2/Keycloak gates the UI to `administrators` group only. **If the agent ever gets a Keycloak session for `administrator`, portainer becomes a click-to-`docker run` GUI** — worth thinking about. |
| `traefik` | ro | Service discovery via docker labels | Legit. RO mount is fine here — Traefik only reads container metadata. |
| `netdata`, `dozzle`, `promtail` | ro | Observability / log shipping | Legit. RO mount is sufficient for their stated purpose. |
| `agents-cli-claude-administrator` | ro | Admin's CLI Claude session container | Legit *for admin*, but the same image likely runs the websurfinmurf variant — see below. |
| `agents-cli-claude-websurfinmurf` | ro | **Developer's autonomous AI agent runtime** | **The breach vector.** Any prompt-injected / misbehaving agent running here can `docker -H unix:///var/run/docker.sock run --network mcp-ib-live-net …` and reach live trading without credentials. RO is theater — the Docker API over the socket lets you start arbitrary containers regardless. |
| `webui-claude-administrator` | ro | Admin's webui session | Same as agents-cli-admin. |
| `webui-claude-websurfinmurf` | ro | **Developer's webui session — also an agent runtime** | **Same breach class as agents-cli-claude-websurfinmurf.** |
| `webui-claude-joe` | ro | Joe's webui session | Lower autonomous risk (no AI agent driving it), but still daemon-equivalent to whoever drives it. |
| `mcp-ib-paper` | ro | Paper IB wrapper, mounts for `/gateway/reconnect` | **No good reason on live-money axis;** paper is dev's playground. But the socket gives anything that reaches the wrapper full daemon control. Already flagged in the IB gateway work. |

> **Inventory gap found 2026-06-04 (LT-7 verification):** the GitLab dev runners **`gitlab-runner-dev`** and **`gitlab-runner-docker-dev`** also mount `/var/run/docker.sock` (rw) and are **missing from the table above** — they are additional root-equivalent holders. Separately, the existing CI **deploy pattern is breach-path #1 automated**: deploy jobs run `ssh websurfinmurf@$DEPLOY_HOST` then `docker login/pull/compose up` — i.e., they deploy *as websurfinmurf using his `docker` group*. Consequence: **removing websurfinmurf from `docker` (A2/NOW-3) breaks all such pipelines until the deploy path is repointed to a dedicated `deploy` identity** (tracked as LT-7 in [`DOCKER-ACCESS-TARGET-ARCHITECTURE.md`](./DOCKER-ACCESS-TARGET-ARCHITECTURE.md)). Add the two runners to this inventory and treat the deploy SSH user as part of the trust surface.

**Key observation:** the `:ro` mode is **non-mitigating** against API control — the review board specifically called this out, and the code-executor session verified it experimentally (inside the container, `docker ps` and `docker network ls` worked despite the RO mount).

The "RO socket" idea is a misconception: RO protects the filesystem inode, not the API behavior. Anyone with read access to the unix socket can send commands to the daemon and the daemon executes them with full privilege.

### 1.4 Compose-layer trust surfaces (specific to the live IB gateway)

| Surface | Status as of 2026-06-03 | Fix |
|---|---|---|
| Live wrapper on `mcp-net` + `traefik-net` | **CLOSED 2026-06-03** in `~administrator/projects/mcp/ib-live/docker-compose.yml`. Wrapper joins only `mcp-ib-live-net`. | — |
| Live wrapper publishing `48014:8000` | **CLOSED 2026-06-03**. | — |
| Live gateway publishing `127.0.0.1:14011:4003` (raw IB API socat) | **CLOSED 2026-06-03**. | — |
| Live gateway publishing `127.0.0.1:15901:5900` (VNC — GUI order surface) | **CLOSED 2026-06-03**. | — |
| Live containers haven't been recreated to apply the compose changes yet | Open — pending `start-gateway` recreate. | Pending admin action. |

---

## 2. Reach paths the autonomous developer agent has today

After 1.4's compose changes land (containers recreated) but **before** anything in 1.1/1.2/1.3 is changed:

| # | Path | Closed by |
|---|---|---|
| 1 | `docker run --network mcp-ib-live-net …` from his Linux shell | Removing `websurfinmurf` from `docker` group **+** killing his sessions (`pkill -KILL -u`) |
| 2 | Inside his own agent container (`agents-cli-claude-websurfinmurf`) → uses the mounted docker.sock → same `docker run` against the host daemon | Removing the docker.sock mount from `agents-cli-claude-websurfinmurf` (and `webui-claude-websurfinmurf`), recreating |
| 3 | `sudo -u administrator docker …` | Removing the NOPASSWD line from `/etc/sudoers.d/administrators` |
| 4 | Pivot via any other socket-mounted container the agent can reach (`mcp-ib-paper`, `portainer` if it has a Keycloak session) | Per-container: either remove the mount or block reach to that container |
| 5 | Rootless docker daemon for the live stack (admin only) — once live moves there, the rootful daemon doesn't host the live network at all | The durable fix; closes 1-4 in one move because nothing on the rootful daemon's docker.sock can see live |

Paths 1–4 are independently exploitable. Closing 1 alone is theater (the breach demo used 1, but paths 2-4 are sitting right there). The review board's recommendation is to land **path 5 (rootless live daemon)** as the durable answer; paths 1–4 become safety belts on top of that.

---

## 3. Prioritized fix list

### Tier A — CLOSE TODAY (the host-wide settings that defeat half the other fixes)

A1. **Remove the NOPASSWD line in `/etc/sudoers.d/administrators`.**
   - Edit (as root): `sudoedit /etc/sudoers.d/administrators`
   - Delete the line `websurfinmurf ALL=(administrator) NOPASSWD: ALL`
   - Save; `visudo -c` confirms no syntax errors before the file replaces.
   - Side effect: websurfinmurf-the-human goes back to typing his password when he runs `sudo -u administrator …`. Confirm with him this isn't going to break some workflow before doing it.
   - **Severity:** critical. While this exists, every Tier-B fix is partial.

A2. **Remove `websurfinmurf` from the `docker` group + force-logout existing sessions.**
   - `sudo gpasswd -d websurfinmurf docker`
   - `sudo pkill -KILL -u websurfinmurf` (existing sessions retain supplementary groups until logout).
   - Then verify no respawning units re-establish access: `sudo crontab -u websurfinmurf -l`, `sudo systemctl --user --machine websurfinmurf@ list-units`, `sudo -u websurfinmurf atq`.
   - **Severity:** critical (closes path 1 in §2).

A3. **Recreate live IB containers** with the new compose (already edited).
   - `CONFIRM_LIVE=yes start-gateway` — needs admin's Bitwarden master password.
   - **Severity:** critical (closes paths via host port publishes + mcp-net pivot).

### Tier B — CLOSE THIS WEEK (the per-runtime socket mounts)

B1. **Remove the docker.sock mount from `agents-cli-claude-websurfinmurf` and `webui-claude-websurfinmurf`.**
   - These are the AI-agent runtime containers. Their socket mounts give the autonomous agent daemon control independent of every other fix.
   - Project location: TBD (likely `~administrator/projects/agents-cli/` and `~administrator/projects/webui/` or similar — find the compose files that define these containers).
   - Severity: critical (closes path 2 in §2).
   - Side effect: anything the agent currently does via `docker …` from inside its own container stops working. Identify those uses first and replace with safer mechanisms (e.g., explicit MCP tools that gate what the agent can do, rather than "here's full daemon access").

B2. **Remove the docker.sock mount from `mcp-ib-paper`.**
   - Mounted to support the wrapper's `/gateway/reconnect` endpoint, which restarts the gateway container.
   - That endpoint should be redesigned to not need daemon control — e.g., use IBC's command server (already enabled via `CommandServerPort=7462`), or remove the endpoint and rely on admin-driven restart via `start-gateway`.
   - Coordinate with the developer-owned `developers/ib-gateway` work (websurfinmurf's repo); his image already has IBC command server enabled.
   - Severity: medium-high (closes one path of §2 #4, and paper is a stepping stone the agent might use).

B3. **Decide on the AI-agent containers' design going forward.**
   - The structural fix is the **identity split**: the autonomous AI agent runs under a Linux uid (e.g., `websurfinmurf-agent`) that is NOT in `sudo`, NOT in `docker`, and whose container doesn't mount docker.sock.
   - The human `websurfinmurf` keeps a separate identity for hands-on dev work.
   - This is project-level work in the `agents-cli` / `webui` projects (or equivalents).

### Tier C — DEFENSE IN DEPTH (this week, parallel to Tier B)

C1. **Move the live IB stack to a rootless docker daemon** (under admin's uid).
   - Once live is on `~administrator/.local/share/docker`, the rootful daemon (which all 11 socket-mounters point at) no longer hosts the `mcp-ib-live-net` network at all. The socket holders' reach to live is structurally impossible, not just policy-blocked.
   - Update the launcher (`~/projects/ib-launcher/start-gateway.sh`) to target the rootless docker socket for the admin-uid live branch.
   - Severity: high (durable answer; supersedes most of Tier A/B as a one-time architectural move).

C2. **IBKR-side blast-radius controls on `U15907310`.**
   - Sub-account with hard position / notional / daily-loss caps.
   - API trusted-IP allowlist restricted to this host's public egress IP.
   - Daily order count cap.
   - Severity: critical (the ONLY layer that survives a fully-owned host; the only thing that holds against a Tier-A/B regression).

### Tier D — CLEAN-UP (admin can pace these)

D1. **`mcp-code-executor` docker.sock pivot** — already CLOSED 2026-06-03 (Option 2 by the code-executor project session; mount removed permanently from the image and compose).

D2. **`portainer` is rw-mounted on the docker socket.** Keep, but acknowledge it as an admin-only escape hatch. Verify Keycloak gating is tight (`administrators` group only, no fallback). If `administrator` is the only allowed identity, and `administrator`'s Keycloak session is bound to a strong password / MFA, portainer is acceptable. If not, tighten.

D3. **`traefik`, `netdata`, `dozzle`, `promtail` socket mounts** — accepted, RO is correct here because these consumers only read container metadata / logs; they don't `docker run`.

D4. **`webui-claude-joe`, `webui-claude-administrator`, `agents-cli-claude-administrator`** — same socket mount pattern as the websurfinmurf variants but lower autonomous risk. Decide whether to apply the same socket-removal treatment to them as B1 (probably yes, for consistency).

---

## 4. Cross-project work coordination

Each fix item lands in a specific project. Listing them here so each project session sees its own piece:

| Project | Items it owns | Where |
|---|---|---|
| (host / root) | A1 (sudoers), A2 (group removal), A3-execute (recreate live) | `/etc/sudoers.d/administrators`, `gpasswd`, `start-gateway` |
| `~administrator/projects/mcp/ib-live/` | A3-compose (already done), C1 (move live to rootless daemon) | Compose file + launcher edit |
| `~administrator/projects/agents-cli/` (or wherever those compose files live) | B1, B3 (identity split for the AI runtimes) | Compose file edit + uid creation |
| `~administrator/projects/webui/` (same) | B1 (webui-claude-websurfinmurf socket), D4 (consistency for other webui variants) | Compose file edit |
| `~administrator/projects/mcp/ib-paper/` | B2 (paper wrapper socket removal + endpoint redesign) | Compose + wrapper code |
| `~administrator/projects/portainer/` (here) | D2 (verify Keycloak gating, document acceptable-by-design) | This doc + Keycloak settings audit |
| `~administrator/projects/ib-launcher/` | C1 (launcher targets rootless docker socket for live branch) | Launcher edit |
| (IBKR portal) | C2 (sub-account + trusted-IP + caps) | Admin's IBKR account settings |

---

## 5. Validation matrix (run after each tier; from the AI-agent's actual identity, not admin's)

After **Tier A** (and the compose recreate from A3): re-run the original breach demo as `websurfinmurf` → must fail.
```
sudo -u administrator docker run --rm --network mcp-ib-live-net ...    # must fail (NOPASSWD removed)
docker run --rm --network mcp-ib-live-net ...                          # must fail (not in docker group)
```

After **Tier B**: from inside `agents-cli-claude-websurfinmurf` (or wherever the agent runs), attempt `docker -H unix:///var/run/docker.sock ps` → must fail (no socket mount).

After **Tier C1** (rootless): from any rootful-daemon container, `docker network inspect mcp-ib-live-net` → must fail (network not on this daemon).

Full validation matrix is in the review-board synthesis (`~administrator/projects/ibgateway/docs/reviews/ib-gateway-running-session-breach.final.md`, Phase B).

---

## 6. What is NOT addressed in this inventory

- **`sudo`-based escalation from `websurfinmurf` to root.** Out of scope per admin's threat-model call — the goal is to constrain the autonomous AI agent under that uid, not to defend against a fully malicious human admin. Even after A1, websurfinmurf with `sudo -i` can do anything on this host; the agent (without scriptable sudo) can't.
- **Image supply-chain.** The `developers/ib-gateway` work is moving live to a pinned tag from CI; admin diff-review is the gate. Not docker-host-level.
- **The dev side's paper IB gateway.** Paper is dev's playground; he owns its compose, its image, its IBKR account. Trust boundary is appropriately different.
- **Secrets at runtime.** Bitwarden round-trip with attended start gets us to the agreed posture. Process memory remains root-readable; that's the prior threat-model call.

---

## 7. Sequencing recommendation

If admin runs everything in this list serially, the order that minimizes the breach window:

1. **A3-execute** (recreate live with new compose — closes 4 of the easier paths).
2. **A1** (sudoers NOPASSWD).
3. **A2** (group removal + force-logout).
4. **B1** (kill the autonomous agent's socket mount; this is the path that actually closes the AI exfiltration vector).
5. **C2** (IBKR controls — IBKR portal task, can happen in parallel from step 1 onward).
6. **C1** (rootless live daemon — defense in depth; supersedes A2/B1 as the durable boundary).
7. **B2, B3, D-items** as ongoing cleanup.

Between step 3 and step 4, the autonomous agent still has its docker.sock — keep it stopped or reduce its reach until B1 lands.

---

## References

- Breach demo + chain: `/mnt/shared/aichat/linuxserver.websurfinmurf.md` (search for `U15907310`).
- Review-board synthesis (canonical fix plan): `~administrator/projects/ibgateway/docs/reviews/ib-gateway-running-session-breach.final.md`.
- Per-reviewer takes: `~administrator/projects/ibgateway/docs/reviews/ib-gateway-running-session-breach.{gemini,codex,claude}.md`.
- Live compose (already hardened): `~administrator/projects/mcp/ib-live/docker-compose.yml`.
- Code-executor pivot fix (completed 2026-06-03): `~administrator/projects/mcp/code-executor/docs/fix-live-pivot-2026-06-03.md` and the response in `/mnt/shared/aichat/linuxserver.administrator.md`.
- Code-executor remaining items: `~administrator/projects/mcp/code-executor/docs/remaining-issues-2026-06-03.md`.
