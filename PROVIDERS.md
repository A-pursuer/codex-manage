# 供应商接入规划（PROVIDERS.md）

本文档记录 Codex 接口管理（`win11/provider.ps1`）已支持、以及未来打算评估接入的模型供应商。

新增一个供应商 **不需要**新框架/插件系统，只需要：
1. 在 `provider.ps1` 的 `Get-ProviderRuntimeSettings`、`Write-ProviderConfig`、`Get-ModeLabel`、
   `Test-ResponsesEndpoint`（expected 标记）等函数里，仿照现有 `cpa`/`deepseek` 分支加一个新的 `$Mode` 分支。
2. 在下表加一行，记录接入方式、要求，方便以后回顾"当时为什么这么接"。
3. 涉及个人基础设施细节（自建代理地址等）的默认值留空，靠 `Read-SettingOrPrompt` 首次使用时交互式输入，
   不要把个人 base_url/model 写死进会公开托管到 GitHub 的脚本正文。

## 已支持

| 供应商 | 状态 | 接入方式 | wire_api | 自定义 model_catalog_json | 备注 |
|---|---|---|---|---|---|
| OpenAI 官方 | 已支持 | `auth.json`（ChatGPT OAuth，account.ps1 管理） | - | 不需要 | 走官方登录/账号切换，不经过 provider.ps1 |
| CLIProxyAPI（CPA） | 已支持 | `config.toml` command-backed bearer token（本地 PowerShell helper 读取 DPAPI 存的 key） | responses | 不需要 | 自建/本地代理，`base_url` 必须以 `/v1` 结尾；地址与模型 ID 因人而异，首次使用时交互式输入 |
| DeepSeek V4 Flash | 已支持 | `config.toml` command-backed bearer token + 自定义 `model_catalog_json` | responses | 需要（`Write-DeepSeekCatalog` 生成） | 官方 Responses API 集成，要求 Codex CLI ≥ 0.144.0，官方文档：https://api-docs.deepseek.com/zh-cn/quick_start/agent_integrations/codex/ |

## 规划中（尚未实现，仅记录接入前需要确认的信息）

| 供应商 | 状态 | 需确认事项 |
|---|---|---|
| Kimi / Moonshot | 规划中 | base_url、是否原生支持 Responses API（`wire_api="responses"`）还是只有 Chat Completions、鉴权方式（API Key 是否可直接当 bearer token）、是否需要自定义 model_catalog_json、Codex 版本要求 |
| 智谱 GLM | 规划中 | 同上；另外确认是否有独立的 Anthropic/OpenAI 兼容层导致字段命名不同 |
| 阿里 Qwen | 规划中 | 同上；确认国内/国际版 endpoint 是否一致 |
| OpenRouter | 规划中 | OpenRouter 本身是聚合网关，需要确认它转发的具体模型是否兼容 Codex 的 Responses API 语义（工具调用、流式等），可能需要按具体子模型分别验证 |

## 接入检查清单（评估一个新供应商时过一遍）

- [ ] 有没有 Responses API（`/v1/responses`）？如果只有 Chat Completions，Codex 当前版本不支持（`wire_api="chat"` 已被硬性禁用）。
- [ ] `/v1/models` 是否能列出目标模型 ID，用于 `Test-ModelsEndpoint` 校验。
- [ ] 鉴权：纯 Bearer Token（可以复用现有 command-backed 机制）还是需要额外 header/签名（可能需要扩展 `auth` 配置或 `http_headers`）？
- [ ] 是否需要自定义 `model_catalog_json`（模型不在 Codex 内置目录里时必需，参考 `Write-DeepSeekCatalog`）。
- [ ] 最低 Codex CLI 版本要求。
- [ ] 官方文档链接（存进这份表格备查）。
