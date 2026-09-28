#!/usr/bin/env bash

# Mutable profile state. initialize_profile_state resets it for each command.
PROFILE_PATHS=()
PROFILE_DIRS=()
PROFILE_NAMES=()
PROFILE_FRAGMENTS=()
PROFILE_VOLUME_SPECS=()
PROFILE_VOLUME_DIRS=()
PROFILE_PUBLISH_SPECS=()
PROFILE_HOST_SPECS=()
PROFILE_ENV_TARGETS=()
PROFILE_ENV_VALUES=()
PROFILE_ENV_FILE=""
PROFILE_RUNTIME_OPTS=()
PROFILE_GPU=""
PROFILE_NAMESPACE=""
PROFILE_BASE_PROJECT_NAME=""
PROFILE_BASE_IMAGE=""
PROFILE_IMAGE=""
PROFILE_BUILD_DIR=""
PROFILE_DOCKERFILE=""
PROFILE_EMPTY_CONTEXT=""
PROFILE_COMPOSE_OVERRIDE=""
PROFILE_HAS_FRAGMENT=0

PROFILE_PARSE_FILE=""
PROFILE_PARSE_LINE=0
PROFILE_TEXT=""
PROFILE_VALUE=""
PROFILE_ARRAY_VALUES=()

# Reset all profile state before environment and CLI options are applied.
initialize_profile_state() {
  PROFILE_PATHS=()
  PROFILE_DIRS=()
  PROFILE_NAMES=()
  PROFILE_FRAGMENTS=()
  PROFILE_VOLUME_SPECS=()
  PROFILE_VOLUME_DIRS=()
  PROFILE_PUBLISH_SPECS=()
  PROFILE_HOST_SPECS=()
  PROFILE_ENV_TARGETS=()
  PROFILE_ENV_VALUES=()
  PROFILE_ENV_FILE=""
  PROFILE_RUNTIME_OPTS=()
  PROFILE_GPU=""
  PROFILE_NAMESPACE=""
  PROFILE_BASE_PROJECT_NAME=""
  PROFILE_BASE_IMAGE=""
  PROFILE_IMAGE=""
  PROFILE_BUILD_DIR=""
  PROFILE_DOCKERFILE=""
  PROFILE_EMPTY_CONTEXT=""
  PROFILE_COMPOSE_OVERRIDE=""
  PROFILE_HAS_FRAGMENT=0
}

# Print a parser error with its profile path and source line.
profile_parse_error() {
  die "${PROFILE_PARSE_FILE}:${PROFILE_PARSE_LINE}: $*"
}

# Trim leading and trailing shell whitespace from one TOML token.
profile_trim() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# Strip a TOML comment without treating hashes inside strings as comments.
profile_strip_comment() {
  local input="$1"
  local output=""
  local quote=""
  local char=""
  local index=0

  PROFILE_TEXT=""
  while [[ "$index" -lt "${#input}" ]]; do
    char="${input:$index:1}"
    index=$((index + 1))

    if [[ -n "$quote" ]]; then
      if [[ "$quote" == '"' && "$char" == \\ ]]; then
        return 2
      fi
      output+="$char"
      if [[ "$char" == "$quote" ]]; then
        quote=""
      fi
      continue
    fi

    case "$char" in
      \#) break ;;
      "'"|'"')
        quote="$char"
        output+="$char"
        ;;
      *) output+="$char" ;;
    esac
  done

  [[ -z "$quote" ]] || return 1
  PROFILE_TEXT="$(profile_trim "$output")"
}

# Decode one supported single-line TOML string.
profile_parse_string() {
  local input=""
  local quote=""
  local value=""
  local control_check=""

  input="$(profile_trim "$1")"
  if [[ "${#input}" -lt 2 ]]; then
    return 1
  fi

  quote="${input:0:1}"
  if [[ "$quote" != '"' && "$quote" != "'" ]]; then
    return 1
  fi
  if [[ "${input:$((${#input} - 1)):1}" != "$quote" ]]; then
    return 1
  fi

  value="${input:1:$((${#input} - 2))}"
  if [[ "$value" == *"$quote"* ]]; then
    return 1
  fi
  if [[ "$quote" == '"' && "$value" == *\\* ]]; then
    return 1
  fi
  control_check="${value//$'\t'/}"
  if [[ "$control_check" =~ [[:cntrl:]] ]]; then
    return 1
  fi

  PROFILE_VALUE="$value"
}

# Return success once an array has a closing bracket outside a string.
profile_array_is_closed() {
  local input="$1"
  local quote=""
  local char=""
  local index=0

  while [[ "$index" -lt "${#input}" ]]; do
    char="${input:$index:1}"
    index=$((index + 1))
    if [[ -n "$quote" ]]; then
      if [[ "$char" == "$quote" ]]; then
        quote=""
      fi
      continue
    fi
    case "$char" in
      "'"|'"') quote="$char" ;;
      ']') return 0 ;;
    esac
  done
  return 1
}

# Decode one supported TOML array of strings.
profile_parse_array() {
  local input="$1"
  local char=""
  local quote=""
  local value=""
  local index=0
  local length="${#input}"
  local expect_value=1
  local found_value=0
  local closed=0

  PROFILE_ARRAY_VALUES=()
  [[ "${input:0:1}" == '[' ]] || return 1
  index=1

  while [[ "$index" -lt "$length" ]]; do
    char="${input:$index:1}"
    if [[ "$char" == [[:space:]] ]]; then
      index=$((index + 1))
      continue
    fi

    if [[ "$char" == ']' ]]; then
      closed=1
      index=$((index + 1))
      while [[ "$index" -lt "$length" ]]; do
        char="${input:$index:1}"
        [[ "$char" == [[:space:]] ]] || return 1
        index=$((index + 1))
      done
      break
    fi

    if [[ "$expect_value" -eq 0 ]]; then
      [[ "$char" == ',' ]] || return 1
      expect_value=1
      index=$((index + 1))
      continue
    fi

    if [[ "$char" != '"' && "$char" != "'" ]]; then
      return 1
    fi
    quote="$char"
    value=""
    index=$((index + 1))
    while [[ "$index" -lt "$length" ]]; do
      char="${input:$index:1}"
      index=$((index + 1))
      if [[ "$char" == "$quote" ]]; then
        break
      fi
      if [[ "$quote" == '"' && "$char" == \\ ]]; then
        return 1
      fi
      value+="$char"
    done
    [[ "$char" == "$quote" ]] || return 1
    if [[ "${value//$'\t'/}" =~ [[:cntrl:]] ]]; then
      return 1
    fi
    PROFILE_ARRAY_VALUES+=("$value")
    expect_value=0
    found_value=1
  done

  [[ "$closed" -eq 1 ]] || return 1
  if [[ "$expect_value" -eq 1 && "$found_value" -eq 0 ]]; then
    return 0
  fi
  return 0
}

# Read a complete array value, including following physical lines.
profile_read_array() {
  local value="$1"
  local line=""

  if [[ "$(profile_trim "$value")" != \[* ]]; then
    profile_parse_error 'invalid or unsupported string array'
  fi
  while ! profile_array_is_closed "$value"; do
    if ! IFS= read -r line <&3 && [[ -z "$line" ]]; then
      profile_parse_error 'unterminated array'
    fi
    PROFILE_PARSE_LINE=$((PROFILE_PARSE_LINE + 1))
    line="${line%$'\r'}"
    if ! profile_strip_comment "$line"; then
      profile_parse_error 'unsupported or unterminated string'
    fi
    value+=$'\n'
    value+="$PROFILE_TEXT"
  done

  if ! profile_parse_array "$value"; then
    profile_parse_error 'invalid or unsupported string array'
  fi
}

# Read the supported multiline literal used for Dockerfile content.
profile_read_dockerfile_content() {
  local line=""
  local content=""

  while IFS= read -r line <&3 || [[ -n "$line" ]]; do
    PROFILE_PARSE_LINE=$((PROFILE_PARSE_LINE + 1))
    line="${line%$'\r'}"
    if [[ "$line" == "'''" ]]; then
      PROFILE_VALUE="$content"
      return
    fi
    if [[ "$line" == *"'''"* ]]; then
      profile_parse_error "the closing ''' delimiter must be alone"
    fi
    if [[ "${line//$'\t'/}" =~ [[:cntrl:]] ]]; then
      profile_parse_error 'Dockerfile content contains a control character'
    fi
    content+="$line"
    content+=$'\n'
  done

  profile_parse_error 'unterminated Dockerfile content'
}

# Return success when an array already contains a string.
profile_array_contains() {
  local needle="$1"
  shift
  local value=""

  for value in "$@"; do
    [[ "$value" == "$needle" ]] && return 0
  done
  return 1
}

# Validate one fragment before it reaches either container builder.
validate_profile_fragment() {
  local fragment="$1"

  if printf '%s' "$fragment" | grep -Eiq \
    '^[[:space:]]*FROM([[:space:]]|$)'; then
    profile_parse_error 'Dockerfile content must not contain FROM'
  fi
  if printf '%s' "$fragment" | grep -Eiq \
    '^[[:space:]]*#[[:space:]]*(syntax|escape)='; then
    profile_parse_error 'Dockerfile content must not contain parser directives'
  fi
}

# Resolve an explicit path, user profile name, or bundled profile name.
resolve_profile_dir() {
  local requested="$1"
  local named_profile=""

  if [[ "$requested" == */* || "$requested" == "." || \
    "$requested" == ".." ]]; then
    if [[ ! -d "$requested" ]]; then
      die "profile directory not found: $requested"
    fi
    printf '%s\n' "$requested"
    return 0
  fi
  if [[ "$requested" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    for named_profile in \
      "$CAPSULE_PROFILE_HOME/$requested" \
      "$CAPSULE_ROOT/profiles/$requested"; do
      if [[ -d "$named_profile" ]]; then
        printf '%s\n' "$named_profile"
        return
      fi
    done
  fi
  die "profile name not found: $requested"
}

# Parse and merge one profile directory.
parse_profile() {
  local requested_dir="$1"
  local profile_dir=""
  local profile_file=""
  local line=""
  local key=""
  local rhs=""
  local section="top"
  local profile_name=""
  local profile_gpu=""
  local profile_namespace=""
  local profile_fragment=""
  local seen_version=0
  local seen_name=0
  local seen_volume=0
  local seen_publish=0
  local seen_host=0
  local seen_gpu=0
  local seen_namespace=0
  local seen_env=0
  local seen_dockerfile=0
  local seen_content=0
  local value=""
  local index=0
  local profile_env_targets=()
  local profile_env_values=()
  local profile_volumes=()
  local profile_publishes=()
  local profile_hosts=()

  requested_dir="$(resolve_profile_dir "$requested_dir")"
  profile_dir="$(CDPATH='' cd -- "$requested_dir" && pwd -P)"
  if profile_array_contains "$profile_dir" \
    ${PROFILE_DIRS[@]+"${PROFILE_DIRS[@]}"}; then
    warn "ignoring duplicate profile directory: $profile_dir"
    return
  fi
  profile_file="$profile_dir/capsule.toml"
  if [[ ! -f "$profile_file" || ! -r "$profile_file" ]]; then
    die "profile file is not readable: $profile_file"
  fi

  PROFILE_PARSE_FILE="$profile_file"
  PROFILE_PARSE_LINE=0
  exec 3<"$profile_file"
  while IFS= read -r line <&3 || [[ -n "$line" ]]; do
    PROFILE_PARSE_LINE=$((PROFILE_PARSE_LINE + 1))
    line="${line%$'\r'}"

    if [[ "$section" == "dockerfile" ]]; then
      value="$(profile_trim "$line")"
      if [[ -z "$value" || "$value" == \#* ]]; then
        continue
      fi
      if [[ "$seen_content" -eq 1 ]]; then
        profile_parse_error '[dockerfile] must be the final table'
      fi
      key="$(profile_trim "${value%%=*}")"
      rhs="$(profile_trim "${value#*=}")"
      if [[ "$value" != *=* || "$key" != "content" || \
        "$rhs" != "'''" ]]; then
        profile_parse_error \
          "[dockerfile] requires: content = '''"
      fi
      seen_content=1
      profile_read_dockerfile_content
      [[ -n "$PROFILE_VALUE" ]] || \
        profile_parse_error 'Dockerfile content must not be empty'
      profile_fragment="$PROFILE_VALUE"
      continue
    fi

    if ! profile_strip_comment "$line"; then
      profile_parse_error 'unsupported or unterminated string'
    fi
    [[ -n "$PROFILE_TEXT" ]] || continue

    case "$PROFILE_TEXT" in
      '[env]')
        [[ "$section" == "top" ]] || \
          profile_parse_error '[env] is duplicated or out of order'
        [[ "$seen_env" -eq 0 ]] || \
          profile_parse_error '[env] must not be reopened'
        section="env"
        seen_env=1
        continue
        ;;
      '[dockerfile]')
        [[ "$seen_dockerfile" -eq 0 ]] || \
          profile_parse_error '[dockerfile] must not be reopened'
        section="dockerfile"
        seen_dockerfile=1
        continue
        ;;
      \[*\]) profile_parse_error "unsupported table: $PROFILE_TEXT" ;;
    esac

    if [[ ! "$PROFILE_TEXT" =~ \
      ^([A-Za-z0-9_-]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      profile_parse_error 'invalid or unsupported TOML assignment'
    fi
    key="${BASH_REMATCH[1]}"
    rhs="${BASH_REMATCH[2]}"

    if [[ "$section" == "env" ]]; then
      if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        profile_parse_error "invalid environment variable name: $key"
      fi
      if profile_array_contains "$key" \
        ${profile_env_targets[@]+"${profile_env_targets[@]}"}; then
        profile_parse_error "duplicate environment variable: $key"
      fi
      if ! profile_parse_string "$rhs"; then
        profile_parse_error "invalid environment value for $key"
      fi
      # The patterns are literal interpolation markers.
      # shellcheck disable=SC2016
      if [[ "$PROFILE_VALUE" == *'${'* || \
        "$PROFILE_VALUE" == *'$${'* ]]; then
        if [[ ! "$PROFILE_VALUE" =~ \
          ^\$\{[A-Za-z_][A-Za-z0-9_]*\}$ ]] && \
          [[ ! "$PROFILE_VALUE" =~ \
          ^\$\$\{[A-Za-z_][A-Za-z0-9_]*\}$ ]]; then
          profile_parse_error "invalid partial interpolation for $key"
        fi
      fi
      profile_env_targets+=("$key")
      profile_env_values+=("$PROFILE_VALUE")
      continue
    fi

    case "$key" in
      version)
        [[ "$seen_version" -eq 0 ]] || \
          profile_parse_error 'duplicate version'
        [[ "$rhs" == 1 ]] || profile_parse_error 'version must be 1'
        seen_version=1
        ;;
      name)
        [[ "$seen_name" -eq 0 ]] || profile_parse_error 'duplicate name'
        if ! profile_parse_string "$rhs"; then
          profile_parse_error 'name must be a supported TOML string'
        fi
        profile_name="$PROFILE_VALUE"
        seen_name=1
        ;;
      volume|publish|host)
        case "$key" in
          volume)
            [[ "$seen_volume" -eq 0 ]] || \
              profile_parse_error 'duplicate volume'
            seen_volume=1
            ;;
          publish)
            [[ "$seen_publish" -eq 0 ]] || \
              profile_parse_error 'duplicate publish'
            seen_publish=1
            ;;
          host)
            [[ "$seen_host" -eq 0 ]] || \
              profile_parse_error 'duplicate host'
            seen_host=1
            ;;
        esac
        profile_read_array "$rhs"
        case "$key" in
          volume)
            profile_volumes=(
              ${PROFILE_ARRAY_VALUES[@]+"${PROFILE_ARRAY_VALUES[@]}"}
            )
            ;;
          publish)
            profile_publishes=(
              ${PROFILE_ARRAY_VALUES[@]+"${PROFILE_ARRAY_VALUES[@]}"}
            )
            ;;
          host)
            profile_hosts=(
              ${PROFILE_ARRAY_VALUES[@]+"${PROFILE_ARRAY_VALUES[@]}"}
            )
            ;;
        esac
        ;;
      gpu|namespace)
        if ! profile_parse_string "$rhs"; then
          profile_parse_error "$key must be a supported TOML string"
        fi
        if [[ "$key" == "gpu" ]]; then
          [[ "$seen_gpu" -eq 0 ]] || profile_parse_error 'duplicate gpu'
          [[ "$PROFILE_VALUE" == "all" ]] || \
            profile_parse_error 'gpu must be "all"'
          profile_gpu="$PROFILE_VALUE"
          seen_gpu=1
        else
          [[ "$seen_namespace" -eq 0 ]] || \
            profile_parse_error 'duplicate namespace'
          profile_namespace="$PROFILE_VALUE"
          seen_namespace=1
        fi
        ;;
      *) profile_parse_error "unknown top-level key: $key" ;;
    esac
  done
  exec 3<&-

  [[ "$seen_version" -eq 1 ]] || profile_parse_error 'missing version'
  [[ "$seen_name" -eq 1 ]] || profile_parse_error 'missing name'
  if [[ "$seen_dockerfile" -eq 1 && "$seen_content" -eq 0 ]]; then
    profile_parse_error '[dockerfile] requires content'
  fi
  if [[ ! "$profile_name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    profile_parse_error "invalid profile name: $profile_name"
  fi
  if profile_array_contains "$profile_name" \
    ${PROFILE_NAMES[@]+"${PROFILE_NAMES[@]}"}; then
    profile_parse_error "duplicate active profile name: $profile_name"
  fi
  if [[ -n "$profile_namespace" ]] && \
    [[ ! "$profile_namespace" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    profile_parse_error "invalid namespace: $profile_namespace"
  fi
  if [[ "$seen_namespace" -eq 1 && -z "$profile_namespace" ]]; then
    profile_parse_error 'namespace must not be empty'
  fi
  if [[ -n "$profile_namespace" && -n "$PROFILE_NAMESPACE" ]] && \
    [[ "$profile_namespace" != "$PROFILE_NAMESPACE" ]]; then
    profile_parse_error \
      "conflicting namespace: $profile_namespace and $PROFILE_NAMESPACE"
  fi
  if [[ -n "$profile_gpu" && -n "$PROFILE_GPU" ]] && \
    [[ "$profile_gpu" != "$PROFILE_GPU" ]]; then
    profile_parse_error "conflicting gpu request: $profile_gpu"
  fi

  if [[ -n "$profile_fragment" ]]; then
    validate_profile_fragment "$profile_fragment"
    PROFILE_HAS_FRAGMENT=1
  fi
  [[ -z "$profile_namespace" ]] || PROFILE_NAMESPACE="$profile_namespace"
  [[ -z "$profile_gpu" ]] || PROFILE_GPU="$profile_gpu"
  PROFILE_DIRS+=("$profile_dir")
  PROFILE_NAMES+=("$profile_name")
  PROFILE_FRAGMENTS+=("$profile_fragment")

  index=0
  while [[ -n "${profile_volumes[$index]+set}" ]]; do
    value="${profile_volumes[$index]}"
    [[ -n "$value" ]] || profile_parse_error 'empty volume entry'
    PROFILE_VOLUME_SPECS+=("$value")
    PROFILE_VOLUME_DIRS+=("$profile_dir")
    index=$((index + 1))
  done
  for value in ${profile_publishes[@]+"${profile_publishes[@]}"}; do
    [[ -n "$value" ]] || profile_parse_error 'empty publish entry'
    PROFILE_PUBLISH_SPECS+=("$value")
  done
  for value in ${profile_hosts[@]+"${profile_hosts[@]}"}; do
    [[ -n "$value" ]] || profile_parse_error 'empty host entry'
    PROFILE_HOST_SPECS+=("$value")
  done
  index=0
  while [[ -n "${profile_env_targets[$index]+set}" ]]; do
    PROFILE_ENV_TARGETS+=("${profile_env_targets[$index]}")
    PROFILE_ENV_VALUES+=("${profile_env_values[$index]}")
    index=$((index + 1))
  done
}

# Append semicolon-separated profiles from CAPSULE_PROFILES.
apply_profile_env() {
  local paths="${CAPSULE_PROFILES:-}"
  local path=""

  while [[ "$paths" == *';'* ]]; do
    path="${paths%%;*}"
    [[ -z "$path" ]] || PROFILE_PATHS+=("$path")
    paths="${paths#*;}"
  done
  [[ -z "$paths" ]] || PROFILE_PATHS+=("$paths")
  return 0
}

# Parse every selected profile in effective order.
configure_profiles() {
  local profile_path=""

  for profile_path in ${PROFILE_PATHS[@]+"${PROFILE_PATHS[@]}"}; do
    [[ -n "$profile_path" ]] || \
      die '--profile requires a name or directory path'
    parse_profile "$profile_path"
  done
}

# Apply the selected namespace to backend-owned names and persistent state.
apply_profile_namespace() {
  local project_name=""

  project_name="${COMPOSE_PROJECT_NAME:-}"
  if [[ -z "$project_name" ]]; then
    project_name="${CAPSULE_COMPOSE_PROJECT_NAME:-casual-capsule}"
  fi
  export PROFILE_BASE_PROJECT_NAME="$project_name"
  PROFILE_BASE_IMAGE="${project_name}-cli:latest"
  if [[ -n "$PROFILE_NAMESPACE" ]]; then
    project_name="${project_name}-${PROFILE_NAMESPACE}"
    if [[ -z "${CAPSULE_HOME_VOLUME:-}" ]]; then
      CAPSULE_HOME_VOLUME="${DEFAULT_PODMAN_HOME_VOLUME}-${PROFILE_NAMESPACE}"
      export CAPSULE_HOME_VOLUME
    fi
  fi
  export CAPSULE_COMPOSE_PROJECT_NAME="$project_name"
}

# Return a stable token for the ordered canonical profile paths.
profile_set_token() {
  local checksum=""

  checksum="$(
    printf '%s\n' ${PROFILE_DIRS[@]+"${PROFILE_DIRS[@]}"} | cksum | \
      cut -d' ' -f1
  )"
  printf '%08x\n' "$checksum"
}

# Return a stable token for every input affecting generated profile files.
profile_artifact_token() {
  local checksum=""
  local value=""

  checksum="$(
    {
      printf 'format\0%s\0' '1'
      printf 'base-image\0%s\0' "$PROFILE_BASE_IMAGE"
      printf 'image\0%s\0' "$PROFILE_IMAGE"
      printf 'has-fragment\0%s\0' "$PROFILE_HAS_FRAGMENT"
      for value in ${PROFILE_DIRS[@]+"${PROFILE_DIRS[@]}"}; do
        printf 'directory\0%s\0' "$value"
      done
      for value in ${PROFILE_NAMES[@]+"${PROFILE_NAMES[@]}"}; do
        printf 'name\0%s\0' "$value"
      done
      for value in ${PROFILE_FRAGMENTS[@]+"${PROFILE_FRAGMENTS[@]}"}; do
        printf 'fragment\0%s\0' "$value"
      done
      for value in ${PROFILE_HOST_SPECS[@]+"${PROFILE_HOST_SPECS[@]}"}; do
        printf 'host\0%s\0' "$value"
      done
    } | cksum | cut -d' ' -f1
  )"
  printf '%08x\n' "$checksum"
}

# Create the generated Dockerfile and Compose image override.
generate_profile_build_files() {
  local cache_home="${XDG_CACHE_HOME:-$HOME/.cache}"
  local artifact_token=""
  local base_image_checksum=""
  local base_image_token=""
  local image_prefix=""
  local image_repository=""
  local image_suffix=""
  local unqualified_repository_limit=237
  local token=""
  local profile_names=""
  local profile_names_checksum=""
  local profile_names_token=""
  local index=0
  local complete_marker=""
  local dockerfile_tmp=""
  local compose_tmp=""
  local marker_tmp=""

  if [[ "$PROFILE_HAS_FRAGMENT" -eq 0 && -z "$PROFILE_NAMESPACE" ]] && \
    [[ -z "${PROFILE_HOST_SPECS[0]+set}" ]]; then
    return 0
  fi
  token="$(profile_set_token)"
  if [[ "$PROFILE_HAS_FRAGMENT" -eq 1 ]]; then
    profile_names="$(IFS=-; printf '%s' "${PROFILE_NAMES[*]}")"
    image_prefix="${CAPSULE_COMPOSE_PROJECT_NAME:-casual-capsule}-p-"
    image_suffix="-${token}"
    if [[ "$RUNTIME_BACKEND" == "podman" ]]; then
      base_image_checksum="$(
        printf '%s\0' "$PROFILE_BASE_IMAGE" | cksum | cut -d' ' -f1
      )"
      printf -v base_image_token '%08x' "$base_image_checksum"
      image_suffix="${image_suffix}-${base_image_token}"
    fi
    image_repository="${image_prefix}${profile_names}${image_suffix}"
    # Docker normalizes unqualified names below docker.io/library/.
    if [[ "${#image_repository}" -gt "$unqualified_repository_limit" ]]; then
      profile_names_checksum="$(
        printf '%s\0' "${PROFILE_NAMES[@]}" | cksum | cut -d' ' -f1
      )"
      printf -v profile_names_token '%08x' "$profile_names_checksum"
      image_repository="${image_prefix}${profile_names_token}${image_suffix}"
    fi
    if [[ "${#image_repository}" -gt "$unqualified_repository_limit" ]]; then
      die 'Compose project name is too long for a profile image'
    fi
    PROFILE_IMAGE="${image_repository}:local"
  else
    PROFILE_IMAGE="$PROFILE_BASE_IMAGE"
  fi
  artifact_token="$(profile_artifact_token)"
  PROFILE_BUILD_DIR="$cache_home/capsule/profiles/$token/$artifact_token"
  PROFILE_DOCKERFILE="$PROFILE_BUILD_DIR/Dockerfile"
  PROFILE_EMPTY_CONTEXT="$PROFILE_BUILD_DIR/context"
  PROFILE_COMPOSE_OVERRIDE="$PROFILE_BUILD_DIR/compose.yml"
  complete_marker="$PROFILE_BUILD_DIR/.complete"
  if [[ -f "$complete_marker" && -d "$PROFILE_EMPTY_CONTEXT" ]] && \
    [[ "$PROFILE_HAS_FRAGMENT" -eq 0 || -f "$PROFILE_DOCKERFILE" ]] && \
    [[ -f "$PROFILE_COMPOSE_OVERRIDE" ]]; then
    return 0
  fi

  mkdir -p "$PROFILE_EMPTY_CONTEXT"
  rm -f "$complete_marker"
  dockerfile_tmp="$PROFILE_BUILD_DIR/.Dockerfile.$$"
  compose_tmp="$PROFILE_BUILD_DIR/.compose.yml.$$"
  marker_tmp="$PROFILE_BUILD_DIR/.complete.$$"

  if [[ "$PROFILE_HAS_FRAGMENT" -eq 1 ]]; then
    {
      printf '%s\n' '# syntax=docker/dockerfile:1'
      printf 'ARG CAPSULE_BASE_IMAGE=%s\n' "$PROFILE_BASE_IMAGE"
      # The generated Dockerfile expands this build argument.
      # shellcheck disable=SC2016
      printf '%s\n' 'FROM ${CAPSULE_BASE_IMAGE}'
      while [[ -n "${PROFILE_NAMES[$index]+set}" ]]; do
        if [[ -n "${PROFILE_FRAGMENTS[$index]}" ]]; then
          printf '\n# profile: %s\n' "${PROFILE_NAMES[$index]}"
          printf '%s' "${PROFILE_FRAGMENTS[$index]}"
        fi
        index=$((index + 1))
      done
    } >"$dockerfile_tmp"
  fi

  {
    printf '%s\n' 'services:'
    printf '%s\n' '  cli:'
    printf '    image: %s\n' "$PROFILE_IMAGE"
    if [[ -n "${PROFILE_HOST_SPECS[0]+set}" ]]; then
      printf '%s\n' '    extra_hosts:'
      for spec in "${PROFILE_HOST_SPECS[@]}"; do
        printf "      - '%s'\n" "${spec//\'/\'\'}"
      done
    fi
  } >"$compose_tmp"

  if [[ "$PROFILE_HAS_FRAGMENT" -eq 1 ]]; then
    mv -f "$dockerfile_tmp" "$PROFILE_DOCKERFILE"
  fi
  mv -f "$compose_tmp" "$PROFILE_COMPOSE_OVERRIDE"
  printf '%s\n' '1' >"$marker_tmp"
  mv -f "$marker_tmp" "$complete_marker"
}

# Return the image name produced by the base Docker Compose build.
docker_base_image_name() {
  printf '%s\n' "$PROFILE_BASE_IMAGE"
}

# Build the generated profile image with the selected backend.
run_profile_build() {
  local engine="$1"
  local base_image="$2"
  local build_args=()
  local index=0

  [[ "$PROFILE_HAS_FRAGMENT" -eq 1 ]] || return 0
  build_args=(build)
  if [[ "$engine" == "podman" ]]; then
    build_args+=(--format docker)
  fi
  build_args+=(
    --tag "$PROFILE_IMAGE"
    --build-arg "CAPSULE_BASE_IMAGE=${base_image}"
    --file "$PROFILE_DOCKERFILE"
  )
  if [[ "$NO_CACHE" -eq 1 ]]; then
    build_args+=(--no-cache)
  fi
  if [[ -n "${GITHUB_API_TOKEN:+set}" ]]; then
    build_args+=(--secret "id=github_api_token,env=GITHUB_API_TOKEN")
  fi
  while [[ -n "${PROFILE_NAMES[$index]+set}" ]]; do
    build_args+=(
      --build-context
      "${PROFILE_NAMES[$index]}=${PROFILE_DIRS[$index]}"
    )
    index=$((index + 1))
  done
  build_args+=("$PROFILE_EMPTY_CONTEXT")
  "$engine" "${build_args[@]}"
}

# Resolve a profile volume source to an absolute launcher-visible path.
profile_absolute_source() {
  local source="$1"
  local profile_dir="$2"
  local base_dir=""
  local parent_dir=""
  local leaf=""
  local tilde="~"

  if [[ -n "$REMOTE_HOST" && "$source" != /* ]] && \
    [[ "$source" != "~" && "$source" != "$tilde/"* ]]; then
    die "relative profile volume source is unsupported with --remote: $source"
  fi

  if [[ "$source" == "~" ]]; then
    if [[ -n "$REMOTE_HOST" ]]; then
      # Expand HOME on the remote host, not in this shell.
      # shellcheck disable=SC2016
      base_dir="$(run_remote_ssh 'printf "%s\n" "$HOME"')"
      [[ -n "$base_dir" ]] || \
        die 'failed to resolve remote home for profile volume'
      printf '%s\n' "$base_dir"
      return
    fi
    source="$HOME"
  elif [[ "$source" == "$tilde/"* ]]; then
    if [[ -n "$REMOTE_HOST" ]]; then
      # Expand HOME on the remote host, not in this shell.
      # shellcheck disable=SC2016
      base_dir="$(run_remote_ssh 'printf "%s\n" "$HOME"')"
      [[ -n "$base_dir" ]] || \
        die 'failed to resolve remote home for profile volume'
      printf '%s/%s\n' "$base_dir" "${source#"$tilde/"}"
      return
    fi
    source="$HOME/${source#"$tilde/"}"
  elif [[ "$source" != /* ]]; then
    source="$profile_dir/$source"
  fi

  if [[ -n "$REMOTE_HOST" && "$source" == /* ]]; then
    printf '%s\n' "$source"
    return
  fi

  parent_dir="$(dirname -- "$source")"
  leaf="$(basename -- "$source")"
  if [[ ! -d "$parent_dir" ]]; then
    die "profile volume parent directory not found: $parent_dir"
  fi
  parent_dir="$(CDPATH='' cd -- "$parent_dir" && pwd -P)"
  if [[ "$leaf" == "." ]]; then
    printf '%s\n' "$parent_dir"
  else
    printf '%s/%s\n' "$parent_dir" "$leaf"
  fi
}

# Map a launcher-visible source to the path seen by the selected daemon.
profile_daemon_source() {
  local source="$1"
  local home_dir="${HOME%/}"
  local home_host_dir="${CAPSULE_HOME_HOST_DIR:-}"
  local relative_source=""
  local mapped=""

  [[ -n "$home_dir" ]] || home_dir="/"

  if [[ -n "$REMOTE_HOST" || "$RUNTIME_BACKEND" == "podman" ]]; then
    printf '%s\n' "$source"
    return
  fi

  if [[ "$IN_NESTED_CAPSULE" -eq 1 ]]; then
    if [[ "$source" == "$home_dir" ]] || \
      [[ "$home_dir" == "/" && "$source" == /* ]] || \
      [[ "$source" == "$home_dir/"* ]]; then
      if [[ -z "$home_host_dir" ]]; then
        die "profile volume source under $home_dir inside Capsule requires" \
          'CAPSULE_HOME_HOST_DIR; use --private-home on the outer Capsule'
      fi
      if [[ "$home_host_dir" != /* ]]; then
        die "CAPSULE_HOME_HOST_DIR must be absolute: $home_host_dir"
      fi
      if [[ "$source" == "$home_dir" ]]; then
        printf '%s\n' "$home_host_dir"
        return
      fi
      if [[ "$home_dir" == "/" ]]; then
        relative_source="${source#/}"
      else
        relative_source="${source#"$home_dir/"}"
      fi
      printf '%s/%s\n' "${home_host_dir%/}" "$relative_source"
      return
    fi
    if [[ "$source" == "$CAPSULE_CONTAINER_WORKDIR" ]]; then
      printf '%s\n' "$CAPSULE_HOST_WORKDIR"
      return
    fi
    if [[ "$source" == "$CAPSULE_CONTAINER_WORKDIR"/* ]]; then
      printf '%s%s\n' \
        "$CAPSULE_HOST_WORKDIR" \
        "${source#"$CAPSULE_CONTAINER_WORKDIR"}"
      return
    fi
  fi

  if mapped="$(resolve_host_path_map "$source")"; then
    printf '%s\n' "$mapped"
    return
  fi
  printf '%s\n' "$source"
}

# Add one profile volume and retain its host-visible path for nested runs.
append_profile_volume() {
  local spec="$1"
  local profile_dir="$2"
  local source=""
  local destination_spec=""
  local destination=""
  local absolute_source=""
  local daemon_source=""

  if [[ "$spec" != *:* ]]; then
    die "profile volume requires HOST:CONTAINER[:OPTIONS]: $spec"
  fi
  source="${spec%%:*}"
  destination_spec="${spec#*:}"
  destination="${destination_spec%%:*}"
  if [[ -z "$source" || "$destination" != /* ]]; then
    die "invalid profile volume: $spec"
  fi

  absolute_source="$(profile_absolute_source "$source" "$profile_dir")"
  daemon_source="$(profile_daemon_source "$absolute_source")"
  PROFILE_RUNTIME_OPTS+=(
    --volume "${daemon_source}:${destination_spec}"
  )
}

# Remove the per-run file containing resolved profile environment values.
cleanup_profile_environment() {
  if [[ -n "$PROFILE_ENV_FILE" ]]; then
    rm -f "$PROFILE_ENV_FILE"
    PROFILE_ENV_FILE=""
  fi
}

# Create a private file for resolved profile environment values.
initialize_profile_environment() {
  local cache_home="${XDG_CACHE_HOME:-$HOME/.cache}"
  local runtime_dir=""

  if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
    runtime_dir="$XDG_RUNTIME_DIR/capsule"
  else
    runtime_dir="$cache_home/capsule/runtime"
  fi
  mkdir -p "$runtime_dir"
  chmod 700 "$runtime_dir"
  PROFILE_ENV_FILE="$(mktemp "$runtime_dir/profile-env.XXXXXX")"
  chmod 600 "$PROFILE_ENV_FILE"
  trap cleanup_runtime_state EXIT INT TERM
}

# Write one resolved value without exposing it in process arguments.
write_profile_environment() {
  local target="$1"
  local value="$2"
  local escaped=""

  if [[ -z "$PROFILE_ENV_FILE" ]]; then
    initialize_profile_environment
  fi
  if [[ "$RUNTIME_BACKEND" == "podman" ]]; then
    if [[ "$value" == *$'\n'* ]]; then
      die "profile environment value contains a newline: $target"
    fi
    (
      set +x
      printf '%s=%s\n' "$target" "$value" >>"$PROFILE_ENV_FILE"
    )
    return
  fi

  escaped="${value//\'/\\\'}"
  (
    set +x
    printf "%s='%s'\n" "$target" "$escaped" >>"$PROFILE_ENV_FILE"
  )
}

# Resolve one environment value without invoking a shell evaluator.
append_profile_environment() {
  local xtrace_enabled=0

  if [[ "$-" == *x* ]]; then
    set +x
    xtrace_enabled=1
  fi

  local target="$1"
  local value="$2"
  local source=""
  local value_is_set=1
  local reference_re='^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$'
  local escaped_re='^\$\$\{([A-Za-z_][A-Za-z0-9_]*)\}$'
  local marker="\${"
  local escaped_marker="\$\${"

  if [[ "$value" =~ $escaped_re ]]; then
    source="${BASH_REMATCH[1]}"
    value="\${${source}}"
  elif [[ "$value" =~ $reference_re ]]; then
    source="${BASH_REMATCH[1]}"
    if value="$(
      printenv "$source"
      printenv_status=$?
      printf '\001'
      exit "$printenv_status"
    )"; then
      value="${value%$'\n\001'}"
    else
      value_is_set=0
    fi
  elif [[ "$value" == *"$marker"* || \
    "$value" == *"$escaped_marker"* ]]; then
    die "invalid partial profile interpolation for $target"
  fi

  if [[ "$value_is_set" -eq 1 ]]; then
    write_profile_environment "$target" "$value"
  fi
  if [[ "$xtrace_enabled" -eq 1 ]]; then
    set -x
  fi
}

# Translate merged profile runtime settings into backend-neutral CLI options.
configure_profile_runtime() {
  local index=0
  local spec=""
  local name=""
  local address=""
  local seen_host_names=()
  local seen_host_addresses=()
  local seen_index=0

  PROFILE_RUNTIME_OPTS=()
  while [[ -n "${PROFILE_ENV_TARGETS[$index]+set}" ]]; do
    append_profile_environment \
      "${PROFILE_ENV_TARGETS[$index]}" \
      "${PROFILE_ENV_VALUES[$index]}"
    index=$((index + 1))
  done
  if [[ -n "$PROFILE_ENV_FILE" ]]; then
    if [[ "$RUNTIME_BACKEND" == "podman" ]]; then
      PROFILE_RUNTIME_OPTS+=(--env-file "$PROFILE_ENV_FILE")
    else
      PROFILE_RUNTIME_OPTS+=(--env-from-file "$PROFILE_ENV_FILE")
    fi
  fi
  for spec in ${PROFILE_PUBLISH_SPECS[@]+"${PROFILE_PUBLISH_SPECS[@]}"}; do
    PROFILE_RUNTIME_OPTS+=(--publish "$spec")
  done
  for spec in ${PROFILE_HOST_SPECS[@]+"${PROFILE_HOST_SPECS[@]}"}; do
    if [[ "$spec" != *=* ]]; then
      die "profile host requires NAME=ADDRESS: $spec"
    fi
    name="${spec%%=*}"
    address="${spec#*=}"
    if [[ -z "$name" || -z "$address" ]] || \
      [[ "$name" == *[[:space:]]* || "$address" == *[[:space:]]* ]]; then
      die "invalid profile host mapping: $spec"
    fi
    seen_index=0
    while [[ -n "${seen_host_names[$seen_index]+set}" ]]; do
      if [[ "${seen_host_names[$seen_index]}" == "$name" ]] && \
        [[ "${seen_host_addresses[$seen_index]}" != "$address" ]]; then
        die "conflicting profile host mapping: $name"
      fi
      seen_index=$((seen_index + 1))
    done
    seen_host_names+=("$name")
    seen_host_addresses+=("$address")
    if [[ "$RUNTIME_BACKEND" == "podman" ]]; then
      PROFILE_RUNTIME_OPTS+=(--add-host "${name}:${address}")
    fi
  done
  index=0
  while [[ -n "${PROFILE_VOLUME_SPECS[$index]+set}" ]]; do
    append_profile_volume \
      "${PROFILE_VOLUME_SPECS[$index]}" \
      "${PROFILE_VOLUME_DIRS[$index]}"
    index=$((index + 1))
  done
}
