# shellcheck shell=bash

mrm_scope_docker_metadata() {
  cat <<'EOF'
title=Docker Engine registry-mirrors
description=Merges registry-mirrors into /etc/docker/daemon.json
requires_root=1
EOF
}

mrm_scope_docker_requires_root() {
  echo 1
}

mrm_scope_docker_daemon() {
  echo "/etc/docker/daemon.json"
}

mrm_scope_docker__cn_mirrors_json() {
  mrm_require_yq || return 1
  yq -o=json '.["chinese"].registry_mirrors' "${MRM_SHARE_PROFILES}/presets/docker.yaml"
}

mrm_scope_docker_restart() {
  if systemctl is-active --quiet docker.service 2>/dev/null || systemctl is-active --quiet docker 2>/dev/null; then
    echo "mrm(docker): restarting docker.service…" >&2
    systemctl restart docker.service 2>/dev/null || systemctl restart docker 2>/dev/null || {
      echo "mrm(docker): systemctl restart docker failed" >&2
      return 1
    }
    return 0
  fi
  echo "mrm(docker): docker.service not active under systemd; restart Docker manually to apply daemon.json." >&2
  return 0
}

mrm_scope_docker_get_state() {
  if ! command -v yq >/dev/null 2>&1; then
    echo "state=unknown"
    echo "preset="
    echo "detail=yq required"
    return 0
  fi
  local d
  d=$(mrm_scope_docker_daemon)
  if [[ ! -f "$d" ]]; then
    echo "state=default"
    echo "preset=official"
    echo "detail=no daemon.json"
    return 0
  fi
  command -v jq >/dev/null 2>&1 || {
    echo "state=unknown"
    echo "preset="
    echo "detail=jq required to parse daemon.json"
    return 0
  }
  local cnj
  cnj=$(mrm_scope_docker__cn_mirrors_json) || {
    echo "state=unknown"
    echo "preset="
    echo "detail=cannot read preset"
    return 0
  }
  # Docker Engine expects "registry-mirrors" (hyphen). Older mrm builds wrongly used
  # "registry_mirrors"; merge both when inferring state.
  local m
  for m in $(yq -r '.["chinese"].registry_mirrors[]' "${MRM_SHARE_PROFILES}/presets/docker.yaml" 2>/dev/null); do
    if jq -e --arg m "$m" '
      ((.["registry-mirrors"] // []) + (.registry_mirrors // [])) | index($m) != null
    ' "$d" >/dev/null 2>&1; then
      echo "state=cn"
      echo "preset=chinese"
      echo "detail=registry-mirrors contains CN mirror endpoint"
      return 0
    fi
  done
  # Any non-empty registry-mirrors (or legacy key) means Hub is mirrored; show mixed if not our CN list.
  if jq -e '
    ((.["registry-mirrors"] // []) + (.registry_mirrors // []) | length) > 0
  ' "$d" >/dev/null 2>&1; then
    echo "state=mixed"
    echo "preset="
    echo "detail=registry-mirrors set but no built-in chinese preset URL matched"
    return 0
  fi
  echo "state=default"
  echo "preset=official"
  echo "detail=no registry-mirrors (or empty)"
}

# Hostnames (no scheme) from daemon.json mirror URLs.
mrm_scope_docker__daemon_mirror_hosts() {
  local d=$1
  [[ -f "$d" ]] || return 0
  jq -r '((.["registry-mirrors"] // []) + (.registry_mirrors // [])) | .[]' "$d" 2>/dev/null |
    sed -e 's|^https\?://||' -e 's|/.*$||' -e 's|:.*$||'
}

# True if every non-empty mirror host from daemon.json appears in `docker info` output (running config).
mrm_scope_docker__running_engine_lists_daemon_mirrors() {
  local d=$1
  command -v docker >/dev/null 2>&1 || return 1
  local inf
  inf=$(docker info 2>/dev/null) || return 1
  local h ok=0
  while IFS= read -r h; do
    [[ -z "$h" ]] && continue
    ok=1
    grep -qF "$h" <<<"$inf" || return 1
  done < <(mrm_scope_docker__daemon_mirror_hosts "$d")
  # No mirrors in file: nothing to match
  [[ "$ok" -eq 0 ]] && return 0
  return 0
}

mrm_scope_docker__inferred_preset() {
  local k v pr=""
  while IFS= read -r line; do
    k=${line%%=*}
    v=${line#*=}
    [[ "$k" == preset ]] && pr="$v"
  done < <(mrm_scope_docker_get_state 2>/dev/null)
  printf '%s' "$pr"
}

# If the requested preset matches inferred state, validate the live Engine (docker pull).
# Otherwise only HTTP-probe the preset's .probe URL (YAML), since the daemon is not on that preset.
mrm_scope_docker_test_preset() {
  local preset=$1 inferred
  case "$preset" in
    official|chinese) ;;
    *)
      echo "mrm(docker-test): unknown preset: ${preset}" >&2
      return 1
      ;;
  esac
  inferred=$(mrm_scope_docker__inferred_preset)
  if [[ -n "$inferred" && "$inferred" == "$preset" ]]; then
    echo "mrm(docker-test): ${preset} matches inferred preset → Engine probe (docker pull)" >&2
    mrm_scope_docker__engine_probe "$preset"
  else
    echo "mrm(docker-test): ${preset} is not the inferred preset (${inferred:-none}) → HTTP probe only (.probe in presets/docker.yaml)" >&2
    mrm_default_test_preset_from_yaml docker "$preset"
  fi
}

mrm_scope_docker__engine_probe() {
  local mode=$1
  local d ref
  d=$(mrm_scope_docker_daemon)
  ref="docker.io/library/busybox:1.36"

  command -v docker >/dev/null 2>&1 || {
    echo "mrm(docker-test): docker CLI not found; install Docker client to validate Engine." >&2
    return 1
  }
  if command -v timeout >/dev/null 2>&1; then
    if ! timeout 8 docker version >/dev/null 2>&1; then
      echo "mrm(docker-test): FAIL docker version (Engine unreachable? start docker or check DOCKER_HOST)" >&2
      return 1
    fi
  elif ! docker version >/dev/null 2>&1; then
    echo "mrm(docker-test): FAIL docker version (Engine unreachable?)" >&2
    return 1
  fi

  if [[ "$mode" == "chinese" ]]; then
    if [[ ! -f "$d" ]]; then
      echo "mrm(docker-test): FAIL chinese preset expects ${d} with registry-mirrors" >&2
      return 1
    fi
    if ! jq -e '((.["registry-mirrors"] // []) + (.registry_mirrors // [])) | length > 0' "$d" >/dev/null 2>&1; then
      echo "mrm(docker-test): FAIL daemon.json has no registry-mirrors for chinese preset" >&2
      return 1
    fi
    if ! mrm_scope_docker__running_engine_lists_daemon_mirrors "$d"; then
      echo "mrm(docker-test): FAIL mirror hosts in ${d} are not all listed in docker info (daemon.json not applied?)." >&2
      echo "mrm(docker-test): hint: sudo systemctl restart docker" >&2
      return 1
    fi
  fi

  # Use docker pull (daemon + registry-mirrors). `docker manifest inspect` often talks to the registry
  # from the CLI and can bypass mirrors or hit Moby issues with mirrors (see moby/moby#47012).
  echo "mrm(docker-test): docker pull -q ${ref} (Hub via Engine; registry-mirrors apply here)" >&2
  local rc
  set +e
  if command -v timeout >/dev/null 2>&1; then
    DOCKER_CONTENT_TRUST=0 timeout 90 docker pull -q "$ref" >/dev/null 2>&1
    rc=$?
    if [[ "$rc" -eq 124 ]]; then
      echo "mrm(docker-test): FAIL docker pull timed out (90s) for ${ref}" >&2
      set -e
      return 1
    fi
  else
    echo "mrm(docker-test): WARN no timeout(1); docker pull without time limit" >&2
    DOCKER_CONTENT_TRUST=0 docker pull -q "$ref" >/dev/null 2>&1
    rc=$?
  fi
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "mrm(docker-test): FAIL docker pull ${ref} (exit ${rc}); Engine could not fetch Hub image (mirrors or network)" >&2
    return 1
  fi
  if [[ "$mode" == "chinese" ]]; then
    printf 'docker/chinese: OK (Engine docker pull %s; mirrors listed in docker info)\n' "$ref"
  else
    printf 'docker/official: OK (Engine docker pull %s)\n' "$ref"
  fi
  return 0
}

mrm_scope_docker_apply_preset() {
  local preset=$1
  mrm_is_root || {
    echo "mrm(docker): root required to write $(mrm_scope_docker_daemon)" >&2
    return 2
  }
  if ! command -v jq >/dev/null 2>&1; then
    echo "mrm(docker): jq required" >&2
    return 1
  fi
  local d tmp wrote=0
  d=$(mrm_scope_docker_daemon)
  mkdir -p /etc/docker

  case "$preset" in
    chinese)
      local cnj merged cur
      cnj=$(mrm_scope_docker__cn_mirrors_json) || return 1
      if [[ -f "$d" ]]; then
        merged=$(jq -c --argjson cn "$cnj" '
          .["registry-mirrors"] = ((.["registry-mirrors"] // []) + (.registry_mirrors // []) + $cn | unique)
          | del(.registry_mirrors)
        ' "$d")
        cur=$(jq -c . "$d")
        if [[ "$merged" == "$cur" ]]; then
          echo "already using docker/chinese" >&2
          return 0
        fi
        mrm_backup_file "$d" >/dev/null
        jq --argjson cn "$cnj" '
          .["registry-mirrors"] = ((.["registry-mirrors"] // []) + (.registry_mirrors // []) + $cn | unique)
          | del(.registry_mirrors)
        ' "$d" >"${d}.tmp" && mv "${d}.tmp" "$d"
        wrote=1
      else
        jq -n --argjson cn "$cnj" '{"registry-mirrors": $cn}' >"$d"
        chmod 0644 "$d"
        wrote=1
      fi
      ;;
    official)
      [[ -f "$d" ]] || {
        echo "already using docker/official" >&2
        return 0
      }
      local cnj
      cnj=$(mrm_scope_docker__cn_mirrors_json) || return 1
      local filtered
      filtered=$(jq -c --argjson cn "$cnj" '
        (
          ((.["registry-mirrors"] // []) + (.registry_mirrors // []))
          | map(select(. as $m | ($cn | index($m)) == null))
          | unique
        ) as $kept
        | if ($kept | length) == 0 then
            del(.["registry-mirrors"]) | del(.registry_mirrors)
          else
            .["registry-mirrors"] = $kept | del(.registry_mirrors)
          end
      ' "$d")
      cur=$(jq -c . "$d")
      if [[ "$cur" == "$filtered" ]]; then
        echo "already using docker/official" >&2
        return 0
      fi
      mrm_backup_file "$d" >/dev/null
      echo "$filtered" >"${d}.tmp" && mv "${d}.tmp" "$d"
      wrote=1
      ;;
    *)
      echo "mrm(docker): unknown preset: ${preset}" >&2
      return 1
      ;;
  esac
  if [[ "$wrote" -eq 1 ]]; then
    mrm_scope_docker_restart || true
  fi
  return 0
}

mrm_scope_docker_apply_group() {
  local group=$1 p
  p=$(mrm_group_preset "$group" "docker") || return 1
  [[ -n "$p" && "$p" != "null" ]] || return 1
  mrm_scope_docker_apply_preset "$p"
}

mrm_scope_docker_list_presets() {
  mrm_preset_table_lines docker
}
