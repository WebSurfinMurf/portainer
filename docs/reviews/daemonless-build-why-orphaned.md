---
name: daemonless-build-why-orphaned
created: 2026-06-04
status: pending-review
---

# Is "daemonless, unprivileged, NO-user-namespace, Dockerfile image build" a genuinely orphaned use case in 2026 OSS — and if so, WHY?

## Ask in one line
We've concluded that **no actively-maintained open-source tool** builds container images under our exact constraint set. The operator will accept that — **but only if you can explain *why the world abandoned this path*.** Not "which tool" (we've done that); **why does the ecosystem no longer support it, what assumption does everyone else make that we don't, and what did they consolidate on instead.**

## Our exact constraint set
Build an OCI/Docker image (Dockerfile-based; simple `FROM python… + apt GDAL + pip`) inside a GitLab CI job that is ALL of:
1. **Daemonless** — no dockerd, no `/var/run/docker.sock` in the job.
2. **Unprivileged** — `privileged: false`.
3. **No user namespaces** — `unshare(CLONE_NEWUSER)` is DENIED. This host *deliberately* disables unprivileged userns host-wide (`kernel.apparmor_restrict_unprivileged_userns`; loosening it was tried and reverted as a regression — see `/workspace/administrator/projects/portainer/docs/no-rootless.md`). Running as root *inside* an unprivileged container is fine; *creating* new namespaces is not.
4. **Free, shell-bearing job image** — GitLab's docker executor needs a shell in the image to run `script:`.

## What we verified empirically (GitLab CI, this host)
- ✅ **Archived `gcr.io/kaniko-project/executor:debug` builds green** — daemonless, no userns, shell present. The *approach* works.
- ❌ **Buildah/BuildKit-rootless**: `Error during unshare(CLONE_NEWUSER): Operation not permitted` — they require the userns this host denies.
- ❌ **Chainguard's maintained Kaniko fork is not usable on the free tier**: `-dev` (shell) variant is paid; free `:latest` is distroless (no shell → can't run a GitLab job); the fork repo publishes no images.
- **Net:** the only thing that actually fits is **archived Kaniko** (pinnable by digest, frozen).

## The questions for you (web-research + reason; cite sources, be concise)
1. **Is the niche genuinely orphaned?** Confirm or refute: in 2026, no maintained OSS tool does Dockerfile-based, daemonless, unprivileged, **no-userns**, shell-bearing image builds. (We've checked BuildKit, Buildah, Podman, img, Stacker, apko/melange, Bazel rules_oci, buildpacks, umoci/crane, Kaniko + its Chainguard fork.)
2. **WHY did the world abandon it?** This is the real question. Specifically:
   - Is the load-bearing assumption that **unprivileged user namespaces are available** (default-on across modern distros), so the entire rootless-build ecosystem (BuildKit-rootless, Buildah, Podman) is *built on* userns — making "no-userns" a constraint essentially nobody designs for anymore?
   - Did the ecosystem **consolidate on BuildKit** (and userns-based rootless) such that Kaniko's distinct "run-as-root-in-container, userspace layer extraction, no-userns" technique became redundant and unmaintained?
   - Is our situation an **outlier created by our own hardening** (we turned OFF the very capability — userns — that the modern approach depends on)?
3. **Given that, what would the world actually endorse** for a host that deliberately denies userns? Options we see: (A) accept frozen/pinned archived Kaniko; (B) keep a privileged build runner; (C) maintain our own shell image from the Chainguard fork; (D) **provide the missing capability at a different layer** — a dedicated build node/VM where privilege (or userns) is acceptable and isolated. Which is the architecturally-honest answer, and is "the industry answer" really (D) — i.e., *don't* do unprivileged-no-userns builds on a hardened general runner; do builds where the capability legitimately lives?

## Constraints / don't re-tread
- Rootless dockerd is settled-NO here; do not re-propose it or host-wide userns loosening.
- We've already done the tool-by-tool matrix (`reviews/kaniko-replacement-builder.final.md`); **don't repeat it** — focus on the *why* and the *industry direction*.
- Builds run **only on protected refs** (reviewed code); a daemonless builder here is hygiene to retire a privileged runner, not a security boundary. The legacy privileged runner is already `ref_protected` (MRs can't reach it).
- Be concise and direct; cite sources for the "why."
