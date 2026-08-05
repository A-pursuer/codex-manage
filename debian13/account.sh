#!/usr/bin/env bash
# Codex 接口管理 - account.sh（账号导入/切换模块，Debian 13）
#
# bash 版的 402（Windows 上的 402-Codex-Account-Switcher-Win11.ps1），
# 这套逻辑在 Debian 上此前完全没有，是新写的，语义逐项对齐 Windows account.ps1：
# - 解析登录导出 JSON / auth.json，解码 JWT，做字段一致性校验，算账号指纹
# - 保险库、时间戳备份、首次原始快照
# - 只读写 auth.json（以及为确保切换生效而管理的 cli_auth_credentials_store
#   字段），从不修改 provider.sh 管理的 model_provider / model_providers.* 字段
#
# 与 Windows 版的差异（因平台现实调整，已与用户确认）：
# - Debian13 场景是 Termius/SSH 连接的无桌面服务器，没有系统剪贴板，
#   所以账号导入只提供"粘贴多行 JSON，单独一行输入 EOF 结束"的 stdin
#   读取方式，没有剪贴板选项，也没有文件路径选项。
# - 保险库用明文文件 + chmod 600（目录 700），不是 Windows 的 DPAPI 加密——
#   这与现有 401 里 CPA/DeepSeek 密钥文件的安全模型完全一致，同样的警告：
#   Linux 文件权限无法抵御 root、主机入侵或磁盘快照泄露。
#
# 本文件不能单独运行，需在 common.sh 之后被 source。
# 依赖 common.sh 的 init_manager_paths 预先设置好：$CODEX_DIR、$CONFIG_FILE、$AUTH_FILE。

# ==================== 运行期设置 ====================
get_account_common_settings() {
  ACCOUNT_VERIFY_MODE="$(get_setting account verify_mode status)"
  case "$ACCOUNT_VERIFY_MODE" in status|local) ;; *) die "account.verify_mode 只能为 status 或 local。" ;; esac

  ACCOUNT_STATUS_TIMEOUT="$(get_setting account status_timeout_sec 30)"
  is_uint "$ACCOUNT_STATUS_TIMEOUT" || die "account.status_timeout_sec 必须为正整数。"
  (( ACCOUNT_STATUS_TIMEOUT >= 5 )) || die "account.status_timeout_sec 不能小于 5 秒。"

  ACCOUNT_REFUSE_IF_RUNNING="$(get_setting account refuse_if_codex_running true)"
  case "$ACCOUNT_REFUSE_IF_RUNNING" in true|false) ;; *) die "account.refuse_if_codex_running 只能为 true 或 false。" ;; esac

  ACCOUNT_AUTO_SYNC="$(get_setting account auto_sync_current true)"
  case "$ACCOUNT_AUTO_SYNC" in true|false) ;; *) die "account.auto_sync_current 只能为 true 或 false。" ;; esac

  ACCOUNT_BACKUP_KEEP="$(get_setting account backup_keep 30)"
  [[ "$ACCOUNT_BACKUP_KEEP" == "-1" || "$ACCOUNT_BACKUP_KEEP" =~ ^[0-9]+$ ]] || die "account.backup_keep 只能为 -1 或非负整数。"

  ACCOUNT_ENFORCE_FILE_STORE="$(get_setting account enforce_file_auth_store true)"
  case "$ACCOUNT_ENFORCE_FILE_STORE" in true|false) ;; *) die "account.enforce_file_auth_store 只能为 true 或 false。" ;; esac
}

# ==================== 状态目录 ====================
init_account_dirs() {
  ACCOUNT_STATE_ROOT="$CODEX_DIR/account-switcher-402-debian13"
  ACCOUNTS_DIR="$ACCOUNT_STATE_ROOT/accounts"
  AUTH_BACKUPS_DIR="$ACCOUNT_STATE_ROOT/auth-backups"
  ACCOUNT_CONFIG_BACKUPS_DIR="$ACCOUNT_STATE_ROOT/config-backups"
  ACCOUNT_ORIGINAL_DIR="$ACCOUNT_STATE_ROOT/original"
  AUTH_ORIGINAL_FILE="$ACCOUNT_ORIGINAL_DIR/auth.original.json"
  AUTH_ORIGINAL_META="$ACCOUNT_ORIGINAL_DIR/auth.original.meta.json"
  CONFIG_ORIGINAL_FILE="$ACCOUNT_ORIGINAL_DIR/config.original.toml"
  CONFIG_ORIGINAL_META="$ACCOUNT_ORIGINAL_DIR/config.original.meta.json"

  mkdir -p "$ACCOUNT_STATE_ROOT" "$ACCOUNTS_DIR" "$AUTH_BACKUPS_DIR" "$ACCOUNT_CONFIG_BACKUPS_DIR" "$ACCOUNT_ORIGINAL_DIR"
  chmod 700 "$ACCOUNT_STATE_ROOT" "$ACCOUNTS_DIR" "$AUTH_BACKUPS_DIR" "$ACCOUNT_CONFIG_BACKUPS_DIR" "$ACCOUNT_ORIGINAL_DIR" 2>/dev/null || true
}

# ==================== JSON/JWT 解析（python3） ====================
# normalize_auth_json <输入JSON文件> <输出目录>
# 成功：往 <输出目录> 写 auth.json（标准化后的内容）+ meta.json（指纹/邮箱等）。
# 失败：非零退出，原因写到 stderr。
normalize_auth_json() {
  local in_file="$1" out_dir="$2"
  python3 - "$in_file" "$out_dir" <<'PY'
import base64, datetime, hashlib, json, os, sys


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def get_str(v):
    return "" if v is None else str(v).strip()


def get_prop(obj, name):
    return obj.get(name) if isinstance(obj, dict) else None


def consistent(values, field_name, case_insensitive=False, required=False):
    clean = [get_str(v) for v in values if get_str(v)]
    if not clean:
        if required:
            die(f"无法取得 {field_name}。")
        return ""
    first = clean[0]
    for item in clean:
        a, b = (first.lower(), item.lower()) if case_insensitive else (first, item)
        if a != b:
            die(f"输入 JSON 与 JWT 中的 {field_name} 不一致。")
    return first


def b64url_decode(seg):
    seg = seg + "=" * (-len(seg) % 4)
    try:
        return base64.urlsafe_b64decode(seg.encode("ascii"))
    except Exception:
        die("无法解码 JWT payload。")


def decode_jwt(token, field_name):
    if not token:
        die(f"缺少字段：{field_name}。")
    parts = token.split(".")
    if len(parts) != 3:
        die(f"{field_name} 不是三段式 JWT。")
    try:
        return json.loads(b64url_decode(parts[1]))
    except Exception:
        die(f"无法解析 {field_name} 的 JWT payload。")


def epoch_to_utc(v):
    if v is None:
        return ""
    try:
        return datetime.datetime.utcfromtimestamp(int(v)).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    except Exception:
        return ""


def rfc3339_to_utc(v):
    s = get_str(v)
    if not s:
        return ""
    try:
        dt = datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        return dt.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    except Exception:
        return ""


in_path, out_dir = sys.argv[1], sys.argv[2]

try:
    with open(in_path, encoding="utf-8") as f:
        text = f.read()
except Exception as e:
    die(f"无法读取输入文件：{e}")

if not text.strip():
    die("输入 JSON 为空。")

try:
    root = json.loads(text)
except Exception as e:
    die(f"JSON 语法错误：{e}")

if not isinstance(root, dict):
    die("输入内容必须是 JSON 对象。")

if root.get("disabled") is True:
    die("该账号在输入 JSON 中标记为 disabled=true。")

declared_type = get_str(root.get("type"))
if declared_type and declared_type.lower() != "codex":
    die(f"type={declared_type}，不是 codex。")

auth_mode = get_str(root.get("auth_mode"))
if auth_mode and auth_mode.lower() != "chatgpt":
    die(f"auth_mode={auth_mode}，不是 chatgpt。")

tokens_prop = root.get("tokens")
if isinstance(tokens_prop, dict):
    token_source, source_kind = tokens_prop, "auth.json"
else:
    token_source, source_kind = root, "export"

id_token = get_str(token_source.get("id_token"))
access_token = get_str(token_source.get("access_token"))
refresh_token = get_str(token_source.get("refresh_token"))
if not refresh_token:
    die("缺少 refresh_token。")

id_claims = decode_jwt(id_token, "id_token")
access_claims = decode_jwt(access_token, "access_token")

AUTH_NS = "https://api.openai.com/auth"
PROFILE_NS = "https://api.openai.com/profile"
id_auth = get_prop(id_claims, AUTH_NS)
access_auth = get_prop(access_claims, AUTH_NS)
access_profile = get_prop(access_claims, PROFILE_NS)

account_id = consistent([
    token_source.get("account_id"), root.get("account_id"),
    get_prop(id_auth, "chatgpt_account_id"), get_prop(access_auth, "chatgpt_account_id"),
], "account_id", required=True)

email = consistent([
    root.get("email"), get_prop(id_claims, "email"), get_prop(access_profile, "email"),
], "email", case_insensitive=True)

user_id = consistent([
    get_prop(id_auth, "chatgpt_user_id"), get_prop(id_auth, "user_id"),
    get_prop(access_auth, "chatgpt_user_id"), get_prop(access_auth, "user_id"),
], "user_id")

subject = consistent([get_prop(id_claims, "sub"), get_prop(access_claims, "sub")], "JWT sub")

if not user_id:
    user_id = subject
if not email and not user_id:
    die("JWT 中既没有邮箱，也没有可用的用户标识，无法安全区分账号。")

plan_type = get_str(get_prop(access_auth, "chatgpt_plan_type")) or get_str(get_prop(id_auth, "chatgpt_plan_type")) or "unknown"

now_utc = datetime.datetime.utcnow()
last_refresh = rfc3339_to_utc(root.get("last_refresh"))
if not last_refresh:
    last_refresh = epoch_to_utc(get_prop(access_claims, "iat"))
if not last_refresh:
    last_refresh = epoch_to_utc(get_prop(id_claims, "iat"))
if not last_refresh:
    last_refresh = now_utc.strftime("%Y-%m-%dT%H:%M:%S.%fZ")

try:
    lr_dt = datetime.datetime.fromisoformat(last_refresh.replace("Z", "+00:00"))
    if lr_dt.replace(tzinfo=None) > now_utc + datetime.timedelta(minutes=5):
        last_refresh = now_utc.strftime("%Y-%m-%dT%H:%M:%S.%fZ")
except Exception:
    pass

access_expires = epoch_to_utc(get_prop(access_claims, "exp"))
id_expires = epoch_to_utc(get_prop(id_claims, "exp"))
declared_expires = rfc3339_to_utc(root.get("expired"))

identity = "|".join([user_id.lower(), subject.lower(), email.lower(), account_id])
fingerprint = hashlib.sha256(identity.encode("utf-8")).hexdigest()[:20]

normalized = {
    "auth_mode": "chatgpt",
    "OPENAI_API_KEY": None,
    "tokens": {
        "id_token": id_token,
        "access_token": access_token,
        "refresh_token": refresh_token,
        "account_id": account_id,
    },
    "last_refresh": last_refresh,
}

meta = {
    "schema_version": 1,
    "fingerprint": fingerprint,
    "label": "",
    "email": email if email else "(JWT未提供邮箱)",
    "account_id": account_id,
    "user_id": user_id,
    "subject": subject,
    "plan_type": plan_type,
    "access_expires": access_expires,
    "id_expires": id_expires,
    "declared_expires": declared_expires,
    "last_refresh": last_refresh,
    "source_kind": source_kind,
    "generated_at": now_utc.strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
}

os.makedirs(out_dir, exist_ok=True)
with open(os.path.join(out_dir, "auth.json"), "w", encoding="utf-8", newline="\n") as f:
    json.dump(normalized, f, ensure_ascii=False, indent=2)
    f.write("\n")
with open(os.path.join(out_dir, "meta.json"), "w", encoding="utf-8", newline="\n") as f:
    json.dump(meta, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
}

# get_meta_field <meta.json> <key> —— 布尔/数字统一按 JSON 字面量输出（true/false/123），字符串原样输出。
get_meta_field() {
  local meta_file="$1" key="$2"
  python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
    v = data.get(sys.argv[2])
    if v is None:
        print("")
    elif isinstance(v, str):
        print(v)
    else:
        print(json.dumps(v))
except Exception:
    print("")
' "$meta_file" "$key"
}

# ==================== 保险库 ====================
get_saved_account_fingerprints() {
  find "$ACCOUNTS_DIR" -maxdepth 1 -name '*.meta.json' -type f -printf '%f\n' 2>/dev/null | sed 's/\.meta\.json$//' | sort
}

# save_account_info <normalized_dir> <label> <reason>
# normalized_dir 需包含 normalize_auth_json 产出的 auth.json + meta.json。
save_account_info() {
  local normalized_dir="$1" label="$2" reason="$3"
  local fingerprint new_last_refresh
  fingerprint="$(get_meta_field "$normalized_dir/meta.json" fingerprint)"
  [[ -n "$fingerprint" ]] || die "标准化结果缺少 fingerprint。"
  new_last_refresh="$(get_meta_field "$normalized_dir/meta.json" last_refresh)"

  local blob="$ACCOUNTS_DIR/${fingerprint}.auth.json"
  local meta="$ACCOUNTS_DIR/${fingerprint}.meta.json"
  local existing_label=""

  if [[ -f "$meta" ]]; then
    local existing_last_refresh
    existing_last_refresh="$(get_meta_field "$meta" last_refresh)"
    # 固定格式的 ISO8601 UTC 时间戳可以直接按字符串比较先后。
    if [[ -n "$existing_last_refresh" && "$existing_last_refresh" > "$new_last_refresh" ]]; then
      warn "保险库中的账号凭据看起来更新，未被较旧 auth.json 覆盖：$(get_meta_field "$meta" email)"
      return 1
    fi
    existing_label="$(get_meta_field "$meta" label)"
  fi

  [[ -n "$label" ]] || label="$existing_label"
  [[ -n "$label" ]] || label="$(get_meta_field "$normalized_dir/meta.json" email)"

  local tmp
  tmp="$(mktemp "${meta}.tmp.XXXXXX")" || return 1
  if ! python3 - "$normalized_dir/meta.json" "$label" "$reason" > "$tmp" <<'PY'
import json, sys, datetime
src, label, reason = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src, encoding="utf-8") as f:
    meta = json.load(f)
meta["label"] = label
meta["saved_at"] = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S.%fZ")
meta["save_reason"] = reason
json.dump(meta, sys.stdout, ensure_ascii=False, indent=2)
sys.stdout.write("\n")
PY
  then
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$meta"

  cp -a "$normalized_dir/auth.json" "$blob"
  chmod 600 "$blob" 2>/dev/null || true
  return 0
}

show_accounts() {
  local active
  active="$(get_active_fingerprint)"
  echo ""
  echo "================ 已保存账号 ================"
  local fps
  mapfile -t fps < <(get_saved_account_fingerprints)
  if ((${#fps[@]} == 0)); then
    echo "(无)"
  else
    local i fp meta mark label email plan account_id access_exp
    for i in "${!fps[@]}"; do
      fp="${fps[$i]}"
      meta="$ACCOUNTS_DIR/${fp}.meta.json"
      label="$(get_meta_field "$meta" label)"
      email="$(get_meta_field "$meta" email)"
      plan="$(get_meta_field "$meta" plan_type)"
      account_id="$(get_meta_field "$meta" account_id)"
      access_exp="$(get_meta_field "$meta" access_expires)"
      [[ -n "$access_exp" ]] || access_exp="unknown"
      mark=" "
      [[ "$fp" == "$active" ]] && mark="*"
      echo "${mark}[$((i + 1))] ${label} | ${email} | plan=${plan} | account=${account_id:0:12} | access_exp=${access_exp}"
    done
  fi
  echo "* 表示当前 auth.json 对应账号"
  echo "============================================="
}

# select_saved_account <prompt> —— 只把选中的 fingerprint 打印到 stdout，
# 不在这个函数里调用 show_accounts（调用方应先自行展示列表，避免展示文本混进
# 用来捕获返回值的命令替换里）。
select_saved_account() {
  local prompt="$1"
  local fps
  mapfile -t fps < <(get_saved_account_fingerprints)
  ((${#fps[@]} > 0)) || { warn "没有已保存账号。"; return 1; }
  local choice
  read -r -p "$prompt" choice
  [[ "$choice" =~ ^[0-9]+$ ]] || { warn "选择无效。"; return 1; }
  (( choice >= 1 && choice <= ${#fps[@]} )) || { warn "选择无效。"; return 1; }
  printf '%s' "${fps[$((choice - 1))]}"
}

get_active_fingerprint() {
  [[ -f "$AUTH_FILE" ]] || { printf ''; return 0; }
  local tmp
  tmp="$(mktemp -d)" || return 1
  if normalize_auth_json "$AUTH_FILE" "$tmp" >/dev/null 2>&1; then
    get_meta_field "$tmp/meta.json" fingerprint
  else
    printf ''
  fi
  rm -rf "$tmp"
}

sync_current_auth() {
  local reason="$1" quiet="${2:-false}"
  [[ -f "$AUTH_FILE" ]] || return 1
  local tmp errmsg
  tmp="$(mktemp -d)" || return 1
  if ! errmsg="$(normalize_auth_json "$AUTH_FILE" "$tmp" 2>&1)"; then
    [[ "$quiet" == "true" ]] || warn "当前 auth.json 无法收录：$errmsg"
    rm -rf "$tmp"
    return 1
  fi
  if save_account_info "$tmp" "" "$reason"; then
    if [[ "$quiet" != "true" ]]; then
      info "已同步当前账号到保险库：$(get_meta_field "$tmp/meta.json" email)"
    fi
    rm -rf "$tmp"
    return 0
  fi
  rm -rf "$tmp"
  return 1
}

# ==================== 备份（auth.json 专用） ====================
create_auth_backup() {
  local reason="$1" ts base
  ts="$(date +%Y%m%d%H%M%S)"
  base="$AUTH_BACKUPS_DIR/${ts}"
  local suffix=0
  while [[ -e "${base}.meta.json" ]]; do
    suffix=$((suffix + 1))
    base="$AUTH_BACKUPS_DIR/${ts}-${suffix}"
  done

  local exists="false" fingerprint="" email=""
  if [[ -f "$AUTH_FILE" ]]; then
    exists="true"
    cp -a "$AUTH_FILE" "${base}.auth.json"
    chmod 600 "${base}.auth.json" 2>/dev/null || true
    local tmp
    tmp="$(mktemp -d)"
    if normalize_auth_json "$AUTH_FILE" "$tmp" >/dev/null 2>&1; then
      fingerprint="$(get_meta_field "$tmp/meta.json" fingerprint)"
      email="$(get_meta_field "$tmp/meta.json" email)"
    fi
    rm -rf "$tmp"
  fi

  local tmp2
  tmp2="$(mktemp "${base}.meta.json.tmp.XXXXXX")"
  python3 - "$exists" "$reason" "$fingerprint" "$email" > "$tmp2" <<'PY'
import json, sys, datetime
exists, reason, fingerprint, email = sys.argv[1] == "true", sys.argv[2], sys.argv[3], sys.argv[4]
json.dump({
    "exists": exists,
    "captured_at": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
    "reason": reason,
    "fingerprint": fingerprint,
    "email": email,
}, sys.stdout, ensure_ascii=False, indent=2)
sys.stdout.write("\n")
PY
  chmod 600 "$tmp2" 2>/dev/null || true
  mv -f "$tmp2" "${base}.meta.json"

  prune_auth_backups
  printf '%s' "$base"
}

prune_auth_backups() {
  local keep
  keep="$(get_setting account backup_keep 30)"
  [[ "$keep" == "-1" ]] && return 0
  local metas
  mapfile -t metas < <(find "$AUTH_BACKUPS_DIR" -maxdepth 1 -name '*.meta.json' -type f -printf '%f\n' 2>/dev/null | sort -r)
  local count=${#metas[@]}
  (( count <= keep )) && return 0
  local i base
  for ((i = keep; i < count; i++)); do
    base="${metas[$i]%.meta.json}"
    rm -f "$AUTH_BACKUPS_DIR/${base}.meta.json" "$AUTH_BACKUPS_DIR/${base}.auth.json"
  done
}

restore_auth_backup_object() {
  local base="$1" exists
  exists="$(get_meta_field "${base}.meta.json" exists)"
  if [[ "$exists" == "true" ]]; then
    cp -a "${base}.auth.json" "$AUTH_FILE"
    chmod 600 "$AUTH_FILE" 2>/dev/null || true
  else
    rm -f "$AUTH_FILE"
  fi
}

# ==================== 校验 / 应用 ====================
test_codex_login_status() {
  [[ "$ACCOUNT_VERIFY_MODE" == "local" ]] && return 0
  command -v codex >/dev/null 2>&1 || {
    warn "未在 PATH 中找到 codex；已完成本地结构校验，但跳过 codex login status。"
    return 0
  }
  local out rc
  out="$(mktemp)"
  if timeout "$ACCOUNT_STATUS_TIMEOUT" codex login status >"$out" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  if [[ $rc -eq 0 ]] && grep -Fqi "Logged in using ChatGPT" "$out"; then
    info "codex login status：Logged in using ChatGPT"
    rm -f "$out"
    return 0
  fi
  warn "codex login status 返回：$(tr '\n' ' ' < "$out" 2>/dev/null)"
  rm -f "$out"
  return 1
}

verify_active_auth() {
  local expected_fp="$1"
  [[ -f "$AUTH_FILE" ]] || { warn "auth.json 不存在。"; return 1; }
  local tmp errmsg
  tmp="$(mktemp -d)"
  if ! errmsg="$(normalize_auth_json "$AUTH_FILE" "$tmp" 2>&1)"; then
    warn "auth.json 本地校验失败：$errmsg"
    rm -rf "$tmp"
    return 1
  fi
  local fp
  fp="$(get_meta_field "$tmp/meta.json" fingerprint)"
  rm -rf "$tmp"
  if [[ -n "$expected_fp" && "$fp" != "$expected_fp" ]]; then
    warn "写入后的账号指纹与目标账号不一致。"
    return 1
  fi
  test_codex_login_status
}

# apply_auth_text <标准化后的auth.json文件路径> <期望指纹> <备份原因>
apply_auth_text() {
  local src_file="$1" expected_fp="$2" reason="$3"
  get_account_common_settings
  assert_codex_not_running "$ACCOUNT_REFUSE_IF_RUNNING"
  sync_current_auth "before-switch" true || true

  local backup
  backup="$(create_auth_backup "$reason")"

  if ! cp -a "$src_file" "$AUTH_FILE"; then
    warn "写入 auth.json 失败。"
    restore_auth_backup_object "$backup"
    return 1
  fi
  chmod 600 "$AUTH_FILE" 2>/dev/null || true

  if ! verify_active_auth "$expected_fp"; then
    warn "切换后验证失败，正在恢复修改前的 auth.json。"
    restore_auth_backup_object "$backup"
    return 1
  fi
  sync_current_auth "after-switch" true || true
  return 0
}

import_and_switch() {
  local normalized_dir="$1"
  local email fingerprint
  email="$(get_meta_field "$normalized_dir/meta.json" email)"
  fingerprint="$(get_meta_field "$normalized_dir/meta.json" fingerprint)"

  local field expiry
  for field in access_expires id_expires; do
    expiry="$(get_meta_field "$normalized_dir/meta.json" "$field")"
    if [[ -n "$expiry" ]]; then
      if python3 -c '
import sys, datetime
try:
    dt = datetime.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
    sys.exit(0 if dt < datetime.datetime.now(datetime.timezone.utc) else 1)
except Exception:
    sys.exit(1)
' "$expiry"; then
        warn "${field} 已过期；Codex 需要依赖 refresh_token 在线刷新。"
      fi
    fi
  done

  local label
  read -r -p "账号别名（留空则使用邮箱 ${email}）：" label
  [[ -n "$label" ]] || label="$email"

  if ! save_account_info "$normalized_dir" "$label" "import"; then
    local blob="$ACCOUNTS_DIR/${fingerprint}.auth.json"
    if [[ -f "$blob" ]]; then
      cp -a "$blob" "$normalized_dir/auth.json"
      info "检测到保险库已有更新凭据，本次切换使用较新的保险库副本。"
    fi
  fi

  if apply_auth_text "$normalized_dir/auth.json" "$fingerprint" "before-import-switch"; then
    info "已导入并切换到：${label} <${email}>"
  else
    error "导入已保存到保险库，但活动账号切换失败并已回滚。"
  fi
}

# 无桌面 SSH 场景下的"剪贴板替代"：粘贴多行 JSON，单独一行输入 EOF 结束。
import_from_stdin_paste() {
  [[ -t 0 ]] || die "当前不是交互式终端，无法粘贴输入。"
  echo ""
  echo "请粘贴完整登录导出 JSON（可以是多行），粘贴完成后单独一行输入 EOF 并回车结束："
  local tmpfile line
  tmpfile="$(mktemp)"
  while IFS= read -r line; do
    [[ "$line" == "EOF" ]] && break
    printf '%s\n' "$line" >> "$tmpfile"
  done
  if [[ ! -s "$tmpfile" ]]; then
    rm -f "$tmpfile"
    die "未读取到任何内容。"
  fi

  local normalized_dir errmsg
  normalized_dir="$(mktemp -d)"
  if ! errmsg="$(normalize_auth_json "$tmpfile" "$normalized_dir" 2>&1)"; then
    rm -f "$tmpfile"
    rm -rf "$normalized_dir"
    die "$errmsg"
  fi
  rm -f "$tmpfile"
  import_and_switch "$normalized_dir"
  rm -rf "$normalized_dir"
}

switch_to_saved_account() {
  show_accounts
  local fp
  fp="$(select_saved_account "输入要切换的账号序号：")" || return 0
  [[ -n "$fp" ]] || return 0
  local blob="$ACCOUNTS_DIR/${fp}.auth.json" meta="$ACCOUNTS_DIR/${fp}.meta.json"
  [[ -f "$blob" && -f "$meta" ]] || die "账号保险库文件缺失。"
  local label email
  label="$(get_meta_field "$meta" label)"
  email="$(get_meta_field "$meta" email)"
  if apply_auth_text "$blob" "$fp" "before-saved-account-switch"; then
    info "已切换到：${label} <${email}>"
  else
    error "切换失败并已回滚。"
  fi
}

delete_saved_account() {
  show_accounts
  local fp
  fp="$(select_saved_account "输入要从保险库删除的账号序号：")" || return 0
  [[ -n "$fp" ]] || return 0
  if [[ "$fp" == "$(get_active_fingerprint)" ]]; then
    warn "不能删除当前活动账号；请先切换到其他账号。"
    return 0
  fi
  local meta="$ACCOUNTS_DIR/${fp}.meta.json"
  local label email confirm
  label="$(get_meta_field "$meta" label)"
  email="$(get_meta_field "$meta" email)"
  read -r -p "确认删除 ${label} <${email}>？输入 DELETE：" confirm
  if [[ "$confirm" != "DELETE" ]]; then
    info "已取消删除。"
    return 0
  fi
  rm -f "$ACCOUNTS_DIR/${fp}.auth.json" "$meta"
  info "已删除所选账号的保险库副本。"
}

# ==================== 首次快照 / 时间戳备份恢复（auth.json） ====================
save_original_auth_snapshot() {
  [[ -f "$AUTH_ORIGINAL_META" ]] && return 0
  local exists="false" fingerprint="" email=""
  if [[ -f "$AUTH_FILE" ]]; then
    exists="true"
    cp -a "$AUTH_FILE" "$AUTH_ORIGINAL_FILE"
    chmod 600 "$AUTH_ORIGINAL_FILE" 2>/dev/null || true
    local tmp
    tmp="$(mktemp -d)"
    if normalize_auth_json "$AUTH_FILE" "$tmp" >/dev/null 2>&1; then
      fingerprint="$(get_meta_field "$tmp/meta.json" fingerprint)"
      email="$(get_meta_field "$tmp/meta.json" email)"
    fi
    rm -rf "$tmp"
  fi
  local tmp2
  tmp2="$(mktemp "${AUTH_ORIGINAL_META}.tmp.XXXXXX")"
  python3 - "$exists" "$fingerprint" "$email" > "$tmp2" <<'PY'
import json, sys, datetime
exists, fingerprint, email = sys.argv[1] == "true", sys.argv[2], sys.argv[3]
json.dump({
    "exists": exists,
    "captured_at": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
    "fingerprint": fingerprint,
    "email": email,
}, sys.stdout, ensure_ascii=False, indent=2)
sys.stdout.write("\n")
PY
  chmod 600 "$tmp2" 2>/dev/null || true
  mv -f "$tmp2" "$AUTH_ORIGINAL_META"
}

restore_original_auth() {
  [[ -f "$AUTH_ORIGINAL_META" ]] || { warn "没有首次 auth.json 快照。"; return 0; }
  get_account_common_settings
  assert_codex_not_running "$ACCOUNT_REFUSE_IF_RUNNING"
  sync_current_auth "before-restore-original" true || true
  local rollback exists
  rollback="$(create_auth_backup "rollback-before-restore-original")"
  exists="$(get_meta_field "$AUTH_ORIGINAL_META" exists)"
  if [[ "$exists" == "true" ]]; then
    cp -a "$AUTH_ORIGINAL_FILE" "$AUTH_FILE"
    chmod 600 "$AUTH_FILE" 2>/dev/null || true
    if ! verify_active_auth "$(get_meta_field "$AUTH_ORIGINAL_META" fingerprint)"; then
      warn "首次快照恢复后验证失败，正在回滚。"
      restore_auth_backup_object "$rollback"
      return 1
    fi
    sync_current_auth "after-restore-original" true || true
  else
    rm -f "$AUTH_FILE"
  fi
  info "已恢复首次运行前的 auth.json。"
}

list_auth_backups() {
  find "$AUTH_BACKUPS_DIR" -maxdepth 1 -name '*.meta.json' -type f -printf '%f\n' 2>/dev/null | sed 's/\.meta\.json$//' | sort -r
}

restore_account_timestamp_backup() {
  local bases
  mapfile -t bases < <(list_auth_backups)
  ((${#bases[@]} > 0)) || { warn "没有 auth.json 时间戳备份。"; return 0; }

  echo ""
  echo "================ auth.json 备份 ============="
  local i base meta email
  for i in "${!bases[@]}"; do
    base="${bases[$i]}"
    meta="$AUTH_BACKUPS_DIR/${base}.meta.json"
    email="$(get_meta_field "$meta" email)"
    [[ -n "$email" ]] || email="(无账号/无法识别)"
    echo "[$((i + 1))] $(get_meta_field "$meta" captured_at) | ${email} | $(get_meta_field "$meta" reason)"
  done
  local choice
  read -r -p "输入要恢复的备份序号：" choice
  [[ "$choice" =~ ^[0-9]+$ ]] || { warn "选择无效。"; return 0; }
  (( choice >= 1 && choice <= ${#bases[@]} )) || { warn "选择无效。"; return 0; }

  get_account_common_settings
  assert_codex_not_running "$ACCOUNT_REFUSE_IF_RUNNING"
  sync_current_auth "before-restore-backup" true || true
  local rollback selected_base selected_meta exists
  rollback="$(create_auth_backup "rollback-before-restore-backup")"
  selected_base="${bases[$((choice - 1))]}"
  selected_meta="$AUTH_BACKUPS_DIR/${selected_base}.meta.json"
  exists="$(get_meta_field "$selected_meta" exists)"
  if [[ "$exists" == "true" ]]; then
    cp -a "$AUTH_BACKUPS_DIR/${selected_base}.auth.json" "$AUTH_FILE"
    chmod 600 "$AUTH_FILE" 2>/dev/null || true
    if ! verify_active_auth "$(get_meta_field "$selected_meta" fingerprint)"; then
      warn "恢复失败，正在回滚。"
      restore_auth_backup_object "$rollback"
      return 1
    fi
    sync_current_auth "after-restore-backup" true || true
  else
    rm -f "$AUTH_FILE"
  fi
  info "已恢复所选 auth.json 备份。"
}

# ==================== config.toml 里的 cli_auth_credentials_store ====================
get_current_provider() {
  [[ -f "$CONFIG_FILE" ]] || { printf 'openai'; return 0; }
  local v
  v="$(sed -n 's/^[[:space:]]*model_provider[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" | head -1)"
  [[ -n "$v" ]] && printf '%s' "$v" || printf 'openai'
}

get_credential_store_mode() {
  [[ -f "$CONFIG_FILE" ]] || { printf ''; return 0; }
  sed -n 's/^[[:space:]]*cli_auth_credentials_store[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" | tail -1
}

save_original_config_snapshot() {
  [[ -f "$CONFIG_ORIGINAL_META" ]] && return 0
  local exists="false"
  if [[ -f "$CONFIG_FILE" ]]; then
    exists="true"
    cp -a "$CONFIG_FILE" "$CONFIG_ORIGINAL_FILE"
    chmod 600 "$CONFIG_ORIGINAL_FILE" 2>/dev/null || true
  fi
  local tmp
  tmp="$(mktemp "${CONFIG_ORIGINAL_META}.tmp.XXXXXX")"
  python3 - "$exists" > "$tmp" <<'PY'
import json, sys, datetime
exists = sys.argv[1] == "true"
json.dump({"exists": exists, "captured_at": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S.%fZ")}, sys.stdout, ensure_ascii=False, indent=2)
sys.stdout.write("\n")
PY
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$CONFIG_ORIGINAL_META"
}

backup_config() {
  local reason="$1" ts base exists="false"
  ts="$(date +%Y%m%d%H%M%S)"
  base="$ACCOUNT_CONFIG_BACKUPS_DIR/${ts}"
  local suffix=0
  while [[ -e "${base}.meta.json" ]]; do
    suffix=$((suffix + 1))
    base="$ACCOUNT_CONFIG_BACKUPS_DIR/${ts}-${suffix}"
  done
  if [[ -f "$CONFIG_FILE" ]]; then
    exists="true"
    cp -a "$CONFIG_FILE" "${base}.config.toml"
    chmod 600 "${base}.config.toml" 2>/dev/null || true
  fi
  local tmp
  tmp="$(mktemp "${base}.meta.json.tmp.XXXXXX")"
  python3 - "$exists" "$reason" > "$tmp" <<'PY'
import json, sys, datetime
exists, reason = sys.argv[1] == "true", sys.argv[2]
json.dump({"exists": exists, "captured_at": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S.%fZ"), "reason": reason}, sys.stdout, ensure_ascii=False, indent=2)
sys.stdout.write("\n")
PY
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "${base}.meta.json"
}

ensure_file_credential_store() {
  local mode
  mode="$(get_credential_store_mode)"
  [[ "$mode" == "file" ]] && return 0

  get_account_common_settings
  if [[ "$ACCOUNT_ENFORCE_FILE_STORE" != "true" ]]; then
    if [[ "$mode" == "auto" || "$mode" == "keyring" ]]; then
      die "config.toml 当前 cli_auth_credentials_store=$mode；账号模块只管理 auth.json 文件模式。"
    fi
    [[ -f "$AUTH_FILE" ]] || die "未找到 auth.json，且未强制文件认证模式。"
    return 0
  fi

  save_original_config_snapshot
  backup_config "set-cli-auth-credentials-store-file"

  local tmp
  tmp="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")"
  {
    echo "# Managed by Codex 接口管理 (account module, 原 402) for deterministic auth.json switching"
    echo 'cli_auth_credentials_store = "file"'
    echo ""
    if [[ -f "$CONFIG_FILE" ]]; then
      grep -v '^[[:space:]]*cli_auth_credentials_store[[:space:]]*=' "$CONFIG_FILE" || true
    fi
  } > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$CONFIG_FILE"

  [[ "$(get_credential_store_mode)" == "file" ]] || die "无法将 cli_auth_credentials_store 设置为 file。"
  info "已将 Codex 凭据存储模式设置为 file；原 config.toml 已备份。"
}

restore_original_config() {
  [[ -f "$CONFIG_ORIGINAL_META" ]] || { warn "没有首次 config.toml 快照。"; return 0; }
  get_account_common_settings
  assert_codex_not_running "$ACCOUNT_REFUSE_IF_RUNNING"
  backup_config "before-restore-original-config"
  local exists
  exists="$(get_meta_field "$CONFIG_ORIGINAL_META" exists)"
  if [[ "$exists" == "true" ]]; then
    cp -a "$CONFIG_ORIGINAL_FILE" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
  else
    rm -f "$CONFIG_FILE"
  fi
  info "已恢复首次运行前的 config.toml。"
  warn "如果 account.enforce_file_auth_store 仍为 true，下次启动本工具会再次把 cli_auth_credentials_store 设回 file；如需永久保留原模式，请把该设置改为 false。"
}

# ==================== 状态展示 / 安全提示 ====================
show_account_current_status() {
  echo ""
  echo "================ Codex 账号（account）当前状态 ================="
  echo "Codex Home: $CODEX_DIR"
  echo "auth.json: $AUTH_FILE"
  echo "保险库: $ACCOUNTS_DIR"
  echo "认证存储模式: $(get_credential_store_mode)"
  echo "model_provider: $(get_current_provider)"
  if [[ -f "$AUTH_FILE" ]]; then
    local tmp errmsg
    tmp="$(mktemp -d)"
    if errmsg="$(normalize_auth_json "$AUTH_FILE" "$tmp" 2>&1)"; then
      echo "当前账号: $(get_meta_field "$tmp/meta.json" email)"
      echo "账号指纹: $(get_meta_field "$tmp/meta.json" fingerprint)"
      echo "计划类型: $(get_meta_field "$tmp/meta.json" plan_type)"
      echo "account_id: $(get_meta_field "$tmp/meta.json" account_id)"
      echo "last_refresh: $(get_meta_field "$tmp/meta.json" last_refresh)"
      echo "access_token 过期时间: $(get_meta_field "$tmp/meta.json" access_expires)"
    else
      echo "当前账号: (auth.json 无法解析：$errmsg)"
    fi
    rm -rf "$tmp"
  else
    echo "当前账号: (auth.json 不存在)"
  fi
  echo "=================================================================="
  show_accounts
}

show_account_security_warnings() {
  [[ -z "${OPENAI_API_KEY:-}" ]] || warn "当前环境变量设置了 OPENAI_API_KEY；它可能改变 Codex 的认证选择。"
  [[ -z "${CODEX_API_KEY:-}" ]] || warn "当前环境变量设置了 CODEX_API_KEY；它可能覆盖 auth.json 认证。"
  local provider
  provider="$(get_current_provider)"
  [[ "$provider" == "openai" ]] || warn "当前 model_provider=$provider。账号可管理，但这些 ChatGPT OAuth 凭据通常只在 OpenAI 认证路径中使用。"
}

# 由 menu.sh 在 $CODEX_DIR/$CONFIG_FILE/$AUTH_FILE 就绪后调用一次。
init_account_module() {
  init_account_dirs
  save_original_auth_snapshot
  ensure_file_credential_store
  show_account_security_warnings
  get_account_common_settings
  if [[ "$ACCOUNT_AUTO_SYNC" == "true" ]]; then
    sync_current_auth "startup-auto-sync" true || true
  fi
}
