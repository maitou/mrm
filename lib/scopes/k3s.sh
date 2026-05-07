# shellcheck shell=bash

mrm_scope_k3s_metadata() {
  cat <<'EOF'
title=K3s registries.yaml
description=Installs or removes /etc/rancher/k3s/registries.yaml (CN mirror endpoints)
requires_root=1
EOF
}

mrm_scope_k3s_requires_root() {
  echo 1
}

mrm_scope_k3s_target() {
  echo "/etc/rancher/k3s/registries.yaml"
}

mrm_scope_k3s_cn_template() {
  local t
  t=$(mrm_preset_yq k3s chinese '.template') || return 1
  [[ "$t" != "null" && -n "$t" ]] || return 1
  echo "${MRM_SHARE_TEMPLATES}/${t}"
}

mrm_scope_k3s_get_state() {
  local tgt tpl
  tgt=$(mrm_scope_k3s_target)
  tpl=$(mrm_scope_k3s_cn_template) || {
    echo "state=unknown"
    echo "preset="
    echo "detail=no cn template"
    return 0
  }
  [[ -f "$tpl" ]] || {
    echo "state=unknown"
    echo "preset="
    echo "detail=missing ${tpl}"
    return 0
  }
  if [[ ! -f "$tgt" ]]; then
    echo "state=default"
    echo "preset=official"
    echo "detail=no registries.yaml"
    return 0
  fi
  if cmp -s "$tpl" "$tgt" 2>/dev/null; then
    echo "state=cn"
    echo "preset=chinese"
    echo "detail=matches built-in cn template"
    return 0
  fi
  echo "state=unknown"
  echo "preset="
  echo "detail=registries.yaml exists but differs from built-in template"
}

mrm_scope_k3s_restart() {
  local u
  for u in k3s k3s-agent; do
    if systemctl is-enabled --quiet "${u}" 2>/dev/null && systemctl is-active --quiet "${u}" 2>/dev/null; then
      echo "mrm(k3s): restarting ${u}…" >&2
      systemctl restart "${u}" || return 1
      return 0
    fi
  done
  echo "mrm(k3s): no active k3s/k3s-agent systemd unit; restart K3s manually to apply." >&2
  return 0
}

mrm_scope_k3s_apply_preset() {
  local preset=$1 tgt tpl
  mrm_is_root || {
    echo "mrm(k3s): root required" >&2
    return 2
  }
  tgt=$(mrm_scope_k3s_target)
  mkdir -p /etc/rancher/k3s

  case "$preset" in
    chinese)
      tpl=$(mrm_scope_k3s_cn_template) || return 1
      [[ -f "$tpl" ]] || {
        echo "mrm(k3s): template missing: ${tpl}" >&2
        return 1
      }
      if [[ -f "$tgt" ]] && cmp -s "$tpl" "$tgt" 2>/dev/null; then
        echo "already using k3s/chinese" >&2
        return 0
      fi
      [[ -f "$tgt" ]] && mrm_backup_file "$tgt" >/dev/null
      install -m 0644 "$tpl" "$tgt"
      mrm_scope_k3s_restart || true
      ;;
    official)
      tpl=$(mrm_scope_k3s_cn_template) || return 1
      if [[ ! -f "$tgt" ]]; then
        echo "already using k3s/official" >&2
        return 0
      fi
      if cmp -s "$tpl" "$tgt" 2>/dev/null; then
        mrm_backup_file "$tgt" >/dev/null
        rm -f "$tgt"
        mrm_scope_k3s_restart || true
        echo "mrm(k3s): removed registries.yaml matching cn template" >&2
        return 0
      fi
      echo "mrm(k3s): registries.yaml differs from built-in cn template; not removed automatically; fix manually or restore from .bak." >&2
      return 1
      ;;
    *)
      echo "mrm(k3s): unknown preset: ${preset}" >&2
      return 1
      ;;
  esac
  return 0
}

mrm_scope_k3s_apply_group() {
  local group=$1 p
  p=$(mrm_group_preset "$group" "k3s") || return 1
  [[ -n "$p" && "$p" != "null" ]] || return 1
  mrm_scope_k3s_apply_preset "$p"
}

mrm_scope_k3s_list_presets() {
  mrm_preset_table_lines k3s
}

mrm_scope_k3s__inferred_preset() {
  local k v pr=""
  while IFS= read -r line; do
    k=${line%%=*}
    v=${line#*=}
    [[ "$k" == preset ]] && pr="$v"
  done < <(mrm_scope_k3s_get_state 2>/dev/null)
  printf '%s' "$pr"
}

# Pull a tiny Hub image; prefer k3s crictl (CRI path, mirrors from registries.yaml), then ctr.
mrm_scope_k3s__live_pull_smoke() {
  local ref=$1 log rc
  log=$(mktemp)
  : >"$log"
  if command -v k3s >/dev/null 2>&1 && k3s crictl info >/dev/null 2>&1; then
    echo "mrm(k3s-test): trying k3s crictl pull ${ref}" >&2
    set +e
    if command -v timeout >/dev/null 2>&1; then
      timeout 180 k3s crictl pull "$ref" >>"$log" 2>&1
    else
      k3s crictl pull "$ref" >>"$log" 2>&1
    fi
    rc=$?
    set -e
    if [[ "$rc" -eq 0 ]]; then
      rm -f "$log"
      return 0
    fi
    if [[ "$rc" -eq 124 ]]; then
      echo "mrm(k3s-test): FAIL crictl pull timed out (180s) for ${ref}" >&2
      tail -n 25 "$log" >&2 || true
      rm -f "$log"
      return 1
    fi
    echo "mrm(k3s-test): crictl pull failed (exit ${rc}); falling back to ctr" >&2
    tail -n 8 "$log" >&2 || true
    : >"$log"
  fi
  if ! command -v k3s >/dev/null 2>&1; then
    echo "mrm(k3s-test): k3s not on PATH" >&2
    rm -f "$log"
    return 1
  fi
  set +e
  if command -v timeout >/dev/null 2>&1; then
    timeout 180 k3s ctr -n k8s.io images pull "$ref" >>"$log" 2>&1
  else
    k3s ctr -n k8s.io images pull "$ref" >>"$log" 2>&1
  fi
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    rm -f "$log"
    return 0
  fi
  if [[ "$rc" -eq 124 ]]; then
    echo "mrm(k3s-test): FAIL ctr pull timed out (180s) for ${ref}" >&2
    tail -n 20 "$log" >&2 || true
    rm -f "$log"
    return 1
  fi
  set +e
  if command -v timeout >/dev/null 2>&1; then
    timeout 180 k3s ctr images pull "$ref" >>"$log" 2>&1
  else
    k3s ctr images pull "$ref" >>"$log" 2>&1
  fi
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    rm -f "$log"
    return 0
  fi
  if [[ "$rc" -eq 124 ]]; then
    echo "mrm(k3s-test): FAIL ctr pull timed out (180s) for ${ref}" >&2
  else
    echo "mrm(k3s-test): FAIL k3s ctr images pull ${ref} (exit ${rc})" >&2
  fi
  tail -n 25 "$log" >&2 || true
  rm -f "$log"
  return 1
}

mrm_scope_k3s__test_preset_live() {
  local preset=$1 img
  img="docker.io/library/alpine:3.19"
  echo "mrm(k3s-test): ${preset} matches inferred → live pull ${img} (crictl then ctr; registries.yaml must mirror registry-1.docker.io)" >&2
  if ! command -v k3s >/dev/null 2>&1; then
    echo "mrm(k3s-test): k3s not on PATH; install K3s or add it to PATH for live pull test" >&2
    return 1
  fi
  mrm_scope_k3s__live_pull_smoke "$img" || return 1
  printf 'k3s/%s: OK (live pull %s)\n' "$preset" "$img"
}

mrm_scope_k3s_test_preset() {
  local preset=$1 inferred
  case "$preset" in
    chinese|official) ;;
    *)
      echo "mrm(k3s): unknown preset: ${preset}" >&2
      return 1
      ;;
  esac
  inferred=$(mrm_scope_k3s__inferred_preset)
  if [[ -n "$inferred" && "$inferred" == "$preset" ]]; then
    mrm_scope_k3s__test_preset_live "$preset"
  else
    echo "mrm(k3s-test): ${preset} is not inferred (${inferred:-none}) → HTTP probe only (.probe)" >&2
    mrm_default_test_preset_from_yaml k3s "$preset"
  fi
}
