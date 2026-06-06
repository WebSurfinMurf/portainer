---
source: claude
reviewed: 2026-06-04
context: lt7-runner-and-net.md
note: this node pulled the actual stocktrader/.gitlab-ci.yml to ground the review against reality
---

## Decision 2 — non-privileged `dev-ci` runner

**(1) Pattern correct, but doc misdiagnoses where pre-merge risk lives and stops one step short.**

The runner *process* still holding daemon access does NOT reintroduce risk, and it's the same logic as no-rootless.md pointing the other way: the network/socket-proxy ideas failed because the attacker was *already* host-root via the mounted socket. The dev-ci design *removes* the socket from the job container → the in-container attacker is not host-root and has nothing to step over. The boundary becomes "developer controls `script:`, admin controls `config.toml` (host-resident, admin-owned, not in any repo)" — a real boundary made of file ownership, not a ritual. The runner process being root-equivalent is fine (same trust class as admin/daemon already). Shell-executor-as-uid is a regression (no container isolation); Podman rootless re-enters the settled-NO swamp. Kaniko/daemonless build is the clean answer.

**The misdiagnosis:** the actual `build:` job rules are `main / staging / $CI_COMMIT_TAG` — **build does NOT run on MRs today.** The only `if: $CI_MERGE_REQUEST_IID` jobs are five `python:3.12-slim` jobs (lint/syntax/smoke/unit/test-autotrade), none needing docker. So **the pre-merge root-equivalence closes the moment those five jobs leave runner 7 — nothing to do with Kaniko.** Kaniko is post-merge build hygiene (lower threat). Do the retag first; don't let the build conversion gate it.

**(2) Recommendation**
1. Provision `dev-ci` as the *default* non-privileged dev docker runner (`run_untagged=true`, `privileged=false`, no socket volume), and **retire runner 7 — do not merely `ref_protected` it.** For `docker:26-dind` to have worked, runner 7 almost certainly has `privileged=true` — a privileged runner is worse than a socket mount and `ref_protected` still runs it on `main`. Once Kaniko removes the only reason a dev runner needs privilege/socket, no legitimate dev job needs runner 7 (deploys SSH to host + compose there; tests need nothing; build→Kaniko). Keeping it "for protected branches only" is the shortcut-now tech debt the operator rejects.
2. Retag stocktrader CI (developer's repo — coordinate): 5 python jobs → `dev-ci` (closes the hole); `build`→Kaniko on `dev-ci`; `deploy-*`+`post-deploy-tests`→shell runner 3 (ref_protected); `qa-autotrade-integration`→`dev-ci`.
3. **Audit runner→group authorization** — ensure the only runners the `developers` group can reach are shell-3 (ref_protected) and dev-ci (non-priv). If admin runner 8 or any instance runner is privileged AND visible to dev projects, the whole exercise is theater.

**Location: 2b. Do not pierce the hard-deny, even supervised.** The value of a hard-deny is that it's inviolable; the first "supervised exception" makes it negotiable. A runner is not the GitLab server — it's a separate container that registers to GitLab. Put it in `projects/cicd/runners/dev-ci/` (a *more* correct home than burying it in the server tree); end-state, migrate all runners out of the safety net into `cicd/`. Leave a one-line pointer in gitlab docs. 2c violates deploy.sh reproducibility — out.

**(3) Gotchas**
1. build doesn't run on MR today — pre-merge fix is the test-job retag, full stop.
2. Verify `privileged=true` on runner 7 → makes "retire" clearly correct.
3. **Registry-push poisoning IF you add build-on-MR:** `CI_JOB_TOKEN` is available on MR pipelines; a same-project MR build pushing a mutable tag (`:model`/`:latest`/`:staging`) poisons what deploy later pulls. Mitigate: MR build `--no-push` or immutable per-MR tag only; deploys pull only protected/immutable tags. **This surface does not exist today** (no MR build) — the doc's "keep builds on MRs" framing would *introduce* it.
4. **Runner→group authorization is the actual boundary**, not the dev-ci config. If any privileged runner is shared to dev projects, a malicious MR can `tags: [that-runner]` and you're back to root-equivalent. Single most important step.
5. `run_untagged` race during migration — sequence: stand up dev-ci → retag/confirm all stocktrader jobs → then retire 7. Confirm no other dev project relies on untagged-onto-7.
6. Kaniko mechanics on CE: `:debug` image, drop dind `DOCKER_TLS_CERTDIR`/`DOCKER_HOST`, write `/kaniko/.docker/config.json` with `gitlab-ci-token:$CI_JOB_TOKEN`, mount internal CA if `:5050` presents one, no cache repo → full rebuilds.

**(4) Blind spots**
- The build-on-MR premise is false against the real file — "keep MR builds" *adds* a push surface rather than preserving one.
- `ref_protected` feels sufficient but isn't (runner 7 almost certainly privileged, still runs on main).
- The fix's integrity is in runner-sharing config, not the runner you build.
- Editing `stocktrader/.gitlab-ci.yml` is a cross-user material change — coordinate/`refocus`, not admin-unilateral.

## Decision 3 — `mcp-dev-net`: ABANDON (and delete the network).

**(1) No.** Fatal defect the doc states but doesn't connect: the wiring **doesn't fit the subnet.** `10.4.0.176/29` = 5–6 usable IPs; plan needs 7 containers (5 backends + 2 apps). **Not deployable** without resizing (destroy/recreate). Beyond that: not a security boundary (host root joins any net), not even a functional boundary (every backend must join → `mcp-dev-net ≡ mcp-net`), and negative hygiene (multi-home 5 admin containers, edit 5 deploy scripts, permanent "why does this exist" drift). Added complexity cuts *against* the operator's reasonable-max-hygiene bar.

**(2) Only valuable config is the inverse of proposed:** put *only* the curated subset dev may reach on `mcp-dev-net` and remove dev apps from `mcp-net` entirely, so the proxy resolves only the allowed set — genuine app-level least-privilege egress (binds because the dev apps, carrying no socket, are not host-root). **But it evaporates against verified facts:** live IB is already isolated; the remaining `mcp-net` set the proxy can reach is exactly what it's supposed to reach. Curated-subset == full-needed-set == no restriction gained. Flips to "keep" only if `mcp-net` carries a backend the dev proxy should be *denied* — inventory shows none.

**Verdict: abandon, `docker network rm mcp-dev-net`.** "Refine later" is YAGNI — a docker network is a one-command zero-cost artifact to create when a concrete need appears; an unused `/29` rots into inventory noise. Delete it.

**(3) Multi-homing risks:** subnet capacity (fatal); DNS interface ambiguity; MTU mismatch → silent fragmentation/hangs; drift (5 scripts must forever attach both nets; one forgotten redeploy silently breaks dev name resolution).

**(4)/blind spot:** the /29 can't hold the plan — proposal stated as deployable, isn't. "Refinement later" inverts the cost calculus: cheap to create later on demand, a standing liability now. Delete, don't leave unwired.

## Bottom line
- **Decision 2:** pattern right and consistent with the model; pre-merge hole closed by retagging the **5 python test jobs** off runner 7 (Kaniko separate post-merge hygiene); **retire runner 7, don't ref_protect** (likely privileged=true); real control is **runner→developers-group authorization** (audit it); config in **projects/cicd/runners/dev-ci/ (2b)**, never pierce hard-deny; if build-on-MR added, `--no-push`/immutable-only; CI retag is a **cross-user change — coordinate.**
- **Decision 3:** **abandon and delete.** Neither security nor functional boundary, doesn't fit its own /29, "refine later" is YAGNI. Revisit only if mcp-net carries a deny-worthy backend → then a curated-subset net (dev off mcp-net), not the all-backends version.
