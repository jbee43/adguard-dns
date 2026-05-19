---
name: Bug report
about: Report a problem with the flash flow, Ansible roles, or running appliance
title: "[bug] "
labels: ["bug"]
---

<!--
Before opening: confirm `make lint` passes on your branch and redact
anything sensitive (real hostnames, IPs, MACs, admin password hashes,
age keys) before pasting logs.
-->

## What happened

<!-- One or two sentences. -->

## What you expected

<!-- One or two sentences. -->

## Environment

- Host: <!-- Pi Zero 2 W / Pi 4 / Pi 5 / x86 mini PC / VM -->
- OS image and version: <!-- e.g. Raspberry Pi OS Lite Bookworm 2024-11-19 -->
- Ansible version: <!-- output of `ansible --version | head -1` -->
- Repo commit: <!-- output of `git rev-parse --short HEAD` -->

## Steps to reproduce

1. <!-- exact `flash-image.ps1` / `flash-sd.sh` invocation -->
2. <!-- exact `ansible-playbook` / `make dns` invocation -->
3. <!-- ... -->

## Logs

<details>
<summary>First-boot log (<code>cat /boot/firmware/firstrun.log</code>)</summary>

```text
<!-- paste here -->
```

</details>

<details>
<summary>Ansible task output</summary>

```text
<!-- paste only the failing task's stdout, not the full run -->
```

</details>
