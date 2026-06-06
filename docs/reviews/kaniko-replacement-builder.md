---
name: kaniko-replacement-builder
created: 2026-06-04
status: pending-review
---

# Is there an actively-maintained daemonless image builder that works on a no-privilege, NO-user-namespace runner — or is archived Kaniko the only fit?

## Situation
GitLab CI on a single host, ONE rootful docker daemon. We stood up a non-privileged `dev-ci` runner to build/test developer code without root-equivalence:
- GitLab **docker executor**, **`privileged=false`**, **NO `/var/run/docker.sock` in job containers**.
- Job containers run as **root inside the container** (uid 0) but the container is unprivileged (default seccomp/AppArmor).
- **This host deliberately restricts unprivileged user namespaces** (`kernel.apparmor_restrict_unprivileged_userns` + AppArmor mediation). Loosening it host-wide was attempted and **reverted as a regression** — see `/workspace/administrator/projects/portainer/docs/no-rootless.md`. So **`unshare(CLONE_NEWUSER)` is DENIED** for job containers, and we will not loosen it (the same runner pattern also runs untrusted merge-request code).

We need to build OCI/Docker images (Dockerfile-based; e.g. a Python image with system libs like GDAL + pip deps) in this runner and push to our GitLab registry with `$CI_JOB_TOKEN`.

## What we already tested (hard data)
- **Kaniko** (`gcr.io/kaniko-project/executor`): ✅ **builds green here** — daemonless, runs as root-in-container, **needs NO user namespaces**. BUT the project was **archived 2025-06-03** (no upstream maintenance/security fixes).
- **Buildah / BuildKit-rootless**: ❌ require `CLONE_NEWUSER` (rootless userns) → **blocked** by this host's userns restriction. Using them would mean loosening the sandbox that runs untrusted MR code. Rejected.

## The precise spec — evaluate every candidate against ALL of these
1. **Dockerfile-based** (or a trivial migration path for a simple `FROM python… + apt/pip` image).
2. **Daemonless** — no dockerd, no socket mounted into the job.
3. Works **without `privileged: true`**.
4. **Works WITHOUT unprivileged user namespaces** (no `CLONE_NEWUSER`). Running as root *inside* an unprivileged container is fine; *creating new user namespaces* is not. ← **THIS is the killer constraint that eliminates Buildah/BuildKit-rootless. Judge each candidate explicitly on it.**
5. Pushes to a registry with `CI_JOB_TOKEN` / basic creds.
6. **Actively maintained in 2026** (the entire point — Kaniko fails only this criterion).

## What I need
1. **Name any actively-maintained OSS image builder that meets ALL 6.** The operator strongly suspects a live competitor exists. **Web-search current (2026) options** and assess each against #4 and #6 specifically. Candidates to check (not exhaustive): BuildKit non-rootless / `buildctl` with `--oci-worker-no-process-sandbox`, Buildah in any non-userns mode, **apko/melange** (Chainguard), **Bazel rules_oci**, `img`, Stacker, `umoci`+`skopeo`, nerdctl, Podman build, Cloud Native Buildpacks (`pack`/lifecycle), Depot, `oci-build`/`crane`-based flows. For each: maintained? needs userns? Dockerfile-based? pushes with token?
2. If one fits → name it + a **minimal GitLab CI job snippet** for this constraint.
3. If **Kaniko's exact niche (Dockerfile + daemonless + no-privilege + no-userns + runs-as-root-in-container) is genuinely unfilled by a maintained tool**, say so plainly — that materially changes our call.

## Secondary — challenge the premise if warranted
Builds run **only on protected refs** (main/staging/tags), **never on merge requests** — so the build job is reviewed/merged code, not untrusted MR code. The pre-merge root-equivalence hole is **already closed** (MR test jobs run on the non-priv runner; the legacy privileged runner is now `ref_protected`, so MR pipelines cannot reach it). Given that: **is chasing a daemonless builder for the build job even worth it, or should builds simply stay on the existing `ref_protected` privileged runner (maintained dind/BuildKit) with "zero privileged runners" backlogged to a dedicated build host/VM?** Give the strongest answer even if it moots Q1.

## Constraints
- Single rootful daemon; **rootless is settled-NO** on this host (`no-rootless.md`) — do NOT propose rootless dockerd or host-wide userns loosening.
- Do NOT propose weakening the `dev-ci` runner's sandbox (it also runs untrusted MR code).
- GitLab **CE**; registry `gitlab.ai-servicers.com:5050`; auth via `CI_JOB_TOKEN`.
- Images are simple (Python + system libs), not a complex multi-stage matrix.
- Judge on cost/benefit within this accepted model; prior related review: `lt7-runner-and-net.final.md` (same folder).
