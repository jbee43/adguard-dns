# ADR-001: AdGuard Home over Pi-hole

**Date**: 2026-04-09
**Status**: Accepted

## Context

The DNS appliance runs on a Raspberry Pi Zero 2 W with 512 MB of RAM. Pi-hole
is the obvious default but its memory profile and multi-component layout are
awkward on a host this small.

## Decision

Use AdGuard Home.

## Rationale

| Criteria             | AdGuard Home                     | Pi-hole                             |
| -------------------- | -------------------------------- | ----------------------------------- |
| Memory usage         | 30 to 50 MB                      | 80 to 120 MB (FTL plus web)         |
| Config sync          | Native via AdGuardHome-sync      | Requires Gravity Sync (third party) |
| UI                   | Modern, responsive               | Functional but dated                |
| DNS-over-HTTPS / TLS | Built-in                         | Needs additional setup              |
| Custom rules         | Powerful, regex-based            | Regex available but less flexible   |
| Community size       | Growing                          | Larger, more mature                 |
| Single binary        | Yes (easy to deploy via Ansible) | Multiple components (FTL, web, CLI) |

### Key factor: RAM

On 512 MB every megabyte matters. AdGuard Home's lower footprint leaves
headroom for Unbound, optional Zabbix Agent, and zram swap activity during
filter reloads.

### Key factor: config sync

If a second appliance is ever added, AdGuardHome-sync makes keeping the two
identical straightforward. Pi-hole's equivalent is third-party.

## Consequences

- Smaller community means fewer troubleshooting resources than Pi-hole.
- Filter list ecosystem is slightly different, though the popular lists are
  compatible.
- No `pihole -t`-style real-time tail. The web UI shows live query logs.
