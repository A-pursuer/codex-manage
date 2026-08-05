#!/usr/bin/env bash
# Codex 接口管理 - common.sh（公共基础设施模块，Debian 13）
#
# 本文件不能单独运行，需被 bootstrap 脚本 `source` 之后使用（bash 5.x）。
# 来源：从 401-Codex-CPA-DeepSeek-Switcher-Debian13.sh 内层 bash 逻辑里
# 抽取出的通用部分，逻辑保持一致；新增了本地个性化设置
# （local.settings.json）读写辅助函数，用于把个人基础设施细节（如自建
# CPA 的 base_url/model）从会被公开托管到 GitHub 的脚本正文中移出。
#
# 依赖：bash、curl、python3、sha256sum、flock、grep、sed、mktemp、date、
# find、timeout（provider.sh/account.sh 会各自按需再检查一次自己特有的命令）。

# ==================== 日志 / 错误 ====================
info()  { echo "[INFO] $*"; }
warn()  { echo "[WARN] $*" >&2; }
error() { echo "[ERROR] $*" >&2; }
die()   { error "$*"; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "未检测到必需命令：$1"
}

# ==================== 基础校验/转换 ====================
is_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

normalize_url() {
  local url="$1"
  while [[ "$url" == */ ]]; do url="${url%/}"; done
  printf '%s' "$url"
}

toml_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

json_escape() {
  python3 - "$1" <<'PY'
import json, sys
print(json.dumps(sys.argv[1], ensure_ascii=False)[1:-1], end="")
PY
}

sha256_hex() {
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

# ==================== 原子写入 ====================
# 从 stdin 读取内容写入 $1，权限设为 $2（八进制字符串，如 "600"）。
write_text_atomic() {
  local target="$1" mode="$2" tmp
  tmp="$(mktemp "${target}.tmp.XXXXXX")" || return 1
  cat > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod "$mode" "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$target" || { rm -f "$tmp"; return 1; }
}

# 直接把字符串值（如密钥）原子写入 $1，权限固定 600。
write_secret_atomic() {
  local target="$1" value="$2" tmp
  tmp="$(mktemp "${target}.tmp.XXXXXX")" || return 1
  printf '%s' "$value" > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$target" || { rm -f "$tmp"; return 1; }
}

safe_excerpt() {
  local file="$1" key="$2"
  python3 - "$file" "$key" <<'PY'
import sys
text = open(sys.argv[1], "r", encoding="utf-8", errors="replace").read(1000)
key = sys.argv[2]
if key:
    text = text.replace(key, "[REDACTED]")
print(" ".join(text.split())[:800])
PY
}

# ==================== 隐藏输入（API Key 等） ====================
# $1=提示标签 $2=预设值（非空且不是占位符时直接使用，跳过交互）
read_secret_hidden() {
  local label="$1" preset="$2" value=""
  if [[ -n "$preset" && "$preset" != "请替换" && "$preset" != "replace-me" ]]; then
    printf '%s' "$preset"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    die "$label 为空，且当前不是交互式终端。"
  fi

  read -r -s -p "请输入 ${label}（输入不显示）：" value
  echo ""
  [[ -n "$value" ]] || die "$label 不能为空。"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "$label 不得包含换行。"
  printf '%s' "$value"
}

# ==================== Codex 进程守卫 ====================
assert_codex_not_running() {
  local refuse="${1:-true}"
  [[ "$refuse" == "true" ]] || return 0

  local matches=""
  if command -v pgrep >/dev/null 2>&1; then
    matches="$(pgrep -af '(^|/)(codex|codex-cli)([[:space:]]|$)|@openai/codex|codex app-server' 2>/dev/null || true)"
    matches="$(printf '%s\n' "$matches" | grep -v -F "$$" || true)"
  else
    matches="$(ps -eo pid=,args= 2>/dev/null | grep -E '(^|/)(codex|codex-cli)([[:space:]]|$)|@openai/codex|codex app-server' | grep -v grep || true)"
  fi

  [[ -z "$matches" ]] || die "检测到 Codex 仍在运行。请关闭 Codex CLI、IDE 扩展会话和 app-server 后重试：$matches"
}

# ==================== 路径 ====================
get_codex_home() {
  printf '%s' "${CODEX_HOME:-$HOME/.codex}"
}

get_manager_state_root() {
  printf '%s' "$(get_codex_home)/codex-interface-manager"
}

get_local_settings_path() {
  printf '%s' "$(get_manager_state_root)/local.settings.json"
}

# 由 menu.sh（或 bootstrap）在 source 完所有模块后调用一次，
# 设好全局路径变量供 provider.sh / account.sh 共用。
init_manager_paths() {
  CODEX_DIR="$(get_codex_home)"
  CONFIG_FILE="$CODEX_DIR/config.toml"
  AUTH_FILE="$CODEX_DIR/auth.json"
  MANAGER_STATE_ROOT="$(get_manager_state_root)"
  mkdir -p "$CODEX_DIR" "$MANAGER_STATE_ROOT"
  chmod 700 "$MANAGER_STATE_ROOT" 2>/dev/null || true
}

# ==================== 本地个性化设置（local.settings.json） ====================
# 仅存放非密钥类偏好（base_url、model、reasoning effort 等）。
# API Key 一律走各模块自己的密钥文件（chmod 600），不进这个文件。
# 该文件只存在于本机 <CODEX_HOME>/codex-interface-manager/，不会出现在 GitHub 仓库里。

# get_setting <section> <key> <default>
get_setting() {
  local section="$1" key="$2" default="$3" path
  path="$(get_local_settings_path)"
  if [[ ! -f "$path" ]]; then
    printf '%s' "$default"
    return 0
  fi
  python3 - "$path" "$section" "$key" "$default" <<'PY'
import json, sys
path, section, key, default = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print(default, end="")
    sys.exit(0)
value = None
if isinstance(data, dict) and isinstance(data.get(section), dict):
    value = data[section].get(key)
if value is None or value == "":
    print(default, end="")
elif isinstance(value, str):
    print(value, end="")
else:
    print(json.dumps(value), end="")
PY
}

# set_setting <section> <key> <value>
set_setting() {
  local section="$1" key="$2" value="$3" path dir tmp
  path="$(get_local_settings_path)"
  dir="$(dirname "$path")"
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  tmp="$(mktemp "${path}.tmp.XXXXXX")" || return 1
  if ! python3 - "$path" "$section" "$key" "$value" > "$tmp" <<'PY'
import json, sys
path, section, key, value = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        data = {}
except Exception:
    data = {}
if not isinstance(data.get(section), dict):
    data[section] = {}
data[section][key] = value
json.dump(data, sys.stdout, ensure_ascii=False, indent=2)
sys.stdout.write("\n")
PY
  then
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

# read_setting_or_prompt <section> <key> <default> <prompt_text> [validator_fn]
# 仅当本地设置里没有合法值时才提示输入；已配置过的值直接返回，不会每次运行都追问。
read_setting_or_prompt() {
  local section="$1" key="$2" default="$3" prompt_text="$4" validator_fn="${5:-}"
  local current value
  current="$(get_setting "$section" "$key" "$default")"
  if [[ -n "$current" ]]; then
    if [[ -z "$validator_fn" ]] || "$validator_fn" "$current"; then
      printf '%s' "$current"
      return 0
    fi
  fi
  while true; do
    [[ -t 0 ]] || die "${prompt_text} 未配置，且当前不是交互式终端。"
    read -r -p "${prompt_text} [${current}]: " value
    [[ -n "$value" ]] || value="$current"
    if [[ -z "$validator_fn" ]] || "$validator_fn" "$value"; then
      set_setting "$section" "$key" "$value"
      printf '%s' "$value"
      return 0
    fi
    warn "输入值不符合要求，请重新输入。"
  done
}

# force_prompt_setting <section> <key> <default> <prompt_text> [validator_fn]
# 无论是否已配置，都强制重新询问一次（供"修改供应商参数"菜单使用）。
force_prompt_setting() {
  local section="$1" key="$2" default="$3" prompt_text="$4" validator_fn="${5:-}"
  local current value
  current="$(get_setting "$section" "$key" "$default")"
  while true; do
    read -r -p "${prompt_text} [${current}]: " value
    [[ -n "$value" ]] || value="$current"
    if [[ -z "$validator_fn" ]] || "$validator_fn" "$value"; then
      set_setting "$section" "$key" "$value"
      printf '%s' "$value"
      return 0
    fi
    warn "输入值不符合要求，请重新输入。"
  done
}
