# Review Board — Docker-access target architecture

**Dispatched:** 2026-06-04 · **Nodes:** gemini, codex, claude · all healthy · all `success: true`

Source: `DOCKER-ACCESS-TARGET-ARCHITECTURE.md`. Raw responses below, verbatim.


---

## gemini

**THE CRITICAL FLAW (The Lead)**
The design fundamentally misunderstands Portainer’s boundaries: **Pillar 1 (Rootless separation) is entirely defeated by Pillar 2 (Portainer RBAC) unless Portainer's Endpoint Security is strictly locked down.** 
Portainer's RBAC restricts *where* a user can deploy (environment scoping), but out-of-the-box it does not restrict *what* they can deploy. If developers have Portainer access to the rootful daemon, they can deploy a container with a host bind mount (`-v /:/host`) or `--privileged`. From there, a compromised agent or determined user can traverse the host filesystem, read `~administrator/.local/share/docker` (the rootless socket), and take over the live IB environment, completely bypassing the rootless isolation.

Here is the concrete critique of the architecture:

**1. COMPLETENESS**
*   **Portainer Capability Limits:** The architecture completely misses the requirement to configure Portainer's "Endpoint Security" settings (disabling bind mounts, privileged mode, and host PID/network namespaces). Without this, Portainer is a click-to-root GUI, regardless of RBAC roles.
*   **Rootless Lifecycle & Networking:** The design omits the host-level requirements for rootless Docker, specifically `loginctl enable-linger` for the administrator. It also ignores that rootless Docker uses user-mode networking (`slirp4netns`), which may break Traefik ingress routing or VNC performance for the IB gateway.

**2. CORRECTNESS**
*   **Portainer-as-access-plane:** Not sound against a determined admin-team member unless the capability limits (above) are enforced. Co-locating developer deployments on the host's rootful daemon is structurally unsafe if they can mount the host.
*   **docker-socket-proxy:** Sound and perfectly correct. Verb-filtering (stripping `POST`, `EXEC`) is the exact structural answer to the `:ro` socket mount theater.
*   **Rootless-daemon separation:** Conceptually sound for access control, but practically fragile for a networked stack.

**3. PROPORTIONALITY**
*   **Over-engineered (Socket-Proxy for static observability):** Deploying a proxy in front of static, trusted, third-party infrastructure images (`traefik`, `netdata`, `promtail`) on a Tier-1 LAN buys very little security for the operational cost of maintaining the proxy. The actual threat model is the dynamic *AI agent runtime*. 
*   **Over-engineered (Rootless Docker):** If the AI agent's access to the socket is severed and its `sudo` escalation is removed, standing up a rootless daemon introduces significant routing/networking complexity for marginal actual risk reduction in a single-host homelab.

**4. THE ACCEPTED GAP (§5)**
*   **Completely indefensible.** The document conflates the long-term "identity split" project with the tactical revocation of privilege. Removing the `sudoers NOPASSWD` line (A1) and `docker` group membership (A2) are 10-second terminal commands (`visudo`, `gpasswd -d`). Deferring these because "durable fixes are real projects" is an egregious operational failure.
*   Relying on IBKR caps (LT-6) only limits the *magnitude* of financial damage; it does absolutely nothing to prevent an agent with `NOPASSWD` from establishing persistence, reading other host secrets, or disabling Portainer entirely.

**5. SEQUENCING**
*   The proposed order is wrong because it treats 10-second tactical fixes as project dependencies. 
*   **Correct Order:**
    1.  **Immediate Tactical (A1/A2/B1):** Remove `sudoers NOPASSWD`, remove `docker` group, and kill the agent container's socket mount. This takes 2 minutes and severs the active breach path immediately.
    2.  **LT-6 (IBKR Caps):** Secure the external asset.
    3.  **LT-4 (Identity Split):** Build the durable autonomous agent runtime (now that the human is safely using passwords).
    4.  **LT-3 / LT-2 (Proxy & Portainer):** Secure the authorized paths.
    5.  **LT-1 (Rootless):** Re-evaluate if this complexity is even necessary once the agent is mathematically locked out of the rootful daemon.

---

## codex

**Findings**

1. The biggest overclaim is in Pillar 1: rootless-live separation is being described like a hard boundary when it is really a blast-radius reduction. [DOCKER-ACCESS-TARGET-ARCHITECTURE.md](/workspace/administrator/projects/portainer/DOCKER-ACCESS-TARGET-ARCHITECTURE.md:31) says the rootful socket “physically cannot see” live and [line 57](/workspace/administrator/projects/portainer/DOCKER-ACCESS-TARGET-ARCHITECTURE.md:57) implies live then requires compromising the rootless daemon specifically. That is only true for identities limited to the rootful Docker API surface you’ve constrained. It is not true against any remaining rootful-daemon-control path, because rootful Docker access is host-root-equivalent and host root can usually pivot into the admin user’s rootless socket/process/files. Inference from Docker’s rootless model: the daemon is just a non-root user daemon, not a protection boundary against host root. Source: Docker rootless docs: https://docs.docker.com/engine/security/rootless/

2. The accepted gap in §5 is too generous because it defers the cheapest direct closure of the demonstrated path. [DOCKER-ACCESS-TARGET-ARCHITECTURE.md](/workspace/administrator/projects/portainer/DOCKER-ACCESS-TARGET-ARCHITECTURE.md:92) explicitly leaves the agent containers’ socket mounts open, and the companion doc already identifies removing those mounts as the direct fix for the autonomous path at [DOCKER-SECURITY-ISSUES.md:108](/workspace/administrator/projects/portainer/DOCKER-SECURITY-ISSUES.md:108). Relying on LT-6 alone is not a strong justification here, because the threat that already materialized was “agent under a trusted human identity,” which the current “Tier-1 trusted human” rationale does not actually contain. If you want one must-do-now item, it is `B1` or simply stopping those agent containers until `B1` lands.

3. Portainer is sound as an audited workflow plane, but not as the primary hard security boundary the target doc sometimes implies. [DOCKER-ACCESS-TARGET-ARCHITECTURE.md:36](/workspace/administrator/projects/portainer/DOCKER-ACCESS-TARGET-ARCHITECTURE.md:36) is fine if the claim is “humans use this path by default, with audit.” It is not fine if the claim is “this prevents a determined admin-team member from reaching live.” Portainer docs are explicit that RBAC is separate from Docker security policies, and that for non-admins you also need policies like disabling bind mounts, privileged mode, devices, PID 1, capabilities, and possibly stacks entirely; Portainer even says it cannot block all Docker privilege paths except by the “sledgehammer” of disabling stacks. Sources: https://docs.portainer.io/sts/admin/user/roles and https://docs.portainer.io/admin/environments/policies/docker-policies/security-policy

4. Pillar 3 is directionally correct, but the proxy claim is slightly too broad. [DOCKER-ACCESS-TARGET-ARCHITECTURE.md:42](/workspace/administrator/projects/portainer/DOCKER-ACCESS-TARGET-ARCHITECTURE.md:42) through [line 45](/workspace/administrator/projects/portainer/DOCKER-ACCESS-TARGET-ARCHITECTURE.md:45) are sound for preventing `docker run` if `POST=0`, `EXEC=0`, start/stop remain disabled, and the per-section allowlist stays tight. Tecnativa documents that `POST` disabled means only `GET`/`HEAD` are allowed. But GET access still leaks a lot: container metadata, env, labels, networks, logs. So this is a write-confinement control, not a confidentiality control. Source: https://github.com/Tecnativa/docker-socket-proxy

5. The design omits a few non-socket crossover rules that matter once live moves rootless: no shared host bind mounts, no localhost management ports, no shared secret files, and no shared human-session material between human and agent identities. The identity split at [DOCKER-ACCESS-TARGET-ARCHITECTURE.md:48](/workspace/administrator/projects/portainer/DOCKER-ACCESS-TARGET-ARCHITECTURE.md:48) is incomplete unless it also separates Keycloak/Portainer sessions, SSH keys, Docker contexts, browser profiles, and any mounted home/config volumes. Otherwise Portainer becomes reachable by credential/session theft rather than Docker API reach.

**Direct Answers**

Completeness: the four pillars miss host-shared surfaces between rootful and rootless planes, and they understate Portainer/session material as a trust surface.

Correctness: rootless separation is good but overclaimed; Portainer RBAC works for scoped delegation only if live is a separate endpoint and Portainer security policies are locked down; socket-proxy is sound for read-only consumers but should be described as “blocks control-plane writes,” not “safe in general.”

Proportionality: the main place you may be over-investing is turning Portainer into a doctrinal “front door” for a 1-2 trusted-human homelab. Its audit value is real, but it is not where the biggest risk reduction comes from. Rootless-live separation and removing raw sockets from agent/runtime containers buy more security per unit effort.

Accepted gap: narrowly defensible only if you say plainly “the host can still place live trades today; LT-6 caps are the backstop.” It is not defensible to defer `B1`; that is the cheap must-do-now item. `A1` is the next cheap one.

Sequencing: `LT-6` first is fine, and `LT-4` before `LT-2` is correct. But I would move “stop/remove agent socket mounts now” ahead of the rest, then `LT-4`, then `LT-1`, then `LT-2`/`LT-3`. If live remains on the same host, `LT-1` is the durable control with the most actual separation value.

---

## claude

Read both. Here's the critique — concrete, not a summary.

## The single most important thing: §5 launders the tactical doc's "CLOSE TODAY" items into "backlog"

The companion `DOCKER-SECURITY-ISSUES.md` rates **A1 (remove the sudoers `NOPASSWD` line)** and **A2 (group removal)** as *Tier A — CLOSE TODAY, critical, non-optional*, and **B1 (remove the socket mount from the websurfinmurf agent containers)** as the fix that "actually closes the AI exfiltration vector." The target-architecture §5 then re-files those same three into "consciously accepted gap, schedule later as real projects."

They are not the same size:
- **A1 is a one-line, one-minute edit** — `sudoedit`, delete one line, `visudo -c`. The doc's own §0 calls NOPASSWD "the true multiplier" and says "A1 gates the value of A2." Deferring a 60-second fix that your own analysis names the highest-leverage action in the plan is exactly the "Phase A now / Phase C later → deliberately choosing tech debt" anti-pattern. It is not a project. It rides into LT-4's "M" effort bucket only because it was bundled with the identity split, which *is* a project.
- **B1 is a compose edit + recreate** — an afternoon, not a quarter. It closes the *literal demonstrated breach path* (agent container → mounted socket → `docker run --network mcp-ib-live-net`).

So the accepted state in §5 leaves the *proven* exploit fully open while the only thing standing in front of live money is **LT-6, which isn't done either** ("do early" / IBKR-portal task with external latency). There is a window — possibly days — where the demonstrated exploit is open *and* the compensating control is not yet live. That's indefensible when two of the three host fixes are sub-day and one is sub-minute.

**Fix:** split LT-4. Pull A1 (sudoers line) and B1 (agent socket) out as do-today belts, independent of the identity-split project. Backlog only the genuinely project-sized work (rootless daemon, Portainer, socket-proxy, sidecar). LT-6 runs in parallel but must not *gate* a one-line sudoers edit.

## On the pillars

**Pillar 2 (Portainer as access plane) is the weakest pillar and is mis-sold as containment.** Three concrete problems:

1. **It relocates root-equivalence onto a *public* surface.** Portainer is Tier-2 — `https://portainer.ai-servicers.com`, internet-facing behind Keycloak (per its CLAUDE.md and the master index). It rw-mounts the raw socket. You're proposing to retire docker-group membership (LAN/VPN-only) and consolidate the same root-equivalent control into a publicly-exposed web app. The companion's own D2 flags it: "if the agent ever gets a Keycloak session for administrator, portainer becomes a click-to-`docker run` GUI." Net remote attack surface goes *up* (Keycloak compromise, OAuth2-proxy bug, session theft → click-to-root), not down.
2. **The RBAC you're specifying may not be licensed.** Per-team roles + environment/endpoint scoping ("developer team can't touch the live-IB environment") is **Portainer Business Edition**. Community Edition is essentially admin-vs-standard. The doc never mentions CE/BE. The entire LT-2 deliverable could be blocked on a paid license — that needs to be on the page before it's costed as "M–L."
3. **Even with BE, RBAC is enforced in the app, not the daemon — so it can't contain the people it's aimed at.** This answers your explicit question directly: **No, Portainer RBAC does not prevent a determined admin-team member from reaching live.** websurfinmurf/joe/administrator all hold host shell, and §6 of the inventory *accepts* sudo-to-root as out of scope. Anyone who can `sudo -i` bypasses Portainer entirely and talks to the socket directly. Portainer RBAC only constrains an identity whose *sole* path is Portainer — which none of the three humans are. So LT-2's access-control value is ~zero; its real value is the **audit log** (who-did-what), which is genuine but is a different claim. **Descope LT-2 to "audited convenience GUI," drop the RBAC-as-boundary framing**, and you also dodge the BE license.

**Pillar 1 (rootless daemon) is the only real containment boundary — and it's underweighted.** It's the one pillar that closes the breach *class* structurally: the rootful socket physically can't see `mcp-ib-live-net`. But:
- It only holds against **containers and the agent**, not against a host-root actor. Root reads any user's `/run/user/1000/docker.sock` and data dir. Since websurfinmurf-the-human can `sudo -i` (accepted), the human is *never* walled from live — only the agent (no scriptable sudo) is. The "End-state property" sentence ("reaching live trading requires compromising the admin's rootless daemon") is true for the agent/containers and **false for the admin-team humans**. Say that plainly rather than letting the property imply human containment it doesn't provide.
- It deserves to be the **flagship**, ranked above LT-2, not "in parallel as capacity allows." It's the durable answer; Portainer is decoration on top.

**Pillar 3 (socket-proxy) is sound and a good buy — with one correctness nuance the doc misses.** Tecnativa's proxy does filter by API path, and "compromised observability container can't `docker run`" is real and structural. But verb-filtering is *coarse*: `CONTAINERS=1` enables `GET /containers/{id}/json` (inspect), whose response includes the container's **`Env` array — i.e., secrets-in-environment for every container**. So a compromised netdata/traefik with `CONTAINERS=1` can't start containers but *can* enumerate every container's env vars. "Read-only = harmless" is not quite true; it's a recon/secret-exfil surface. Worth noting that secrets shouldn't live in env (ties to the LT-5 lesson) and that the proxy can't express "list but don't inspect."

**Pillar 4 (identity split + remove NOPASSWD) is the soundest, cheapest, highest-value pillar.** No notes except: as established above, half of it (the sudoers line) shouldn't wait for the other half (the uid split).

## Proportionality

The over-engineered part is exactly **Pillar 2's full RBAC + team→Keycloak mapping + environment definitions for a 3-human Tier-1 set who all already hold host root.** That's heavy identity machinery to differentiate people the machinery can't actually separate. Keep Portainer for audit + convenience; drop the RBAC build-out. That's the clearest "buying little security for real operational cost" in the design.

Everything else is proportionate: rootless for one live stack (one-time move, real boundary), socket-proxy for four consumers (low cost, structural win), sudoers/identity split (cheap, high value).

## A reach path the four pillars don't name

The **break-glass + sudo-to-root chain for the human**. Pillars contain the agent and compromised containers; they explicitly do not contain a determined admin-team human (§6 scopes that out). That's a legitimate threat-model choice — but it means the design's actual guarantee is narrower than the "End-state property" paragraph states. The honest one-liner: *"After the four pillars, the **autonomous agent** and **any compromised container** cannot reach live; a **determined admin-team human** still can, by accepted threat-model scope."* State the boundary where it really is.

## Sequencing

LT-6-first is right (cheap, survives an owned host) — but it's an external IBKR-portal task; kick it off in parallel, don't let it gate the faster host fixes. The real ordering should be:

1. **Today, hours:** A1 (sudoers line) + B1 (agent socket mount). These close the demonstrated path and don't depend on anything.
2. **Parallel, external:** LT-6 IBKR caps + trusted-IP.
3. **Flagship project:** LT-1 rootless live daemon — the durable boundary.
4. LT-3 socket-proxy (independent, low cost).
5. LT-2 Portainer **last and descoped to audit-only**; drop the RBAC-as-boundary deliverable (and the implied BE license).

The doc's stated order (LT-6 → LT-4 → rest in parallel) has two flaws: it treats LT-4 as atomic (so the one-line sudoers fix inherits a project's schedule), and it ranks LT-1 — the only structural fix — as parallel-equal with LT-2, which isn't a boundary at all.

One caveat on LT-6 as "the compensating control": it's asset-specific. It caps the blast radius of the *known* IB account, not the host and not the next sensitive workload. Relying on it as the *sole* control while §5 is open re-instances the exact "policy bolted onto co-located architecture" the doc sets out to kill — and a daily-loss cap bounds a bad day, it doesn't prevent one. Good as *a* layer; not a reason to defer a one-line fix.