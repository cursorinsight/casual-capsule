#!/usr/bin/env bash

podman_info_summary() {
  local format='{{.Host.Security.Rootless}} {{.Host.OCIRuntime.Name}}'
  format+=$'\n{{range .Host.IDMappings.UIDMap}}uid {{.Size}}\n{{end}}'
  format+=$'{{range .Host.IDMappings.GIDMap}}gid {{.Size}}\n{{end}}'

  podman info --format "$format" 2>/dev/null | awk '
    NR == 1 { rootless = $1; runtime = $2 }
    $1 == "uid" { uid_count += $2 }
    $1 == "gid" { gid_count += $2 }
    END {
      if (NR > 0)
        printf "%s %.0f %.0f %s\n", rootless, uid_count, gid_count, runtime
    }
  '
}

podman_host_reason() {
  local info="$1"
  local rootless=""
  local uid_count=""
  local gid_count=""
  local _runtime=""

  if [[ -z "$info" ]]; then
    printf '%s\n' 'podman cannot reach a working engine (try: podman info)'
    return
  fi
  read -r rootless uid_count gid_count _runtime <<<"$info"
  if [[ "$rootless" != "true" ]]; then
    printf '%s\n' 'podman is running rootful; the Capsule wants rootless'
    return
  fi
  if [[ ! "$uid_count" =~ ^[0-9]+$ ]] || [[ "$uid_count" -lt 65537 ]]; then
    printf 'insufficient subordinate %s (need 65536; install uidmap)\n' UIDs
    return
  fi
  if [[ ! "$gid_count" =~ ^[0-9]+$ ]] || [[ "$gid_count" -lt 65537 ]]; then
    printf 'insufficient subordinate %s (need 65536; install uidmap)\n' GIDs
  fi
}
