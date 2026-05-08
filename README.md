# mrm — Mirror Registry Manager

**English** | [中文](README.zh_CN.md)

## Overview

**mrm** is a multi-environment registry manager for Linux.

It lets developers switch and manage registries, mirrors, and upstream settings across apt, Docker, k3s, Git, Go, and other development environments using reusable YAML preset groups — without manually editing scattered configs.

Inspired by tools like **nrm** and **yrm**, **mrm** provides simple and consistent environment switching with commands such as `use`, `current`, and `ls`. Which paths are edited and whether **root** is needed are summarized under [Scopes](#scopes) below.

## Install

### Requirements

- **Bash** 4+ (associative arrays).
- **[yq](https://github.com/mikefarah/yq)** (YAML) — required for `groups.yaml` / presets.
- **[jq](https://jqlang.github.io/jq/)** — required for the **docker** scope (merge `daemon.json`).
- **sudo** for scopes that write system paths: **apt**, **docker**, **k3s**.

The installer pulls in **yq**, **jq**, and **curl** as needed. Default install prefix is **`$HOME/.local`** (usually no root).

### One-shot install

Clone the repository and run **install.sh** (from any directory).

If **Git is unavailable** on the install machine (or `git clone` is blocked), download a source snapshot instead — for example **Code → Download ZIP** on the GitHub repository page — unpack it, `cd` into the extracted folder (next to **install.sh** and `bin/`), and run **`bash install.sh`** with the same flags as below.

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
