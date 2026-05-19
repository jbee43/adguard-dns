FROM mcr.microsoft.com/devcontainers/python:1-3.12-bookworm@sha256:7876580dc67fd460fd962f004cbeb480027e9bbc0657096f1087db11f9eaff39

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# --- Tool versions (pinned for reproducibility, updated by Renovate) ---
# renovate: datasource=github-releases depName=getsops/sops
ARG SOPS_VERSION=3.13.0
# renovate: datasource=github-releases depName=FiloSottile/age
ARG AGE_VERSION=1.3.1
# renovate: datasource=github-releases depName=hadolint/hadolint
ARG HADOLINT_VERSION=2.14.0
# renovate: datasource=github-releases depName=rhysd/actionlint
ARG ACTIONLINT_VERSION=1.7.12
# renovate: datasource=github-releases depName=editorconfig-checker/editorconfig-checker
ARG EC_VERSION=3.6.1
# renovate: datasource=github-releases depName=gitleaks/gitleaks
ARG GITLEAKS_VERSION=8.30.1
# renovate: datasource=github-releases depName=aquasecurity/trivy
ARG TRIVY_VERSION=0.70.0
# renovate: datasource=github-releases depName=koalaman/shellcheck
ARG SHELLCHECK_VERSION=0.11.0
# renovate: datasource=github-releases depName=lycheeverse/lychee
ARG LYCHEE_VERSION=0.20.1

# --- System packages ---
# Remove stale Yarn repo shipped in base image (expired GPG key breaks apt-get update)
RUN rm -f /etc/apt/sources.list.d/yarn.list
RUN apt-get update && apt-get install -y --no-install-recommends \
    apache2-utils \
    curl \
    jq \
    make \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

# --- SOPS ---
RUN curl -fsSL -o /usr/local/bin/sops \
    "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.amd64" \
    && chmod +x /usr/local/bin/sops

# --- age ---
RUN curl -fsSL "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-amd64.tar.gz" \
    | tar xz -C /usr/local/bin --strip-components=1 age/age age/age-keygen \
    && chmod +x /usr/local/bin/age /usr/local/bin/age-keygen

# --- Linting and validation tools (for make lint/security/validate) ---

# --- Hadolint ---
RUN curl -fsSL -o /usr/local/bin/hadolint \
    "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-linux-x86_64" \
    && chmod +x /usr/local/bin/hadolint

# --- actionlint ---
RUN curl -fsSL \
    "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" \
    | tar xz -C /usr/local/bin actionlint \
    && chmod +x /usr/local/bin/actionlint

# --- editorconfig-checker ---
RUN curl -fsSL \
    "https://github.com/editorconfig-checker/editorconfig-checker/releases/download/v${EC_VERSION}/ec-linux-amd64.tar.gz" \
    | tar xz -C /usr/local/bin --strip-components=1 \
    && mv /usr/local/bin/ec-linux-amd64 /usr/local/bin/ec

# --- lychee (broken-link checker for docs) ---
RUN curl -fsSL \
    "https://github.com/lycheeverse/lychee/releases/download/lychee-v${LYCHEE_VERSION}/lychee-x86_64-unknown-linux-gnu.tar.gz" \
    | tar xz -C /usr/local/bin lychee \
    && chmod +x /usr/local/bin/lychee

# --- Trivy ---
# Pinned binary install (not `curl … main/contrib/install.sh | sh`) — Renovate
# tracks the version via the ARG marker above. Avoids running an unpinned
# script that fetches from upstream `main` at every image build.
RUN curl -fsSL \
    "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" \
    | tar xz -C /usr/local/bin trivy \
    && chmod +x /usr/local/bin/trivy

# --- gitleaks ---
RUN curl -fsSL \
    "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
    | tar xz -C /usr/local/bin gitleaks \
    && chmod +x /usr/local/bin/gitleaks

# --- shellcheck ---
RUN curl -fsSL \
    "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" \
    | tar xJ -C /usr/local/bin --strip-components=1 "shellcheck-v${SHELLCHECK_VERSION}/shellcheck" \
    && chmod +x /usr/local/bin/shellcheck

# --- Shell aliases (append to /etc/bash.bashrc so both login and non-login
#     interactive bash shells get them - VS Code terminals open non-login).
RUN echo "alias cls='clear'" >> /etc/bash.bashrc
