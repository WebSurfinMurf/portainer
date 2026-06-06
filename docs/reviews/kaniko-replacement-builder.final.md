---
name: kaniko-replacement-builder
created: 2026-06-04
status: review-complete
sources: [claude, gemini, codex]
note: gemini+codex timed out on first dispatch; returned on retry. All three returned.
---

# Daemonless builder for the no-privilege / no-userns runner — Review Board synthesis

## Consensus (3-way)
- **Maintained Kaniko exists.** Google's `GoogleContainerTools/kaniko` was archived 2025-06-03, but **Chainguard forked it June 2025** (`github.com/chainguard-dev/kaniko`) and actively maintains it. Codex verified 2026 releases: **Feb 10, Apr 29, May 13 2026 (v1.25.15)**, with security/dep updates. → Requirement #6 (maintained) now PASSES for Kaniko. The earlier "not Kaniko" was based on the upstream archive, not the ecosystem.
- **Recommended builder = Chainguard's Kaniko fork.** Drop-in for the already-green job, daemonless, runs root-in-container, **no user namespaces**, no sandbox loosening. Zero migration.
- **A daemonless builder is hygiene, NOT a security boundary here.** Builds run only on protected refs (reviewed/merged code), and the untrusted-MR root-equivalence hole is already closed by `ref_protected` on the legacy runner. So this is defense-in-depth / "retire the last privileged runner," not a load-bearing control.

## Key insights
- **(Claude) The original brief had TWO outdated premises** — "Kaniko unmaintained" (a maintained fork existed *before* the brief was written) and "Buildah needs userns" (that's *rootless* Buildah; root-in-container is different). The maintained fork being missed is the same lesson as the original Kaniko miss: *archived repo ≠ dead ecosystem — check for forks.*
- **(Codex) Buildah does NOT cleanly fit** the strict profile: even root-in-container `--isolation=chroot` still creates mount/UTS namespaces, and Docker's default seccomp blocks `unshare`/`mount` — so it likely fails under this host's confined runner, contrary to the Claude node's read.
- **(Gemini) Even if Buildah works, `STORAGE_DRIVER=vfs` has a heavy disk/IO penalty** (full tree copy per layer) vs Kaniko's snapshotting.

## Disagreement
- **Buildah-chroot+vfs viability:** Claude said it fits (real root → no userns); Codex said the confined seccomp/namespace profile still blocks it; Gemini said works-but-slow. **Resolution:** treat Buildah as NOT a safe fit — at minimum it needs a POC, and Codex's seccomp argument suggests it would fail outright. Kaniko-fork avoids the question entirely. → **Don't use Buildah.**
- **Is daemonless worth it (Q4):** Gemini/Codex → "keep builds on the ref_protected privileged runner; backlog a dedicated build VM." Claude → "adopt it because Chainguard-Kaniko makes it free and it retires the last privileged runner." **Resolution:** since the maintained fork makes it ~zero-cost, the architecturally-correct end-state (no privileged runner) is achievable now for free → take it. The "keep privileged runner" path is the acceptable fallback, not the rec.

## Action items
1. **Repoint the Kaniko build job to `chainguard-dev/kaniko`** (verify current tag/digest in Chainguard's catalog; pin by digest). njproperties first, then stocktrader. Keep `rules: $CI_COMMIT_REF_PROTECTED == "true"`.
2. **Retire privileged runner 7** once both builds are on Kaniko-fork and confirmed green.
3. **Reconcile the "NOT Kaniko" lines** I wrote (LT-7 docs, `docs/context/security.md`, architect agent, the dev handoff) → "maintained Chainguard fork; pin by digest."
4. **Backlog:** if builds outgrow simple (or need features), move to a dedicated build VM/host running maintained privileged BuildKit — the true end-state. Not now.

## Risks flagged
- **Chainguard fork is "no new features" (security/bugfix stewardship only)** — fine for simple GDAL+pip; not for complex pipelines (Claude).
- **Buildah would fail or thrash** under the strict profile / vfs (Codex, Gemini) — avoid.
- **Supply-chain residual is builder-agnostic** — a malicious `RUN` in a *merged* Dockerfile executes regardless of builder; pin/hash-lock deps + build-time egress limits are the real follow-on (Claude). Separate work.
- **Lesson:** "archived repo ≠ dead ecosystem — check for an active fork" — pairs with the existing `vet-tool-currency-before-recommending` memory.
