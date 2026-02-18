#!/usr/bin/env bash
set -euo pipefail

INSTALL_ROOT="${SWRMGR_ROOT:-/opt/swrmgr}"
CONFIG_DIR="${SWRMGR_CONFIG_DIR:-/etc/swrmgr}"
LOG_DIR="/var/log/swrmgr"

# ------------------------------------------------------------------------------
# Prerequisites
# ------------------------------------------------------------------------------
echo "Checking prerequisites..."

# Required commands
missing=()
for cmd in docker aws jq curl rsync openssl envsubst mysql; do
  command -v "${cmd}" > /dev/null 2>&1 || missing+=("${cmd}")
done

if (( ${#missing[@]} > 0 )); then
  echo "Missing required commands: ${missing[*]}" >&2
  echo "Install them and try again." >&2
  exit 1
fi

# Docker must be running
docker info > /dev/null 2>&1 || {
  echo "Docker is not running." >&2
  exit 1
}

# Must be a swarm manager
node_role="$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null || echo "false")"
if [[ "${node_role}" != "true" ]]; then
  echo "This node is not a Docker Swarm manager." >&2
  echo "Run 'docker swarm init' or join as a manager first." >&2
  exit 1
fi

echo "All prerequisites met."
echo ""

# ------------------------------------------------------------------------------
# Install
# ------------------------------------------------------------------------------
echo "Installing swrmgr to ${INSTALL_ROOT}..."

# Create directories
sudo mkdir -p "${INSTALL_ROOT}" "${CONFIG_DIR}" "${LOG_DIR}" /var/www/html
sudo mkdir -p "${INSTALL_ROOT}/plugins"

[[ -z "${USER:-}" ]] && USER="$(whoami)"

sudo chown -R "${USER}:${USER}" "${INSTALL_ROOT}"
sudo chown -R "${USER}:${USER}" "${CONFIG_DIR}"
sudo chown -R "${USER}:${USER}" "${LOG_DIR}"
sudo chown -R "${USER}:${USER}" /var/www/html

# Copy core files
rsync -av --exclude='.git' --exclude='plugins/*/' \
  bin/ "${INSTALL_ROOT}/bin/"
rsync -av lib/ "${INSTALL_ROOT}/lib/"
rsync -av etc/ "${INSTALL_ROOT}/etc/"

# Install plugins (preserve existing)
if [[ -d plugins/ ]]; then
  rsync -av plugins/ "${INSTALL_ROOT}/plugins/"
fi

# Make all scripts executable
find "${INSTALL_ROOT}/bin" -type f -exec chmod +x {} \;
find "${INSTALL_ROOT}/plugins" -name '*.sh' -o -type f -path '*/bin/*' -o -type f -path '*/hooks/*' | xargs chmod +x 2>/dev/null || true

# Install main command
sudo cp "${INSTALL_ROOT}/bin/swrmgr" /usr/local/bin/swrmgr
sudo chmod +x /usr/local/bin/swrmgr

# Copy example config if no config exists
if [[ ! -f /etc/environment ]] || ! grep -q 'SWRMGR_AWS_ACCOUNT_ID' /etc/environment; then
  echo ""
  echo "No swrmgr configuration found in /etc/environment."
  echo "See ${INSTALL_ROOT}/etc/environment.example for required variables."
  echo ""

  read -r -p "Would you like to configure now? (y/N) " answer
  if [[ "$(echo "${answer}" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
    configure_var() {
      local name="${1}" default="${2}" desc="${3}"
      local current="${!name:-}"
      [[ -n "${current}" ]] && return
      read -e -p "${desc} [${default}]: " -i "${default}" value
      value="${value:-${default}}"
      echo "${name}=${value}" | sudo tee -a /etc/environment > /dev/null
    }

    configure_var SWRMGR_AWS_ACCOUNT_ID "" "AWS Account ID"
    configure_var SWRMGR_AWS_REGION "us-east-1" "AWS Region"
    configure_var SWRMGR_S3_BUCKET "" "S3 bucket for customer data"
    configure_var NODE_SSH_KEY_NAME "swarm-worker-key.pem" "SSH key filename for node access"
    configure_var PUBLIC_DNS_ZONE_ID "" "Route53 public zone ID"
    configure_var PRIVATE_DNS_ZONE_ID "" "Route53 private zone ID (optional)"
    configure_var PRIVATE_DNS_ZONE_NAME "" "Private DNS zone name (optional)"
  fi
fi

echo ""
echo "swrmgr installed successfully."
echo ""
echo "Usage: swrmgr <tower> <function> [args...]"
echo ""
echo "To install plugins, copy them to: ${INSTALL_ROOT}/plugins/"
echo "See ${INSTALL_ROOT}/etc/environment.example for configuration reference."
