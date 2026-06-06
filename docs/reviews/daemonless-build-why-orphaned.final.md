---
name: daemonless-build-why-orphaned
created: 2026-06-04
status: review-complete
sources: [gemini, codex, claude]
---

# Why the OSS world walked away from no-userns daemonless builds — Board synthesis

## The WHY (3-way consensus — this is the answer the operator asked for)
The world didn't *forget* this niche; it *walked away* because the thing it depended on dodging became universal and a better engine won:

1. **User namespaces became default-on everywhere** (Debian/Ubuntu/Fedora/RHEL; k8s userns GA). The *entire* modern rootless build/run ecosystem — BuildKit-rootless, Buildah, Podman, img — is **built on userns**. So "no-userns" is a constraint essentially nobody designs for anymore.
2. **BuildKit won the engine war** (Docker 23.0, 2023-02-01 made buildx/BuildKit the default builder; it's the backend for Docker, Tekton, Dagger, Earthly…). Kaniko's distinctive technique became redundant.
3. **Kaniko's technique was always the odd one out**, and once redundant it was archived (Google read-only 2025-06-03, message: "use BuildKit").

**The mechanism (Claude — the crisp part):** rootless builders run each `RUN` step in a *nested* child container → they must map uid→0, mount overlayfs, and chown → the kernel only grants those via `unshare(CLONE_NEWUSER)`. Strip userns and their first syscall fails — exactly our error. **Kaniko never nests:** it untars layers into its *own* container root, runs `RUN` as real root *in place* (no chroot/mount/namespace), and snapshots the fs in userspace. That's why it alone needs no userns — and why it's the only thing that ever fit "daemonless + unprivileged + no-userns."

**Our situation is a self-imposed outlier:** we disabled unprivileged userns host-wide as hardening — i.e., we removed the exact substrate the modern ecosystem stands on. The world walked away *because the alternative (userns) became universal and strictly better*; we're the rare shop that can use neither dockerd nor userns, by deliberate choice.

## Plot twist (Claude finding): "nobody supports it" is slightly too strong
A maintained **community fork** still serves the exact niche: **`osscontainertools/kaniko` v1.27.5 (2026-05-15)** — **publishes free, shell-bearing images** (`ghcr.io/osscontainertools/kaniko:debug`), preserves the no-userns technique. So the choice is no longer "archived-frozen vs nothing." **Caveat:** it's a small-maintainer fork (Docker Hub mirror is an individual's namespace) → bus-factor risk; mitigate by pinning by digest **and mirroring into our own registry**.

## Q3 — what the industry actually endorses (consensus)
**(D) Build where the capability legitimately lives** — a dedicated, isolated build node/VM (or a build-only runner with userns scoped ON) running **maintained BuildKit**. Rationale (all three): image building inherently needs a daemon, privilege, OR userns; a hardened runner that denies all three is declaring "I am not a build host." Isolate the build capability; keep the general fleet hardened. Bonus: BuildKit is better *engineering* (caching, parallelism, correctness), not just better-maintained.
- Codex: "D is the architecturally honest answer; A (pinned archived Kaniko) is a tolerable stopgap, not the direction."
- Claude: deepest point — the constraint is self-imposed; the durable fix is to **re-enable userns in a scoped context** (the build node only), which reopens the whole modern ecosystem = basically D.

## Two coherent TERMINAL states (Claude — deliberately NOT a tiered "now/later" plan)
- **D — dedicated build context (userns scoped-on / build VM) + BuildKit.** Architecturally correct; stops fighting our own hardening; maintained vendor-backed tooling; retires runner 7. Cost: provision/maintain an isolated build runner or VM (and verify userns can be scoped to it given this host's AppArmor restriction — may need a small VM if not).
- **Maintained Kaniko fork on the existing runner — `osscontainertools/kaniko:debug`, pinned + mirrored.** A legitimate steady state (NOT tech debt): builds are protected-ref-only, hygiene not a boundary, and the tool is *currently maintained*. Removes the "archived" objection entirely. Sacrifices only architectural purity (still building on a "not a build host") + carries small-maintainer bus-factor.

## Recommendation
- **Purist / architecturally-correct end-state: D.** It resolves the self-contradiction permanently and uses the industry-standard maintained engine.
- **Proportionate terminal choice for this one-host homelab: the maintained `osscontainertools/kaniko` fork, pinned + mirrored.** Given the operator's "reasonable-max for a one-host setup" bar, a whole build VM for one gdal+pip protected-ref build may be over-engineering; the maintained fork fits with zero new infra and is not debt.
- **Avoid:** frozen *archived* Kaniko (now strictly dominated by the maintained fork) and option B (keep the privileged runner).
- **Not offered:** a "Kaniko-now / build-VM-later" tier — pick a terminal state.

## Blind spots flagged (Claude)
1. The "only archived Kaniko fits" premise was wrong — `osscontainertools` is maintained, free, shell-bearing; update the prior matrix.
2. Bus-factor on the community fork → pin + mirror; treat a stall as a known risk.
3. Kaniko's correctness/perf weaknesses (overwrites its own root; weaker caching) are independent of maintenance — D/BuildKit fixes those too.
4. The constraint is self-imposed; periodically re-check whether scoped userns on a build-only runner is achievable — that *is* path D and the most durable fix.
