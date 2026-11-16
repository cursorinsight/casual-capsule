#!/usr/bin/env bash

# Apple's `container` CLI runs every container in its own lightweight VM, so
# the apple backend needs macOS on Apple silicon and a running service.

# Return success when the container system service answers.
apple_system_running() {
  container system status >/dev/null 2>&1
}

# Print why this host cannot run Apple container, if anything.
apple_host_reason() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    printf '%s\n' 'Apple container needs macOS'
  elif [[ "$(uname -m)" != "arm64" ]]; then
    printf '%s\n' 'Apple container needs Apple silicon'
  elif ! command -v container >/dev/null 2>&1; then
    printf '%s\n' 'container is not installed'
  elif ! apple_system_running; then
    printf '%s\n' \
      'the container service is not running (run: container system start)'
  fi
}
