#!/bin/bash
set -euo pipefail

PLUGIN_PREFIX="GIT_SSH_CHECKOUT"

# Reads either a value or a list from the given env prefix
function prefix_read_list() {
  local prefix="$1"
  local parameter="${prefix}_0"

  if [ -n "${!parameter:-}" ]; then
    local i=0
    local parameter="${prefix}_${i}"
    while [ -n "${!parameter:-}" ]; do
      echo "${!parameter}"
      i=$((i+1))
      parameter="${prefix}_${i}"
    done
  elif [ -n "${!prefix:-}" ]; then
    echo "${!prefix}"
  fi
}

# Reads either a value or a list from plugin config
function plugin_read_list() {
  prefix_read_list "BUILDKITE_PLUGIN_${PLUGIN_PREFIX}_${1}"
}


# Reads either a value or a list from plugin config into a global result array
# Returns success if values were read
function prefix_read_list_into_result() {
  local prefix="$1"
  local parameter="${prefix}_0"
  result=()

  if [ -n "${!parameter:-}" ]; then
    local i=0
    local parameter="${prefix}_${i}"
    while [ -n "${!parameter:-}" ]; do
      result+=("${!parameter}")
      i=$((i+1))
      parameter="${prefix}_${i}"
    done
  elif [ -n "${!prefix:-}" ]; then
    result+=("${!prefix}")
  fi

  [ ${#result[@]} -gt 0 ] || return 1
}

# Reads either a value or a list from plugin config
function plugin_read_list_into_result() {
  prefix_read_list_into_result "BUILDKITE_PLUGIN_${PLUGIN_PREFIX}_${1}"
}

# Reads a single value
function plugin_read_config() {
  local var="BUILDKITE_PLUGIN_${PLUGIN_PREFIX}_${1}"
  local default="${2:-}"
  echo "${!var:-$default}"
}

# Configures Git to use the plugin's SSH key while preserving any existing SSH options.
function plugin_configure_ssh_command() {
  local key_name="$1"
  local quoted_key_name

  printf -v quoted_key_name '%q' "${key_name}"
  if [ -n "${GIT_SSH_COMMAND:-}" ]; then
    GIT_SSH_COMMAND="${GIT_SSH_COMMAND} -i ${quoted_key_name}"
  else
    GIT_SSH_COMMAND="ssh -i ${quoted_key_name} -o StrictHostKeyChecking=no"
  fi
  export GIT_SSH_COMMAND
}

# Removes the private key directory created by the checkout hook.
function plugin_cleanup_ssh_key_directory() {
  local key_directory="${GIT_SSH_CHECKOUT_PLUGIN_KEY_DIRECTORY:-}"

  if [ -z "${key_directory}" ]; then
    return 0
  fi

  case "${key_directory}" in
    /*) ;;
    *)
      echo "Refusing to remove unexpected SSH key directory: ${key_directory}" >&2
      return 1
      ;;
  esac

  case "${key_directory}" in
    */../*|*/..|*/./*|*/.)
      echo "Refusing to remove unexpected SSH key directory: ${key_directory}" >&2
      return 1
      ;;
  esac

  case "${key_directory##*/}" in
    git_ssh_checkout_plugin_ssh_key.?*) ;;
    *)
      echo "Refusing to remove unexpected SSH key directory: ${key_directory}" >&2
      return 1
      ;;
  esac

  if [ -L "${key_directory}" ]; then
    echo "Refusing to remove SSH key directory symlink: ${key_directory}" >&2
    return 1
  fi

  if [ ! -e "${key_directory}" ]; then
    unset GIT_SSH_CHECKOUT_PLUGIN_KEY_DIRECTORY
    return 0
  fi

  if [ ! -d "${key_directory}" ]; then
    echo "Refusing to remove SSH key path that is not a directory: ${key_directory}" >&2
    return 1
  fi

  rm -rf -- "${key_directory}"
  unset GIT_SSH_CHECKOUT_PLUGIN_KEY_DIRECTORY
}

# Cleans up the private key if the checkout hook exits before completing.
function plugin_cleanup_ssh_key_directory_on_exit() {
  local exit_status=$?

  trap - EXIT
  if [ "${exit_status}" -ne 0 ]; then
    plugin_cleanup_ssh_key_directory || true
  fi

  return "${exit_status}"
}

# Cleans up the private key before terminating after a cancellation signal.
function plugin_cleanup_ssh_key_directory_on_signal() {
  local exit_status="$1"

  trap - EXIT HUP INT TERM
  plugin_cleanup_ssh_key_directory || true
  exit "${exit_status}"
}
