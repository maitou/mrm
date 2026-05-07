# shellcheck shell=bash
# shellcheck source=../common.sh

mrm_scope_git_metadata() {
  cat <<'EOF'
title=Git url.insteadOf (GitHub HTTPS)
description=Mirror prefix for https://github.com/; does not change SSH URLs
requires_root=0
EOF
}

mrm_scope_git_requires_root() {
  echo 0
}

mrm_scope_git_get_state() {
  if ! command -v yq >/dev/null 2>&1; then
    echo "state=unknown"
    echo "preset="
    echo "detail=yq required"
    return 0
  fi
  local with from cur
  with=$(mrm_preset_yq git chinese '.insteadWith' 2>/dev/null || true)
  from=$(mrm_preset_yq git chinese '.insteadOf' 2>/dev/null || true)
  [[ -n "$with" && "$with" != "null" ]] || {
    echo "state=unknown"
    echo "preset="
    echo "detail=no preset data"
    return 0
  }
  cur=$(git config --global --get "url.${with}.insteadOf" 2>/dev/null || true)
  if [[ "$cur" == "$from" ]]; then
    echo "state=cn"
    echo "preset=chinese"
    echo "detail=url.${with}.insteadOf=${from}"
  elif [[ -z "$cur" ]]; then
    echo "state=default"
    echo "preset=official"
    echo "detail=no mrm git insteadOf"
  else
    echo "state=mixed"
    echo "preset="
    echo "detail=insteadOf mismatch"
  fi
}

mrm_scope_git_apply_preset() {
  local preset=$1
  local with from
  case "$preset" in
    chinese)
      local with from cur
      with=$(mrm_preset_yq git chinese '.insteadWith') || return 1
      from=$(mrm_preset_yq git chinese '.insteadOf') || return 1
      [[ "$with" != "null" && "$from" != "null" ]] || return 1
      cur=$(git config --global --get "url.${with}.insteadOf" 2>/dev/null || true)
      if [[ "$cur" == "$from" ]]; then
        echo "already using git/chinese" >&2
        return 0
      fi
      git config --global "url.${with}.insteadOf" "$from"
      ;;
    official)
      local with from cur
      with=$(mrm_preset_yq git chinese '.insteadWith') || return 1
      from=$(mrm_preset_yq git chinese '.insteadOf') || return 1
      cur=$(git config --global --get "url.${with}.insteadOf" 2>/dev/null || true)
      if [[ -z "$cur" ]]; then
        echo "already using git/official" >&2
        return 0
      fi
      git config --global --unset "url.${with}.insteadOf" 2>/dev/null || true
      ;;
    *)
      echo "mrm(git): unknown preset: ${preset}" >&2
      return 1
      ;;
  esac
  return 0
}

mrm_scope_git_apply_group() {
  local group=$1
  local preset
  preset=$(mrm_group_preset "$group" "git") || return 1
  [[ -n "$preset" && "$preset" != "null" ]] || {
    echo "mrm(git): group has no git mapping" >&2
    return 1
  }
  mrm_scope_git_apply_preset "$preset"
}

mrm_scope_git_list_presets() {
  mrm_preset_table_lines git
}

mrm_scope_git__inferred_preset() {
  local k v pr=""
  while IFS= read -r line; do
    k=${line%%=*}
    v=${line#*=}
    [[ "$k" == preset ]] && pr="$v"
  done < <(mrm_scope_git_get_state 2>/dev/null)
  printf '%s' "$pr"
}

mrm_scope_git__test_preset_live() {
  local url=${1:-https://github.com/git/git.git}
  echo "mrm(git-test): git ls-remote ${url} (global url.insteadOf applies when chinese)" >&2
  if ! command -v git >/dev/null 2>&1; then
    echo "mrm(git-test): git not found" >&2
    return 1
  fi
  local rc
  set +e
  if command -v timeout >/dev/null 2>&1; then
    timeout 60 git ls-remote "$url" HEAD >/dev/null 2>&1
    rc=$?
    [[ "$rc" -eq 124 ]] && {
      echo "mrm(git-test): FAIL ls-remote timed out (60s)" >&2
      set -e
      return 1
    }
  else
    git ls-remote "$url" HEAD >/dev/null 2>&1
    rc=$?
  fi
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "mrm(git-test): FAIL git ls-remote (exit ${rc})" >&2
    return 1
  fi
  printf 'git/%s: OK (git ls-remote to GitHub HTTPS)\n' "${2:-live}"
}

mrm_scope_git_test_preset() {
  local preset=$1 inferred
  case "$preset" in
    chinese|official) ;;
    *)
      echo "mrm(git): unknown preset: ${preset}" >&2
      return 1
      ;;
  esac
  inferred=$(mrm_scope_git__inferred_preset)
  if [[ -n "$inferred" && "$inferred" == "$preset" ]]; then
    mrm_scope_git__test_preset_live "https://github.com/git/git.git" "$preset"
  else
    echo "mrm(git-test): ${preset} is not inferred (${inferred:-none}) → HTTP probe only (.probe)" >&2
    mrm_default_test_preset_from_yaml git "$preset"
  fi
}
