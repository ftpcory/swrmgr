#!/usr/bin/env bash
# swrmgr core library
# Sourced by the main dispatcher — provides hooks, logging, and shared utilities.

SWRMGR_ROOT="${SWRMGR_ROOT:-/opt/swrmgr}"
SWRMGR_PLUGINS="${SWRMGR_ROOT}/plugins"
SWRMGR_LOG="${SWRMGR_LOG:-/var/log/swrmgr/audit.log}"

# --------------------------------------------------------------------------
# Audit logging
# --------------------------------------------------------------------------
audit_log() {
  local log_dir
  log_dir="$(dirname "${SWRMGR_LOG}")"
  [[ -d "${log_dir}" ]] || mkdir -p "${log_dir}" 2>/dev/null || true
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) user=${SUDO_USER:-$(whoami)} host=$(hostname) cmd=swrmgr $*" \
    >> "${SWRMGR_LOG}" 2>/dev/null || true
}

# --------------------------------------------------------------------------
# Plugin discovery
# --------------------------------------------------------------------------

# List all installed plugin directories
list_plugins() {
  local d
  for d in "${SWRMGR_PLUGINS}"/*/; do
    [[ -f "${d}plugin.conf" ]] && echo "${d}"
  done
}

# Get a plugin config value
# Usage: plugin_conf_get /path/to/plugin/ PLUGIN_NAME
plugin_conf_get() {
  local plugin_dir="${1}" key="${2}"
  grep -E "^${key}=" "${plugin_dir}plugin.conf" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'"
}

# Check if a plugin registers a tower
# Returns the tower name or empty string
plugin_tower() {
  plugin_conf_get "${1}" "PLUGIN_TOWER"
}

# Resolve a tower to a plugin directory (if any)
# Usage: resolve_plugin_tower "quicksight"
resolve_plugin_tower() {
  local tower="${1}" d t
  for d in $(list_plugins); do
    t="$(plugin_tower "${d}")"
    [[ "${t}" == "${tower}" ]] && echo "${d}" && return 0
  done
  return 1
}

# --------------------------------------------------------------------------
# Hook system
# --------------------------------------------------------------------------

# Run all hooks for a given lifecycle event.
#   run_hooks "stack:create:after" arg1 arg2 ...
#
# Hooks are executable files stored under:
#   plugins/<name>/hooks/<hook_path>/##-<description>
#
# Example:
#   plugins/bitwarden/hooks/stack/create/after/01-create-credentials
#
# Hooks run in numeric-prefix order across all plugins.
run_hooks() {
  local hook="${1}"
  shift
  local hook_path="${hook//:///}"
  local scripts=()
  local plugin_dir script

  # Collect all matching hook scripts
  for plugin_dir in $(list_plugins); do
    local hook_dir="${plugin_dir}hooks/${hook_path}"
    [[ -d "${hook_dir}" ]] || continue
    for script in "${hook_dir}"/*; do
      [[ -x "${script}" ]] && scripts+=("${script}")
    done
  done

  # Sort by basename (numeric prefix) and execute
  if (( ${#scripts[@]} > 0 )); then
    local sorted
    sorted="$(printf '%s\n' "${scripts[@]}" | sort -t/ -k"$(printf '%s\n' "${scripts[0]}" | tr '/' '\n' | wc -l)" -n)"
    while IFS= read -r script; do
      [[ -n "${script}" ]] || continue
      "${script}" "$@"
    done <<< "${sorted}"
  fi
}

# --------------------------------------------------------------------------
# Stack name validation
# --------------------------------------------------------------------------
validate_stack_name() {
  local name="${1}"
  [[ "${name}" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]] || {
    echo "Invalid stack name: ${name}" >&2
    echo "Must be 3-63 characters, lowercase alphanumeric and hyphens, start/end with alphanumeric." >&2
    return 1
  }
}

# --------------------------------------------------------------------------
# Stack path helpers
# --------------------------------------------------------------------------
stack_name() {
  local raw="${1}"
  local name
  name="$(echo "${raw}" | sed -e 's|.*/||' | xargs)"
  validate_stack_name "${name}" || exit 1
  echo "${name}"
}

stack_path() {
  local stack="${1}"
  local base="${SWRMGR_STACKS_DIR:-/var/www/html}"
  local path="${base}/${stack}"
  [[ -d "${path}" ]] || { echo "Stack path does not exist: ${path}" >&2; return 1; }
  echo "${path}"
}

stack_domain() {
  local stack="${1}"
  local folder
  folder="$(stack_path "${stack}")"
  # Read from .env if available
  if [[ -f "${folder}/.env" ]]; then
    grep -i "^STACK_DOMAIN=" "${folder}/.env" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' || echo "${stack}"
  else
    echo "${stack}"
  fi
}
