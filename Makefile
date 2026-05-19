# adguard-dns - Makefile
# Orchestrates flash + provisioning + lint for the DNS appliance.

ANSIBLE_DIR := ansible
INVENTORY ?= $(ANSIBLE_DIR)/inventory/dns.yml
PLAYBOOKS := $(ANSIBLE_DIR)/playbooks

# Cloud-init boot partition mount point. Override per-OS:
#   Windows:      BOOT_MOUNT=E:\
#   Linux:        BOOT_MOUNT=/media/$$USER/bootfs
#   macOS:        BOOT_MOUNT=/Volumes/bootfs
BOOT_MOUNT ?= /media/boot

VAULT_FILE := $(ANSIBLE_DIR)/vault/secrets.sops.yml

.PHONY: help deps deps-check lint security check-all link-check dns dns-check vault-edit vault-view vault-keys flash flash-image

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# --- Setup ---

deps: ## Install Ansible and Python dependencies
	pip install -r .devcontainer/requirements.txt
	ansible-galaxy collection install -r ansible/requirements.yml

deps-check: ## Verify all required tools are installed
	@echo "=== Core Tools ==="
	@command -v ansible-playbook >/dev/null && ansible --version | head -1 || echo "MISSING: ansible"
	@command -v ansible-lint >/dev/null && ansible-lint --version | head -1 || echo "MISSING: ansible-lint"
	@command -v yamllint >/dev/null && yamllint --version || echo "MISSING: yamllint"
	@command -v sops >/dev/null && sops --version 2>&1 | head -1 || echo "MISSING: sops"
	@command -v age >/dev/null && age --version || echo "MISSING: age"
	@command -v shellcheck >/dev/null && shellcheck --version | grep '^version:' || echo "MISSING: shellcheck"
	@echo "=== Linting Tools ==="
	@command -v hadolint >/dev/null && hadolint --version 2>&1 | head -1 || echo "MISSING: hadolint"
	@command -v actionlint >/dev/null && actionlint --version 2>&1 | head -1 || echo "MISSING: actionlint"
	@command -v ec >/dev/null && ec --version 2>&1 | head -1 || echo "MISSING: editorconfig-checker"
	@command -v markdownlint >/dev/null && markdownlint --version || echo "MISSING: markdownlint"
	@command -v pre-commit >/dev/null && pre-commit --version || echo "MISSING: pre-commit"
	@echo "=== Security Tools ==="
	@command -v trivy >/dev/null && trivy --version 2>&1 | head -1 || echo "MISSING: trivy"
	@command -v gitleaks >/dev/null && gitleaks version || echo "MISSING: gitleaks"
	@echo "====================="

lint: ## Lint all code (YAML, Ansible, shell, Markdown, editorconfig, Dockerfile)
	yamllint .
	ansible-lint
	shellcheck scripts/*.sh
	markdownlint '**/*.md' --ignore node_modules
	ec
	actionlint
	hadolint .devcontainer/Dockerfile

security: ## Run security scans (Trivy + gitleaks)
	trivy fs --scanners vuln,misconfig --severity HIGH,CRITICAL --exit-code 1 --skip-dirs .devcontainer .
	gitleaks detect --source . --verbose

check-all: lint security link-check ## Run all checks (lint + security + link-check)

link-check: ## Check for broken links in documentation
	lychee --no-progress --exclude-path .devcontainer --accept 200,204,301,403 '**/*.md'

# --- Provisioning ---

dns: ## Provision DNS appliance (AdGuard Home + Unbound + optional Zabbix Agent)
	ansible-playbook -i $(INVENTORY) $(PLAYBOOKS)/dns.yml

dns-check: ## Dry-run the dns playbook (--check --diff) without changing the host
	ansible-playbook -i $(INVENTORY) $(PLAYBOOKS)/dns.yml --check --diff

# --- SOPS vault ---

vault-edit: ## Edit the SOPS-encrypted Ansible vault (interactive)
	sops $(VAULT_FILE)

vault-view: ## Print the decrypted vault to a terminal (refuses if stdout is redirected)
	@if [ ! -t 1 ]; then \
		echo "ERROR: vault-view refuses to write decrypted secrets to a non-tty (pipe/file)."; \
		echo "       If you need a file, edit with 'make vault-edit' instead."; \
		exit 1; \
	fi
	@sops --decrypt $(VAULT_FILE)

vault-keys: ## List vault keys without revealing values
	sops --decrypt $(VAULT_FILE) | yq 'keys'

# --- SD card flashing ---

flash: ## Inject cloud-init to boot partition (NODE=pi-zero-dns BOOT_MOUNT=/media/boot)
	@test -n "$(NODE)" || (echo "Usage: make flash NODE=<node-type> BOOT_MOUNT=<path>"; exit 1)
	./scripts/flash-sd.sh $(NODE) $(BOOT_MOUNT)

flash-image: ## Flash full OS image + first-run config - Windows only (NODE=pi-zero-dns [DISK=<num>])
	@test -n "$(NODE)" || (echo "Usage: make flash-image NODE=<node-type> [DISK=<number>]"; exit 1)
	pwsh -ExecutionPolicy Bypass -File ./scripts/flash-image.ps1 -NodeType $(NODE) $(if $(DISK),-DiskNumber $(DISK),)
