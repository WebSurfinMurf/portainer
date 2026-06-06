---
name: lt7-runner-and-net
created: 2026-06-04
status: pending-review
---

# LT-7 — Two implementation decisions: a non-privileged CI runner, and a dev-facing MCP network

## Situation

We are finishing **LT-7**: moving a developer's container deploys onto GitLab CI so they no longer depend on his personal docker access. The security model was already settled in a prior Review Board round (see `/workspace/administrator/projects/portainer/docs/no-rootless.md` — read it; it is the grounding doc). Settled conclusions, **not up for re-litigation**:

- This host runs a **single rootful docker daemon**. Rootless was attempted and **abandoned** — on one host it does not bind against the threat (host-root pivot), and it caused host-wide AppArmor/sysctl regressions. Do **not** propose rootless again.
- **Any identity with docker daemon access is host-root-equivalent** (`docker run --privileged -v /:/host` → chroot → host root). So per-network ACLs / socket-proxies / dedicated deploy-uids are "rituals the attacker steps over," not boundaries.
- Therefore **docker-group-for-developers is accepted**. The real live-trading boundary is: **IBKR-side account caps** (the only host-root-survivable control), **autonomous-agent containers having no docker.sock mount**, **live IB stack on an isolated network with no host ports**, and **live deploy staying manual/admin**. Portainer-RBAC-as-boundary was already descoped — do not propose it.
- Operator's bar: **minimize unauthorized access to the reasonable max for a one-host setup; accept + backlog the extreme root-equivalent loopholes** (structural close = live on a separate host, backlogged).

Within that settled model, two concrete implementation decisions remain. Both are "reasonable-max hardening / hygiene," not attempts to build an absolute boundary.

### GitLab runner inventory (current, via API)
- **id 1** `linuxserver-administrator` — admin shell runner.
- **id 3** `developer linux server runner` — tags `shell,linuxserver,developer`, `run_untagged=false`, **`access_level=ref_protected`** (I set this today; only runs on protected branches/tags). Dev shell deploys for `developers/{njproperties,developer,minecraft}` land here; all those jobs are `only:[main/master]`.
- **id 7** `gitlab-runner-docker-dev` — tags `docker,developer,cicd`, **`run_untagged=true`**, **docker executor that mounts `/var/run/docker.sock` into job containers**.
- **id 8** `cicd-runner` — admin docker runner.

### The gap that motivates Decision 2
`developers/stocktrader`'s CI jobs are **untagged** and triggered on merge requests (`rules: if $CI_MERGE_REQUEST_IID`). Untagged jobs land on **runner id 7**, whose job containers have the docker socket → **any merge request executes root-equivalent code on the host *before merge***. Branch protection does NOT mitigate this: MR pipelines run the *source ref's* `.gitlab-ci.yml` pre-merge. The repos are private (only 2 developers can open MRs), so the threat is a *compromised dev account/agent*, bounded by the IBKR caps — but it is the top remaining hardening item in the LT-7 model.

---

## DECISION 2 — Provision a non-privileged `dev-ci` runner so MR/build/test jobs are not root-equivalent

### Proposed solution
Stand up a **second GitLab runner using the docker executor, configured so the docker socket is NOT mounted into job containers** (`volumes` in `config.toml` omits `/var/run/docker.sock`). Tag it **`dev-ci`**. Effect: the runner process talks to the daemon to *create* per-job containers, but **the job's own `script:` has no docker access** → a malicious job cannot `docker run --privileged …`. Then the developer restructures `stocktrader` CI:

- **lint/test/smoke** (`syntax-check`, `unit-tests`, `smoke-test`, `test-autotrade`, etc.) → retag to `dev-ci`; they only need a `python:3.12-slim` image, no docker.
- **build** → convert from `docker:dind` to **Kaniko** (`gcr.io/kaniko-project/executor`), which builds + pushes images in userspace with **no docker daemon/socket**, authenticating to the registry with `$CI_JOB_TOKEN`. This keeps image builds running **on MRs** (pre-merge validation) while being socket-free.
- **deploy** (`deploy-model`/`-staging`/`-production`, `post-deploy-tests`) → tag to the **shell runner id 3** (already `ref_protected`); they only need SSH/alpine, no docker, and are already `only:`-gated to protected refs.
- Once stocktrader (and any other untagged-job project) is off runner 7, **set runner 7 `ref_protected` or retire it**, closing the MR→root-equivalent path for this model.

### The blocker / sub-decision
Provisioning the runner *properly* (its `config.toml` + a `deploy.sh`) means writing files under `projects/gitlab/runner/` — but **`projects/gitlab/` is a hard-deny "safety-net" tree** (an enforcement hook blocks writes there; it is the GitLab server the rest of the platform depends on). Options:
- **(2a)** Operator authorizes a one-time supervised exception to write the runner config/deploy into `projects/gitlab/runner/dev-ci/` (its conventional home).
- **(2b)** Site the `dev-ci` runner's config/deploy *outside* `projects/gitlab/` (e.g. a new `projects/gitlab-runner-dev-ci/`), deviating from the established per-user runner convention.
- **(2c)** Register the runner via API + run the container without a checked-in deploy script (violates the "all deploy steps live in a deploy.sh" platform rule).

### Specific questions for the board (Decision 2)
1. Is "**docker executor with the socket omitted from job-container `volumes`** + **Kaniko** for builds" the correct non-privileged pattern here, or is there a cleaner one (e.g. a **shell executor running as a dedicated unprivileged uid** with no docker group; or **Podman** rootless build)? Note the runner *process* still holds daemon access to spawn job containers — does that reintroduce meaningful risk even though jobs don't get the socket?
2. **MR pipeline semantics:** with runner 7 eventually `ref_protected`, do MR pipelines correctly fall through to the `dev-ci` runner for build/test? Any gotcha with protected variables / `$CI_JOB_TOKEN` registry auth on non-protected (MR) pipelines? Kaniko caching/registry-auth gotchas on this GitLab (CE, registry at `gitlab.ai-servicers.com:5050`)?
3. **Where should the runner live** given the `projects/gitlab/` hard-deny? Is 2a (supervised exception in the correct location) the right call, or is keeping the safety-net inviolate (2b) more important than convention?
4. Are we missing anything that still lets an MR run root-equivalent code after this change (e.g. other untagged-job projects, `default:` tags, tag-spoofing, the runner process itself)?

---

## DECISION 3 — Wire the dev-facing MCP network (`mcp-dev-net`), or abandon it

### Background
We created docker network **`mcp-dev-net`** (bridge, `10.4.0.176/29`) as a *labeled seam*: the idea (operator's) is that dev MCP apps reach admin-owned MCP backends via a dedicated network rather than the shared `mcp-net`, "to enable refinement later."

### Current state (verified)
- Dev apps `mcp-proxy-dev`, `mcp-code-executor-dev` are on `mcp-net` (+ others).
- `mcp-proxy-dev` reaches backend MCP wrappers by **container-name resolution over `mcp-net`**: `mcp-postgres-enhanced`, `mcp-playwright`, `mcp-ib-paper` (paper), and (when running) `mcp-timescaledb`, `mcp-memory`.
- **Live IB is properly isolated:** `mcp-ib-live` and `mcp-ib-gateway-live` are on `mcp-ib-live-net` **only** — NOT on `mcp-net`. The dev proxy only ever reaches `mcp-ib-paper` (paper). So no live-reach is involved in this wiring.

### Proposed solution
Attach the **paper-side backend wrappers** (`mcp-postgres-enhanced`, `mcp-playwright`, `mcp-ib-paper`, `mcp-timescaledb`, `mcp-memory`) to `mcp-dev-net` (multi-homed — they keep `mcp-net`), then move the two dev apps onto `mcp-dev-net`. Persist by editing the backends' deploy scripts under `projects/mcp/` (a material change to a neighboring project).

### The honest problem with the proposed solution
To make name-resolution work, **every backend the dev proxy needs must also join `mcp-dev-net`** — at which point `mcp-dev-net` is **functionally identical to `mcp-net`** for these services. The segmentation becomes **organizational/labeling only, not a boundary** (and on one rootful daemon, per the settled model, a network boundary isn't a security control anyway). So we'd be adding a network, multi-homing 5 admin containers, and editing 5 deploy scripts for ~marginal value.

### Specific questions for the board (Decision 3)
1. **Is `mcp-dev-net` worth wiring at all**, given it becomes ≈ `mcp-net`? Or is the honest call to **abandon it** and leave the dev apps on `mcp-net` (status quo, working)?
2. Is there a configuration that gives **real, durable value** — e.g. *not* attaching all backends, exposing only a curated subset to dev, or using it as the anchor for a future network-policy/firewall layer — that would justify keeping it? What concrete "refinement later" does the seam actually enable that `mcp-net` membership does not?
3. Any risk in **multi-homing** the backend wrappers onto a second bridge (name-resolution ambiguity, the proxy resolving the wrong interface, MTU/subnet issues on `10.4.0.176/29` — a /29 is only 6 usable IPs)?
4. If we keep it: should the dev apps be on `mcp-dev-net` **only**, or `mcp-dev-net` + `mcp-net`? Which minimizes confusion while preserving the seam?

---

## Constraints (read before answering)
- **One rootful docker daemon. Rootless is settled-NO** (`no-rootless.md`). Do not propose it.
- **docker-group-for-devs is accepted**; the real boundary is IBKR caps + isolated live net + no agent socket + manual/admin live deploy. Do not propose Portainer-RBAC-as-boundary (descoped) or a single-vendor agent-runtime migration.
- `projects/gitlab/` and `projects/data/` are **hard-deny safety-net trees**; an enforcement hook blocks writes there.
- Repos are **private**; only 2 developers (websurfinmurf, joe) can open MRs. Threat model = compromised dev account/agent, not anonymous outsider. IBKR caps are the financial backstop (operator verifying separately — out of scope here).
- GitLab is **CE** (no EE-only features); registry at `gitlab.ai-servicers.com:5050`; shell runners SSH to `localhost` as the deploying user to run `docker compose`.
- These two decisions are **reasonable-max hardening / hygiene**, explicitly NOT attempts to build an absolute boundary. Judge them on cost/benefit within the accepted model, not against an ideal.

## What I need
For **each decision**: (1) is the proposed solution correct, or is there a better option within the constraints? (2) concrete recommendation with rationale, (3) risks/gotchas I'm missing. For Decision 3 specifically, a clear **keep-and-wire vs. abandon** verdict.
