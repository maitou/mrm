#!/usr/bin/env bash
# mrm installer: checks/installs deps (yq / jq / curl) and installs mrm into PREFIX/bin.
#
# See mrm_install_print_help (--help only); default PREFIX=$HOME/.local.
#
# Idempotent: skips download/copy when PREFIX/bin/yq is valid and PREFIX/bin/mrm matches source.
# Fail-fast: set -euo pipefail (except explicit test branches).
set -euo pipefail

MRM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# CLI: parse args, help, validation
# ---------------------------------------------------------------------------

mrm_install_print_help() {
  cat <<'EOF'
Usage: bash mrm/install.sh [--prefix=DIR] [--dry-run] [--download-source=upstream|cn]

  --prefix=DIR              Install prefix (default: $HOME/.local); binaries in DIR/bin
  --dry-run                 Print actions only; do not write
  --download-source=SOURCE  Remote fetch policy for yq (default: upstream):
      upstream              Direct GitHub releases URLs
      cn                    CN mirrors: tries built-in proxy bases unless
                            MRM_CN_GITHUB_BASE is set (then only that base)
  Or: MRM_DOWNLOAD_SOURCE=cn bash mrm/install.sh

  Override yq URL (highest priority): export MRM_YQ_URL='https://...'
  Pin yq tag (optional): export MRM_YQ_RELEASE_TAG=v4.45.1
      If unset, a built-in tag list is tried (fixed paths work better behind proxies).

Installs:
  - mrm executable -> PREFIX/bin/mrm
  - mrm data -> PREFIX/share/mrm/ (lib/, share/profiles/, etc. for MRM_PREFIX)
  - Deps: mikefarah/yq (YAML), jq (docker scope), curl (mrm test)

User-writable PREFIX usually needs no sudo; use sudo for /usr/local, etc.
EOF
}

# Parse "$@" into PREFIX / DRY_RUN / MRM_DOWNLOAD_SOURCE; --help prints and exits 0.
mrm_install_parse_args() {
  PREFIX="${HOME}/.local"
  DRY_RUN=0
  MRM_DOWNLOAD_SOURCE="${MRM_DOWNLOAD_SOURCE:-upstream}"

  local arg
  for arg in "$@"; do
    case "$arg" in
      --prefix=*)
        PREFIX="${arg#--prefix=}"
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      --download-source=*)
        MRM_DOWNLOAD_SOURCE="${arg#--download-source=}"
        ;;
      --help)
        mrm_install_print_help
        exit 0
        ;;
      *)
        echo "mrm-install: unknown argument: ${arg} (see --help)" >&2
        exit 1
        ;;
    esac
  done
}

mrm_install_validate_download_source() {
  case "${MRM_DOWNLOAD_SOURCE}" in
    upstream|cn) return 0 ;;
    *)
      echo "mrm-install: invalid --download-source=${MRM_DOWNLOAD_SOURCE} (use upstream or cn)" >&2
      exit 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Logging and dry-run runner
# ---------------------------------------------------------------------------

log() {
  printf '%s\n' "$*" >&2
}

# Run command unless dry-run (then log only).
run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run]' >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
    return 0
  fi
  "$@"
}

# ---------------------------------------------------------------------------
# yq: detect, mikefarah static binary URLs, install
# ---------------------------------------------------------------------------

is_mikefarah_yq() {
  command -v yq >/dev/null 2>&1 || return 1
  local ver
  ver=$(yq --version 2>&1 || true)
  [[ "$ver" == *mikefarah* ]] || [[ "$ver" == *github.com/mikefarah* ]]
}

# stdout: yq_${os}_${arch} os and arch segments; stderr + rc 1 on failure.
mrm_yq_release_os_arch() {
  local kernel machine
  kernel=$(uname -s | tr '[:upper:]' '[:lower:]')
  machine=$(uname -m)
  local yq_arch yq_os
  case "$machine" in
    x86_64) yq_arch=amd64 ;;
    aarch64|arm64) yq_arch=arm64 ;;
    armv7l) yq_arch=arm ;;
    *)
      echo "mrm-install: unsupported architecture: ${machine}" >&2
      return 1
      ;;
  esac
  case "$kernel" in
    linux) yq_os=linux ;;
    darwin) yq_os=darwin ;;
    *)
      echo "mrm-install: unsupported OS: ${kernel} (install yq manually from https://github.com/mikefarah/yq)" >&2
      return 1
      ;;
  esac
  printf '%s %s' "$yq_os" "$yq_arch"
}

# Built-in tag order when MRM_YQ_RELEASE_TAG unset (releases/download path; CN proxies often break latest).
mrm_yq_default_release_tags() {
  printf '%s\n' v4.45.1 v4.44.3 v4.43.1 v4.42.1
}

# $1: tag (e.g. v4.45.1); stdout: releases path segment (no host)
mrm_yq_release_relpath_for_tag() {
  local tag=$1 pair yq_os yq_arch
  [[ -n "$tag" ]] || return 1
  pair=$(mrm_yq_release_os_arch) || return 1
  read -r yq_os yq_arch <<<"$pair"
  printf 'mikefarah/yq/releases/download/%s/yq_%s_%s' "$tag" "$yq_os" "$yq_arch"
}

# stdout: one proxy root per line (no trailing slash). MRM_CN_GITHUB_BASE alone if set.
mrm_yq_cn_mirror_bases() {
  if [[ -n "${MRM_CN_GITHUB_BASE:-}" ]]; then
    printf '%s\n' "${MRM_CN_GITHUB_BASE}"
    return 0
  fi
  # Built-in candidates; ghps.cc last (has returned HTML with HTTP 200).
  printf '%s\n' \
    'https://ghproxy.net/https://github.com' \
    'https://mirror.ghproxy.com/https://github.com' \
    'https://ghps.cc/https://github.com'
}

# stdout: one full yq download URL per line (tags x mirrors); MRM_YQ_URL yields one line.
mrm_yq_urls_to_try() {
  if [[ -n "${MRM_YQ_URL:-}" ]]; then
    printf '%s\n' "${MRM_YQ_URL}"
    return 0
  fi
  local tags=() tag rel base
  if [[ -n "${MRM_YQ_RELEASE_TAG:-}" ]]; then
    tags=("${MRM_YQ_RELEASE_TAG}")
  else
    mapfile -t tags < <(mrm_yq_default_release_tags)
  fi
  for tag in "${tags[@]}"; do
    [[ -z "${tag// /}" ]] && continue
    rel=$(mrm_yq_release_relpath_for_tag "${tag// /}") || return 1
    case "${MRM_DOWNLOAD_SOURCE}" in
      cn)
        while IFS= read -r base; do
          [[ -z "$base" ]] && continue
          printf '%s/%s\n' "$base" "$rel"
        done < <(mrm_yq_cn_mirror_bases)
        ;;
      upstream|*)
        printf 'https://github.com/%s\n' "$rel"
        ;;
    esac
  done
}

# $3 non-empty: quick probe (shorter timeouts/retries) for CN mirror fan-out.
mrm_download_file() {
  local url=$1 out=$2
  local quick=${3:-}
  if command -v curl >/dev/null 2>&1; then
    if [[ -n "$quick" ]]; then
      curl -fsSL --connect-timeout 15 --max-time 120 --retry 1 --retry-delay 1 "$url" -o "$out"
    else
      curl -fsSL --connect-timeout 20 --max-time 180 --retry 3 --retry-delay 2 "$url" -o "$out"
    fi
  elif command -v wget >/dev/null 2>&1; then
    if [[ -n "$quick" ]]; then
      wget -q --timeout=90 "$url" -O "$out"
    else
      wget -q --timeout=180 "$url" -O "$out"
    fi
  else
    echo "mrm-install: curl or wget required to download files" >&2
    return 1
  fi
}

# Proxies may return 200 + HTML; validate size and mikefarah/yq --version output.
mrm_yq_validate_downloaded_binary() {
  local f=$1 ver
  [[ -f "$f" ]] || return 1
  if ! (( $(wc -c <"$f") >= 300000 )); then
    return 1
  fi
  chmod +x "$f"
  ver=$("$f" --version 2>&1 || true)
  [[ "$ver" == *mikefarah* ]] || [[ "$ver" == *github.com/mikefarah* ]] || return 1
  return 0
}

mrm_yq_download_failed_hint() {
  echo "mrm-install: all yq download candidates failed." >&2
  if [[ "${MRM_DOWNLOAD_SOURCE}" == cn ]]; then
    echo "  Try: (1) export MRM_CN_GITHUB_BASE='https://your-mirror/https://github.com' and retry;" >&2
    echo "  (2) bash mrm/install.sh --download-source=upstream (needs GitHub reachability);" >&2
    echo "  (3) export MRM_YQ_URL='...' or MRM_YQ_RELEASE_TAG=v4.45.1 (pick yq_*_* for your CPU)." >&2
  else
    echo "  Try: bash mrm/install.sh --download-source=cn; or export MRM_YQ_URL='...direct URL...'." >&2
  fi
}

install_yq_static() {
  local dest tmp urls_raw urls=() i url quick ok=0
  # Do not rely on mapfile exit status alone
  urls_raw=$(mrm_yq_urls_to_try) || return 1
  mapfile -t urls <<<"${urls_raw}"
  if [[ ${#urls[@]} -eq 0 ]]; then
    echo "mrm-install: could not build any yq download URL" >&2
    return 1
  fi

  mkdir -p "$BIN_DIR"
  dest="${BIN_DIR}/yq"
  tmp=$(mktemp)

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would download and install yq (${#urls[@]} candidate URLs) -> ${dest}"
    log "[dry-run]  first URL: ${urls[0]}"
    rm -f "$tmp"
    return 0
  fi

  quick=
  [[ ${#urls[@]} -gt 1 ]] && quick=1

  for i in "${!urls[@]}"; do
    url="${urls[$i]}"
    log "yq download attempt $((i + 1))/${#urls[@]}: ${url}"
    rm -f "$tmp"
    tmp=$(mktemp)
    if mrm_download_file "$url" "$tmp" "$quick"; then
      if mrm_yq_validate_downloaded_binary "$tmp"; then
        ok=1
        break
      fi
      log "downloaded file is not a valid mikefarah/yq binary (proxy error page?); trying next URL."
    fi
  done

  if [[ "$ok" -ne 1 ]]; then
    rm -f "$tmp"
    mrm_yq_download_failed_hint
    return 1
  fi

  mv "$tmp" "$dest"
  log "installed yq (mikefarah) -> ${dest}"
}

ensure_yq() {
  # Idempotent on PREFIX/bin/yq regardless of PATH order
  if [[ -f "${BIN_DIR}/yq" ]] && mrm_yq_validate_downloaded_binary "${BIN_DIR}/yq"; then
    log "valid mikefarah/yq already present: ${BIN_DIR}/yq; skip download"
    return 0
  fi
  if command -v yq >/dev/null 2>&1 && ! is_mikefarah_yq; then
    log "non-mikefarah yq on PATH; installing official static binary to ${BIN_DIR}"
  else
    log "installing mikefarah/yq to ${BIN_DIR}..."
  fi
  install_yq_static
}

# ---------------------------------------------------------------------------
# Distro packages: jq / curl
# ---------------------------------------------------------------------------

pkg_install() {
  local pkgs=("$@")
  if command -v apt-get >/dev/null 2>&1; then
    run sudo apt-get update -qq
    run sudo apt-get install -y "${pkgs[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    run sudo dnf install -y "${pkgs[@]}"
  elif command -v yum >/dev/null 2>&1; then
    run sudo yum install -y "${pkgs[@]}"
  elif command -v zypper >/dev/null 2>&1; then
    run sudo zypper install -y "${pkgs[@]}"
  elif command -v pacman >/dev/null 2>&1; then
    run sudo pacman -Sy --noconfirm "${pkgs[@]}"
  elif command -v apk >/dev/null 2>&1; then
    run sudo apk add --no-cache "${pkgs[@]}"
  elif command -v brew >/dev/null 2>&1; then
    run brew install "${pkgs[@]}"
  else
    return 1
  fi
  return 0
}

# $1: executable name; $2: log label; $3: extra hint on failure (optional).
mrm_install_ensure_distro_pkg() {
  local exe=$1 label=$2 fail_hint=${3:-}
  if command -v "$exe" >/dev/null 2>&1; then
    log "${label} already present; skip"
    return 0
  fi
  log "installing ${label}..."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would install ${label} via package manager (not run)"
    return 0
  fi
  if pkg_install "$exe"; then
    log "installed ${label} via package manager"
    return 0
  fi
  echo "mrm-install: could not install ${label} automatically. ${fail_hint}" >&2
  return 1
}

ensure_jq() {
  mrm_install_ensure_distro_pkg jq jq "See https://jqlang.github.io/jq/download/"
}

ensure_curl() {
  mrm_install_ensure_distro_pkg curl curl "Install curl with your distro package manager, then re-run this script."
}

ensure_downloader() {
  command -v curl >/dev/null 2>&1 && return 0
  command -v wget >/dev/null 2>&1 && return 0
  log "no curl/wget; trying to install curl via package manager..."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would install curl then fetch yq (not run)"
    return 0
  fi
  ensure_curl
}

# ---------------------------------------------------------------------------
# mrm CLI/data and post-install checks
# ---------------------------------------------------------------------------

install_mrm_cli() {
  [[ -f "$MRM_BIN_SRC" ]] || {
    echo "mrm-install: not found: ${MRM_BIN_SRC}" >&2
    return 1
  }
  mkdir -p "$BIN_DIR"
  if [[ -f "${BIN_DIR}/mrm" ]] && cmp -s "$MRM_BIN_SRC" "${BIN_DIR}/mrm"; then
    run chmod +x "${BIN_DIR}/mrm"
    log "mrm matches ${MRM_BIN_SRC}; skip copy"
    return 0
  fi
  run cp -f "$MRM_BIN_SRC" "${BIN_DIR}/mrm"
  run chmod +x "${BIN_DIR}/mrm"
  log "installed mrm -> ${BIN_DIR}/mrm"
}

# Matches bin/mrm mrm_resolve_prefix layout: PREFIX/share/mrm
install_mrm_data() {
  [[ -d "${MRM_ROOT}/lib" ]] && [[ -d "${MRM_ROOT}/share" ]] || {
    echo "mrm-install: not found: ${MRM_ROOT}/lib or ${MRM_ROOT}/share" >&2
    return 1
  }
  run mkdir -p "$MRM_DATA_DIR"
  run cp -a "${MRM_ROOT}/lib" "${MRM_ROOT}/share" "${MRM_DATA_DIR}/"
  log "synced mrm lib/ and share/ -> ${MRM_DATA_DIR}/"
}

require_bash4() {
  if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    echo "mrm-install: Bash 4+ required (current: ${BASH_VERSION:-?})" >&2
    exit 1
  fi
}

verify_tools() {
  command -v yq >/dev/null 2>&1 || {
    echo "mrm-install: verify failed: yq not on PATH" >&2
    return 1
  }
  is_mikefarah_yq || {
    echo "mrm-install: verify failed: yq is not mikefarah/yq" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "mrm-install: verify failed: jq not on PATH" >&2
    return 1
  }
  command -v curl >/dev/null 2>&1 || {
    echo "mrm-install: verify failed: curl not on PATH" >&2
    return 1
  }
  yq -e 'true' "${MRM_ROOT}/share/profiles/groups.yaml" >/dev/null 2>&1 || {
    echo "mrm-install: verify failed: yq cannot read groups.yaml" >&2
    return 1
  }
  log "dependency check passed (yq / jq / curl)"
}

mrm_install_log_yq_source() {
  if [[ -n "${MRM_YQ_URL:-}" ]]; then
    log "remote download: using MRM_YQ_URL (skips built-in upstream/cn lists)"
    return 0
  fi
  log "remote download source (yq): ${MRM_DOWNLOAD_SOURCE} (releases/download/<tag>/ path; built-in tag list if MRM_YQ_RELEASE_TAG unset)"
  if [[ "${MRM_DOWNLOAD_SOURCE}" == cn ]]; then
    if [[ -n "${MRM_CN_GITHUB_BASE:-}" ]]; then
      log "  cn: using only MRM_CN_GITHUB_BASE=${MRM_CN_GITHUB_BASE}"
    else
      log "  cn: will try built-in proxy base list (mrm_yq_cn_mirror_bases)"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------

main() {
  require_bash4
  log "mrm install prefix: PREFIX=${PREFIX} (bin: ${BIN_DIR})"
  mrm_install_log_yq_source

  ensure_downloader
  ensure_yq
  ensure_jq
  ensure_curl
  install_mrm_data
  install_mrm_cli

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] done; no files written"
    exit 0
  fi

  export PATH="${BIN_DIR}:${PATH}"
  verify_tools || {
    echo "mrm-install: if yq is in ${BIN_DIR} but not found, run: export PATH=\"${BIN_DIR}:\$PATH\"" >&2
    exit 1
  }

  log ""
  log "install complete. Add to PATH if needed:"
  log "  export PATH=\"${BIN_DIR}:\$PATH\""
  log "then run: mrm --help"
}

mrm_install_parse_args "$@"
mrm_install_validate_download_source

BIN_DIR="${PREFIX}/bin"
MRM_DATA_DIR="${PREFIX}/share/mrm"
MRM_BIN_SRC="${MRM_ROOT}/bin/mrm"

main
