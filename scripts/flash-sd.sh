#!/usr/bin/env bash
set -euo pipefail

# flash-sd.sh - Inject the cloud-init template into a mounted boot partition.
#
# Companion to flash-image.ps1. This script handles only the cloud-init /
# first-run-config injection step on Linux/macOS. The OS image itself must
# already be flashed (e.g. with Raspberry Pi Imager).
#
# Usage:
#   ./scripts/flash-sd.sh <node-type> <boot-mount-path> [options]
#
# Required:
#   <node-type>          Node type (determines cloud-init template)
#   <boot-mount-path>    Mounted boot partition path (FAT32)
#
# Options:
#   --hostname <name>    Hostname to assign (default: node-type)
#   --ip <address>       Optional static IP - most setups should use a DHCP
#                        reservation on the router instead and skip this.
#   --username <name>    OS username (default: admin)
#   --ssh-key <string>   SSH public key. If omitted, reads ~/.ssh/id_ed25519.pub
#                        (or id_rsa.pub).
#   --timezone <tz>      IANA timezone (default: Etc/UTC)
#
# Examples:
#   ./scripts/flash-sd.sh pi-zero-dns /media/boot --hostname dns-1
#   ./scripts/flash-sd.sh pi-zero-dns /Volumes/bootfs --hostname dns-1 \
#       --username pi --timezone Europe/London

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLOUD_INIT_DIR="${REPO_ROOT}/cloud-init"

# --- Config (add new node types here) ---

declare -A CONFIG_MAP=(
  [pi-zero-dns]="pi-zero-dns.yml"
)

declare -A BASE_IP_MAP=()

# --- Parse arguments ---

NODE_TYPE="${1:-}"
BOOT_MOUNT="${2:-}"
HOSTNAME=""
IP=""
USERNAME="admin"
SSH_PUBLIC_KEY=""
TIMEZONE="Etc/UTC"

if [[ -z "${NODE_TYPE}" || -z "${BOOT_MOUNT}" ]]; then
  echo "Usage: $0 <node-type> <boot-mount-path> [--hostname <name>] [--ip <address>] [--username <name>] [--ssh-key <string>] [--timezone <tz>]"
  echo ""
  echo "Node types and their cloud-init configs:"
  for key in $(printf '%s\n' "${!CONFIG_MAP[@]}" | sort); do
    printf "  %-16s -> cloud-init/%s\n" "${key}" "${CONFIG_MAP[${key}]}"
  done
  exit 1
fi

shift 2

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname)  HOSTNAME="$2"; shift 2 ;;
    --ip)        IP="$2"; shift 2 ;;
    --username)  USERNAME="$2"; shift 2 ;;
    --ssh-key)   SSH_PUBLIC_KEY="$2"; shift 2 ;;
    --timezone)  TIMEZONE="$2"; shift 2 ;;
    *)
      echo "ERROR: Unknown option '$1'"
      exit 1
      ;;
  esac
done

# --- Validate ---

CONFIG_FILE_NAME="${CONFIG_MAP[${NODE_TYPE}]:-}"
if [[ -z "${CONFIG_FILE_NAME}" ]]; then
  valid_types=$(printf '%s\n' "${!CONFIG_MAP[@]}" | sort | paste -sd ', ')
  echo "ERROR: Unknown node type '${NODE_TYPE}'. Valid types: ${valid_types}"
  exit 1
fi

CONFIG_FILE="${CLOUD_INIT_DIR}/${CONFIG_FILE_NAME}"
if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "ERROR: Config file not found: ${CONFIG_FILE}"
  exit 1
fi

if [[ ! -d "${BOOT_MOUNT}" ]]; then
  echo "ERROR: Boot mount path not found: ${BOOT_MOUNT}"
  echo "Make sure the boot partition is mounted."
  exit 1
fi

if [[ -z "${HOSTNAME}" ]]; then
  HOSTNAME="${NODE_TYPE}"
fi

if [[ -n "${IP}" ]] && ! [[ "${IP}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  echo "ERROR: Invalid IP address format: '${IP}'. Expected IPv4 (e.g., 192.0.2.10)."
  exit 1
fi

# Resolve SSH public key
if [[ -z "${SSH_PUBLIC_KEY}" ]]; then
  for key_path in "${HOME}/.ssh/id_ed25519.pub" "${HOME}/.ssh/id_rsa.pub"; do
    if [[ -f "${key_path}" ]]; then
      SSH_PUBLIC_KEY="$(tr -d '\n' < "${key_path}")"
      echo "  SSH key:  ${key_path}"
      break
    fi
  done
fi
if [[ -z "${SSH_PUBLIC_KEY}" ]]; then
  echo "ERROR: No SSH public key found. Pass --ssh-key or generate one (ssh-keygen -t ed25519)."
  exit 1
fi

# --- Deploy ---

if command -v python3 &>/dev/null; then
  if ! python3 -c "import yaml; yaml.safe_load(open('${CONFIG_FILE}'))" 2>/dev/null; then
    echo "WARNING: YAML validation failed for ${CONFIG_FILE}"
    echo "Continuing anyway - check the file manually."
  fi
fi

TEMP_FILE=$(mktemp)
PARTIAL_USER_DATA=""

cleanup() {
  local exit_code=$?
  rm -f "${TEMP_FILE}"
  if [[ ${exit_code} -ne 0 && -n "${PARTIAL_USER_DATA}" && -f "${PARTIAL_USER_DATA}" ]]; then
    echo "ERROR: aborted mid-deploy - removing partial ${PARTIAL_USER_DATA}" >&2
    rm -f "${PARTIAL_USER_DATA}"
  fi
}
trap cleanup EXIT

# Substitute __PLACEHOLDER__ tokens. Use a Python helper to avoid sed escaping
# headaches with SSH keys (which contain '/' and other sed delimiters).
python3 - <<PYEOF > "${TEMP_FILE}"
with open("${CONFIG_FILE}", "r", encoding="utf-8") as fh:
    content = fh.read()
subs = {
    "__HOSTNAME__":       "${HOSTNAME}",
    "__ADMIN_USER__":     "${USERNAME}",
    "__TIMEZONE__":       "${TIMEZONE}",
    "__SSH_PUBLIC_KEY__": """${SSH_PUBLIC_KEY}""",
}
for k, v in subs.items():
    content = content.replace(k, v)
print(content, end="")
PYEOF

BASE_IP="${BASE_IP_MAP[${NODE_TYPE}]:-}"
if [[ -n "${BASE_IP}" && -n "${IP}" && "${BASE_IP}" != "${IP}" ]]; then
  escaped_base_ip=$(printf '%s' "${BASE_IP}" | sed 's/\./\\./g')
  sed -i.bak -e "s/${escaped_base_ip}/${IP}/g" "${TEMP_FILE}"
  rm -f "${TEMP_FILE}.bak"
fi

PARTIAL_USER_DATA="${BOOT_MOUNT}/user-data"
cp "${TEMP_FILE}" "${PARTIAL_USER_DATA}"
touch "${BOOT_MOUNT}/meta-data"
PARTIAL_USER_DATA=""

# --- Summary ---

echo "Cloud-init config deployed:"
echo "  Source:   cloud-init/${CONFIG_FILE_NAME}"
echo "  Target:   ${BOOT_MOUNT}/user-data"
echo "  Hostname: ${HOSTNAME}"
echo "  Username: ${USERNAME}"
echo "  Timezone: ${TIMEZONE}"
if [[ -n "${IP}" ]]; then
  echo "  IP:       ${IP}"
fi
echo ""
echo "Next steps:"
echo "  1. Safely eject the storage device"
echo "  2. Insert into the Pi and power on"
echo "  3. Wait for cloud-init to complete and the Pi to reboot"
if [[ -n "${IP}" ]]; then
  echo "  4. SSH in: ssh ${USERNAME}@${IP}"
else
  echo "  4. SSH in: ssh ${USERNAME}@<dhcp-assigned-ip>"
fi
