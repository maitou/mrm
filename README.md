# mrm — Mirror Registry Manager

**English** | [中文](README.zh_CN.md)

## Overview

Developers routinely use package managers, containers, language toolchains, and Git together; mirror and upstream settings are scattered, and switching between a **China-reachable** setup and **reverting to defaults** is repetitive and hard to keep consistent. **mrm** switches these **local** host settings in one place: apply a named **group** across stacks, or change a single stack, **without** touching your application repository.

The command style is similar to **nrm** / **yrm** (e.g. `use`, `current`). You can align with domestic network conditions using built-in **groups**, or move back toward upstream-oriented defaults; which paths are edited and whether **root** is needed are summarized under [Scopes](#scopes) below.

## Install

### Requirements

- **Bash** 4+ (associative arrays).
- **[yq](https://github.com/mikefarah/yq)** (YAML) — required for `groups.yaml` / presets.
- **[jq](https://jqlang.github.io/jq/)** — required for the **docker** scope (merge `daemon.json`).
- **sudo** for scopes that write system paths: **apt**, **docker**, **k3s**.

### Install methods

The installer pulls in **yq**, **jq**, and **curl** as needed. Default install prefix is **`$HOME/.local`** (usually no root).

#### One-shot install

Clone the repository and run **install.sh** (from any directory).

**User-level** (install under the current user, default **`$HOME/.local`**, no root):

```bash
# Default (GitHub reachable)
git clone https://github.com/maitou/mrm.git && cd mrm && bash install.sh
```

```bash
# Mainland China (CN-friendly download path for installer dependencies)
git clone https://github.com/maitou/mrm.git && cd mrm && bash install.sh --download-source=cn
```

**System-wide** (install to `/usr/local`, requires **sudo**):

```bash
# Default
git clone https://github.com/maitou/mrm.git && cd mrm && sudo bash install.sh --prefix=/usr/local
```

```bash
# Mainland China (add --download-source=cn)
git clone https://github.com/maitou/mrm.git && cd mrm && sudo bash install.sh --prefix=/usr/local --download-source=cn
```

#### Already have the repo

If you already have a local copy, run **`bash install.sh`** at the repository root (alongside **install.sh** and `bin/`). The script installs missing dependencies automatically.

**User-level**:

```bash
# Default
cd /path/to/mrm && bash install.sh
```

```bash
# Mainland China
cd /path/to/mrm && bash install.sh --download-source=cn
```

**System-wide**:

```bash
# Default
cd /path/to/mrm && sudo bash install.sh --prefix=/usr/local
```

```bash
# Mainland China
cd /path/to/mrm && sudo bash install.sh --prefix=/usr/local --download-source=cn
```

If you used the default prefix, ensure **`$HOME/.local/bin`** is on **`PATH`** (e.g. `export PATH="$HOME/.local/bin:$PATH"`), then run **`mrm --help`**.

## Usage examples

Common invocations below; all subcommands and flags are defined in **`mrm --help`**.

```bash
# List built-in scopes (apt, git, docker, k3s, go)
mrm --list-scopes

# Show current inferred profile (subset)
mrm current --scopes=git,go

# Apply China-oriented mirrors (needs sudo for apt/docker/k3s)
sudo mrm use chinese-group

# Revert toward default/upstream group (same sudo rules)
sudo mrm use official-group

# Single stack
mrm use git/chinese

# Go: apply preset to ~/.bashrc / ~/.profile and refresh GOPROXY/GOSUMDB in this shell
# (mrm runs in a subprocess; without eval, $GOPROXY in your terminal stays unchanged.)
#
# Equivalent two-step: write rc files, then import exports into the current shell
# mrm use go/chinese
# eval "$(mrm shell-env --scopes=go)"
#
# With --export-shell-env, mrm use prints shell exports on stdout and the status table on stderr;
# eval "$(...)" updates this session while still persisting the mrm block in your rc files.
eval "$(mrm use go/chinese --export-shell-env)"
```

## More features

For the full CLI (subcommands, options, and descriptions), run **`mrm --help`**; the terminal output is authoritative.

### Apply and inspect

| Purpose | Command | Notes |
|---------|---------|--------|
| Switch multiple stacks via a group | `mrm use <group>` | e.g. `chinese-group`, `official-group` — applies every scope defined in that group. |
| Change one stack only | `mrm use <scope>/<preset>` | e.g. `git/chinese`; `scope` and `preset` come from built-in or custom config. |
| Read current inferred state | `mrm current` | Read-only; optional `--scopes=` filter. |
| List available scopes | `mrm --list-scopes` | Shows built-in stacks and whether **root** is required. |

### Behavior notes

- **Multi-scope `use`**: scopes run in order, best-effort; failure in one scope does not guarantee overall success.
- **Idempotent `use`**: when already on the target, redundant writes and pointless backups are skipped.

### Out of scope

- Does **not** rewrite `image:` fields in Kubernetes manifests or Dockerfiles in your git repo.
- Does **not** manage in-cluster workloads or registry credentials beyond local host config files.

## Scopes

Built-in scopes and what they touch (and whether **root** is required):

| Scope   | What it touches | Root |
|---------|-----------------|------|
| `apt`   | `/etc/apt/sources.list.d/mrm.sources` (Ubuntu/Debian deb822) | yes |
| `git`   | `git config --global` `url.*.insteadOf` for GitHub HTTPS | no |
| `docker`| `/etc/docker/daemon.json` `registry-mirrors` | yes |
| `k3s`   | `/etc/rancher/k3s/registries.yaml` (+ optional systemd restart) | yes |
| `go`    | `~/.profile` / `~/.bashrc` mrm-marked `GOPROXY` / `GOSUMDB` block | no |
