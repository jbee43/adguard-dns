# Provisioning the DNS Appliance

## TLDR

A single Raspberry Pi Zero 2 W (or comparable Debian/Ubuntu node) provides
network-wide ad-blocking DNS with recursive resolution. AdGuard Home filters
queries on port 53 (web UI on 8089), Unbound resolves recursively from the
DNS root servers (loopback port 5335), no third-party forwarder. Optional
Zabbix Agent 2 for monitoring.

Fully automated: flash SD card, first boot, run Ansible, point your router
at the appliance.

## Architecture

```text
Home network clients
        |
        v
Router (DHCP pushes the appliance as primary DNS)
        |
        v
DNS appliance
        |
        v
AdGuard Home (0.0.0.0:53)
   - blocklist filtering (6 lists by default)
   - cache (4 MB, optimistic)
   - forwards to Unbound (127.0.0.1:5335)
        |
        v
Unbound
   - DNSSEC validation (static anchor from the dns-root-data package)
   - qname minimisation (RFC 7816)
   - 0x20 randomisation
   - cache (4 MB msg, 8 MB rrset)
   - recursive resolution from root, TLD, authoritative DNS
```

This is a single-node appliance. There is no built-in HA. Pair it with a
secondary DNS at the router (for example 1.1.1.1) so clients do not lose
the internet if the appliance goes offline.

### Why Unbound?

Queries go directly to authoritative DNS servers (root, then TLD, then
authoritative). No single third-party resolver (Cloudflare, Google) sees
all your DNS traffic.

### Why AdGuard Home and not Pi-hole?

Lower memory footprint (around 30 to 50 MB, versus around 80 to 120 MB for
Pi-hole), single static binary, built-in DoH and DoT support. Critical on
a 512 MB Pi Zero. See [ADR-001](decisions/001-adguard-over-pihole.md).

## Hardware

The default node profile targets a Pi Zero 2 W:

| Component | Spec                                                              |
| --------- | ----------------------------------------------------------------- |
| Board     | Raspberry Pi Zero 2 W (BCM2710A1, 1 GHz quad-core ARM Cortex-A53) |
| RAM       | 512 MB                                                            |
| Storage   | SD card (class 10 or better, 8 GB minimum)                        |
| Network   | WiFi 802.11 b/g/n 2.4 GHz (on-board, no Ethernet)                 |
| Power     | Micro-USB, 5V/1A                                                  |

You can run this on any Debian or Ubuntu host (a small VM, a Pi 4 or 5, an
x86 mini PC). For non-Pi-Zero hosts, skip the flash step and apply Ansible
to your existing node. Set `ansible_host` in `ansible/inventory/dns.yml`
and run the playbook.

### RAM budget (Pi Zero 2 W)

| Component                 | Estimate          |
| ------------------------- | ----------------- |
| RPi OS Lite base          | 80 to 100 MB      |
| Unbound                   | 20 to 30 MB       |
| AdGuard Home              | 30 to 50 MB       |
| Zabbix Agent 2 (optional) | 20 to 30 MB       |
| **Total**                 | **150 to 210 MB** |
| **Free**                  | **300 to 360 MB** |

## Software stack

### Ansible roles (execution order)

| Role           | What it does                                                                                                |
| -------------- | ----------------------------------------------------------------------------------------------------------- |
| `common`       | Timezone, NTP, apt update, base packages, unattended-upgrades, persistent journald, zram swap on `pi_zero`  |
| `hardening`    | SSH hardening (no password auth, no root login), UFW (deny incoming, allow SSH:22)                          |
| `unbound`      | Install Unbound and dns-root-data, deploy recursive config, DNSSEC anchor, verify resolution                |
| `adguard`      | Download AdGuard Home ARM64 binary, install systemd service, deploy config (upstream Unbound), UFW rules    |
| `zabbix_agent` | Optional. Install zabbix-agent2, deploy config, UFW (passive checks: 10050). Gated by `enable_zabbix_agent` |

### Unbound configuration

| Setting            | Value                                        | Why                                                                  |
| ------------------ | -------------------------------------------- | -------------------------------------------------------------------- |
| Interface          | `127.0.0.1:5335`                             | Loopback only, not exposed to the network                            |
| DNSSEC             | `trust-anchor-file: /usr/share/dns/root.key` | Static, package-managed via `dns-root-data`. Read-only               |
| qname minimisation | Enabled                                      | Each DNS server in the chain only sees the minimum needed (RFC 7816) |
| 0x20 randomisation | `use-caps-for-id: yes`                       | Query forgery resistance                                             |
| Cache              | 4 MB msg, 8 MB rrset                         | Tuned for 512 MB RAM                                                 |
| Prefetch           | Enabled                                      | Refreshes popular entries before TTL expiry                          |
| Serve expired      | Enabled (TTL 86400 s)                        | Serves stale cache while refreshing in background                    |
| DNS rebinding      | `private-address` blocks                     | Strips RFC 1918 addresses from external responses                    |

Template: [`ansible/roles/unbound/templates/unbound.conf.j2`](../ansible/roles/unbound/templates/unbound.conf.j2)

### AdGuard Home configuration

| Setting       | Value                              |
| ------------- | ---------------------------------- |
| DNS listen    | `0.0.0.0:53`                       |
| Web UI        | `0.0.0.0:8089`                     |
| Upstream DNS  | `127.0.0.1:5335` (Unbound)         |
| Bootstrap DNS | `127.0.0.1:5335` (Unbound)         |
| DNSSEC        | Disabled (delegated to Unbound)    |
| Cache         | 4 MB, optimistic                   |
| Auth          | 5 attempts, 15 min lockout         |
| Session TTL   | 720 h (30 days)                    |
| Query log     | 24 h retention, 1000 in memory     |
| Statistics    | 168 h (7 days)                     |
| DHCP          | Disabled                           |
| TLS, DoH, DoT | Disabled (Unbound handles privacy) |

Template: [`ansible/roles/adguard/templates/AdGuardHome.yaml.j2`](../ansible/roles/adguard/templates/AdGuardHome.yaml.j2)

### Default blocklists

| #   | Name                                     | Source                                                                                                              |
| --- | ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| 1   | AdGuard DNS filter                       | [adguardteam/HostlistsRegistry](https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt)                |
| 2   | AdAway Default Blocklist                 | [adguardteam/HostlistsRegistry](https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt)                |
| 3   | Hagezi Multi PRO                         | [hagezi/dns-blocklists](https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt)               |
| 4   | Peter Lowe's Ad and tracking server list | [pgl.yoyo.org](https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&showintro=1&mimetype=plaintext) |
| 5   | OISD Small                               | [oisd.nl](https://small.oisd.nl/)                                                                                   |
| 6   | Phishing URL Blocklist                   | [malware-filter](https://malware-filter.gitlab.io/malware-filter/phishing-filter-ag.txt)                            |

Edit `adguard_filters` in
[`ansible/roles/adguard/defaults/main.yml`](../ansible/roles/adguard/defaults/main.yml)
to add or remove lists, then re-run Ansible.

### UFW firewall rules (cumulative)

| Port  | Protocol | Service                                             |
| ----- | -------- | --------------------------------------------------- |
| 22    | TCP      | SSH (hardening role)                                |
| 53    | TCP, UDP | DNS (adguard role)                                  |
| 8089  | TCP      | AdGuard Home web UI (adguard role)                  |
| 10050 | TCP      | Zabbix Agent 2, only if `enable_zabbix_agent: true` |

Default policy: deny incoming, allow outgoing.

## Provisioning step by step

### Phase 0: prerequisites

These are one-time setup steps.

1. SSH key. Generate one if you do not have it:
   `ssh-keygen -t ed25519 -C "your-email@example.com"`. The flash scripts
   read `~/.ssh/id_ed25519.pub` (or `id_rsa.pub`) by default.
2. Raspberry Pi Imager. Only required if you will use the full
   `flash-image.ps1` pipeline on Windows:
   `winget install RaspberryPiFoundation.RaspberryPiImager`.
3. Devcontainer. Open the repo in VS Code, then "Reopen in Container". All
   Ansible, SOPS, and lint tooling is preinstalled.
4. SOPS age key. Needed for the encrypted Ansible vault:

   ```powershell
   # Host (PowerShell 7)
   New-Item -ItemType Directory -Force "$env:USERPROFILE\.config\sops\age"
   age-keygen -o "$env:USERPROFILE\.config\sops\age\keys.txt"
   ```

   Copy the public key (starts with `age1...`) and paste it into
   `.sops.yaml` (you copied this from `.sops.yaml.example` and removed the
   `.example` suffix). Back up `keys.txt` somewhere safe. If you lose it,
   you cannot decrypt anything encrypted with that key.

5. Ansible vault. Generate the AdGuard admin password hash and encrypt:

   ```bash
   # Devcontainer
   cp ansible/vault/secrets.sops.yml.example ansible/vault/secrets.sops.yml
   # Edit secrets.sops.yml and paste a fresh password hash:
   htpasswd -nbBC 10 "" "YourPasswordHere" | cut -d: -f2
   sops --encrypt --in-place ansible/vault/secrets.sops.yml
   ```

### Phase 1: flash SD card

```powershell
# Host (PowerShell 7, Admin)
$wifiPwd = Read-Host -AsSecureString "WiFi password"

.\scripts\flash-image.ps1 `
  -NodeType pi-zero-dns `
  -Hostname dns-1 `
  -WiFiSSID "YourSSID" `
  -WiFiPassword $wifiPwd `
  -WiFiCountryCode "US"
```

This runs a four-phase pipeline:

1. Download. RPi OS Lite Bookworm ARM64 image, SHA256-verified, cached.
2. Prepare. Substitutes `__HOSTNAME__`, `__ADMIN_USER__`, `__TIMEZONE__`,
   `__SSH_PUBLIC_KEY__` into the cloud-init template.
3. Flash. `rpi-imager --cli` writes the image (with double-confirmation).
4. Inject. Writes `firstrun.sh` and patches `cmdline.txt` so the first
   boot sets up WiFi, the user, and SSH.

> WiFi credentials live on the SD card only. Never in git.

On Linux or macOS, flash with Raspberry Pi Imager or `dd`, mount the boot
partition, then:

```bash
./scripts/flash-sd.sh pi-zero-dns /media/$USER/bootfs --hostname dns-1
```

### Phase 2: DHCP reservation

Before first boot, reserve a static IP on your router for the appliance's
WiFi MAC (printed on the board label, or visible after the first DHCP
lease). This matters because clients will be configured to point at this
IP for DNS.

### Phase 3: first boot

Insert the SD card, power on the Pi, wait two to three minutes for
first-run setup to finish and the device to reboot.

```bash
ping <appliance-ip>
ssh admin@<appliance-ip>     # adjust user if you used --username
```

On the Pi, smoke-test:

```bash
# First-run completed?
cat /boot/firmware/firstrun.log | tail -20

# Hostname?
hostname

# WiFi connected?
iwconfig wlan0 2>/dev/null | grep ESSID
```

### Phase 4: Ansible provisioning

```bash
# Devcontainer
cp ansible/inventory/dns.yml.example ansible/inventory/dns.yml
cp ansible/inventory/group_vars/all/vars.yml.example ansible/inventory/group_vars/all/vars.yml
cp ansible/inventory/group_vars/dns_servers.yml.example ansible/inventory/group_vars/dns_servers.yml
# Edit each with your IP, hostname, timezone, etc.

make dns
```

Or directly:

```bash
ansible-playbook -i ansible/inventory/dns.yml ansible/playbooks/dns.yml
```

The playbook is idempotent. Re-run it whenever you change config (new
blocklist, new DNS rewrite, version bump).

#### What Ansible does (in order)

1. `common`. Sets timezone and NTP, updates apt cache, installs base
   packages, enables unattended-upgrades, persistent journald (200 M cap),
   zram swap on `pi_zero` hosts (zstd, 50% of RAM).
2. `hardening`. Disables SSH password auth and root login, sets
   `ClientAliveInterval 30`, `ClientAliveCountMax 3`,
   `MaxStartups 10:30:60`, installs UFW with default deny incoming and
   allow outgoing, allows SSH on 22.
3. `unbound`. Installs `unbound` and `dns-root-data`, deploys the
   recursive resolver config to
   `/etc/unbound/unbound.conf.d/pi-recursive.conf`, verifies resolution
   with `dig`.
4. `adguard`. Creates `/opt/AdGuardHome/`, downloads the ARM64 binary,
   installs it as a systemd service, deploys `AdGuardHome.yaml` (upstream
   Unbound, blocklists, web UI on 8089), opens UFW ports.
5. `zabbix_agent`. Skipped unless `enable_zabbix_agent: true`. Adds the
   official Zabbix apt repo, installs zabbix-agent2, deploys config,
   opens UFW port 10050.

### Phase 5: verify

```bash
# Devcontainer (or any DNS-aware host)
APPLIANCE=<appliance-ip>

# Pi resolves DNS through AdGuard
dig @$APPLIANCE example.com A +short

# Ads are blocked
dig @$APPLIANCE ads.google.com A +short
# Expected: 0.0.0.0 or empty

# Confirm upstream is Unbound (loopback)
ssh admin@$APPLIANCE 'grep upstream_dns /opt/AdGuardHome/AdGuardHome.yaml'
# Expected: - 127.0.0.1:5335

# Unbound is loopback-only (network access correctly refused)
dig @$APPLIANCE -p 5335 example.com +short +time=2
# Expected: connection timed out

# DNSSEC validation
ssh admin@$APPLIANCE 'dig @127.0.0.1 -p 5335 sigfail.verteiltesysteme.net +time=5'
# Expected: SERVFAIL
ssh admin@$APPLIANCE 'dig @127.0.0.1 -p 5335 sigok.verteiltesysteme.net +time=5'
# Expected: NOERROR with the ad flag
```

Open `http://<appliance-ip>:8089` in a browser, log in with the admin
credentials you set, and confirm the dashboard shows queries arriving.

### Phase 6: make it the network DNS

On your router's DHCP settings:

- Primary DNS: `<appliance-ip>` (this appliance, ad-blocking).
- Secondary DNS: `1.1.1.1` (Cloudflare, unfiltered fallback).

The secondary maintains DNS availability if the appliance goes down.
Trade-off: when the appliance is down, clients lose ad-blocking. Remove
the secondary if you would rather fail closed.

Existing devices need to renew their DHCP lease (or restart networking)
to pick up the new DNS servers.

## Day-2 operations

### Re-running Ansible

All roles are idempotent.

```bash
make dns
```

### Upgrading AdGuard Home

Edit `adguard_version` in
[`ansible/roles/adguard/defaults/main.yml`](../ansible/roles/adguard/defaults/main.yml),
re-run Ansible. The role detects the version mismatch, stops the service,
downloads the new binary, restarts.

### Adding or removing blocklists

Edit `adguard_filters` in the same defaults file, re-run Ansible. Or edit
in the AdGuard Home web UI. Note that UI-only changes will be overwritten
on the next Ansible run.

### Logs

```bash
sudo journalctl -u unbound       --since "1 hour ago" --no-pager
sudo journalctl -u AdGuardHome   --since "1 hour ago" --no-pager
sudo journalctl -u zabbix-agent2 --since "1 hour ago" --no-pager
```

### RAM usage on Pi Zero

```bash
free -h
ps -eo rss,comm --sort=-rss | head -10
zramctl
```

If RAM usage climbs above around 400 MB, reduce Unbound cache sizes in
[`ansible/roles/unbound/defaults/main.yml`](../ansible/roles/unbound/defaults/main.yml)
or drop a blocklist (Hagezi PRO and OISD Small overlap heavily with
AdAway and Peter Lowe's).

## Troubleshooting

### Unbound fails to start

```bash
sudo unbound-checkconf /etc/unbound/unbound.conf.d/pi-recursive.conf
sudo journalctl -u unbound -n 50 --no-pager
```

Common causes:

- Port conflict with systemd-resolved on 5335. Check
  `ss -tlnp | grep 5335`.
- Missing trust anchor: `sudo apt install --reinstall dns-root-data`.
- Legacy autotrust file corrupted. If `unbound-checkconf` reports
  `error: trust anchor presented twice`, the old
  `/var/lib/unbound/root.key` was corrupted (typically by an OOM kill
  mid-write). Recover by replacing it with the static anchor:

  ```bash
  sudo systemctl stop unbound
  sudo cp -a /var/lib/unbound/root.key /var/lib/unbound/root.key.broken-$(date +%F)
  sudo install -o unbound -g unbound -m 644 /usr/share/dns/root.key /var/lib/unbound/root.key
  sudo -u unbound unbound-checkconf
  sudo systemctl start unbound
  ```

  See [ADR-003](decisions/003-unbound-recursive-dns.md) for the full
  rationale on the static anchor.

### AdGuard Home shows no queries

- Verify upstream is reachable:
  `dig @127.0.0.1 -p 5335 example.com +short` (from the Pi).
- AdGuard Home logs: `sudo journalctl -u AdGuardHome -n 50`.
- Confirm a client is actually using this DNS server:
  `nslookup example.com <appliance-ip>`.

### Slow initial DNS resolution

Expected. A cold cache requires the full root, TLD, authoritative walk
(50 to 150 ms). Subsequent queries are cached at two layers (Unbound and
AdGuard). Prefetch keeps popular entries warm.

### Pi Zero 2 W WiFi drops

Pi Zero 2 W's 2.4 GHz on-board radio is prone to interference.
Mitigations:

- Move it away from microwaves, Bluetooth devices, other 2.4 GHz
  transmitters.
- Check signal: `iwconfig wlan0`. Look for `Signal level`.
- For a permanent solution, switch to wired Ethernet via a USB Ethernet
  HAT.

## Future enhancements

- Second node. Copy the inventory entry, run Ansible against both. Note
  that proper HA needs a VIP via keepalived. Not reliable on WiFi, do
  this only on wired hosts.
- DoH or DoT to clients. AdGuard Home supports both. Generate a cert
  (Let's Encrypt or self-signed) and enable in `AdGuardHome.yaml.j2`
  under `tls`.
- DHCP. AdGuard Home can be a DHCP server. Disabled by default in this
  template. Change `dhcp.enabled` if you want it.

## File reference

| File                                          | Purpose                                                                                         |
| --------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `cloud-init/pi-zero-dns.yml`                  | First-boot config: hostname, SSH key, packages (unbound, dnsutils), service disabling, swap off |
| `ansible/playbooks/dns.yml`                   | Playbook: common, hardening, unbound, adguard, optional zabbix_agent                            |
| `ansible/inventory/dns.yml.example`           | Inventory template. Copy to `dns.yml` and edit for your node                                    |
| `ansible/roles/unbound/`                      | Unbound role: install, configure recursive resolver, verify                                     |
| `ansible/roles/adguard/`                      | AdGuard Home role: download, install, configure, blocklists, firewall                           |
| `ansible/roles/zabbix_agent/`                 | Optional Zabbix Agent 2 role                                                                    |
| `ansible/roles/common/`                       | Base OS config: timezone, NTP, packages, unattended-upgrades                                    |
| `ansible/roles/hardening/`                    | SSH hardening and UFW                                                                           |
| `ansible/vault/secrets.sops.yml.example`      | Vault skeleton: AdGuard admin password hash, optional Zabbix server IP                          |
| `scripts/flash-image.ps1`                     | Windows full-pipeline flasher (download, flash, inject)                                         |
| `scripts/flash-sd.sh`                         | Linux/macOS injection-only helper (assumes you flashed the image separately)                    |
| `scripts/flash-config.psd1`                   | Image URLs, checksums, node-to-image mapping                                                    |
| `docs/decisions/001-adguard-over-pihole.md`   | ADR: why AdGuard Home over Pi-hole                                                              |
| `docs/decisions/002-devcontainer-tooling.md`  | ADR: devcontainer-pinned tooling                                                                |
| `docs/decisions/003-unbound-recursive-dns.md` | ADR: why Unbound for recursive DNS, why a static trust anchor                                   |
