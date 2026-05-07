# shellcheck shell=bash
# Ordered scope list; scheduler runs use in this order 
MRM_SCOPE_REGISTRY=(apt git docker k3s go)

mrm_registry_list() {
  printf '%s\n' "${MRM_SCOPE_REGISTRY[@]}"
}

# Comma-separated scope ids for a group, in registry order (keys from groups.yaml).
mrm_group_scope_ids_ordered_csv() {
  local group=$1
  mrm_group_exists "$group" || return 1
  mrm_require_yq || return 1
  local keys=() key sid
  while IFS= read -r key; do
    [[ -z "$key" || "$key" == "null" ]] && continue
    keys+=("$key")
  done < <(yq -r ".[\"${group}\"] | keys | .[]" "${MRM_SHARE_PROFILES}/groups.yaml")
  local out=()
  while IFS= read -r sid; do
    local k
    for k in "${keys[@]}"; do
      [[ "$sid" == "$k" ]] && out+=("$sid")
    done
  done < <(mrm_registry_list)
  (IFS=','; echo "${out[*]}")
}
