#!/usr/bin/env bats

setup() {
  load "${BATS_PLUGIN_PATH}/load.bash"

  # Uncomment to enable stub debugging
  # export CURL_STUB_DEBUG=/dev/tty
  export DRY_RUN='true'
  export BUILDKITE_PLUGIN_GIT_SSH_CHECKOUT_REPOSITORY_URL='git@example.com:organisation/repository.git'
}

@test "Running without arguments succeeds" {
  run "${PWD}/hooks/checkout"

  assert_success
  assert_output --partial 'Running SSH Checkout plugin'
  assert_output --partial '- repository-url: git@example.com:organisation/repository.git'
  assert_output --partial '- ssh-secret-key-name: GIT_SSH_CHECKOUT_PLUGIN_SSH_KEY'
  assert_output --partial '- checkout-path: .'
}

@test "Normal basic operations" {
  export BUILDKITE_PLUGIN_GIT_SSH_CHECKOUT_REPOSITORY_URL='git@example.com:org/repo.git'
  run "${PWD}/hooks/checkout"

  assert_success
  assert_output --partial 'Running SSH Checkout plugin with options'
  assert_output --partial '- repository-url: git@example.com:org/repo.git'
  assert_output --partial '- ssh-secret-key-name: GIT_SSH_CHECKOUT_PLUGIN_SSH_KEY'
  assert_output --partial '- checkout-path: .'
}

@test "Optional value changes behaviour" {
  export BUILDKITE_PLUGIN_GIT_SSH_CHECKOUT_REPOSITORY_URL='git@example.com:org/repo.git'
  export BUILDKITE_PLUGIN_GIT_SSH_CHECKOUT_SSH_SECRET_KEY_NAME='SUPER_SECRET_KEY'
  export BUILDKITE_PLUGIN_GIT_SSH_CHECKOUT_CHECKOUT_PATH='sub'

  run "${PWD}/hooks/checkout"

  assert_success
  assert_output --partial 'Running SSH Checkout plugin with options'
  assert_output --partial '- repository-url: git@example.com:org/repo.git'
  assert_output --partial '- ssh-secret-key-name: SUPER_SECRET_KEY'
  assert_output --partial '- checkout-path: sub'
}

@test "Configures SSH with the secret key when GIT_SSH_COMMAND is unset" {
  unset GIT_SSH_COMMAND
  source "${PWD}/lib/plugin.bash"

  plugin_configure_ssh_command "/tmp/ssh key"

  assert_equal "${GIT_SSH_COMMAND}" "ssh -i /tmp/ssh\\ key -o StrictHostKeyChecking=no"
}

@test "Adds the secret key to the agent v4 GIT_SSH_COMMAND" {
  export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new"
  source "${PWD}/lib/plugin.bash"

  plugin_configure_ssh_command "/tmp/ssh key"

  assert_equal "${GIT_SSH_COMMAND}" "ssh -o StrictHostKeyChecking=accept-new -i /tmp/ssh\\ key"
}

@test "Quotes single quotes in the SSH key path" {
  unset GIT_SSH_COMMAND
  source "${PWD}/lib/plugin.bash"

  plugin_configure_ssh_command "/tmp/ssh'key"

  assert_equal "${GIT_SSH_COMMAND}" "ssh -i /tmp/ssh\\'key -o StrictHostKeyChecking=no"
}

@test "Preserves an existing custom SSH command" {
  export GIT_SSH_COMMAND="ssh -F /etc/ssh/custom-config"
  source "${PWD}/lib/plugin.bash"

  plugin_configure_ssh_command "/tmp/ssh-key"

  assert_equal "${GIT_SSH_COMMAND}" "ssh -F /etc/ssh/custom-config -i /tmp/ssh-key"
}

@test "Checkout preserves the agent v4 SSH options and adds the secret key" {
  local hook="${PWD}/hooks/checkout"
  local test_root="${BATS_TEST_TMPDIR}/test root"
  local test_bin="${test_root}/bin"
  local work_dir="${test_root}/work"
  export DRY_RUN="false"
  export GIT_LOG="${BATS_TEST_TMPDIR}/git-log"
  export GIT_CONFIG_LOG="${BATS_TEST_TMPDIR}/git-config-log"
  export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new"
  export BUILDKITE_PLUGIN_GIT_SSH_CHECKOUT_CHECKOUT_PATH="${work_dir}/checkout"
  export BUILDKITE_BRANCH="main"
  export BUILDKITE_COMMIT="HEAD"

  mkdir -p "${test_bin}" "${work_dir}"
  cat > "${test_bin}/buildkite-agent" <<'EOF'
#!/bin/bash
printf '%s\n' 'PRIVATE_SSH_KEY'
EOF
  cat > "${test_bin}/git" <<'EOF'
#!/bin/bash
printf '%s\n' "${GIT_SSH_COMMAND}" >> "${GIT_LOG}"
if [ "$1" = "clone" ]; then
  mkdir -p "$3"
elif [ "$1" = "config" ] && [ "$2" = "core.sshCommand" ]; then
  printf '%s\n' "$3" > "${GIT_CONFIG_LOG}"
fi
EOF
  chmod +x "${test_bin}/buildkite-agent" "${test_bin}/git"
  export PATH="${test_bin}:${PATH}"

  cd "${work_dir}"
  run "${hook}"

  assert_success
  run grep -F -- "StrictHostKeyChecking=accept-new" "${GIT_LOG}"
  assert_success
  run grep -E -- "-i .*/git_ssh_checkout_plugin_ssh_key\\.[A-Za-z0-9]+/id" "${GIT_LOG}"
  assert_success
  run grep -Fx -- "$(head -n 1 "${GIT_LOG}")" "${GIT_CONFIG_LOG}"
  assert_success
}

@test "Checkout creates the SSH key with restrictive permissions" {
  local hook="${PWD}/hooks/checkout"
  local test_root="${BATS_TEST_TMPDIR}/permissions"
  local test_bin="${test_root}/bin"
  local work_dir="${test_root}/work"
  export DRY_RUN="false"
  export KEY_PATH_LOG="${BATS_TEST_TMPDIR}/key-path"
  export BUILDKITE_PLUGIN_GIT_SSH_CHECKOUT_CHECKOUT_PATH="${work_dir}/checkout"
  export BUILDKITE_BRANCH="main"
  export BUILDKITE_COMMIT="HEAD"

  mkdir -p "${test_bin}" "${work_dir}"
  cat > "${test_bin}/buildkite-agent" <<'EOF'
#!/bin/bash
printf '%s\n' 'PRIVATE_SSH_KEY'
EOF
  cat > "${test_bin}/git" <<'EOF'
#!/bin/bash
if [ "$1" = "clone" ]; then
  printf '%s\n' "${GIT_SSH_CHECKOUT_PLUGIN_KEY_DIRECTORY}/id" > "${KEY_PATH_LOG}"
  mkdir -p "$3"
fi
EOF
  chmod +x "${test_bin}/buildkite-agent" "${test_bin}/git"
  export PATH="${test_bin}:${PATH}"

  cd "${work_dir}"
  run "${hook}"

  assert_success
  local key_path
  key_path=$(cat "${KEY_PATH_LOG}")
  assert_file_permission 400 "${key_path}"
  assert_file_permission 700 "$(dirname "${key_path}")"
}

@test "Pre-exit removes the generated SSH key directory" {
  export GIT_SSH_CHECKOUT_PLUGIN_KEY_DIRECTORY="${BATS_TEST_TMPDIR}/git_ssh_checkout_plugin_ssh_key.cleanup"
  mkdir -p "${GIT_SSH_CHECKOUT_PLUGIN_KEY_DIRECTORY}"
  printf '%s\n' 'PRIVATE_SSH_KEY' > "${GIT_SSH_CHECKOUT_PLUGIN_KEY_DIRECTORY}/id"

  run "${PWD}/hooks/pre-exit"

  assert_success
  assert_dir_not_exist "${GIT_SSH_CHECKOUT_PLUGIN_KEY_DIRECTORY}"
}

@test "Pre-exit succeeds when no SSH key directory was created" {
  unset GIT_SSH_CHECKOUT_PLUGIN_KEY_DIRECTORY

  run "${PWD}/hooks/pre-exit"

  assert_success
}

@test "Pre-exit succeeds when the SSH key directory is already absent" {
  export GIT_SSH_CHECKOUT_PLUGIN_KEY_DIRECTORY="${BATS_TEST_TMPDIR}/git_ssh_checkout_plugin_ssh_key.absent"

  run "${PWD}/hooks/pre-exit"

  assert_success
}

@test "Cleanup refuses to remove an unexpected directory" {
  export GIT_SSH_CHECKOUT_PLUGIN_KEY_DIRECTORY="${BATS_TEST_TMPDIR}/unrelated"
  mkdir -p "${GIT_SSH_CHECKOUT_PLUGIN_KEY_DIRECTORY}"

  run "${PWD}/hooks/pre-exit"

  assert_success
  assert_dir_exist "${GIT_SSH_CHECKOUT_PLUGIN_KEY_DIRECTORY}"
  assert_output --partial "Refusing to remove unexpected SSH key directory"
}

@test "Cleanup refuses to remove a relative directory" {
  local hook="${PWD}/hooks/pre-exit"
  export GIT_SSH_CHECKOUT_PLUGIN_KEY_DIRECTORY="git_ssh_checkout_plugin_ssh_key.relative"
  mkdir -p "${BATS_TEST_TMPDIR}/${GIT_SSH_CHECKOUT_PLUGIN_KEY_DIRECTORY}"

  cd "${BATS_TEST_TMPDIR}"
  run "${hook}"

  assert_success
  assert_dir_exist "${BATS_TEST_TMPDIR}/${GIT_SSH_CHECKOUT_PLUGIN_KEY_DIRECTORY}"
  assert_output --partial "Refusing to remove unexpected SSH key directory"
}

@test "Cleanup refuses a path containing parent traversal" {
  local protected_directory="${BATS_TEST_TMPDIR}/protected"
  export GIT_SSH_CHECKOUT_PLUGIN_KEY_DIRECTORY="${BATS_TEST_TMPDIR}/git_ssh_checkout_plugin_ssh_key.unsafe/../protected"
  mkdir -p "${protected_directory}"

  run "${PWD}/hooks/pre-exit"

  assert_success
  assert_dir_exist "${protected_directory}"
  assert_output --partial "Refusing to remove unexpected SSH key directory"
}

@test "Cleanup refuses an SSH key directory symlink" {
  local protected_directory="${BATS_TEST_TMPDIR}/protected-symlink-target"
  export GIT_SSH_CHECKOUT_PLUGIN_KEY_DIRECTORY="${BATS_TEST_TMPDIR}/git_ssh_checkout_plugin_ssh_key.symlink"
  mkdir -p "${protected_directory}"
  ln -s "${protected_directory}" "${GIT_SSH_CHECKOUT_PLUGIN_KEY_DIRECTORY}"

  run "${PWD}/hooks/pre-exit"

  assert_success
  assert_dir_exist "${protected_directory}"
  assert_output --partial "Refusing to remove SSH key directory symlink"
}

@test "Cleanup refuses an SSH key path that is not a directory" {
  export GIT_SSH_CHECKOUT_PLUGIN_KEY_DIRECTORY="${BATS_TEST_TMPDIR}/git_ssh_checkout_plugin_ssh_key.file"
  printf '%s\n' 'do not remove' > "${GIT_SSH_CHECKOUT_PLUGIN_KEY_DIRECTORY}"

  run "${PWD}/hooks/pre-exit"

  assert_success
  assert_file_exist "${GIT_SSH_CHECKOUT_PLUGIN_KEY_DIRECTORY}"
  assert_output --partial "Refusing to remove SSH key path that is not a directory"
}

@test "Failed checkout removes the generated SSH key immediately" {
  local hook="${PWD}/hooks/checkout"
  local test_root="${BATS_TEST_TMPDIR}/failed-checkout"
  local test_bin="${test_root}/bin"
  local work_dir="${test_root}/work"
  export DRY_RUN="false"
  export BUILDKITE_PLUGIN_GIT_SSH_CHECKOUT_CHECKOUT_PATH="${work_dir}/checkout"

  mkdir -p "${test_bin}" "${work_dir}"
  cat > "${test_bin}/buildkite-agent" <<'EOF'
#!/bin/bash
printf '%s\n' 'PRIVATE_SSH_KEY'
EOF
  cat > "${test_bin}/git" <<'EOF'
#!/bin/bash
exit 128
EOF
  chmod +x "${test_bin}/buildkite-agent" "${test_bin}/git"
  export PATH="${test_bin}:${PATH}"

  cd "${work_dir}"
  run "${hook}"

  assert_failure 128
  run find "${test_root}" -maxdepth 1 -type d -name 'git_ssh_checkout_plugin_ssh_key.*' -print -quit
  assert_success
  assert_output ""
}

@test "Canceled checkout removes the generated SSH key immediately" {
  local hook="${PWD}/hooks/checkout"
  local test_root="${BATS_TEST_TMPDIR}/canceled-checkout"
  local test_bin="${test_root}/bin"
  local work_dir="${test_root}/work"
  export DRY_RUN="false"
  export BUILDKITE_PLUGIN_GIT_SSH_CHECKOUT_CHECKOUT_PATH="${work_dir}/checkout"

  mkdir -p "${test_bin}" "${work_dir}"
  cat > "${test_bin}/buildkite-agent" <<'EOF'
#!/bin/bash
printf '%s\n' 'PRIVATE_SSH_KEY'
EOF
  cat > "${test_bin}/git" <<'EOF'
#!/bin/bash
kill -TERM "${PPID}"
EOF
  chmod +x "${test_bin}/buildkite-agent" "${test_bin}/git"
  export PATH="${test_bin}:${PATH}"

  cd "${work_dir}"
  run "${hook}"

  assert_failure 143
  run find "${test_root}" -maxdepth 1 -type d -name 'git_ssh_checkout_plugin_ssh_key.*' -print -quit
  assert_success
  assert_output ""
}
