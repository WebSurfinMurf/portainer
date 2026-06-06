---
source: codex
reviewed: 2026-06-04
context: lt7-runner-and-net.md
---

**Decision 2**
1. Architecture is correct, with one change: keep the dedicated non-socket `dev-ci` runner, but do not start a new build path on Kaniko. Better option within constraints: non-privileged Docker executor for MR/test jobs plus a daemonless image builder that is still maintained. A dedicated shell executor under an unprivileged UID is not better; GitLab's own runner security guidance treats `shell` as higher risk than non-privileged Docker because jobs run directly on the host. The runner process having daemon access to start job containers is acceptable; that is normal Docker-executor trust, materially different from handing the job container `/var/run/docker.sock`.

2. Recommendation:
- Create `dev-ci` as a dedicated Docker executor runner with `privileged=false`, no socket mount, `run_untagged=false`, single explicit tag `dev-ci`.
- Move all MR/build/test jobs to explicit `tags: [dev-ci]`. Don't rely on "untagged falls through."
- For image builds, replace Kaniko with **Buildah** or GitLab's current daemonless BuildKit path. Buildah is the cleaner fit with the "no rootless daemon" decision. No daemon in the job, no socket in the job.
- Keep deploy jobs on runner id 3.
- Location: choose **2b**, not 2a or 2c — keep `projects/gitlab/` hard-deny intact, place checked-in runner config/deploy in a separate admin-owned path. Skipping a checked-in deploy.sh is also wrong.
- After migration, set runner 7 `run_untagged=false` immediately, then retire it or keep it protected and narrowly tagged for admin-only. Don't leave a dangerous runner with generic tags like `docker`/`developer`.

3. Risks / gotchas:
- **Kaniko is archived** (GoogleContainerTools/kaniko archived 2025-06-03). Don't introduce new dependency on it in 2026.
- MR pipelines run the source branch's `.gitlab-ci.yml` pre-merge — your diagnosis is correct; it's the core reason runner 7 is the live problem.
- Don't assume protected variables for MR builds. Use predefined `CI_REGISTRY_USER`/`CI_REGISTRY_PASSWORD`.
- If GitLab CE older than 18.1, protected-runner access from MR pipelines is version-sensitive. Verify.
- Audit every repo for untagged jobs, `default: tags`, and any job that can select runner 7. Otherwise you close stocktrader and leave the path open elsewhere.
- Separate untrusted MR image outputs from trusted deploy-consumed tags. An MR pipeline should not push `latest`/`main`/`staging` or any tag the protected deploy path consumes as authoritative.
- On a shared non-ephemeral Docker runner, use `pull_policy = "always"` and avoid reusable cross-project state.
- Scope `dev-ci` as narrowly as practical; a compromised project on a shared runner can still contaminate other jobs even without host-root.

**Decision 3**
1. Verdict: **abandon it.** Within the accepted model it creates no real boundary, and operationally it mostly duplicates `mcp-net` while increasing moving parts.

2. Recommendation:
- Leave dev apps on `mcp-net`.
- Don't multi-home the five backends; don't edit five neighboring deploy scripts for this.
- Delete `mcp-dev-net`, or leave it explicitly dormant/backlogged, documented as "not wired because it adds no present value."
- If you ever want a real seam: not "attach everything to a second bridge" — the useful version is a dedicated broker/gateway on a dev-only network exposing a curated subset upstream, or a separate host with real network policy. Different design.

3. Risks / gotchas:
- Subnet undersized. 5 backends + 2 dev apps = 7 endpoints; a `/29` doesn't support that.
- Dev apps on `mcp-dev-net` only → must re-home every backend, gain almost nothing.
- Dev apps on both → seam is ceremonial and more confusing to debug.
- Multi-homing adds DNS/address ambiguity and increases deploy-script blast radius.
- "Refinement later" is not a benefit by itself; network labels don't become security later by magic without a real enforcement point.

Sources checked: GitLab MR pipeline semantics, runner security guidance, Docker executor docs (Buildah/Podman), registry auth, BuildKit guidance, Kaniko archive status.
