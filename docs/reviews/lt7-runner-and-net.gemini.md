---
source: gemini
reviewed: 2026-06-04
context: lt7-runner-and-net.md
---

### Review: LT-7 Implementation Decisions

#### DECISION 2 — Provision a non-privileged `dev-ci` runner

**1. Is the proposed solution correct?**
Yes. Using a Docker executor with the `/var/run/docker.sock` volume omitted, paired with Kaniko for daemonless image builds, is the correct, industry-standard pattern here. It removes the trivial `docker run --privileged` root-pivot from CI jobs without requiring rootless Docker or Podman, keeping you within the settled single-rootful-daemon constraints.

**2. Concrete Recommendation & Rationale**
*   **Implementation:** Adopt the socket-free Docker executor and use Kaniko for MR builds.
*   **Location:** Go with **Option 2b** — site the new runner outside the safety net (e.g., `projects/gitlab-runner-dev-ci/`). A hard-deny safety net like `projects/gitlab/` should remain absolute. Granting "one-time exceptions" normalizes breaking automated enforcement boundaries.
*   **Routing:** Explicitly tag the new jobs `dev-ci` rather than relying on untagged fallthrough. Once `stocktrader` is fully migrated, make runner 7 `ref_protected` to close the MR root-equivalent loophole.

**3. Risks or Gotchas I'm Missing**
*   **Protected Variables in MRs:** MR pipelines run on unprotected refs. If your Kaniko build relies on protected CI/CD variables, the MR pipeline will fail because it cannot see them. Unprotect necessary variables or redesign the build to not need them pre-merge.
*   **Untagged Job Breakage:** Making runner 7 `ref_protected` or disabling `run_untagged` will break *any other project* relying on untagged jobs. Audit all repositories before restricting runner 7.
*   **Kaniko Caching on CE:** Kaniko's layer caching pushes/pulls cache layers to the registry. With GitLab CE and `$CI_JOB_TOKEN`, you may hit permissions issues if Kaniko writes cache layers outside the immediate project's container registry path.

#### DECISION 3 — Wire the dev-facing MCP network (`mcp-dev-net`)

**1. Is the proposed solution correct?**
No. Aside from being security theater within your accepted model, it is mathematically broken. A `/29` subnet has 8 IPs. Network, gateway (bridge), broadcast consume 3, leaving exactly **5 usable IPs**. You proposed 5 backends + 2 dev apps = **7 containers**. Docker will fail with IP pool exhaustion on the 6th container.

**2. Concrete Recommendation & Rationale**
*   **Verdict: ABANDON IT.**
*   **Rationale:** The settled `no-rootless.md` model acknowledges network boundaries on a single rootful daemon are not real security boundaries against a root-equivalent threat. Multi-homing 5 admin containers and editing 5 adjacent deploy scripts just to create an organizational alias of `mcp-net` is all cost and zero benefit. Delete `mcp-dev-net` and leave the dev apps on `mcp-net`.

**3. Risks or Gotchas I'm Missing**
*   **IP Exhaustion:** the `/29` subnet breaks deployments immediately.
*   **Multi-homing DNS Ambiguity:** a container on multiple user-defined bridge networks can have Docker's embedded DNS return IPs unpredictably by network order. `mcp-proxy-dev` might resolve a backend on `mcp-net` instead of `mcp-dev-net`, or route asymmetrically, causing hard-to-debug TCP timeouts.
