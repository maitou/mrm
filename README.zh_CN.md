# mrm — Mirror Registry Manager

[English](README.md) | **中文**

## 概述

日常开发往往同时用到包管理器、容器、语言工具链与 Git 等；镜像与上游分散在各处，切换「国内可达」与「恢复默认」时容易重复改文件、难统一、也难回滚。**mrm** 面向**本机**这些配置的集中切换：用组合名一键套用多栈，或只改某一栈，而**不**动你的业务代码仓库。

命令风格类似 **nrm** / **yrm**（如 `use`、`current`）。效果上，你可以用预设组合快速对齐国内网络环境，或在需要时回到更贴近上游的默认组合；具体改哪些路径、是否需要 root，见下文 [作用域](#作用域)。

## 安装

### 环境要求

- **Bash** 4+（关联数组）。
- **[yq](https://github.com/mikefarah/yq)**（YAML）— 组合/预设必需。
- **[jq](https://jqlang.github.io/jq/)** — **docker** 作用域必需（合并 `daemon.json`）。
- 写入系统路径的作用域需要 **sudo**：**apt**、**docker**、**k3s**。

### 安装方式

安装脚本会按需安装 **yq**、**jq**、**curl** 等依赖，默认安装到 **`$HOME/.local`**（一般无需 root）。

#### 一键安装

克隆仓库并执行 **install.sh**（在任意目录执行即可）。

**用户级**（安装到当前用户目录，默认 **`$HOME/.local`**，无需 root）：

```bash
# 默认（GitHub 访问正常）
git clone https://github.com/maitou/mrm.git && cd mrm && bash install.sh
```

```bash
# 国内（安装脚本下载依赖走国内友好路径）
git clone https://github.com/maitou/mrm.git && cd mrm && bash install.sh --download-source=cn
```

**系统级**（安装到 `/usr/local`，需 **sudo**）：

```bash
# 默认
git clone https://github.com/maitou/mrm.git && cd mrm && sudo bash install.sh --prefix=/usr/local
```

```bash
# 国内（加上 --download-source=cn）
git clone https://github.com/maitou/mrm.git && cd mrm && sudo bash install.sh --prefix=/usr/local --download-source=cn
```

#### 自动安装

本地**已有**本仓库时，在仓库根目录（与 **install.sh**、`bin/` 同级）执行 **`bash install.sh`**，由脚本自动补齐依赖。

**用户级**：

```bash
# 默认
cd /path/to/mrm && bash install.sh
```

```bash
# 国内
cd /path/to/mrm && bash install.sh --download-source=cn
```

**系统级**：

```bash
# 默认
cd /path/to/mrm && sudo bash install.sh --prefix=/usr/local
```

```bash
# 国内
cd /path/to/mrm && sudo bash install.sh --prefix=/usr/local --download-source=cn
```

安装完成后若使用默认前缀，请确保 **`$HOME/.local/bin`** 在 **`PATH`** 中（例如 `export PATH="$HOME/.local/bin:$PATH"`），再执行 **`mrm --help`**。

## 使用示例

以下为最常见用法；子命令与全部参数以 **`mrm --help`** 为准。

```bash
# 列出内置作用域（apt、git、docker、k3s、go）
mrm --list-scopes

# 查看当前推断的配置（子集）
mrm current --scopes=git,go

# 应用国内导向镜像（apt/docker/k3s 需要 sudo）
sudo mrm use chinese-group

# 恢复默认/上游组合（sudo 规则相同）
sudo mrm use official-group

# 单栈
mrm use git/chinese

# Go：写入 ~/.bashrc / ~/.profile，并同时让当前终端里的 GOPROXY/GOSUMDB 生效
#（mrm 在子进程里跑；不用 eval 的话，当前 shell 里的 $GOPROXY 不会变。）
#
# 等价的两步：先改 rc，再把导出语句导入当前 shell
# mrm use go/chinese
# eval "$(mrm shell-env --scopes=go)"
#
# 加上 --export-shell-env 后，可执行的 export 语句走 stdout、状态表走 stderr；
# 用 eval "$(...)" 既能写持久配置，又能立刻更新当前会话的环境变量。
eval "$(mrm use go/chinese --export-shell-env)"
```

## 更多功能

完整用法请运行 **`mrm --help`**（子命令、参数、选项与说明均以终端输出为准）。

### 应用与查看

| 用途 | 命令 | 说明 |
|------|------|------|
| 按组合切换多栈 | `mrm use <group>` | 例如 `chinese-group`、`official-group`，一次套用预设里包含的多个作用域。 |
| 只改某一栈 | `mrm use <scope>/<preset>` | 例如 `git/chinese`；`scope` 与 `preset` 由内置或自定义配置提供。 |
| 查看当前推断结果 | `mrm current` | 只读；可用 `--scopes=` 限定范围。 |
| 列出可用作用域 | `mrm --list-scopes` | 查看内置栈及是否需要 **root**。 |

### 行为要点

- **多作用域 `use`**：按作用域依次执行；尽力而为，某一栈失败不保证整体成功。
- **`use` 幂等**：已与目标一致时会跳过多余写入与无意义备份。

### 使用边界

- **不会**改写你 git 仓库里 Kubernetes 清单或 Dockerfile 中的 `image:` 字段。
- **不会**管理集群内工作负载或除本机配置文件以外的镜像凭据。

## 作用域

以下为当前内置作用域（修改位置与是否需要 root）：


| 作用域      | 修改内容                                                          | Root |
| -------- | ------------------------------------------------------------- | ---- |
| `apt`    | `/etc/apt/sources.list.d/mrm.sources`（Ubuntu/Debian deb822）   | 是    |
| `git`    | `git config --global` 中针对 GitHub HTTPS 的 `url.*.insteadOf`    | 否    |
| `docker` | `/etc/docker/daemon.json` 中的 `registry-mirrors`               | 是    |
| `k3s`    | `/etc/rancher/k3s/registries.yaml`（+ 可选 systemd 重启）           | 是    |
| `go`     | `~/.profile` / `~/.bashrc` 中带 mrm 标记的 `GOPROXY` / `GOSUMDB` 块 | 否    |


