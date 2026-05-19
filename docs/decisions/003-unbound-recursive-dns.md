# ADR-003: Unbound as Recursive DNS Resolver

**Date**: 2026-04-23
**Status**: Accepted

## Context

AdGuard Home was forwarding queries to external resolvers via DNS-over-HTTPS
(Cloudflare and Google). That encrypts the transport but still hands every
domain you resolve to a third party.

## Decision

Add Unbound as a local recursive resolver on the appliance, sitting between
AdGuard Home and the root DNS servers. AdGuard Home forwards to
`127.0.0.1:5335` (Unbound) instead of an external resolver.

## Architecture

```text
Client query
  -> AdGuard Home (0.0.0.0:53)
       blocklist filtering
       caching (4 MB)
       forwards to:
  -> Unbound (127.0.0.1:5335)
       DNSSEC validation
       qname minimisation
       recursive resolution from root servers
       local cache (4 MB msg, 8 MB rrset)
  -> Root, TLD, authoritative DNS servers
```

Each appliance runs its own independent Unbound and AdGuard stack. No
cross-node dependency.

## Rationale

### Privacy

- No third-party resolver sees all queries. Queries go directly to the
  authoritative servers.
- qname minimisation (RFC 7816). Each server in the chain only sees the
  minimum needed to route the query.
- No single point of data collection. Queries are distributed across many
  authoritative servers.

### Security

- DNSSEC validation at the Unbound layer (AdGuard delegates to Unbound).
- DNS rebinding protection via `private-address` directives.
- 0x20 randomisation (`use-caps-for-id`) for query forgery resistance.
- Identity hiding. Unbound does not reveal its version or hostname.

### Performance

- Two-layer cache. Unbound cache (warm) sits behind AdGuard cache (hot),
  reducing repeated root walks.
- Prefetching. Unbound proactively refreshes popular entries before TTL
  expiry.
- Serve-expired. Stale answers are served immediately while a refresh runs
  in the background.

### RAM budget (512 MB Pi Zero 2 W)

| Component      | Estimate          |
| -------------- | ----------------- |
| RPi OS base    | 80 to 100 MB      |
| Unbound        | 20 to 30 MB       |
| AdGuard Home   | 30 to 50 MB       |
| Zabbix Agent 2 | 20 to 30 MB       |
| **Total**      | **150 to 210 MB** |
| **Remaining**  | **300 to 360 MB** |

Unbound adds 20 to 30 MB. Acceptable given the privacy and security
benefits.

## Alternatives considered

### Keep DoH forwarding (Cloudflare or Google)

Rejected:

- Trusts a third party with all DNS data.
- Cloudflare or Google can correlate queries with source IPs.
- Transport encryption is not the same as privacy.

### DNSCrypt-proxy

Rejected:

- Still forwards to third-party resolvers (same privacy issue).
- Additional binary to maintain.
- Unbound is in Debian repos, well established, lower maintenance.

### Stubby (DNS-over-TLS forwarder)

Rejected:

- Same issue as DoH. Encrypts transport but still forwards to a third party.
- Unbound does recursive resolution and removes the third party entirely.

## Consequences

- Cold cache is slower. The first query for a domain requires walking the
  root, TLD, and authoritative servers (typically 50 to 150 ms versus 10 to
  30 ms for DoH to Cloudflare). Cache warms quickly for frequently accessed
  domains.
- Root server dependency. If root DNS is unreachable, resolution fails.
  Mitigated by `serve-expired`, which serves stale cache entries while
  retrying.
- A bit more RAM, around 20 to 30 MB per node. Acceptable on 512 MB.
- DNSSEC failures are strict. Domains with broken DNSSEC will fail to
  resolve. This is correct behaviour but may surface issues with
  misconfigured domains.
- No encrypted transport to the authoritative servers. Queries to root, TLD,
  and authoritative are plain DNS. This is inherent to recursive resolution
  and is no worse than the authoritative leg of any forwarded query.

## Amendments

### 2026-05-02, zram swap re-enabled on Pi Zero

The original RAM budget assumed steady-state usage. In practice AdGuard
Home reloads around 485 k blocklist rules during the early-morning filter
refresh, briefly pushing memory usage past the available headroom on the
512 MB host. With disk swap disabled (cloud-init plus `common` role) the
kernel could not absorb the spike. The result was user-space stalls (sshd
unresponsive while ICMP still answered) without any OOM kill.

Decision: enable a small `zram` swap (compressed in-RAM swap) on all
`pi_zero` group hosts via the `common` role. Configuration: `ALGO=zstd`,
`PERCENT=50` (about 256 MB device on a 512 MB host), `PRIORITY=100`.

Why zram, not disk swap. Zram pages compress at roughly 3 to 1 with zstd
and never touch the SD card. That preserves the original SD-endurance
argument for disabling disk swap while still giving the kernel headroom
during transient peaks. Resident cost is bounded by what is actually
swapped, typically tens of MB.

Trade-off: a small CPU cost during compression and decompression. On
quad-core Pi Zero 2 W this is invisible next to the cost of an SSH stall.

Companion changes (same maintenance pass): `apt-daily.timer` and
`apt-daily-upgrade.timer` pinned to 05:00 and 06:00 (away from AdGuard's
04:00 reload); AdGuard query log retention reduced from 72 h to 24 h;
persistent journald with a 200 M cap to keep evidence across rotations;
IGMP allowed in UFW `before.rules` to silence multicast log noise from the
ISP router.

### 2026-05-03, static trust anchor and service-resilience hardening

The day after the zram amendment the appliance flapped again with a
different signature: unbound exit-looped on every start with
`error: trust anchor presented twice`, hit systemd's `StartLimitBurst` (5
fails in 10 s), and latched off. Browser clients saw
`DNS_PROBE_FINISHED_BAD_CONFIG`. `unbound-checkconf` reproduced the error
independently of systemd, confirming content corruption rather than a
runtime issue.

Root cause: `/var/lib/unbound/root.key` (the `auto-trust-anchor-file`) had
a duplicated `.` anchor on line 2, with mtime exactly at the RFC 5011
probe time. Unbound's autotrust write is in-place. If the process is
SIGKILL'd mid-write (likely during the AdGuard 04:00 reload pressure
window) the file is left truncated or duplicated. The previous amendment's
zram added headroom but did not eliminate kernel OOM kills outright on a
512 MB host, so the autotrust file remains a corruption hazard.

Decision: switch from `auto-trust-anchor-file: "/var/lib/unbound/root.key"`
to `trust-anchor-file: "/usr/share/dns/root.key"`. That is the static,
package-managed anchor shipped by Debian's `dns-root-data`, already a hard
dependency of `unbound`. The static file is read-only at runtime, nothing
writes to it, so SIGKILL cannot corrupt it. Trade-off: in-process RFC 5011
auto-rollover is lost, but Debian ships KSK rollover updates via
`dns-root-data` package upgrades, and the next root KSK rollover is years
out. For a Pi Zero where corruption recurrence is the demonstrated risk,
eliminating the in-place write is worth more than in-process rollover.

Companion changes (same pass, all in `roles/unbound/`):

- systemd resilience drop-in
  (`/etc/systemd/system/unbound.service.d/resilience.conf`):
  `Restart=always`, `RestartSec=10s`, `StartLimitIntervalSec=10min`,
  `StartLimitBurst=10`, `OOMScoreAdjust=-100`. Stops the cascade of
  fast-fails from latching the unit off, and biases the OOM killer toward
  AdGuard (default score 0) over unbound when memory pressure forces a
  kill.
- time-sync wait drop-in (`wait-time.conf`): `After=time-sync.target` and
  `Wants=time-sync.target`, plus `systemd-timesyncd-wait-sync.service`
  enabled. Triage showed timesyncd took 9 minutes to converge after boot;
  without the wait, DNSSEC validation against freshly-signed RRsets can
  fail at boot on a WiFi-only Pi.
- `unbound-anchor` package added to the role's apt list. It was missing,
  and is a separate Debian package from `unbound`. Useful for bootstrap
  and manual recovery scenarios.
- Legacy `/var/lib/unbound/root.key` removed by Ansible so it cannot
  quietly come back into play.

Deferred, noted for follow-up: the kernel cmdline on this host contains
`cgroup_disable=memory`, which makes systemd `MemoryHigh=` and
`MemoryMax=` no-ops. Capping AdGuard's filter-reload spike via cgroups
would need `cgroup_enable=memory cgroup_memory=1` in
`/boot/firmware/cmdline.txt` and a reboot, costing about 1 % RAM (around
5 MB on 512 MB). Not pursued today because the trust-anchor fix removes
the immediate corruption vector. Revisit only if OOM kills recur.
