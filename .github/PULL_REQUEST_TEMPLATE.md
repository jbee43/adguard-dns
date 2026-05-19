<!--
Thanks for the contribution!
-->

## What and why

<!-- One or two sentences. Link any related issue (`Fixes #N`). -->

## Checklist

- [ ] `make lint` passes locally (or `pre-commit run --all-files`).
- [ ] `make link-check` passes if any docs were touched.
- [ ] User-facing changes (flash flow, Ansible roles, inventory shape) are
      reflected in [README.md](../README.md) and
      [docs/provisioning.md](../docs/provisioning.md).
- [ ] An ADR was added under [docs/decisions/](../docs/decisions/) if this
      is an architectural change.
- [ ] No plaintext secrets, real hostnames, real IPs, MAC addresses, or age
      keys in the diff.
- [ ] If a new SOPS-managed file was added, it's encrypted (CI will
      otherwise fail the `vault` job).

## Tested on

<!-- Which host did you run this against? Pi Zero 2 W, Pi 4, VM, and so on. -->

## Notes for reviewers

<!-- Optional. Anything subtle, anything you're unsure about. -->
