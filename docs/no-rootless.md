---
title: Why no rootless docker on this host
author: claude (administrator's session)
created: 2026-06-04
status: settled position
supersedes: rootless-wall-2026-06-03.md (problem framing)
grounded-in:
  - docs/reviews/rootless-wall-2026-06-03.md
  - docs/reviews/rootless-wall-2026-06-03.gemini.md
  - docs/reviews/rootless-wall-2026-06-03.codex.md
  - docs/reviews/rootless-wall-2026-06-03.claude.md
  - docs/reviews/rootless-wall-2026-06-03.final.md
  - docs/reviews/ib-gateway-running-session-breach.final.md
---

# Why we don't run rootless docker on this host

## TL;DR

We spent roughly two days attempting to migrate the live IB Gateway and live MCP
wrapper onto a rootless docker daemon under `administrator`'s uid. The goal was
to put the live trading containers on a daemon that the developer's autonomous
AI agent — running in a rootful container with `/var/run/docker.sock` mounted —
could not see.

We abandoned the effort. The reason is **not** "rootless is hard to get right
on Ubuntu 24.04 with kernel 6.17" — though that is also true. The reason is
that **rootless docker on the same host does not bind against the threat we
care about.** Host root owns the rootless daemon's socket, its namespaces, and
its container memory. The actor we were defending against (an autonomous agent
holding the rootful docker socket) *is* host root, transitively. A boundary
that the attacker can step over is not a boundary; it's a ritual.

This document captures the perspective so we don't re-litigate the question
when a future contributor asks "have we considered rootless?" The answer is
yes, comprehensively, and here is why the answer was no.

---

## What rootless docker actually does

Rootless docker runs `dockerd` inside a user namespace owned by an unprivileged
uid (here, `administrator`, uid 2000). Inside the user namespace, that uid
has the appearance of root: full `CapEff`, the ability to call `clone(CLONE_NEWNET)`,
create veth pairs, write iptables rules, etc. Outside the user namespace,
nothing it does maps to real root. The container processes run with subuids
in the host range `296608–362143`, not as actual root.

The boundary it provides is:
**a non-administrator on the host cannot read the rootless daemon's socket
or signal its containers.** That's a meaningful boundary in a multi-tenant
host where you want to give some users their own docker without giving them
the keys to everyone else's.

**That is not the boundary we needed.**

The boundary we needed was: *an actor with full control of the rootful
daemon cannot reach the live trading network.* Rootless does not provide
that boundary, because the rootful daemon belongs to root and root owns
everything, including administrator's rootless socket and administrator's
container processes.

This is the central confusion that made rootless seem promising. It defends
against *the wrong direction of attack*.

---

## The technical walls — what stopped us

We do owe a technical record, because the walls are real and the next person
to try this on this kernel will hit the same ones.

### Wall 1 — bridge driver: `Error response from daemon: operation not permitted`

`docker network create` from the rootless daemon failed at libnetwork's bridge
creation path. The dockerd journal showed `RTM_NEWLINK` and bridge MTU set
returning `EPERM`. With `bridge: none` in `daemon.json`, the daemon would
start, but no user-defined bridge networks could be created — which is most
real Docker workloads.

### Wall 2 — AppArmor profile check: `Could not check if docker-default AppArmor profile was loaded`

`docker run` failed before container start because dockerd tried to verify
the `docker-default` AppArmor profile by reading
`/sys/kernel/security/apparmor/profiles` and got `EACCES`. A *cleanly* rootless
daemon would not see securityfs at all and would skip the check; here
securityfs was partially visible (host `/sys/kernel/security` leaking into
the rootless mount namespace), so the "do I support AppArmor?" probe
returned true but the actual `read` failed.

### Wall 3 — IPv6 + bridge MTU set in the dockerd log:

```
unable to disable IPv6 router advertisement
    error="open /proc/sys/net/ipv6/conf/docker0/accept_ra: permission denied"
Failed to set bridge MTU docker0 via netlink
    error="operation not permitted"
```

Same root cause as Wall 1: capability-gated operations failing for the daemon
even though the rootless namespace nominally has `CapEff: 000001ffffffffff`.

### The misleading diagnostic

The thing that prolonged the investigation was that **manual `unshare -U -r -n`
and manual `rootlesskit --net=slirp4netns sh -c '…'` succeeded at exactly
the operations the daemon failed at.** `ip link add brtest type bridge` worked.
`ip6tables -t nat -N TEST` worked. Same uid, same userns mechanism, same
capability bits. We concluded the namespace was capable, ergo the daemon's
failure must be a config issue inside the daemon, and went hunting flags.

The conclusion was wrong. The namespace *was* capable; the daemon's failure
was not about the namespace. The discriminator was AppArmor capability
mediation, which is **orthogonal to kernel credentials**.

---

## The diagnosis — what was actually wrong

AppArmor mediates capabilities by profile, not by uid. A process confined by
a profile containing `audit deny capability` gets `EPERM` on every
`CAP_NET_ADMIN`-gated syscall regardless of `CapEff`. AppArmor profile
attachment happens by exec-time transition, not by uid. Our manual `unshare`
and `rootlesskit` tests ran from administrator's *unconfined login shell* and
inherited unconfined — so they had no capability mediation. The rootless
`dockerd` is launched via `dockerd-rootless.sh` and transitions through
profiles at exec; whatever profile it landed in had `deny capability`
behavior that cost it the bridge syscalls.

We modified `/etc/apparmor.d/unprivileged_userns` to `flags=(unconfined)` and
reloaded — but `apparmor_parser -r` does not retransition an already-running
process, and it's not clear the daemon was even transitioning *into* the
`unprivileged_userns` profile (it may have been landing in `docker-default`
or a `rootlesskit`/`dockerd` profile under a different name). We also set
`kernel.apparmor_restrict_unprivileged_userns=0` — but that sysctl gates
userns *creation*, not capability mediation *inside* an already-created
userns. We fixed the AppArmor mechanism that wasn't the wall.

The single command that would have ended the investigation on day one,
which we never ran:

```bash
sudo dmesg -T | grep -iE 'apparmor.*denied'
```

That would have printed the exact `operation=` / `capname=` / `profile=`
triple that was being denied and named the profile to address. We instead
chased credential-path verification, which proved that capabilities were
present (true) and not that the daemon was unconfined (the actual question).

Two additional aggravating factors:

1. **Kernel 6.17 on Noble.** This host runs the HWE/mainline 6.17 kernel
   under Ubuntu 24.04 userland. Docker's Noble rootless AppArmor handling
   was written against the 6.8 GA kernel. Profile-name matching and `userns`
   semantics may have drifted. Not a single bug — a structural mismatch.

2. **Detach-netns default.** Docker 29.1.3 defaults
   `DOCKERD_ROOTLESS_ROOTLESSKIT_DETACH_NETNS=1` (on). In detached mode the
   slirp4netns netns is split from dockerd's, and the default-bridge sysctl
   work can hit a netns/procfs ownership mismatch that yields `EPERM` on
   `docker0` specifically. Our manual `rootlesskit … sh -c` test ran
   single-netns, which is *another* reason it succeeded where the daemon
   failed.

Could we have made it work in 1–2 more steps if we'd run the dmesg
discriminator? Probably. But making it work would not have achieved the
goal, which brings us to the central point.

---

## The central problem: the boundary did not bind

The goal of the migration was, verbatim from the brief:

> the agent "cannot reach the live network *even with full docker daemon
> control*."

"Full docker daemon control" of the rootful daemon = host root, transitively.
A container with `/var/run/docker.sock` mounted can:

```bash
docker run --privileged -v /:/host -it alpine chroot /host
```

…and now it is root on the host, period. Once it is root on the host, the
rootless daemon under administrator is not a boundary:

- `/run/user/2000/docker.sock` is just a Unix socket; root reads it.
- `/proc/<pid of administrator's container>/ns/net` is a netns link; root
  enters it with `nsenter -t <pid> -n`.
- `/proc/<pid>/environ` of the same container leaks the env vars, including
  `TWS_PASSWORD`, to root.
- The qcow2 backing a hypothetical local VM (the "Option B" recommendation
  from two of three reviewers) is just a file root reads. The qemu process
  is `ptrace`-able by root. The libvirt API is local to root.

In all of those, "host root owns it" is the load-bearing fact. Rootless
docker, like a local VM, isolates against *unprivileged users* — not against
host root.

So the migration we were attempting had this structure:

| State | Agent reach to live |
|---|---|
| Today (rootful, agent holds socket) | Open: `docker run --network mcp-ib-live-net …` |
| After perfect rootless migration (agent still holds socket) | **Still open: agent → host root → administrator's rootless socket → live netns** |
| After removing agent's socket (Phase A, no rootless) | Closed: agent has no path to host root, and live is on a network the agent can't join |
| After Phase A *plus* rootless | Closed: but rootless isn't doing the work — Phase A is |

The "rootless" column is empty of value. In the only configuration where it
appears to add isolation, Phase A has already done the work. In the only
configuration where Phase A isn't done, rootless doesn't bind. There is no
threat-model row where rootless is the load-bearing control.

That is the perspective. The reason we don't run rootless on this host is
not "it walled." It is "it doesn't matter whether it walls."

---

## The collateral damage we did inflict

This is the part that matters going forward, because two of the changes
were **host-wide regressions** in service of a per-service boundary that
wouldn't have bound anyway.

1. `kernel.apparmor_restrict_unprivileged_userns = 0` persisted in
   `/etc/sysctl.d/99-rootless-docker.conf`. This sysctl gates *all*
   unprivileged user-namespace creation on the host. Setting it to 0
   widens the unprivileged userns attack surface for **every container
   and every process on the host**, including the agent we were defending
   against. Reverted on 2026-06-04. Stays reverted.

2. `/etc/apparmor.d/unprivileged_userns` was rewritten with
   `flags=(unconfined)` and the original moved to
   `unprivileged_userns.bak`. Same scope: host-wide unprivileged-userns
   profile, applied to every transitioning process, not just dockerd.
   Restored from `.bak` on 2026-06-04 and reloaded. Stays restored.

3. `websurfinmurf` and `joe` were removed from the `docker` group on the
   theory that the migration would relocate dev workflows to rootless.
   This broke developer ability to do hands-on container work for a
   period. Reverted on 2026-06-04 via `gpasswd -a`. The "developer in
   docker group" model is intentional and correct on this host — the
   load-bearing fix is the agent runtime container's removed socket
   mount, not the human's group membership.

We pursued a boundary at the cost of (1) and (2) — globally weakening the
host's AppArmor posture. The net security delta was negative until those
were reverted. That's the cost of debugging the wrong layer, and it's the
single most important entry in the "don't do this again" column.

---

## What we did instead

The synthesis the review board produced (and that we executed) is
documented in `rootless-wall-2026-06-03.final.md`. In one paragraph:

We removed `/var/run/docker.sock` mounts (and `group_add: ["127"]`) from
the autonomous agent's runtime containers (`agents-cli-claude-websurfinmurf`
and `webui-claude-websurfinmurf`). We recreated the live IB Gateway stack
so it joins only `mcp-ib-live-net` and publishes no host ports. We
reverted the AppArmor regressions. We restored developer docker group
membership. We left IBKR-side controls on `U15907310` (trusted-IP
allowlist, sub-account caps, daily order count cap) as the user's
portal task — those survive even a fully-owned host and are the
load-bearing control that any infra fix is downstream of.

Validation matrix T1–T6 confirms the agent can no longer reach the live
network. The breach is closed. Rootless was not used. The host runs the
single rootful daemon it has always run.

---

## When rootless IS the right tool (so we don't reflexively reject it next time)

This perspective is "no rootless **on this host, for this threat model**." It
is not "rootless is bad." Cases where it is the right call:

- **Multi-tenant developer hosts** where you want to grant docker access to
  multiple users without making them effectively root on a shared box. The
  CIS Docker Benchmark cites this as the canonical use case.
- **CI runners** where you want each tenant's daemon and images
  jailed under the tenant's uid for blast-radius reasons.
- **Workstations** where a developer wants to run containers without joining
  the docker group (which is root-equivalent on the host).
- **Single-purpose VMs/hosts** where the rootless daemon is *the* docker
  daemon — no rootful daemon also exists for an attacker to pivot through.

None of those describe this host. This host is a single-administrator box
with one docker daemon serving 60+ containers and an autonomous AI agent
that was specifically the threat being modeled. The pivot path through
the rootful daemon's socket dominates the analysis. Rootless does not
neutralize that pivot.

If a future system designer is starting from scratch and asks "should
the live trading workload be on its own daemon?", the right answer may be
"yes, on its own *host*" — not "yes, rootless on the same host." Same
boundary intent, real boundary.

---

## The decision

Stated plainly, for the record:

> **We do not run rootless docker on this host. The rootless daemon under
> administrator's uid has been stopped, disabled, and its configuration
> removed. The AppArmor and sysctl changes made to support it have been
> reverted. The live IB Gateway and live MCP wrapper run on the host's
> single rootful daemon, on an isolated network, with the autonomous agent's
> path to the rootful daemon's socket cut. IBKR-side controls on `U15907310`
> remain the load-bearing blast-radius bound.**

The conditions that would change this decision, in order of plausibility:

1. **A second autonomous-agent host appears.** If we run more than one
   agent identity on more than one host, "rootless per agent" becomes a
   real defense against agent-to-agent pivot. Not the case today.
2. **Live trading moves to a dedicated machine.** That machine's daemon
   could be rootful, rootless, podman, or anything — the boundary is the
   network/identity boundary at the host level, not the daemon mode. This
   is the architecturally correct next step for true host-root-survivable
   isolation, and is tracked as "Step 6 — defer" in the final synthesis.
3. **The threat model changes to include unprivileged users on this box.**
   If we ever add untrusted shell users, rootless becomes the right
   answer for *their* workloads — not for live. Live still belongs on a
   separate machine.

Until one of those happens, the answer to "should we try rootless again?"
is no, and the citation for why is this document plus the four review-board
documents it grounds in.

---

## What this document is not

It is not a rejection of the reviewers. Gemini and Codex both recommended a
local VM as a "hardware-enforced boundary." That recommendation was made in
good faith, and it is the right recommendation *if the agent's host-root
path is already closed*. We closed that path. The local VM is now defensible
defense-in-depth, not a load-bearing control — and we judged the operational
cost not worth the marginal gain over the work that was already done. If we
revisit, it should be a separate host, not a local VM, for the same reasons
"local VM does not bind against host root" rules out rootless.

It is also not an apology for the time spent. The investigation produced four
durable artifacts (the seed brief, three independent reviews, and the
synthesis), exposed a real misalignment between control and threat, and
ended in a clean reversal of the regressions. The cost was real; the
learning paid for it; the documentation persists. The next time someone
on this host proposes "let's just go rootless," they get to read this
instead of running the experiment again.
