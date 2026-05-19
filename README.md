# adguard-dns

[![GitHub CI](https://github.com/jbee43/adguard-dns/actions/workflows/ci.yml/badge.svg)](https://github.com/jbee43/adguard-dns/actions/workflows/ci.yml)

Self-hosted ad-blocking and recursive DNS for your home network.
[AdGuard Home](https://adguard.com/en/adguard-home/overview.html) with
[Unbound](https://nlnetlabs.nl/projects/unbound/about/), on a
[Raspberry Pi Zero 2 W](https://www.raspberrypi.com/products/raspberry-pi-zero-2-w/)
or any Debian/Ubuntu host, provisioned end-to-end with
[cloud-init](https://cloud-init.io/) and [Ansible](https://www.ansible.com/).

## TLDR

- Inputs: a Pi Zero 2 W, an SD card, your WiFi credentials, about 10 minutes.
- Output: a DNS server on your LAN that blocks ads and trackers for every
  device, resolves recursively (no third-party forwarder), and answers with
  median response around 16 ms.
- Workflow: flash-image.ps1 (or flash-sd.sh), first boot, make dns, point your
  router at it.
- Status: working in production. Template repo. Fork it, edit a handful of
  .example files, ship.

## Why

This repo is declarative. The same Ansible run produces the same state every
time, secrets stay encrypted in git, dependencies are version-pinned, and the
pipeline (lint, link-check, security scan) runs in CI. Once it works on your
network you can rebuild the SD card from scratch in about 15 minutes with no
manual steps.

The recursive resolver (Unbound) means no single third party sees all your DNS
traffic. Queries go directly to the root, TLD, and authoritative servers.
[DNSSEC](https://www.dnssec.net/) is validated end-to-end with a static,
package-managed trust anchor.
See [ADR-003](docs/decisions/003-unbound-recursive-dns.md).

## Quick start

The full walkthrough is in [docs/provisioning.md](docs/provisioning.md). It
covers hardware, RAM budget, the templates to copy, day-2 operations,
troubleshooting, and the verification checklist. Skim that first.

Short version, Windows host:

```powershell
$wifiPwd = Read-Host -AsSecureString "WiFi password"
.\scripts\flash-image.ps1 `
  -NodeType pi-zero-dns -Hostname dns-1 `
  -WiFiSSID "YourSSID" -WiFiPassword $wifiPwd -WiFiCountryCode "US"
# Boot the Pi, wait about 3 minutes, then in the devcontainer:
make dns
# Point your router's primary DNS at the appliance, secondary at 1.1.1.1.
```

Linux/macOS host: flash with [Raspberry Pi Imager](https://www.raspberrypi.com/software/),
then `./scripts/flash-sd.sh pi-zero-dns /media/$USER/bootfs --hostname dns-1`.

## At a glance

| Layer          | Tool                                                                                                                       |
| -------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Image flashing | [rpi-imager](https://www.raspberrypi.com/software/) --cli, driven by [scripts/](scripts/)                                  |
| First boot     | cloud-init or RPi OS firstrun ([cloud-init/](cloud-init/))                                                                 |
| Configuration  | Ansible, idempotent ([ansible/](ansible/))                                                                                 |
| Secrets        | [SOPS](https://github.com/getsops/sops) with [age](https://age-encryption.org/) ([.sops.yaml.example](.sops.yaml.example)) |
| Dev env        | [Devcontainer](https://containers.dev/), pinned tools, [Renovate](https://docs.renovatebot.com/)-managed                   |

Supported hosts: any Debian 12+ or Ubuntu 24.04+. Pi Zero 2 W is the default
profile. Pi 4/5, x86 mini PCs, and small VMs all work. See
[provisioning.md](docs/provisioning.md#hardware) for the RAM budget and details.

## Limitations

Single-node, no built-in HA. Pair with a router-level secondary DNS so a
failure does not kill name resolution. Pi Zero 2 W is WiFi-only on 2.4 GHz and
sensitive to interference. DoH and DoT to clients are off by default, easy to
enable. Full list and mitigations in
[provisioning.md](docs/provisioning.md#troubleshooting).

## Architecture decisions

- [ADR-001, AdGuard Home over Pi-hole](docs/decisions/001-adguard-over-pihole.md)
- [ADR-002, Devcontainer for developer tooling](docs/decisions/002-devcontainer-tooling.md)
- [ADR-003, Unbound as recursive DNS, with a static DNSSEC anchor](docs/decisions/003-unbound-recursive-dns.md)
