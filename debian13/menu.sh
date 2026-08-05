#!/usr/bin/env bash
# Codex 接口管理 - menu.sh（统一入口，Debian 13）
#
# 编排 provider.sh（原 401：CPA / DeepSeek 供应商切换，只改 config.toml）
# 与 account.sh（原 402：账号导入/切换，只改 auth.json）两个模块，提供
# 一个持续运行的统一菜单（选一项、做完、回到菜单，直到选 0 退出）。
#
# 因为整个菜单是常驻循环，而 common.sh/provider.sh/account.sh 里的
# die() 会直接 exit，这里对每个会触达 die() 的分支都用 ( 子shell ) 包一层：
# 子 shell 里的 exit 只会结束这一次操作，不会带崩整个菜单循环
# （效果上等价于 Windows 版 menu.ps1 里的 try/catch）。
#
# 调用约定：由本地 bootstrap 脚本（403-Codex-Interface-Manager-Debian13.sh）
# 依次 source common.sh -> provider.sh -> account.sh -> menu.sh，
# 再调用 main_menu 进入主循环。

show_account_switch_submenu() {
  while true; do
    echo ""
    echo "---- 官方登录 / 账号切换 ----"
    echo "1) 粘贴 JSON 并立即切换（推荐；粘贴完成后单独一行输入 EOF 结束）"
    echo "2) 切换到已保存账号"
    echo "3) 删除已保存账号"
    echo "0) 返回上级菜单"
    local choice
    read -r -p "请选择：" choice
    case "$choice" in
      1) ( import_from_stdin_paste ) || warn "本次导入未成功。" ; return ;;
      2) ( switch_to_saved_account ) || warn "本次切换未成功。" ; return ;;
      3) ( delete_saved_account ) || true ; return ;;
      0) return ;;
      *) warn "无效选项：$choice" ;;
    esac
  done
}

show_backup_management_submenu() {
  while true; do
    echo ""
    echo "---- 备份管理 ----"
    echo "1) 恢复账号（auth.json）时间戳备份"
    echo "2) 恢复首次运行前的 auth.json"
    echo "3) 恢复首次运行前的 config.toml（账号模块视角，即 cli_auth_credentials_store 相关备份）"
    echo "4) 恢复供应商（config.toml）配置时间戳备份"
    echo "5) 手动同步当前 auth.json 到账号保险库"
    echo "0) 返回上级菜单"
    local choice
    read -r -p "请选择：" choice
    case "$choice" in
      1) ( restore_account_timestamp_backup ) || true ; return ;;
      2) ( restore_original_auth ) || true ; return ;;
      3) ( restore_original_config ) || true ; return ;;
      4) ( restore_provider_timestamp_backup ) || true ; return ;;
      5)
        (
          get_account_common_settings
          assert_codex_not_running "$ACCOUNT_REFUSE_IF_RUNNING"
          sync_current_auth "manual-sync" false || { warn "没有可同步的有效 auth.json。"; exit 0; }
        ) || true
        return
        ;;
      0) return ;;
      *) warn "无效选项：$choice" ;;
    esac
  done
}

show_unified_status() {
  ( show_account_current_status ) || true
  ( show_provider_status_and_test ) || true
}

invoke_manager_update_check() {
  if declare -f sync_manager_modules_from_github >/dev/null 2>&1; then
    sync_manager_modules_from_github
  else
    warn "当前运行方式不支持在线检查更新（未找到同步函数，可能是离线/独立文件运行模式）。"
  fi
}

main_menu() {
  echo ""
  echo "========================================================"
  echo " Codex 接口管理（Debian 13）"
  echo " CODEX_HOME: $CODEX_DIR"
  echo "========================================================"

  while true; do
    echo ""
    echo "1) 官方登录 / 账号切换"
    echo "2) 切换到 CPA 接口"
    echo "3) 切换到 DeepSeek V4 Flash"
    echo "4) 恢复官方订阅（还原 config.toml 到切换前状态，不影响账号）"
    echo "5) 修改供应商参数（CPA / DeepSeek 的地址、模型、推理强度）"
    echo "6) 状态总览（当前账号 + 当前供应商 + 连通性测试）"
    echo "7) 备份管理"
    echo "8) 检查更新"
    echo "0) 退出"

    [[ -t 0 ]] || { info "非交互式终端，已退出。"; return 0; }
    local choice
    read -r -p "请选择 [0-8]：" choice || { echo ""; info "已退出。"; return 0; }

    case "$choice" in
      1) show_account_switch_submenu ;;
      2) ( switch_to_provider_mode cpa ) || warn "切换到 CPA 未成功。" ;;
      3) ( switch_to_provider_mode deepseek ) || warn "切换到 DeepSeek 未成功。" ;;
      4) ( restore_provider_original ) || warn "恢复官方订阅未成功。" ;;
      5)
        local mode_choice
        read -r -p "修改哪个供应商的参数？[1=CPA / 2=DeepSeek]：" mode_choice
        case "$mode_choice" in
          1) ( edit_provider_settings cpa ) || true ;;
          2) ( edit_provider_settings deepseek ) || true ;;
          *) warn "无效选择。" ;;
        esac
        ;;
      6) show_unified_status ;;
      7) show_backup_management_submenu ;;
      8) ( invoke_manager_update_check ) || true ;;
      0) info "已退出。"; return 0 ;;
      *) warn "无效选项：$choice" ;;
    esac
  done
}
