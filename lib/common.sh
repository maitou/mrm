# shellcheck shell=bash
# Paths, backups, YAML reads, state.json 

: "${MRM_PREFIX:?MRM_PREFIX is not set}"

MRM_SHARE_PROFILES="${MRM_PREFIX}/share/profiles"
MRM_SHARE_TEMPLATES="${MRM_SHARE_PROFILES}/templates"

mrm_config_dir() {
  echo "${XDG_CONFIG_HOME:-$HOME/.config}/mrm"
}

mrm_state_json_path() {
  echo "$(mrm_config_dir)/state.json"
}

# Resolve yq when not on PATH (e.g. sudo drops ~/.local/bin; SUDO_USER still has ~/.local/bin/yq).
mrm_find_yq_executable() {
  local cand h
  for cand in /usr/local/bin/yq /usr/bin/yq /snap/bin/yq; do
    [[ -x "$cand" ]] && {
      printf '%s\n' "$cand"
      return 0
    }
  done
  if [[ -n "${SUDO_USER:-}" ]]; then
    if h=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6); then
      cand="${h}/.local/bin/yq"
      [[ -x "$cand" ]] && {
        printf '%s\n' "$cand"
        return 0
      }
    fi
  fi
  cand="${HOME}/.local/bin/yq"
  [[ -x "$cand" ]] && {
    printf '%s\n' "$cand"
    return 0
  }
  return 1
}

# Prepend PATH so `yq` resolves (sudo often omits ~/.local/bin; use SUDO_USER's tree when set).
mrm_ensure_yq_on_path() {
  command -v yq >/dev/null 2>&1 && return 0
  local yq_path
  yq_path=$(mrm_find_yq_executable) || return 0
  export PATH="$(dirname "$yq_path"):${PATH}"
}

mrm_require_yq() {
  mrm_ensure_yq_on_path
  if command -v yq >/dev/null 2>&1; then
    return 0
  fi
  echo "mrm: install yq (https://github.com/mikefarah/yq) to read groups.yaml and presets/*.yaml." >&2
  echo "mrm: hint: with sudo, put yq on root's PATH or install to /usr/local/bin; or keep yq in the invoking user's ~/.local/bin (mrm looks there when SUDO_USER is set)." >&2
  return 1
}

mrm_group_exists() {
  local b=$1
  mrm_require_yq || return 1
  yq -e "has(\"${b}\")" "${MRM_SHARE_PROFILES}/groups.yaml" >/dev/null 2>&1
}

# Resolve preset id for a group + scope from groups.yaml
mrm_group_preset() {
  local group=$1 scope=$2
  mrm_require_yq || return 1
  yq -r ".[\"${group}\"][\"${scope}\"] // \"\"" "${MRM_SHARE_PROFILES}/groups.yaml"
}

# Read a field from presets/<scope>.yaml (yq path relative to preset root, e.g. .ubuntu_uri)
mrm_preset_yq() {
  local scope=$1 preset=$2 yqpath=$3
  mrm_require_yq || return 1
  local f="${MRM_SHARE_PROFILES}/presets/${scope}.yaml"
  [[ -f "$f" ]] || return 1
  yq -r ".[\"${preset}\"]${yqpath}" "$f"
}

mrm_preset_has() {
  local scope=$1 preset=$2
  mrm_require_yq || return 1
  local f="${MRM_SHARE_PROFILES}/presets/${scope}.yaml"
  [[ -f "$f" ]] || return 1
  yq -e "has(\"${preset}\")" "$f" >/dev/null 2>&1
}

# Backup before write; prints backup path on stdout when created
mrm_backup_file() {
  local f=$1
  [[ -e "$f" ]] || return 0
  local bak="${f}.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "$f" "$bak"
  echo "$bak"
}

mrm_is_root() {
  [[ "${EUID:-0}" -eq 0 ]]
}

# Matches the snapshot taken at the top of bin/mrm (see MRM_INVOKED_VIA_SOURCE).
mrm_is_invoked_via_source() {
  [[ "${MRM_INVOKED_VIA_SOURCE:-0}" == "1" ]]
}

# Scopes whose env is persisted in rc files (e.g. go): suggest eval "$(mrm shell-env ...)" after use.
mrm_register_shell_env_hint() {
  local s=$1
  [[ -n "$s" ]] || return 0
  [[ ",${MRM_SHELL_ENV_HINTS:-}," == *",${s},"* ]] && return 0
  MRM_SHELL_ENV_HINTS="${MRM_SHELL_ENV_HINTS:+$MRM_SHELL_ENV_HINTS,}${s}"
}

mrm_flush_shell_env_hints() {
  [[ -n "${MRM_SHELL_ENV_HINTS:-}" ]] || return 0
  mrm_is_invoked_via_source && {
    unset MRM_SHELL_ENV_HINTS
    return 0
  }
  echo "mrm: shell environment (e.g. GOPROXY) is in your rc files; for this session run:" >&2
  echo "  eval \"\$(mrm shell-env --scopes=${MRM_SHELL_ENV_HINTS})\"" >&2
  echo "mrm: or next time use: mrm use ... --export-shell-env and eval that one stdout (see mrm --help)." >&2
  unset MRM_SHELL_ENV_HINTS
}

mrm_require_jq_optional() {
  command -v jq >/dev/null 2>&1
}

# Update state after a successful scope apply (optional jq; skip if missing)
mrm_state_touch_scope() {
  local scope=$1 preset=$2 target=$3
  mrm_require_jq_optional || return 0
  local f
  f=$(mrm_state_json_path)
  mkdir -p "$(dirname "$f")"
  [[ -f "$f" ]] || echo '{"version":1,"scopes":{},"last_op":{}}' >"$f"
  local tmp
  tmp=$(mktemp)
  if jq --arg s "$scope" --arg p "$preset" --arg t "$target" \
    '.scopes[$s] = {"preset": $p} | .last_op = {"verb":"use","target": $t}' "$f" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"
  fi
}

# Phase B: one line per preset preset_id<TAB>summary<TAB>hint (for ls / test)
mrm_preset_table_lines() {
  local scope=$1
  mrm_require_yq || return 1
  local f="${MRM_SHARE_PROFILES}/presets/${scope}.yaml"
  [[ -f "$f" ]] || return 0
  local pid summ hint
  while IFS= read -r pid; do
    [[ -z "$pid" || "$pid" == "null" ]] && continue
    summ=$(yq -r ".[\"${pid}\"].summary // \"\"" "$f")
    hint=$(yq -r ".[\"${pid}\"].probe // \"\"" "$f")
    printf '%s\t%s\t%s\n' "$pid" "$summ" "$hint"
  done < <(yq -r 'keys | .[]' "$f")
}

# ls --verbose: print preset fields other than summary/probe, then k3s template file if any
mrm_ls_print_verbose_preset_details() {
  local scope=$1 preset=$2
  mrm_require_yq || return 0
  local f="${MRM_SHARE_PROFILES}/presets/${scope}.yaml"
  [[ -f "$f" ]] || return 0
  local body keys_len
  body=$(yq -o=yaml ".[\"${preset}\"] | del(.summary, .probe)" "$f" 2>/dev/null) || return 0
  [[ -z "$body" || "$body" == "null" ]] && return 0
  keys_len=$(printf '%s\n' "$body" | yq 'keys | length' 2>/dev/null) || keys_len=0
  if [[ "$body" == "{}" ]] || [[ "${keys_len:-0}" -eq 0 ]]; then
    return 0
  fi
  echo "      profile:"
  while IFS= read -r line; do
    printf '        %s\n' "$line"
  done < <(printf '%s\n' "$body" | yq -o=yaml '.' 2>/dev/null)

  if [[ "$scope" == "k3s" ]]; then
    local tpl
    tpl=$(mrm_preset_yq k3s "$preset" '.template // ""' 2>/dev/null || true)
    if [[ -n "$tpl" && "$tpl" != "null" && -f "${MRM_SHARE_TEMPLATES}/${tpl}" ]]; then
      echo "      registry mirrors (template ${tpl}):"
      while IFS= read -r line; do
        printf '        %s\n' "$line"
      done < <(yq -o=yaml '.' "${MRM_SHARE_TEMPLATES}/${tpl}" 2>/dev/null)
    fi
  fi
}

# HTTP(S) reachability: one line of output; 2xx/3xx success; needs curl
mrm_http_probe() {
  local url=$1 label=$2
  local _mrm_probe_saved_e=0
  [[ $- == *e* ]] && _mrm_probe_saved_e=1
  trap 'if [[ "${_mrm_probe_saved_e}" == 1 ]]; then set -e; else set +e; fi; trap - RETURN' RETURN

  if [[ -z "$url" || "$url" == "null" ]]; then
    printf '%s: (no probe — skip)\n' "$label"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "mrm: ${label}: curl is required for test" >&2
    return 1
  fi
  local out code sec
  set +e
  out=$(curl -sS -g -o /dev/null -w "%{http_code} %{time_total}" --connect-timeout 3 -m 20 -L "$url" 2>/dev/null)
  local cr=$?
  if [[ "$cr" -ne 0 || -z "$out" ]]; then
    printf '%s: FAIL (curl err=%s) %s\n' "$label" "${cr:-?}" "$url"
    return 1
  fi
  code=${out%% *}
  sec=${out#* }
  if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
    printf '%s: OK http=%s time=%ss\n' "$label" "$code" "$sec"
    return 0
  fi
  printf '%s: FAIL http=%s time=%ss %s\n' "$label" "$code" "$sec" "$url"
  return 1
}

# Phase B: default test (reads .probe from presets)
mrm_default_test_preset_from_yaml() {
  local scope=$1 preset=$2
  mrm_require_yq || return 1
  local url
  url=$(mrm_preset_yq "$scope" "$preset" '.probe // ""') || return 1
  [[ "$url" == "null" ]] && url=""
  mrm_http_probe "$url" "${scope}/${preset}"
}
