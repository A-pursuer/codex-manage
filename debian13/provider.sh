#!/usr/bin/env bash
# Codex 接口管理 - provider.sh（供应商切换模块：CPA / DeepSeek V4 Flash，Debian 13）
#
# 改编自 401-Codex-CPA-DeepSeek-Switcher-Debian13.sh 的内层 bash 逻辑，
# 业务逻辑不变，调整点：
# - 依赖 common.sh 提供的公共基础设施，本文件不再重复定义。
# - 顶部硬编码的个人基础设施细节（CPA 的 base_url / model 等）改为
#   从本地 local.settings.json 读取，缺失时交互式输入并记住，
#   这样本文件可以安全地公开托管在 GitHub 仓库里，不会泄露个人代理地址。
#   DeepSeek 官方地址/型号是公开信息，默认值直接保留。
# - 不再包含独立菜单循环和单实例锁（改由 menu.sh 统一持有一把 flock）。
# - 只读写 config.toml 与 $CODEX_DIR/termius-cpa-state/ 状态目录（沿用旧
#   401 的目录名，保证兼容旧备份），从不读取、修改、恢复 auth.json。
#
# 本文件不能单独运行，需在 common.sh 之后被 source。
# 依赖 common.sh 的 init_manager_paths 预先设置好：$CODEX_DIR、$CONFIG_FILE。

CPA_PROVIDER_ID="cliproxyapi"
DEEPSEEK_PROVIDER_ID="deepseek"

# ==================== 参数校验 ====================
validate_reasoning_effort() {
  case "$1" in minimal|low|medium|high|xhigh) return 0 ;; *) return 1 ;; esac
}

validate_plan_reasoning_effort() {
  case "$1" in none|minimal|low|medium|high|xhigh) return 0 ;; *) return 1 ;; esac
}

validate_nonempty_no_newline() {
  [[ -n "$1" && "$1" != *$'\n'* && "$1" != *$'\r'* ]]
}

validate_cpa_base_url() {
  local u
  u="$(normalize_url "$1")"
  [[ "$u" =~ ^https?://[^[:space:]]+$ && "$u" == */v1 ]]
}

validate_deepseek_base_url() {
  local u
  u="$(normalize_url "$1")"
  [[ "$u" =~ ^https?://[^[:space:]]+$ && "$u" != */v1 ]]
}

validate_deepseek_model() {
  [[ "$1" == "deepseek-v4-flash" ]]
}

# ==================== 运行期设置（本地 local.settings.json + 交互式补全） ====================
get_provider_common_settings() {
  TEST_MODE="$(get_setting provider test_mode full)"
  case "$TEST_MODE" in full|api|none) ;; *) die "provider.test_mode 只能为 full / api / none。" ;; esac

  HTTP_TIMEOUT="$(get_setting provider http_timeout_sec 60)"
  is_uint "$HTTP_TIMEOUT" || die "provider.http_timeout_sec 必须为正整数。"
  (( HTTP_TIMEOUT >= 5 )) || die "provider.http_timeout_sec 不应小于 5 秒。"

  CODEX_TEST_TIMEOUT="$(get_setting provider codex_test_timeout_sec 120)"
  is_uint "$CODEX_TEST_TIMEOUT" || die "provider.codex_test_timeout_sec 必须为正整数。"
  (( CODEX_TEST_TIMEOUT >= 10 )) || die "provider.codex_test_timeout_sec 不应小于 10 秒。"

  REFUSE_IF_CODEX_RUNNING="$(get_setting provider refuse_if_codex_running true)"
  case "$REFUSE_IF_CODEX_RUNNING" in true|false) ;; *) die "provider.refuse_if_codex_running 只能为 true 或 false。" ;; esac

  BACKUP_KEEP="$(get_setting provider backup_keep 30)"
  [[ "$BACKUP_KEEP" == "-1" || "$BACKUP_KEEP" =~ ^[1-9][0-9]*$ ]] || die "provider.backup_keep 只能为 -1 或正整数。"
}

# 只有首次使用（本地未配置 base_url/model）时才会交互式询问。
get_cpa_runtime_settings() {
  get_provider_common_settings
  CPA_BASE_URL="$(read_setting_or_prompt cpa base_url "" "CPA 地址（必须以 /v1 结尾，例如 http://127.0.0.1:8317/v1）" validate_cpa_base_url)"
  CPA_BASE_URL="$(normalize_url "$CPA_BASE_URL")"
  CPA_MODEL="$(read_setting_or_prompt cpa model "" "CPA /v1/models 中实际存在的模型 ID" validate_nonempty_no_newline)"
  CPA_REASONING_EFFORT="$(read_setting_or_prompt cpa reasoning_effort high "推理强度（minimal/low/medium/high/xhigh）" validate_reasoning_effort)"
  CPA_PLAN_REASONING_EFFORT="$(read_setting_or_prompt cpa plan_reasoning_effort high "Plan 模式推理强度（none/minimal/low/medium/high/xhigh）" validate_plan_reasoning_effort)"
  CPA_SUPPORTS_WEBSOCKETS="$(get_setting cpa supports_websockets false)"
}

get_deepseek_runtime_settings() {
  get_provider_common_settings
  DEEPSEEK_BASE_URL="$(read_setting_or_prompt deepseek base_url "https://api.deepseek.com" "DeepSeek 官方 Responses API 根地址（不要附加 /v1）" validate_deepseek_base_url)"
  DEEPSEEK_BASE_URL="$(normalize_url "$DEEPSEEK_BASE_URL")"
  DEEPSEEK_MODEL="$(read_setting_or_prompt deepseek model deepseek-v4-flash "DeepSeek 模型 ID（当前官方集成仅支持 deepseek-v4-flash）" validate_deepseek_model)"
  DEEPSEEK_REASONING_EFFORT="$(read_setting_or_prompt deepseek reasoning_effort high "推理强度（minimal/low/medium/high/xhigh）" validate_reasoning_effort)"
  DEEPSEEK_PLAN_REASONING_EFFORT="$(read_setting_or_prompt deepseek plan_reasoning_effort high "Plan 模式推理强度（none/minimal/low/medium/high/xhigh）" validate_plan_reasoning_effort)"
}

# 强制重新输入某个模式的参数（供菜单"修改供应商参数"使用）。
edit_provider_settings() {
  local mode="$1"
  if [[ "$mode" == "cpa" ]]; then
    force_prompt_setting cpa base_url "$(get_setting cpa base_url '')" "CPA 地址（必须以 /v1 结尾）" validate_cpa_base_url >/dev/null
    force_prompt_setting cpa model "$(get_setting cpa model '')" "CPA 模型 ID" validate_nonempty_no_newline >/dev/null
    force_prompt_setting cpa reasoning_effort "$(get_setting cpa reasoning_effort high)" "推理强度" validate_reasoning_effort >/dev/null
  elif [[ "$mode" == "deepseek" ]]; then
    force_prompt_setting deepseek base_url "$(get_setting deepseek base_url https://api.deepseek.com)" "DeepSeek 根地址" validate_deepseek_base_url >/dev/null
    force_prompt_setting deepseek reasoning_effort "$(get_setting deepseek reasoning_effort high)" "推理强度" validate_reasoning_effort >/dev/null
  else
    die "未知模式：$mode"
  fi
  info "已更新并保存到本地设置文件。"
}

# ==================== 状态目录（沿用旧 401 的目录名） ====================
init_provider_dirs() {
  PROVIDER_STATE_ROOT="$CODEX_DIR/termius-cpa-state"
  PROVIDER_ORIGINAL_DIR="$PROVIDER_STATE_ROOT/original"
  PROVIDER_BACKUP_ROOT="$PROVIDER_STATE_ROOT/backups"
  PROVIDER_MARKER_FILE="$PROVIDER_STATE_ROOT/managed-by-401"
  CPA_SECRET_FILE="$CODEX_DIR/cpa-api-key"
  DEEPSEEK_SECRET_FILE="$CODEX_DIR/deepseek-api-key"
  DEEPSEEK_CATALOG_FILE="$CODEX_DIR/deepseek-v4-flash-models.json"

  mkdir -p "$CODEX_DIR" "$PROVIDER_STATE_ROOT" "$PROVIDER_ORIGINAL_DIR" "$PROVIDER_BACKUP_ROOT"
  chmod 700 "$CODEX_DIR" "$PROVIDER_STATE_ROOT" "$PROVIDER_ORIGINAL_DIR" "$PROVIDER_BACKUP_ROOT" 2>/dev/null || true
}

# ==================== 快照（config.toml + 两组密钥 + 模型目录 + marker） ====================
snapshot_item() {
  local dir="$1" state_name="$2" file_name="$3" source="$4"
  if [[ -e "$source" || -L "$source" ]]; then
    cp -a "$source" "$dir/$file_name"
    printf 'present\n' > "$dir/$state_name"
  else
    printf 'absent\n' > "$dir/$state_name"
  fi
}

create_provider_snapshot() {
  local dir="$1" reason="$2"
  mkdir -p "$dir"
  chmod 700 "$dir"

  snapshot_item "$dir" "config.state" "config.toml" "$CONFIG_FILE"
  snapshot_item "$dir" "secret.state" "cpa-api-key" "$CPA_SECRET_FILE"
  snapshot_item "$dir" "deepseek-secret.state" "deepseek-api-key" "$DEEPSEEK_SECRET_FILE"
  snapshot_item "$dir" "catalog.state" "deepseek-v4-flash-models.json" "$DEEPSEEK_CATALOG_FILE"
  snapshot_item "$dir" "marker.state" "managed-by-401" "$PROVIDER_MARKER_FILE"

  printf '%s\n' "$reason" > "$dir/action"
  date -u +'%Y-%m-%dT%H:%M:%SZ' > "$dir/captured"
  chmod 600 "$dir"/* 2>/dev/null || true
}

capture_provider_original_once() {
  [[ -f "$PROVIDER_ORIGINAL_DIR/captured" ]] && return 0
  info "首次运行：保存切换前的原始 Codex 配置状态（含目前手动配置的 provider，如果有的话）。"
  create_provider_snapshot "$PROVIDER_ORIGINAL_DIR" "original-before-401"
}

prune_provider_backups() {
  [[ "$BACKUP_KEEP" == "-1" ]] && return 0
  local count
  count="$(find "$PROVIDER_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  (( count <= BACKUP_KEEP )) && return 0
  find "$PROVIDER_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
    | sort -r \
    | tail -n "+$((BACKUP_KEEP + 1))" \
    | while IFS= read -r name; do
        [[ -n "$name" ]] && rm -rf -- "$PROVIDER_BACKUP_ROOT/$name"
      done
}

create_provider_timestamp_backup() {
  local reason="$1" ts dir suffix=0
  ts="$(date +%Y%m%d%H%M%S)"
  dir="$PROVIDER_BACKUP_ROOT/${ts}-${reason}"
  while [[ -e "$dir" ]]; do
    suffix=$((suffix + 1))
    dir="$PROVIDER_BACKUP_ROOT/${ts}-${reason}-${suffix}"
  done
  create_provider_snapshot "$dir" "$reason"
  prune_provider_backups
  printf '%s' "$dir"
}

restore_item() {
  local dir="$1" state_name="$2" file_name="$3" target="$4" state
  state="$(cat "$dir/$state_name" 2>/dev/null || echo absent)"
  case "$state" in
    present)
      if [[ ! -e "$dir/$file_name" && ! -L "$dir/$file_name" ]]; then
        error "快照缺少文件：$dir/$file_name"
        return 1
      fi
      cp -a "$dir/$file_name" "$target" || return 1
      ;;
    absent)
      rm -f "$target" || return 1
      ;;
    *)
      error "无效快照状态：$dir/$state_name"
      return 1
      ;;
  esac
}

restore_provider_snapshot() {
  local dir="$1"
  [[ -d "$dir" ]] || die "恢复目录不存在：$dir"

  restore_item "$dir" "config.state" "config.toml" "$CONFIG_FILE" || return 1
  restore_item "$dir" "secret.state" "cpa-api-key" "$CPA_SECRET_FILE" || return 1
  restore_item "$dir" "deepseek-secret.state" "deepseek-api-key" "$DEEPSEEK_SECRET_FILE" || return 1
  restore_item "$dir" "catalog.state" "deepseek-v4-flash-models.json" "$DEEPSEEK_CATALOG_FILE" || return 1
  restore_item "$dir" "marker.state" "managed-by-401" "$PROVIDER_MARKER_FILE" || return 1

  [[ ! -e "$CONFIG_FILE" ]] || chmod 600 "$CONFIG_FILE" 2>/dev/null || true
  [[ ! -e "$CPA_SECRET_FILE" ]] || chmod 600 "$CPA_SECRET_FILE" 2>/dev/null || true
  [[ ! -e "$DEEPSEEK_SECRET_FILE" ]] || chmod 600 "$DEEPSEEK_SECRET_FILE" 2>/dev/null || true
  [[ ! -e "$DEEPSEEK_CATALOG_FILE" ]] || chmod 600 "$DEEPSEEK_CATALOG_FILE" 2>/dev/null || true
  [[ ! -e "$PROVIDER_MARKER_FILE" ]] || chmod 600 "$PROVIDER_MARKER_FILE" 2>/dev/null || true
}

# ==================== 写配置 ====================
write_deepseek_catalog() {
  python3 - "$DEEPSEEK_CATALOG_FILE" "$DEEPSEEK_MODEL" <<'PY'
import json, os, sys, tempfile
path, model = sys.argv[1], sys.argv[2]
instructions = (
    "You are Codex, an agentic coding assistant working in the user's repository. "
    "Inspect the workspace, use tools carefully, make the requested changes, verify them, "
    "and report concrete results. Follow AGENTS.md and user instructions when present."
)
catalog = {
    "models": [{
        "slug": model,
        "prefer_websockets": False,
        "support_verbosity": True,
        "default_verbosity": "low",
        "apply_patch_tool_type": "freeform",
        "web_search_tool_type": "text",
        "input_modalities": ["text"],
        "supports_image_detail_original": False,
        "truncation_policy": {"mode": "tokens", "limit": 10000},
        "supports_parallel_tool_calls": True,
        "tool_mode": None,
        "multi_agent_version": "v2",
        "use_responses_lite": False,
        "include_skills_usage_instructions": False,
        "auto_review_model_override": None,
        "context_window": 1048576,
        "max_context_window": 1048576,
        "effective_context_window_percent": 95,
        "auto_compact_token_limit": None,
        "comp_hash": "3000",
        "reasoning_summary_format": "experimental",
        "default_reasoning_summary": "none",
        "display_name": "DeepSeek-V4-Flash",
        "description": "DeepSeek V4 Flash for the Responses API.",
        "default_reasoning_level": "high",
        "supported_reasoning_levels": [
            {"effort": "low", "description": "Fast responses with lighter reasoning"},
            {"effort": "high", "description": "Extra reasoning depth for complex problems"},
            {"effort": "max", "description": "Maximum reasoning depth"}
        ],
        "shell_type": "shell_command",
        "visibility": "list",
        "minimal_client_version": "0.144.0",
        "supported_in_api": True,
        "availability_nux": None,
        "upgrade": None,
        "priority": 1,
        "model_messages": {
            "instructions_template": instructions,
            "instructions_variables": {
                "personality_default": "",
                "personality_friendly": "",
                "personality_pragmatic": ""
            },
            "approvals": None
        },
        "experimental_supported_tools": [],
        "supports_search_tool": True,
        "default_service_tier": None,
        "supports_reasoning_summaries": True,
        "base_instructions": instructions
    }]
}
directory = os.path.dirname(path)
fd, tmp = tempfile.mkstemp(prefix=".deepseek-models.", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
finally:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
PY
}

write_cpa_config() {
  local key="$1"
  write_secret_atomic "$CPA_SECRET_FILE" "$key" || return 1

  local tmp base model secret
  tmp="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")" || return 1
  base="$(toml_escape "$CPA_BASE_URL")"
  model="$(toml_escape "$CPA_MODEL")"
  secret="$(toml_escape "$CPA_SECRET_FILE")"

  cat > "$tmp" <<EOF
# Managed by Codex 接口管理 (provider module, 原 401)
# Mode: CPA
model = "${model}"
model_provider = "${CPA_PROVIDER_ID}"
model_reasoning_effort = "${CPA_REASONING_EFFORT}"
plan_mode_reasoning_effort = "${CPA_PLAN_REASONING_EFFORT}"

[model_providers.${CPA_PROVIDER_ID}]
name = "CLIProxyAPI"
base_url = "${base}"
wire_api = "responses"
supports_websockets = ${CPA_SUPPORTS_WEBSOCKETS}
request_max_retries = 4
stream_max_retries = 5
stream_idle_timeout_ms = 300000

[model_providers.${CPA_PROVIDER_ID}.auth]
command = "cat"
args = ["${secret}"]
timeout_ms = 5000
refresh_interval_ms = 0
EOF
  local cat_rc=$?
  if [[ $cat_rc -ne 0 ]]; then rm -f "$tmp"; return 1; fi
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$CONFIG_FILE" || { rm -f "$tmp"; return 1; }

  printf 'format=2\nmode=cpa\nprovider=%s\nbase_url=%s\nmodel=%s\nchanged_at=%s\n' \
    "$CPA_PROVIDER_ID" "$CPA_BASE_URL" "$CPA_MODEL" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    | write_text_atomic "$PROVIDER_MARKER_FILE" 600 || return 1
}

write_deepseek_config() {
  local key="$1"
  write_secret_atomic "$DEEPSEEK_SECRET_FILE" "$key" || return 1
  write_deepseek_catalog || return 1

  local tmp base model secret catalog
  tmp="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")" || return 1
  base="$(toml_escape "$DEEPSEEK_BASE_URL")"
  model="$(toml_escape "$DEEPSEEK_MODEL")"
  secret="$(toml_escape "$DEEPSEEK_SECRET_FILE")"
  catalog="$(toml_escape "$DEEPSEEK_CATALOG_FILE")"

  cat > "$tmp" <<EOF
# Managed by Codex 接口管理 (provider module, 原 401)
# Mode: DeepSeek V4 Flash
model = "${model}"
model_provider = "${DEEPSEEK_PROVIDER_ID}"
# 不写 preferred_auth_method：codex-rs 的 ConfigToml 不认识这个字段
# （deny_unknown_fields，会导致加载失败）。
# 也不写 forced_login_method：这个字段管的是 Codex 自己对 ChatGPT/OpenAI
# 后端用什么方式登录，跟具体请求走哪个 model provider 无关——DeepSeek 的
# 密钥已经通过下面 auth 段落的 command 机制独立注入，不需要它。实测把它
# 设成 api 后，只要当前 auth.json 还是 ChatGPT 登录态，Codex 在任何一次
# 调用（包括本工具校验用的 codex exec）里都会检测到冲突并主动删除
# auth.json 把用户登出，和本工具"能随时切回官方订阅"的目标直接冲突。
model_reasoning_effort = "${DEEPSEEK_REASONING_EFFORT}"
plan_mode_reasoning_effort = "${DEEPSEEK_PLAN_REASONING_EFFORT}"
model_catalog_json = "${catalog}"

[model_providers.${DEEPSEEK_PROVIDER_ID}]
name = "DeepSeek"
base_url = "${base}"
wire_api = "responses"
supports_websockets = false
request_max_retries = 4
stream_max_retries = 5
stream_idle_timeout_ms = 300000

[model_providers.${DEEPSEEK_PROVIDER_ID}.auth]
command = "cat"
args = ["${secret}"]
timeout_ms = 5000
refresh_interval_ms = 0
EOF
  local cat_rc=$?
  if [[ $cat_rc -ne 0 ]]; then rm -f "$tmp"; return 1; fi
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$CONFIG_FILE" || { rm -f "$tmp"; return 1; }

  printf 'format=2\nmode=deepseek\nprovider=%s\nbase_url=%s\nmodel=%s\nchanged_at=%s\n' \
    "$DEEPSEEK_PROVIDER_ID" "$DEEPSEEK_BASE_URL" "$DEEPSEEK_MODEL" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    | write_text_atomic "$PROVIDER_MARKER_FILE" 600 || return 1
}

# ==================== 读取/校验当前配置 ====================
get_config_field() {
  local field="$1"
  sed -n "s/^[[:space:]]*${field}[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$CONFIG_FILE" 2>/dev/null | head -1
}

validate_cpa_config() {
  [[ -f "$CONFIG_FILE" && -s "$CPA_SECRET_FILE" ]] || return 1
  [[ "$(get_config_field model_provider)" == "$CPA_PROVIDER_ID" ]] || return 1
  [[ "$(get_config_field model)" == "$CPA_MODEL" ]] || return 1
  grep -Fq "base_url = \"$(toml_escape "$CPA_BASE_URL")\"" "$CONFIG_FILE" || return 1
  grep -Eq '^[[:space:]]*wire_api[[:space:]]*=[[:space:]]*"responses"' "$CONFIG_FILE" || return 1
}

validate_deepseek_config() {
  [[ -f "$CONFIG_FILE" && -s "$DEEPSEEK_SECRET_FILE" && -s "$DEEPSEEK_CATALOG_FILE" ]] || return 1
  [[ "$(get_config_field model_provider)" == "$DEEPSEEK_PROVIDER_ID" ]] || return 1
  [[ "$(get_config_field model)" == "$DEEPSEEK_MODEL" ]] || return 1
  grep -Fq "base_url = \"$(toml_escape "$DEEPSEEK_BASE_URL")\"" "$CONFIG_FILE" || return 1
  python3 - "$DEEPSEEK_CATALOG_FILE" "$DEEPSEEK_MODEL" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
models = data.get("models", [])
raise SystemExit(0 if any(x.get("slug") == sys.argv[2] for x in models if isinstance(x, dict)) else 1)
PY
}

check_codex_minimum_version_for_deepseek() {
  command -v codex >/dev/null 2>&1 || return 0
  local text version
  text="$(codex --version 2>/dev/null || true)"
  version="$(printf '%s' "$text" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  [[ -n "$version" ]] || {
    warn "无法从 codex --version 解析版本，继续执行。DeepSeek 官方模型目录要求 Codex >= 0.144.0。"
    return 0
  }
  if ! python3 - "$version" <<'PY'
import sys
def v(s): return tuple(int(x) for x in s.split("."))
raise SystemExit(0 if v(sys.argv[1]) >= v("0.144.0") else 1)
PY
  then
    die "当前 Codex 版本为 $version；DeepSeek V4 Flash 官方模型目录要求至少 0.144.0。"
  fi
}

# ==================== 联网测试 ====================
http_request() {
  local method="$1" url="$2" key="$3" body_file="$4" output_file="$5"
  local args=(-sS --connect-timeout 10 --max-time "$HTTP_TIMEOUT" -o "$output_file" -w '%{http_code}'
    -X "$method" "$url"
    -H "Authorization: Bearer ${key}"
    -H 'Content-Type: application/json')
  [[ -n "$body_file" ]] && args+=(--data-binary "@$body_file")
  curl "${args[@]}"
}

test_models_endpoint() {
  local base="$1" key="$2" model="$3" label="$4" body code
  body="$(mktemp /tmp/codex-models.XXXXXX.json)" || return 1
  local rc=0
  if code="$(http_request GET "${base}/models" "$key" "" "$body")"; then
    rc=0
  else
    rc=$?
  fi
  if [[ $rc -ne 0 ]]; then
    rm -f "$body"
    error "无法连接 ${label}：${base}/models"
    return 1
  fi
  if [[ "$code" != "200" ]]; then
    error "${label} GET /models 返回 HTTP $code：$(safe_excerpt "$body" "$key")"
    rm -f "$body"
    return 1
  fi
  if ! python3 - "$body" "$model" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    obj = json.load(f)
items = obj.get("data", []) if isinstance(obj, dict) else []
raise SystemExit(0 if any(isinstance(x, dict) and x.get("id") == sys.argv[2] for x in items) else 1)
PY
  then
    error "${label} /models 未找到模型：$model"
    rm -f "$body"
    return 1
  fi
  rm -f "$body"
  info "${label} /models 验证通过，模型存在：$model"
}

test_responses_endpoint() {
  local base="$1" key="$2" model="$3" label="$4" expected="$5" req resp code
  req="$(mktemp /tmp/codex-request.XXXXXX.json)" || return 1
  resp="$(mktemp /tmp/codex-response.XXXXXX.json)" || { rm -f "$req"; return 1; }
  if ! python3 - "$req" "$model" "$expected" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump({"model": sys.argv[2], "input": "Reply with exactly: " + sys.argv[3], "stream": False}, f)
PY
  then
    rm -f "$req" "$resp"
    return 1
  fi
  local rc=0
  if code="$(http_request POST "${base}/responses" "$key" "$req" "$resp")"; then
    rc=0
  else
    rc=$?
  fi
  rm -f "$req"
  if [[ $rc -ne 0 ]]; then
    rm -f "$resp"
    error "无法连接 ${label} Responses API：${base}/responses"
    return 1
  fi
  if [[ "$code" -lt 200 || "$code" -ge 300 ]]; then
    error "${label} POST /responses 返回 HTTP $code：$(safe_excerpt "$resp" "$key")"
    rm -f "$resp"
    return 1
  fi
  if ! python3 - "$resp" "$expected" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
serialized = json.dumps(data, ensure_ascii=False)
raise SystemExit(0 if sys.argv[2] in serialized else 1)
PY
  then
    error "${label} /responses 返回成功状态，但响应不是合法 JSON 或未包含预期标记：$expected"
    rm -f "$resp"
    return 1
  fi
  rm -f "$resp"
  info "${label} /responses 验证通过。"
}

run_codex_test() {
  local expected="$1" key_file="$2"
  command -v codex >/dev/null 2>&1 || {
    warn "未检测到 codex 命令，跳过端到端测试；API 测试已完成。"
    return 0
  }

  local out rc
  out="$(mktemp /tmp/codex-provider-test.XXXXXX.log)" || return 1
  if (
    cd /tmp
    timeout "$CODEX_TEST_TIMEOUT" codex exec \
      --ephemeral \
      --strict-config \
      --skip-git-repo-check \
      --sandbox read-only \
      "Do not use tools. Reply with exactly: ${expected}"
  ) >"$out" 2>&1; then
    rc=0
  else
    rc=$?
  fi

  if [[ $rc -ne 0 ]]; then
    local key=""
    [[ -s "$key_file" ]] && key="$(cat "$key_file")"
    error "codex exec 测试失败，退出码 $rc：$(safe_excerpt "$out" "$key")"
    rm -f "$out"
    return 1
  fi
  if ! grep -Fq "$expected" "$out"; then
    error "codex exec 已结束，但未检测到预期标记：$expected"
    tail -n 30 "$out" >&2 || true
    rm -f "$out"
    return 1
  fi
  rm -f "$out"
  info "Codex 端到端验证通过；测试使用 --ephemeral，不保存测试会话。"
}

perform_mode_tests() {
  local mode="$1"
  case "$TEST_MODE" in
    none)
      warn "test_mode=none：已跳过联网验证。"
      ;;
    api|full)
      if [[ "$mode" == "cpa" ]]; then
        local key
        key="$(cat "$CPA_SECRET_FILE")"
        test_models_endpoint "$CPA_BASE_URL" "$key" "$CPA_MODEL" "CPA" || return 1
        test_responses_endpoint "$CPA_BASE_URL" "$key" "$CPA_MODEL" "CPA" "CPA_OK" || return 1
        [[ "$TEST_MODE" == "api" ]] || run_codex_test "CODEX_CPA_OK" "$CPA_SECRET_FILE" || return 1
      else
        local key
        key="$(cat "$DEEPSEEK_SECRET_FILE")"
        test_models_endpoint "$DEEPSEEK_BASE_URL" "$key" "$DEEPSEEK_MODEL" "DeepSeek" || return 1
        test_responses_endpoint "$DEEPSEEK_BASE_URL" "$key" "$DEEPSEEK_MODEL" "DeepSeek" "DEEPSEEK_OK" || return 1
        [[ "$TEST_MODE" == "api" ]] || run_codex_test "CODEX_DEEPSEEK_OK" "$DEEPSEEK_SECRET_FILE" || return 1
      fi
      ;;
  esac
}

# ==================== 顶层操作 ====================
switch_to_provider_mode() {
  local mode="$1" key backup rc=0
  init_provider_dirs
  if [[ "$mode" == "cpa" ]]; then
    get_cpa_runtime_settings
  else
    get_deepseek_runtime_settings
  fi
  assert_codex_not_running "$REFUSE_IF_CODEX_RUNNING"
  capture_provider_original_once

  if [[ "$mode" == "cpa" ]]; then
    key="$(read_secret_hidden "CPA API Key" "")"
  else
    check_codex_minimum_version_for_deepseek
    key="$(read_secret_hidden "DeepSeek API Key" "")"
  fi

  backup="$(create_provider_timestamp_backup "before-switch-${mode}")"
  info "本次变更前备份：$backup"

  if [[ "$mode" == "cpa" ]]; then
    if write_cpa_config "$key" && validate_cpa_config; then rc=0; else rc=$?; fi
  else
    if write_deepseek_config "$key" && validate_deepseek_config; then rc=0; else rc=$?; fi
  fi
  if [[ $rc -ne 0 ]]; then
    restore_provider_snapshot "$backup"
    die "配置写入后本地校验失败，已自动回滚。"
  fi

  if perform_mode_tests "$mode"; then rc=0; else rc=$?; fi
  key=""

  if [[ $rc -ne 0 ]]; then
    warn "切换后验证失败，正在恢复本次变更前状态。"
    restore_provider_snapshot "$backup"
    die "验证失败，已自动回滚。"
  fi

  echo ""
  echo "========== Codex 供应商切换摘要 =========="
  if [[ "$mode" == "cpa" ]]; then
    echo "状态: 已切换到 CPA"
    echo "Provider: $CPA_PROVIDER_ID"
    echo "地址: $CPA_BASE_URL"
    echo "模型: $CPA_MODEL"
    echo "密钥文件: $CPA_SECRET_FILE（权限 600）"
  else
    echo "状态: 已切换到 DeepSeek V4 Flash"
    echo "Provider: $DEEPSEEK_PROVIDER_ID"
    echo "地址: $DEEPSEEK_BASE_URL"
    echo "模型: $DEEPSEEK_MODEL"
    echo "模型目录: $DEEPSEEK_CATALOG_FILE"
    echo "密钥文件: $DEEPSEEK_SECRET_FILE（权限 600）"
  fi
  echo "Codex 配置: $CONFIG_FILE"
  echo "首次原配置: $PROVIDER_ORIGINAL_DIR"
  echo "本次变更前备份: $backup"
  echo "测试级别: $TEST_MODE"
  echo "auth.json: 未修改"
  echo "==========================================="
}

restore_provider_original() {
  init_provider_dirs
  get_provider_common_settings
  assert_codex_not_running "$REFUSE_IF_CODEX_RUNNING"
  [[ -f "$PROVIDER_ORIGINAL_DIR/captured" ]] || die "尚未建立首次原始快照，无法恢复。"

  local backup
  backup="$(create_provider_timestamp_backup before-restore-original)"
  info "恢复前当前状态备份：$backup"

  local rc=0
  if restore_provider_snapshot "$PROVIDER_ORIGINAL_DIR"; then rc=0; else rc=$?; fi
  if [[ $rc -ne 0 ]]; then
    restore_provider_snapshot "$backup" || true
    die "恢复首次原配置失败；已尝试回滚到操作前状态。"
  fi

  echo ""
  echo "========== 恢复原 Codex 配置摘要 =========="
  echo "状态: 已恢复首次运行本工具前的配置状态"
  echo "（若这台机器在用本工具之前就已经手动配置过 provider，恢复的是那份手动配置，而不是纯官方默认值）"
  echo "原始快照时间: $(cat "$PROVIDER_ORIGINAL_DIR/captured")"
  echo "恢复前状态备份: $backup"
  echo "auth.json: 未修改"
  echo "原始快照继续保留，可重复切换与恢复。"
  echo "============================================"
}

marker_value() {
  local key="$1"
  sed -n "s/^${key}=//p" "$PROVIDER_MARKER_FILE" 2>/dev/null | head -1
}

detect_managed_provider_mode() {
  local mode=""
  if [[ -f "$PROVIDER_MARKER_FILE" ]]; then
    mode="$(marker_value mode)"
    [[ -n "$mode" ]] || {
      case "$(marker_value provider)" in
        "$CPA_PROVIDER_ID") mode="cpa" ;;
        "$DEEPSEEK_PROVIDER_ID") mode="deepseek" ;;
      esac
    }
  fi
  if [[ -z "$mode" && -f "$CONFIG_FILE" ]]; then
    case "$(get_config_field model_provider)" in
      "$CPA_PROVIDER_ID") mode="cpa" ;;
      "$DEEPSEEK_PROVIDER_ID") mode="deepseek" ;;
    esac
  fi
  printf '%s' "$mode"
}

show_provider_status_and_test() {
  init_provider_dirs
  local provider="" model="" base="" mode=""
  [[ ! -f "$CONFIG_FILE" ]] || {
    provider="$(get_config_field model_provider)"
    model="$(get_config_field model)"
    base="$(get_config_field base_url)"
  }
  mode="$(detect_managed_provider_mode)"

  echo ""
  echo "========== Codex 供应商（provider）当前状态 =========="
  echo "CODEX_HOME: $CODEX_DIR"
  echo "config.toml: $([[ -f "$CONFIG_FILE" ]] && echo 存在 || echo 不存在)"
  echo "当前 provider: ${provider:-openai(default/未识别)}"
  echo "当前 model: ${model:-未识别}"
  echo "当前 base_url: ${base:-未识别}"
  echo "受管模式: ${mode:-未检测到（可能是官方或未知手动配置）}"
  echo "CPA 密钥: $([[ -s "$CPA_SECRET_FILE" ]] && echo 存在 || echo 不存在)"
  echo "DeepSeek 密钥: $([[ -s "$DEEPSEEK_SECRET_FILE" ]] && echo 存在 || echo 不存在)"
  echo "DeepSeek 模型目录: $([[ -s "$DEEPSEEK_CATALOG_FILE" ]] && echo 存在 || echo 不存在)"
  echo "首次原始快照: $([[ -f "$PROVIDER_ORIGINAL_DIR/captured" ]] && cat "$PROVIDER_ORIGINAL_DIR/captured" || echo 未创建)"
  echo "时间戳备份数: $(find "$PROVIDER_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  echo "auth.json: provider 模块不管理、不修改"
  echo "======================================================="

  case "$mode" in
    cpa)
      get_cpa_runtime_settings
      validate_cpa_config || { warn "当前 CPA 配置与密钥不一致，跳过联网测试。"; return 0; }
      perform_mode_tests cpa
      ;;
    deepseek)
      get_deepseek_runtime_settings
      check_codex_minimum_version_for_deepseek
      validate_deepseek_config || { warn "当前 DeepSeek 配置、密钥或模型目录不一致，跳过联网测试。"; return 0; }
      perform_mode_tests deepseek
      ;;
    *)
      info "当前不是由本工具管理的 CPA/DeepSeek 配置，未执行联网测试。"
      ;;
  esac
}

list_provider_backup_dirs() {
  find "$PROVIDER_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r
}

restore_provider_timestamp_backup() {
  init_provider_dirs
  get_provider_common_settings
  assert_codex_not_running "$REFUSE_IF_CODEX_RUNNING"

  local -a names=()
  mapfile -t names < <(list_provider_backup_dirs)
  ((${#names[@]} > 0)) || {
    warn "没有可恢复的供应商配置时间戳备份。"
    return 0
  }

  echo ""
  echo "========== 供应商配置时间戳备份 =========="
  local i
  for i in "${!names[@]}"; do
    local dir="$PROVIDER_BACKUP_ROOT/${names[$i]}"
    echo "[$((i + 1))] ${names[$i]} | $(cat "$dir/action" 2>/dev/null || echo unknown) | $(cat "$dir/captured" 2>/dev/null || echo unknown)"
  done
  echo "[0] 取消"
  printf '请选择备份编号：'
  local choice
  read -r choice
  [[ "$choice" =~ ^[0-9]+$ ]] || { warn "输入不是有效编号。"; return 0; }
  (( choice == 0 )) && { info "已取消。"; return 0; }
  (( choice >= 1 && choice <= ${#names[@]} )) || { warn "备份编号超出范围。"; return 0; }

  local selected="$PROVIDER_BACKUP_ROOT/${names[$((choice - 1))]}" pre
  pre="$(create_provider_timestamp_backup before-restore-timestamp-backup)"
  local rc=0
  if restore_provider_snapshot "$selected"; then rc=0; else rc=$?; fi
  if [[ $rc -ne 0 ]]; then
    restore_provider_snapshot "$pre" || true
    die "恢复时间戳备份失败；已尝试回滚。"
  fi
  info "已恢复备份：$selected"
  info "恢复操作前状态保存在：$pre"
}
