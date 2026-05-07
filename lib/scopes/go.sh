# shellcheck shell=bash

mrm_scope_go_metadata() {
  cat <<'EOF'
title=Go GOPROXY / GOSUMDB
description=Injects or removes mrm-marked blocks in shell rc files
requires_root=0
EOF
}

mrm_scope_go_requires_root() {
  echo 0
}

mrm_scope_go_marker_begin() { echo '# >>> mrm begin >>>'; }
mrm_scope_go_marker_end() { echo '# <<< mrm end <<<'; }

mrm_scope_go__targets() {
  local f
  for f in "${HOME}/.profile" "${HOME}/.bashrc"; do
    [[ -f "$f" ]] && echo "$f"
  done
}

mrm_scope_go_get_state() {
  local f has=0 cn=0 off=0 unk=0 anyf=0
  for f in "${HOME}/.profile" "${HOME}/.bashrc"; do
    [[ -f "$f" ]] || continue
    anyf=1
    if grep -qF "$(mrm_scope_go_marker_begin)" "$f" 2>/dev/null; then
      has=1
      if grep -qE 'GOPROXY=.*goproxy\.cn' "$f" 2>/dev/null; then
        cn=1
      elif grep -qE 'GOPROXY=.*proxy\.golang\.org' "$f" 2>/dev/null; then
        off=1
      else
        unk=1
      fi
    fi
  done
  if [[ "$anyf" -eq 0 ]]; then
    echo "state=default"
    echo "preset=official"
    echo "detail=no ~/.profile or ~/.bashrc"
    return 0
  fi
  if [[ "$has" -eq 0 ]]; then
    echo "state=default"
    echo "preset=official"
    echo "detail=no mrm marker block"
    return 0
  fi
  if [[ "$unk" -eq 1 ]]; then
    echo "state=unknown"
    echo "preset="
    echo "detail=mrm block present but GOPROXY not recognized"
    return 0
  fi
  if [[ "$cn" -eq 1 && "$off" -eq 1 ]]; then
    echo "state=mixed"
    echo "preset="
    echo "detail=cn and official blocks in different files"
    return 0
  fi
  if [[ "$cn" -eq 1 ]]; then
    echo "state=cn"
    echo "preset=chinese"
    echo "detail=goproxy.cn"
    return 0
  fi
  echo "state=default"
  echo "preset=official"
  echo "detail=proxy.golang.org or not marked cn"
}

mrm_scope_go__strip_block() {
  local file=$1
  [[ -f "$file" ]] || return 0
  local tmp
  tmp=$(mktemp)
  awk '
    /# >>> mrm begin >>>/ {skip=1; next}
    /# <<< mrm end <<</ {skip=0; next}
    !skip {print}
  ' "$file" >"$tmp" && mv "$tmp" "$file"
}

mrm_scope_go__write_block() {
  local file=$1 goproxy=$2 gosumdb=$3
  mrm_scope_go__strip_block "$file"
  {
    echo ""
    mrm_scope_go_marker_begin
    echo "export GOPROXY=${goproxy}"
    echo "export GOSUMDB=${gosumdb}"
    mrm_scope_go_marker_end
  } >>"$file"
}

# Update GOPROXY/GOSUMDB in the current process when mrm is sourced (same shell as the user).
mrm_scope_go_sync_process_env_from_inferred_state() {
  mrm_is_invoked_via_source || return 0
  mrm_require_yq || return 0
  local pr="" st="" k v gp gs eff
  while IFS= read -r line; do
    k=${line%%=*}
    v=${line#*=}
    [[ "$k" == "preset" ]] && pr="$v"
    [[ "$k" == "state" ]] && st="$v"
  done < <(mrm_scope_go_get_state 2>/dev/null)
  if [[ "$st" == "unknown" || "$st" == "mixed" ]]; then
    return 0
  fi
  eff="${pr:-official}"
  [[ -z "$eff" ]] && eff=official
  gp=$(mrm_preset_yq go "$eff" '.GOPROXY') || return 0
  gs=$(mrm_preset_yq go "$eff" '.GOSUMDB') || return 0
  [[ "$gp" != "null" && "$gs" != "null" ]] || return 0
  export GOPROXY="$gp"
  export GOSUMDB="$gs"
}

# Print sh-compatible exports for eval "$(mrm shell-env --scopes=go)" in the current session.
mrm_scope_go_emit_shell_env() {
  mrm_require_yq || return 1
  local pr="" st="" k v gp gs eff
  while IFS= read -r line; do
    k=${line%%=*}
    v=${line#*=}
    [[ "$k" == "preset" ]] && pr="$v"
    [[ "$k" == "state" ]] && st="$v"
  done < <(mrm_scope_go_get_state 2>/dev/null)
  if [[ "$st" == "unknown" || "$st" == "mixed" ]]; then
    return 0
  fi
  eff="${pr:-official}"
  [[ -z "$eff" ]] && eff=official
  gp=$(mrm_preset_yq go "$eff" '.GOPROXY') || return 1
  gs=$(mrm_preset_yq go "$eff" '.GOSUMDB') || return 1
  [[ "$gp" != "null" && "$gs" != "null" ]] || return 0
  printf 'export GOPROXY=%q\nexport GOSUMDB=%q\n' "$gp" "$gs"
}

mrm_scope_go__hint_or_sync_after_apply() {
  mrm_scope_go_sync_process_env_from_inferred_state
  if ! mrm_is_invoked_via_source && [[ "${MRM_EXPORT_SHELL_ENV:-0}" != "1" ]]; then
    mrm_register_shell_env_hint go
  fi
}

mrm_scope_go_apply_preset() {
  local preset=$1 gp gs

  if [[ "$preset" == official ]]; then
    local anystrip=0 f
    for f in "${HOME}/.profile" "${HOME}/.bashrc"; do
      [[ -f "$f" ]] || continue
      if grep -qF "$(mrm_scope_go_marker_begin)" "$f" 2>/dev/null; then
        mrm_scope_go__strip_block "$f"
        anystrip=1
      fi
    done
    [[ "$anystrip" -eq 0 ]] && echo "already using go/official" >&2
    mrm_scope_go__hint_or_sync_after_apply
    return 0
  fi

  gp=$(mrm_preset_yq go "$preset" '.GOPROXY') || return 1
  gs=$(mrm_preset_yq go "$preset" '.GOSUMDB') || return 1
  [[ "$gp" != "null" && "$gs" != "null" ]] || {
    echo "mrm(go): preset ${preset} missing GOPROXY/GOSUMDB" >&2
    return 1
  }

  local targets=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && targets+=("$f")
  done < <(mrm_scope_go__targets)

  if [[ ${#targets[@]} -eq 0 ]]; then
    touch "${HOME}/.bashrc"
    targets+=("${HOME}/.bashrc")
  fi

  local f all_noop=1
  for f in "${targets[@]}"; do
    if grep -qF "$(mrm_scope_go_marker_begin)" "$f" 2>/dev/null && grep -qF "export GOPROXY=${gp}" "$f" 2>/dev/null; then
      continue
    fi
    mrm_scope_go__strip_block "$f"
    mrm_scope_go__write_block "$f" "$gp" "$gs"
    all_noop=0
  done

  [[ "$all_noop" -eq 1 ]] && echo "already using go/${preset}" >&2
  mrm_scope_go__hint_or_sync_after_apply
  return 0
}

mrm_scope_go_apply_group() {
  local group=$1 p
  p=$(mrm_group_preset "$group" "go") || return 1
  [[ -n "$p" && "$p" != "null" ]] || return 1
  mrm_scope_go_apply_preset "$p"
}

mrm_scope_go_list_presets() {
  mrm_preset_table_lines go
}

mrm_scope_go__inferred_preset() {
  local k v pr=""
  while IFS= read -r line; do
    k=${line%%=*}
    v=${line#*=}
    [[ "$k" == preset ]] && pr="$v"
  done < <(mrm_scope_go_get_state 2>/dev/null)
  printf '%s' "$pr"
}

mrm_scope_go__test_preset_live() {
  local preset=$1 gp gs rc
  echo "mrm(go-test): ${preset} matches inferred → go list -m (GOPROXY/GOSUMDB for this command only)" >&2
  if ! command -v go >/dev/null 2>&1; then
    echo "mrm(go-test): go command not found" >&2
    return 1
  fi
  gp=$(mrm_preset_yq go "$preset" '.GOPROXY') || return 1
  gs=$(mrm_preset_yq go "$preset" '.GOSUMDB') || return 1
  [[ "$gp" != "null" && "$gs" != "null" ]] || {
    echo "mrm(go-test): missing GOPROXY/GOSUMDB in preset ${preset}" >&2
    return 1
  }
  set +e
  if command -v timeout >/dev/null 2>&1; then
    env GOPROXY="$gp" GOSUMDB="$gs" GO111MODULE=on timeout 90 go list -m -json rsc.io/quote@v1.5.2 >/dev/null 2>&1
    rc=$?
    [[ "$rc" -eq 124 ]] && {
      echo "mrm(go-test): FAIL go list timed out (90s)" >&2
      set -e
      return 1
    }
  else
    env GOPROXY="$gp" GOSUMDB="$gs" GO111MODULE=on go list -m -json rsc.io/quote@v1.5.2 >/dev/null 2>&1
    rc=$?
  fi
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "mrm(go-test): FAIL go list -m (exit ${rc}); check GOPROXY/GOSUMDB reachability" >&2
    return 1
  fi
  printf 'go/%s: OK (go list -m rsc.io/quote@v1.5.2 with preset GOPROXY)\n' "$preset"
}

mrm_scope_go_test_preset() {
  local preset=$1 inferred
  case "$preset" in
    chinese|official) ;;
    *)
      echo "mrm(go): unknown preset: ${preset}" >&2
      return 1
      ;;
  esac
  inferred=$(mrm_scope_go__inferred_preset)
  if [[ -n "$inferred" && "$inferred" == "$preset" ]]; then
    mrm_scope_go__test_preset_live "$preset"
  else
    echo "mrm(go-test): ${preset} is not inferred (${inferred:-none}) → HTTP probe only (.probe)" >&2
    mrm_default_test_preset_from_yaml go "$preset"
  fi
}
