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
