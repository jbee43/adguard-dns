#!/usr/bin/env bash
# check-vault-encrypted.sh
# Single source of truth for the "are SOPS-managed files actually encrypted?"
# check used by both .github/workflows/ci.yml and .gitea/workflows/lint.yml.
#
# Walks every tracked *.sops.yml / *.sops.yaml (excluding *.example templates)
# and fails if any of them lacks a SOPS marker.

set -euo pipefail

failed=0
checked=0

while IFS= read -r file; do
  [ -z "$file" ] && continue
  if [ ! -f "$file" ]; then
    continue
  fi
  if [ "${file##*.}" = "example" ]; then
    continue
  fi
  checked=$((checked + 1))
  if ! grep -q "sops:" "$file" && ! grep -q "ENC\[AES256" "$file"; then
    echo "ERROR: $file matches the SOPS pattern but is not encrypted"
    failed=1
  fi
done < <(git ls-files -- \
  'ansible/**/*.sops.yml' \
  'ansible/**/*.sops.yaml' \
  '**/*.sops.yml' \
  '**/*.sops.yaml')

if [ "$failed" -eq 1 ]; then
  echo "Vault check FAILED - encrypt the file(s) above with sops before committing."
  exit 1
fi

echo "Vault check OK - $checked SOPS-managed file(s) verified (none committed unencrypted)."
