# ADR-002: Devcontainer for Developer Tooling

**Date**: 2026-04-13
**Status**: Accepted

## Context

The repo needs several CLI tools for daily work: Ansible, SOPS, age,
shellcheck, lychee, and a handful of linters. Manual install instructions
were not enough. Setting up a new workstation meant installing seven or more
tools individually, and version drift was certain.

Goal: clone the repo, open in VS Code, everything works.

## Decision

Use a VS Code devcontainer (`.devcontainer/`) to provide all development
tools in a reproducible container image.

What is in the container: Ansible, ansible-lint, yamllint, SOPS, age,
shellcheck, lychee, hadolint, gitleaks, trivy, make, and the matching VS Code
extensions.

What stays on the host: Raspberry Pi Imager and `flash-image.ps1` for SD
card flashing. They need raw disk access via `\\.\PhysicalDrive`, which is
not possible from a container.

Version management:

- Python tools pinned in `.devcontainer/requirements.txt`, shared by the
  devcontainer, Makefile, and CI.
- Binary tools pinned via `ARG` in the Dockerfile with Renovate `regex`
  manager comments.

## Alternatives considered

- **Dev Containers only for Ansible**. Would still need manual installs for
  sops, age, lychee. Does not deliver stateless workstations.
- **Devbox (Nix-based)**. No native Windows support, only WSL2. Nix on WSL2
  can be unreliable. Adds significant complexity (Nix store, flake lockfiles)
  for a solo project.
- **mise (.mise.toml)**. Works on Windows but not all tools have plugins.
  Adds a dependency-manager-for-dependencies. Version pinning value is low
  for stable CLI tools in a small project.
- **Extended Makefile and PowerShell setup script**. Zero new dependencies,
  but does not deliver stateless workstations. Every machine still needs
  manual tool installs.
- **PXE / network boot to eliminate SD card flashing entirely**. Pi 4 and 5
  support this but it requires TFTP infrastructure, one-time EEPROM
  configuration per Pi, and a stable always-on server. Out of scope for a
  single-node DNS appliance.

## Consequences

- Docker Desktop becomes a host dependency, alongside VS Code.
- Raspberry Pi Imager is the only other host-level install
  (`winget install RaspberryPiFoundation.RaspberryPiImager`), needed only
  for SD card flashing.
- SSH agent forwarding from host to container is handled by VS Code, which
  needs the Windows OpenSSH Agent service running.
- Container reaches the Pi LAN via Docker Desktop's default bridge
  networking (NAT to host).
- Renovate proposes version bumps for Dockerfile tool pins.
- `make deps` and `make deps-check` work identically inside and outside the
  container.
