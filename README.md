# codex-manage

Codex CLI 的"接口管理"模块脚本仓库：账号切换（auth.json）+ 供应商切换（CPA / DeepSeek V4 Flash，config.toml）统一菜单。

这个仓库本身**不包含任何密钥**。所有 API Key、refresh_token 等敏感信息都只保存在使用者本机的 DPAPI 加密保险库里，从不提交到这里。

## 目录结构

```
win11/
  common.ps1    公共基础设施（日志、ACL、DPAPI、原子写入、本地设置读写等）
  provider.ps1  CPA / DeepSeek 供应商切换模块（只改 config.toml）
  account.ps1   账号导入/切换模块（只改 auth.json）
  menu.ps1      统一菜单，dot-source 以上三个文件
PROVIDERS.md    供应商接入规划文档
```

`debian13/` 暂未提供（账号切换的 bash 版本还没有移植），会在后续版本补上。

## 本地怎么用

这几个文件不直接运行，而是被本机的一个很薄的 bootstrap 脚本
（`403-Codex-Interface-Manager-Win11.ps1`，不在这个仓库里，是本机 snippet）
在首次运行 / 手动"检查更新"时同步到 `<CODEX_HOME>\codex-interface-manager\src\`，
再 dot-source 本地缓存的副本执行。这样：

- 本仓库公开也不会暴露任何人的私有配置或密钥（个性化的 base_url/model 等在首次使用时
  交互式输入，保存在本机 `<CODEX_HOME>\codex-interface-manager\local.settings.json`，
  不会同步回这个仓库）。
- 本地运行时不需要网络也能跑（只有首次同步或手动检查更新时才需要联网拉取脚本本身）。

## 安全边界

- `provider.ps1` 只碰 `config.toml` 里的 provider 相关字段和 `cpa-switcher-401-win11` 状态目录，**从不**读取/修改/恢复 `auth.json`。
- `account.ps1` 只碰 `auth.json`（以及为保证切换生效而管理的 `cli_auth_credentials_store` 这一项）和 `account-switcher-402-win11` 状态目录，**从不**修改 provider 相关字段。
- 两个模块各自的时间戳备份、首次原始快照互不覆盖。

## 参考

- Codex 官方文档：https://learn.chatgpt.com/docs
- DeepSeek × Codex 接入文档：https://api-docs.deepseek.com/zh-cn/quick_start/agent_integrations/codex/
- 供应商接入规划：见 [PROVIDERS.md](./PROVIDERS.md)
