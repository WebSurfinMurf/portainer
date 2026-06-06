# Docker access — long-term target architecture & backlog

**Created:** 2026-06-04 by administrator (code-executor session, continuing the running-session breach response).
**Companion to:** [`DOCKER-SECURITY-ISSUES.md`](./DOCKER-SECURITY-ISSUES.md) — that doc is the *tactical inventory* (every reach path + how to close it, today). **This doc is the *durable end-state*** — how docker access should work so the breach class can't recur — plus the backlog that tracks getting there.
**Status:** DESIGN — backlogged, not yet scheduled. The known gap (§5) is consciously accepted for now so work can proceed.

---

## 0. Problem statement (the class, not the instance)

The live-IB breach was one symptom. The root cause is structural and platform-wide:

> **Docker daemon access is binary and root-equivalent.** Holding the socket (via the `docker` group or a `/var/run/docker.sock` mount) grants *full* control of the host and every container/network — there is no native "least privilege." `:ro` on the mount is non-mitigating (it protects the inode, not the API; verified experimentally 2026-06-03). Today ~3 humans and ~11 containers hold this, so the live-trading network is reachable from a large, undifferentiated trust surface.

A second, same-shaped instance lives inside code-executor itself (§4): user code spawned by `execute_code` shares **UID 1000** with the secret-holding server process, so it can read `/proc/1/environ` (the `GITLAB_TOKEN` admin PAT) even with its own env stripped. Same lesson: **co-location = shared privilege.** The durable answer in both cases is *separation*, not policy bolted onto co-located identities.

### QA findings that sharpen the inventory (2026-06-04)

Confirmed empirically as `websurfinmurf` (script: `/tmp/qa-docker-access.sh`, source archived below):

- **Removing from the `docker` group does NOT require a re-login to take effect.** `gpasswd -d` edits `/etc/group` immediately; `sg`/`newgrp docker` re-check membership *live*, so the latent path closes in the current shell the instant the entry is removed. Only a process that **already activated** docker keeps it until exit. (Refines `DOCKER-SECURITY-ISSUES.md` §3 A2's "force-logout" step — force-logout is only needed to flush *already-active* docker processes, not to make the removal effective.)
- **The membership is latent, not active, in a tmux/attached session.** `id` showed no `docker`; `getent group docker` showed `joe,administrator,websurfinmurf`; `sg docker -c 'docker info'` succeeded and `mcp-ib-live-net` was visible. So "my shell can't reach docker" is timing, not security.
- **The sudoers NOPASSWD line is the true multiplier** (`DOCKER-SECURITY-ISSUES.md` §1.2 A1). While `websurfinmurf ALL=(administrator) NOPASSWD: ALL` exists, removing the docker-group entry is cosmetic — the agent re-acquires everything via `sudo -u administrator docker …` in one syscall. **A1 gates the value of A2.**

---

## 1. Target architecture — four pillars

End-state principle: **no identity, human or container, holds raw unscoped root-equivalent docker access. Access is least-privilege, authenticated, and audited by default; raw socket/group is a rare, explicit, admin-only, attended exception.**

### Pillar 1 — Daemons separated by blast radius  *(the flagship — only real containment boundary)*
- **Rootful daemon:** general, non-sensitive services (the bulk of the stack).
- **Rootless per-user daemon** (`~administrator/.local/share/docker`) for sensitive workloads — starting with the **live IB stack**. The rootful socket then cannot see `mcp-ib-live-net`, so **a container or the autonomous agent on the rootful daemon cannot reach live**.
- **Scope of the boundary (corrected per Review Board 2026-06-04 — do not overclaim):** this contains *containers* and *the agent* (no scriptable sudo). It does **not** contain a host-root actor — host root reads any user's `/run/user/1000/docker.sock`, data dir, and process memory. Since the admin-team humans can `sudo -i` (accepted out-of-scope, `DOCKER-SECURITY-ISSUES.md` §6), **rootless does not wall a determined human from live; only the agent and compromised containers.** Rootless networking (`slirp4netns`) and `loginctl enable-linger` are real lifecycle items and may affect Traefik ingress / IB-gateway VNC — design them in (Gemini).
- Generalizes `DOCKER-SECURITY-ISSUES.md` C1 from a one-off into a standing rule: **sensitivity-tiered daemons.** This is the durable structural fix; rank it **above** Pillar 2.

### Pillar 2 — Portainer as the *audited convenience* management GUI  *(this project owns it — DESCOPED per Review Board 2026-06-04)*
**Original framing ("RBAC replaces docker-group membership as a security boundary") was wrong on three counts, flagged unanimously by the Board:**
1. **RBAC is app-level, not daemon-level — it cannot contain the people it's aimed at.** websurfinmurf/joe/administrator all hold host shell + `sudo -i`; anyone who can sudo bypasses Portainer and talks to the socket directly. Portainer RBAC only constrains an identity whose *sole* path is Portainer — none of these three are. So **No: Portainer RBAC does not prevent a determined admin-team member from reaching live.** Its access-control value here is ~zero.
2. **Per-team / per-environment RBAC is Portainer Business Edition.** CE is essentially admin-vs-standard. The whole "developer team can't touch the live-IB environment" deliverable may be **license-blocked** — must be decided before costing.
3. **Portainer is Tier-2, internet-facing** (`https://portainer.ai-servicers.com`, Keycloak) and rw-mounts the raw socket. Consolidating root-equivalence here moves it from a LAN/VPN-only surface onto a **public** one → net remote attack surface goes *up* (Keycloak compromise / OAuth2-proxy bug / session theft → click-to-`docker run`). `DOCKER-SECURITY-ISSUES.md` D2 already flags this.

**Descoped target:** keep Portainer as an **audited, convenient GUI** for day-to-day container ops — its genuine value is the **audit log** (who-did-what), which raw CLI can't provide. **Drop** the RBAC-as-boundary deliverable, the team→Keycloak mapping, and the implied BE license. *If* Portainer is retained for any non-admin use, its **Endpoint Security policies are mandatory** (disable bind-mounts, privileged mode, host PID/network, capabilities) — without them Portainer is click-to-root regardless of RBAC (Gemini, Codex). `administrator` keeps the attended break-glass CLI path. **Ranked LAST** of the pillars; it is decoration on top of Pillar 1, not a boundary.

### Pillar 3 — Containers that need the Docker API get a *filtered socket-proxy*, never the raw socket
- Deploy **`docker-socket-proxy`** (Tecnativa/HAProxy-based) as a daemon-API firewall on its own internal network.
- Observability/discovery consumers (`traefik`, `netdata`, `dozzle`, `promtail`) connect to the proxy with only the read endpoints they need (`CONTAINERS=1`, `NETWORKS=1`, `SERVICES=1` read-only; `POST=0`, `EXEC=0`, no `/containers/create`, no `/start`). The **raw socket is never mounted into an app container** again.
- Even a fully compromised observability consumer then **cannot `docker run`** — the proxy refuses the verb. This is the structural replacement for today's "RO mount = theater."
- **Nuance (Board 2026-06-04): this is a write-confinement control, not a confidentiality one.** With `CONTAINERS=1`, `GET /containers/{id}/json` still returns each container's **`Env` array** — i.e., any secret-in-environment, for every container. The proxy can't express "list but don't inspect." So a compromised read-only consumer can't *start* containers but *can* enumerate env secrets. Reinforces LT-5's lesson: **secrets must not live in container env.** Frame the proxy as "blocks control-plane writes," not "safe in general."
- code-executor already needed *nothing* here (socket removed 2026-06-03) — it's the proof that most "needs the socket" claims don't survive scrutiny.

### Pillar 4 — Identity split for autonomous agents; no scriptable privilege
- Autonomous AI agents run under a dedicated uid (e.g. `*-agent`) with **no `sudo`, no `docker` group, no socket mount**. Any docker-ish capability is mediated by **explicit allow-listed MCP tools**, not raw daemon access (the code-executor RBAC model, generalized).
- **Remove the sudoers `NOPASSWD` multiplier** (`DOCKER-SECURITY-ISSUES.md` A1) — without it, the agent can't escalate to `administrator` non-interactively; the human keeps an attended path. **(Reclassified do-now — see §2/§5; this one line is not project-sized.)**
- The human `websurfinmurf` and the agent runtime become *different uids* with different privilege.
- **Identity split is incomplete if it stops at the uid (Board/Codex):** it must also separate **Keycloak/Portainer sessions, SSH keys, Docker contexts, browser profiles, and any mounted home/config volumes**. Otherwise the agent reaches Portainer (and thus the daemon) by session/credential theft rather than Docker-API reach — re-opening the path Pillar 2 was supposed to gate.

### Cross-cutting — blast-radius controls at the asset
- IBKR sub-account with hard position/notional/daily-loss caps + API trusted-IP allowlist (`DOCKER-SECURITY-ISSUES.md` C2). **The only layer that survives a fully-owned host** — therefore the top compensating control while the gap in §5 is open.

### End-state property (corrected — state the boundary where it really is)
After the four pillars: **the autonomous agent and any compromised container cannot reach live** (rootful daemon can't see the rootless live net; agent has neither raw docker nor scriptable sudo; observability consumers can't start containers). **A determined admin-team human still can**, by accepted threat-model scope (`DOCKER-SECURITY-ISSUES.md` §6 — sudo-to-root is out of scope). Container-management actions are **audited** through Portainer. The guarantee is *agent/container containment*, not *human containment* — the original "reaching live requires compromising the rootless daemon" phrasing overclaimed and is retracted.

---

## 2. Do-now belts vs. durable projects (re-split per Review Board 2026-06-04)

The Board's lead finding: the first draft **laundered three CLOSE-TODAY items into "backlog."** They are not project-sized and must not inherit a project's schedule. Pulled out:

### Operator decision (2026-06-04) — deploy paths vs. the escalation multiplier
Hard constraint from the operator: **websurfinmurf must never lose the ability to deploy containers.** Both NOW-2 (agent-container socket) and NOW-3 (host `docker` group) are *deploy paths* — so neither may be removed until a **GitLab-based deploy path replaces them** (new item **LT-7**). NOW-1 is *not* a deploy path (pure privilege-escalation multiplier), so it proceeds immediately. This is dependency-gated sequencing, not deferral-for-convenience: a required capability gets its replacement before removal.

### Do NOW (independent of any project)
| ID | Action | Size | Closes |
|----|--------|------|--------|
| **NOW-1 (was bundled in LT-4)** | Remove sudoers line `websurfinmurf ALL=(administrator) NOPASSWD: ALL` (`visudo`-validated) | **~1 min** | The "multiplier" that makes every other host fix cosmetic. **Operator-approved 2026-06-04; pending execution (needs admin sudo password).** |

### Gated on LT-7 (GitLab deploy path) — operator wants NOW-3 pursued actively, NOW-2 backlogged
| ID | Action | Status |
|----|--------|--------|
| **NOW-3 (= A2)** | Remove `websurfinmurf` (review `joe`) from `docker` group | **Active workstream**, gated on LT-7. Do *not* `gpasswd -d` until LT-7 verified — would strand deploy ability (violates the hard constraint). |
| **NOW-2 (= B1)** | Remove `docker.sock` mount from `agents-cli-claude-websurfinmurf` + `webui-claude-websurfinmurf` | **Backlogged** (operator decision). Also a deploy path; revisit after LT-7. |

**Residual risk of backlogging NOW-2 (Board flagged it as the *demonstrated* path):** while NOW-2 is open, a prompt-injected agent in those containers can still reach live via the mounted socket. Accepted by the operator as the cost of preserving agent-driven deploy until LT-7. **Compensating control: LT-6 (IBKR caps) becomes load-bearing** and should be prioritized accordingly. (Optional interim hardening that does *not* cost deploy ability: front the agent containers' socket with a write-filtered `docker-socket-proxy` — LT-3 pattern — so they can still `build/deploy` but not join `mcp-ib-live-net`. Worth weighing vs. waiting for LT-7.)

### Durable projects (genuinely project-sized)
| ID | Item | Owning project | Depends on | Effort |
|----|------|----------------|------------|--------|
| **LT-1** ⭐ flagship | Rootless daemon for live IB; rootful socket can't see live net | `mcp/ib-live`, `ib-launcher` | — | M |
| **LT-6** | IBKR sub-account caps + trusted-IP (asset-side) | IBKR portal | — | S, **start in parallel** |
| **LT-4′** | Agent/human **uid identity split** (incl. session/key/context separation, Pillar 4) | `agents-cli` / `webui` | NOW-1 | M |
| **LT-3** | `docker-socket-proxy` in front of read-only consumers; remove raw socket mounts | `traefik`, observability | — | M |
| **LT-5** | code-executor `execute_code` → secrets-free sidecar (§4) | `mcp/code-executor` | — | M |
| **LT-2** | Portainer as **audited convenience GUI** (DESCOPED — no RBAC-as-boundary, no BE license, Endpoint-Security policies if any non-admin use) | **`portainer` (here)** | — | S–M |
| **LT-7** ⭐ unblocks NOW-3 | **Decouple the EXISTING GitLab deploy path from websurfinmurf's personal docker access.** Verified 2026-06-04: a deploy agent already exists (CI job `ssh websurfinmurf@host` → `docker compose up`, proven on `stocktrader`), but it deploys *as websurfinmurf using his docker group* — so NOW-3 breaks it as-is. Task = repoint deploys to a **dedicated `deploy` identity** with scoped docker access (or socket-proxy), with **no route to `mcp-ib-live-net`** and no dependency on any human's group membership. | `gitlab` + this design | LT-7.0 inventory | M |
| **LT-7.0** | **Deploy inventory (operator-proposed 2026-06-04):** websurfinmurf enumerates *every* app/container it deploys and *how* (script, `docker compose`, direct `docker run`, agent-driven). For each: confirm a GitLab pipeline can build+deploy it, then remove websurfinmurf from the manual deploy steps. This inventory is the acceptance checklist that gates NOW-3 — NOW-3 is safe to execute only once every entry deploys via pipeline. | websurfinmurf + `gitlab` | — | S–M |

**Sequencing (Board order + operator's deploy-ability constraint):**
1. **Now (~1 min):** NOW-1 (sudoers NOPASSWD). Approved; pending execution.
2. **Parallel, external + prioritized** (now load-bearing because NOW-2 is backlogged): LT-6 IBKR caps + trusted-IP.
3. **LT-7** GitLab deploy path — the gate that unblocks NOW-3.
4. **NOW-3** (remove docker group) — immediately after LT-7 verifies websurfinmurf can deploy via pipeline.
5. **Flagship:** LT-1 rootless live daemon — the durable boundary.
6. LT-4′ identity split, LT-3 socket-proxy, LT-5 sidecar.
7. **NOW-2** (agent socket) — revisit post-LT-7. **LT-2 Portainer last, descoped** (audit-only).

> Departure from the Board's "NOW-2 today": the operator requires uninterrupted deploy ability, and NOW-2 removes an agent deploy path. The Board's concern (demonstrated path stays open) is mitigated by prioritizing LT-6 and optionally the socket-proxy interim. This is a *capability-dependency* gate, not the convenience-deferral the Board (rightly) rejected for NOW-1.

---

## 3. Relationship to the tactical inventory

`DOCKER-SECURITY-ISSUES.md` closes the breach *now* with policy changes on the existing co-located architecture (Tiers A–D). **This doc replaces the co-located architecture** so those policy changes stop being load-bearing. Both are needed: tactical first (small window), architecture second (so we're not one `gpasswd` regression away from re-opening it). Neither is a "later" tier of the other — they operate at different layers.

---

## 4. The code-executor secret-leak instance (LT-5 detail)

Same root cause, different daemon. `execute_code` children share UID 1000 with `executor.ts`, which holds `GITLAB_TOKEN` (admin PAT) in env. Proven: child reads it via `/proc/1/environ` even with its own env stripped; `executor.ts` is non-root so it **cannot** spawn children under a different uid. **Correct fix:** move `execute_code` into a separate, secrets-free sidecar container; the main executor proxies execution to it. Plus least-privilege the GitLab token (project-scoped, not admin PAT) — correct on its own merits. Full analysis: `mcp/code-executor/docs/remaining-issues-2026-06-03.md` §6.2.

---

## 5. What's genuinely accepted vs. what was wrongly deferred (corrected per Board)

**The first draft of this section was indefensible** — all three reviewers said so. It parked NOW-1 (a 1-minute sudoers edit, which §0 itself names the highest-leverage action) and NOW-2 (the *demonstrated* breach path) into "accepted gap, schedule later," leaving the proven exploit open while the only backstop (LT-6) also isn't done. That is the "Phase-A-now / Phase-C-later → deliberately choosing tech debt" anti-pattern. **Retracted.**

**Do now (depends on nothing, not a deploy path):** NOW-1 (sudoers NOPASSWD). Operator-approved 2026-06-04.

**Gated on LT-7 by operator decision (hard constraint: never end websurfinmurf's deploy ability):** NOW-3 (docker-group removal — *active* workstream behind LT-7) and NOW-2 (agent-container socket — *backlogged*). Both are deploy paths; they are removed only after the GitLab deploy path (LT-7) verifiably replaces them. This is capability-dependency sequencing — distinct from the NOW-1-style convenience-deferral the Board rejected. While NOW-2 stays open, **LT-6 (IBKR caps) is the load-bearing compensating control.**

**Legitimately project-sized, may proceed in parallel:** LT-1 rootless daemon, LT-7 GitLab deploy path, LT-4′ identity split, LT-3 socket-proxy, LT-5 sidecar, LT-2 Portainer.

**Closed already:** the code-executor *container* path (socket + docker-cli removed 2026-06-03).

**Genuinely-accepted residual (threat-model scope, not laziness):** a *determined admin-team human* can still reach live via `sudo -i` even after every item above — explicitly out of scope per `DOCKER-SECURITY-ISSUES.md` §6. LT-6 (IBKR caps) bounds the *financial magnitude* of that and of any regression, but — Board caveat — it caps a known account's bad day; it does **not** prevent persistence, host-secret theft, or the next sensitive workload. It is *a* layer, never the reason to defer a one-line fix.

**Operational note for the current session:** code-executor is up and usable now. Proceeding to *use* the tooling is fine; what is *not* fine is shipping this doc with NOW-1/NOW-2 still filed as "backlog." They are surfaced to the operator as do-today.

---

## 6. Review Board verdict (2026-06-04) — applied above

Dispatched to gemini + codex + claude (all healthy, all returned). **Unanimous convergence**; this doc was revised to incorporate it. Raw responses: [`reviews/2026-06-04-target-architecture.md`](./reviews/2026-06-04-target-architecture.md).

- **Lead finding (all 3):** §5 deferred NOW-1 (1-min sudoers) and NOW-2 (afternoon agent-socket) as "backlog." Indefensible — split them out as do-today. ✅ applied (§2, §5).
- **Pillar 1 overclaimed (all 3):** rootless contains agent/containers, **not** a host-root human. ✅ corrected (Pillar 1, End-state property).
- **Pillar 2 mis-sold (all 3):** app-level RBAC can't contain sudo-capable humans; per-env RBAC is Portainer **BE** (license); Portainer is **Tier-2 public** + rw socket → surface goes up; Endpoint-Security policies mandatory. ✅ descoped to audit-only, ranked last.
- **Pillar 3 nuance (claude, codex):** read-only proxy still leaks container `Env` via inspect — write-confinement, not confidentiality. ✅ added.
- **Pillar 4 incompleteness (codex):** identity split must also separate sessions/keys/contexts/profiles/volumes. ✅ added.
- **Proportionality (all 3):** the over-build is Pillar 2's full RBAC for 3 humans who all hold host root. ✅ dropped. (Gemini also questioned rootless complexity; claude/codex rank rootless as the *only* real boundary — kept as flagship, with the lifecycle caveats Gemini raised.)

## 7. References
- Tactical inventory: [`DOCKER-SECURITY-ISSUES.md`](./DOCKER-SECURITY-ISSUES.md)
- Review Board raw responses: [`reviews/2026-06-04-target-architecture.md`](./reviews/2026-06-04-target-architecture.md)
- Review-board breach synthesis: `~administrator/projects/ibgateway/docs/reviews/ib-gateway-running-session-breach.final.md`
- code-executor fix + remaining items: `~administrator/projects/mcp/code-executor/docs/{fix-live-pivot-2026-06-03.md,remaining-issues-2026-06-03.md}`
- QA script (latent docker-access check): `/tmp/qa-docker-access.sh`
