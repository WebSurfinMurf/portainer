---
name: lt7-runner-and-net
created: 2026-06-04
status: review-complete
sources: [gemini, codex, claude]
---

# LT-7 — `dev-ci` runner + `mcp-dev-net`: Review Board synthesis

## Consensus (3-way unless noted)

### Decision 2 — non-privileged `dev-ci` runner
- **The pattern is correct:** a Docker-executor runner with the docker socket **omitted from job-container volumes** (`privileged=false`, no `/var/run/docker.sock`). Jobs run containerized but socket-free → not host-root-equivalent. Consistent with the settled model (removing the socket makes the file-ownership boundary *real*, unlike the rejected network/proxy rituals). The runner *process* holding daemon access is fine — same trust class as the daemon/admin already.
- **Location = 2b. Do NOT pierce the `projects/gitlab/` hard-deny, even "supervised."** All three: a safety net's value is that it's inviolable; the first exception makes it negotiable. A runner is a separate container that registers *to* GitLab, not part of the server tree.
- **Use explicit `dev-ci` tags**; never rely on untagged fallthrough.
- **Audit which runners the `developers` group can reach** — if any *other* privileged/socket runner stays visible to dev projects, a malicious MR just targets that one and the fix is theater. (Codex + Claude call this the actual control; Gemini's "audit all repos before restricting runner 7" is the same point.)
- **Don't assume protected CI variables on MR pipelines**; use predefined `CI_REGISTRY_USER`/`CI_REGISTRY_PASSWORD` / `CI_JOB_TOKEN`.

### Decision 3 — `mcp-dev-net`
- **ABANDON. Unanimous.** And all three independently caught the **fatal defect: the `/29` subnet (`10.4.0.176/29` ≈ 5–6 usable IPs) cannot hold the 7 containers** (5 backends + 2 apps) the plan requires — it's not even deployable as written.
- It is neither a security boundary (host root joins any net) nor a functional one (every backend must join → `mcp-dev-net ≡ mcp-net`), and it adds negative hygiene (multi-home 5 admin containers, edit 5 deploy scripts, DNS/MTU ambiguity, drift).
- **Leave dev apps on `mcp-net`** (status quo, working).

## Key Insights
- **(Claude) The pre-merge hole is closed by retagging the FIVE python test jobs — not by Kaniko.** Claude pulled the real `stocktrader/.gitlab-ci.yml`: `build:` runs on `main/staging/tags`, **not on MRs**. The only `$CI_MERGE_REQUEST_IID` jobs are 5 `python:3.12-slim` jobs needing no docker. So the doc's premise ("Kaniko keeps builds on MRs") is false — moving the 5 test jobs off runner 7 is the entire pre-merge fix; Kaniko is separate, lower-priority post-merge hygiene.
- **(Codex) Kaniko is archived** (GoogleContainerTools/kaniko, 2025-06-03). Don't adopt a dead dependency in 2026 — use **Buildah** or GitLab's **BuildKit** daemonless path instead.
- **(Claude) Retire runner 7, don't just `ref_protected` it.** For `docker:dind` to have worked it almost certainly has `privileged=true` — worse than a socket mount, and `ref_protected` still runs it post-merge on `main`. After Kaniko/Buildah, no legitimate dev job needs it.
- **(Claude) Registry-push poisoning is a surface that does NOT exist today** and the doc's "keep builds on MRs" framing would *introduce* it. If build-on-MR is ever added: `--no-push` (validate only) or immutable per-MR tags only; deploys consume only protected/immutable tags.
- **(Claude) Best home is `projects/cicd/runners/dev-ci/`** — a *more* correct location than the server tree; end-state migrate all runners into `cicd/`.
- **(Claude/Codex) Editing `stocktrader/.gitlab-ci.yml` is a cross-user, material change** in the developer's repo → coordinate (the developer owns the retag), admin owns the runner side.

## Disagreements
- **Build tool:** Gemini said Kaniko is fine; Codex said Kaniko is archived → Buildah/BuildKit; Claude said Kaniko is clean *but* build isn't the urgent part. **Resolution:** prefer **Buildah or BuildKit** (maintained, daemonless); the build conversion is low-priority post-merge hygiene regardless, so it must not gate the high-value test-job retag.
- Otherwise no material disagreement — both decisions are effectively unanimous.

## Action Items (ordered)
1. **Provision `dev-ci`** docker-executor runner: `privileged=false`, no socket volume, explicit `dev-ci` tag. Config/deploy in **`projects/cicd/runners/dev-ci/`** (NOT `projects/gitlab/`). Admin task.
2. **Audit runner→group authorization**: confirm the only runners reachable by `developers` projects are shell-3 (`ref_protected`) + `dev-ci` (non-priv). Check runner 8 / any instance runner is not privileged-and-shared. Admin task. **(Highest-leverage — do before declaring the gap closed.)**
3. **Developer retags `stocktrader` CI** (coordinate): 5 python test jobs → `dev-ci`; `deploy-*`+`post-deploy-tests` → shell runner 3; `qa-autotrade-integration` → `dev-ci`. This closes the pre-merge root-equivalence.
4. **Convert `build:` to Buildah/BuildKit** on `dev-ci` (post-merge hygiene; lower priority). If build-on-MR is added, `--no-push`/immutable-tag-only.
5. **Audit other dev projects** (`njproperties`, `developer`, `minecraft`) for untagged jobs / `default: tags` that could still select runner 7.
6. **Retire runner 7** (not merely `ref_protected`) once all dev jobs are off it; verify its `privileged` flag first to confirm. Sequence after 1–5 to avoid the `run_untagged` race.
7. **Decision 3: `docker network rm mcp-dev-net`**; leave dev apps on `mcp-net`. Update the LT-7 closeout + memory to reflect abandonment.

## Risks Flagged
- **`/29` IP exhaustion** — `mcp-dev-net` as wired is undeployable (all three).
- **Kaniko archived** — don't build new dependence on it (Codex).
- **Runner 7 likely `privileged=true`** — `ref_protected` is insufficient; retire (Claude).
- **Other reachable privileged runners** make the whole fix theater if not audited (Codex/Claude/Gemini).
- **Registry-tag poisoning** if build-on-MR pushes mutable tags (Claude/Codex).
- **Multi-homing DNS/MTU ambiguity** if `mcp-dev-net` were kept (all three).
- **`run_untagged` race** while both runner 7 and `dev-ci` exist — sequence the migration (Claude).
- **Cross-user edit** of stocktrader CI — coordinate, don't do unilaterally (Claude/Codex).
