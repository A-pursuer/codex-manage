#requires -Version 5.1
<#
Codex 接口管理 - provider.ps1（供应商切换模块：CPA / DeepSeek V4 Flash）

改编自 401-Codex-CPA-DeepSeek-Switcher-Win11.ps1，业务逻辑不变，调整点：
- 依赖 common.ps1 提供的公共基础设施，本文件不再重复定义。
- 顶部硬编码的个人基础设施细节（CPA 的 base_url / model 等）改为
  从本地 local.settings.json 读取，缺失时交互式输入并记住，
  这样本文件可以安全地公开托管在 GitHub 仓库里，不会泄露个人代理地址。
  DeepSeek 官方地址/型号是公开信息，默认值直接保留。
- 不再包含独立菜单循环和单实例锁，改为暴露函数，由 menu.ps1 统一编排、
  统一持有单实例锁。
- 只读写 config.toml 与 <CODEX_HOME>\cpa-switcher-401-win11\ 状态目录，
  从不读取、修改、恢复 auth.json，不干扰 account.ps1 管理的账号数据。

本文件不能单独运行，需在 common.ps1 之后被 menu.ps1 dot-source。
依赖 menu.ps1 预先设置好的共享变量：$script:CodexHome、$script:ConfigFile。
#>

Set-StrictMode -Version 2.0

# 供应商相关状态与 DPAPI entropy 沿用旧版 401 的路径/常量，
# 保证如果这台机器之前跑过独立版 401，其备份/密钥仍可被识别、解密。
$script:ProviderDpapiEntropy = [Text.Encoding]::UTF8.GetBytes('401-codex-cpa-win11-dpapi-v1')

function Test-ReasoningEffort([string]$Value) {
    return $Value -in @('minimal', 'low', 'medium', 'high', 'xhigh')
}

function Test-PlanReasoningEffort([string]$Value) {
    return $Value -in @('none', 'minimal', 'low', 'medium', 'high', 'xhigh')
}

function Test-UrlLooksValid([string]$Value) {
    $uri = $null
    return [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -in @('http', 'https')
}

# 读取（必要时交互式补全）本次切换所需的全部参数。
# CPA 的 base_url/model 默认值为空，因此首次使用会强制询问；
# DeepSeek 官方地址/型号已有安全默认值，不会打扰用户。
function Get-ProviderRuntimeSettings([string]$Mode) {
    $testMode = Get-SettingValue 'provider' 'test_mode' 'full'
    $httpTimeout = [int](Get-SettingValue 'provider' 'http_timeout_sec' 60)
    $codexTestTimeout = [int](Get-SettingValue 'provider' 'codex_test_timeout_sec' 120)
    $refuseIfRunning = [bool](Get-SettingValue 'provider' 'refuse_if_codex_running' $true)
    $backupKeep = [int](Get-SettingValue 'provider' 'backup_keep' 30)

    if ($testMode -notin @('full', 'api', 'none')) { Stop-WithError 'provider.test_mode 只能为 full / api / none。' }
    if ($httpTimeout -lt 5) { Stop-WithError 'provider.http_timeout_sec 不应小于 5 秒。' }
    if ($codexTestTimeout -lt 10) { Stop-WithError 'provider.codex_test_timeout_sec 不应小于 10 秒。' }
    if ($backupKeep -eq 0 -or $backupKeep -lt -1) { Stop-WithError 'provider.backup_keep 只能为 -1 或大于等于 1。' }

    $result = [pscustomobject]@{
        TestMode = $testMode
        HttpTimeout = $httpTimeout
        CodexTestTimeout = $codexTestTimeout
        RefuseIfRunning = $refuseIfRunning
        BackupKeep = $backupKeep
        BaseUrl = ''
        Model = ''
        ReasoningEffort = ''
        PlanReasoningEffort = ''
        SupportsWebsockets = $false
    }

    if ($Mode -eq 'cpa') {
        $result.BaseUrl = Normalize-Url (Read-SettingOrPrompt -Section 'cpa' -Key 'base_url' -Default '' `
            -PromptText 'CPA 地址（必须以 /v1 结尾，例如 http://127.0.0.1:8317/v1）' `
            -Validator { param($v) (Test-UrlLooksValid $v) -and $v.EndsWith('/v1', [StringComparison]::OrdinalIgnoreCase) })
        $result.Model = Read-SettingOrPrompt -Section 'cpa' -Key 'model' -Default '' `
            -PromptText 'CPA /v1/models 中实际存在的模型 ID' `
            -Validator { param($v) $v -and ($v -notmatch '[\r\n]') }
        $result.ReasoningEffort = Read-SettingOrPrompt -Section 'cpa' -Key 'reasoning_effort' -Default 'high' `
            -PromptText '推理强度（minimal/low/medium/high/xhigh）' -Validator { param($v) Test-ReasoningEffort $v }
        $result.PlanReasoningEffort = Read-SettingOrPrompt -Section 'cpa' -Key 'plan_reasoning_effort' -Default 'high' `
            -PromptText 'Plan 模式推理强度（none/minimal/low/medium/high/xhigh）' -Validator { param($v) Test-PlanReasoningEffort $v }
        $result.SupportsWebsockets = [bool](Get-SettingValue 'cpa' 'supports_websockets' $false)
    } elseif ($Mode -eq 'deepseek') {
        $result.BaseUrl = Normalize-Url (Read-SettingOrPrompt -Section 'deepseek' -Key 'base_url' -Default 'https://api.deepseek.com' `
            -PromptText 'DeepSeek 官方 Responses API 根地址（不要附加 /v1）' `
            -Validator { param($v) (Test-UrlLooksValid $v) -and (-not $v.EndsWith('/v1', [StringComparison]::OrdinalIgnoreCase)) })
        $result.Model = Read-SettingOrPrompt -Section 'deepseek' -Key 'model' -Default 'deepseek-v4-flash' `
            -PromptText 'DeepSeek 模型 ID（当前官方集成仅支持 deepseek-v4-flash）' `
            -Validator { param($v) $v -eq 'deepseek-v4-flash' }
        $result.ReasoningEffort = Read-SettingOrPrompt -Section 'deepseek' -Key 'reasoning_effort' -Default 'high' `
            -PromptText '推理强度（minimal/low/medium/high/xhigh）' -Validator { param($v) Test-ReasoningEffort $v }
        $result.PlanReasoningEffort = Read-SettingOrPrompt -Section 'deepseek' -Key 'plan_reasoning_effort' -Default 'high' `
            -PromptText 'Plan 模式推理强度（none/minimal/low/medium/high/xhigh）' -Validator { param($v) Test-PlanReasoningEffort $v }
    } else {
        Stop-WithError "未知模式：$Mode"
    }

    return $result
}

# 强制重新输入某个模式的参数（供菜单"修改供应商参数"使用）。
function Edit-ProviderSettings([string]$Mode) {
    if ($Mode -eq 'cpa') {
        [void](Read-SettingOrPrompt -Section 'cpa' -Key 'base_url' -Default (Get-SettingValue 'cpa' 'base_url' '') -PromptText 'CPA 地址（必须以 /v1 结尾）' -Validator { param($v) (Test-UrlLooksValid $v) -and $v.EndsWith('/v1', [StringComparison]::OrdinalIgnoreCase) } -ForcePrompt)
        [void](Read-SettingOrPrompt -Section 'cpa' -Key 'model' -Default (Get-SettingValue 'cpa' 'model' '') -PromptText 'CPA 模型 ID' -Validator { param($v) $v -and ($v -notmatch '[\r\n]') } -ForcePrompt)
        [void](Read-SettingOrPrompt -Section 'cpa' -Key 'reasoning_effort' -Default (Get-SettingValue 'cpa' 'reasoning_effort' 'high') -PromptText '推理强度' -Validator { param($v) Test-ReasoningEffort $v } -ForcePrompt)
    } elseif ($Mode -eq 'deepseek') {
        [void](Read-SettingOrPrompt -Section 'deepseek' -Key 'base_url' -Default (Get-SettingValue 'deepseek' 'base_url' 'https://api.deepseek.com') -PromptText 'DeepSeek 根地址' -Validator { param($v) (Test-UrlLooksValid $v) -and (-not $v.EndsWith('/v1')) } -ForcePrompt)
        [void](Read-SettingOrPrompt -Section 'deepseek' -Key 'reasoning_effort' -Default (Get-SettingValue 'deepseek' 'reasoning_effort' 'high') -PromptText '推理强度' -Validator { param($v) Test-ReasoningEffort $v } -ForcePrompt)
    } else {
        Stop-WithError "未知模式：$Mode"
    }
    Write-Info '已更新并保存到本地设置文件。'
}

function Get-EffectiveSecret([string]$Mode) {
    $label = if ($Mode -eq 'cpa') { 'CPA API Key' } elseif ($Mode -eq 'deepseek') { 'DeepSeek API Key' } else { Stop-WithError "未知模式：$Mode" }

    Write-Host ''
    Write-Host "请输入 $label（输入内容不会显示；留空则尝试沿用已保存的密钥）：" -ForegroundColor Yellow
    $secure = Read-Host -AsSecureString
    $plain = Convert-SecureStringToPlainText $secure
    if ([string]::IsNullOrWhiteSpace($plain)) {
        try {
            $existing = Get-SavedProviderApiKey $Mode
            if ($existing) { return $existing }
        } catch {}
        Stop-WithError "$label 不能为空，且没有可沿用的已保存密钥。"
    }
    if ($plain -match '[\r\n]') { Stop-WithError "$label 不得包含换行。" }
    return $plain.Trim()
}

function Initialize-ProviderDirectories {
    foreach ($dir in @($script:ProviderStateRoot, $script:ProviderBackupsDir, $script:ProviderOriginalDir)) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $dir -Force)
        }
    }
    Set-RestrictedDirectoryAcl $script:ProviderStateRoot
    Set-RestrictedDirectoryAcl $script:ProviderBackupsDir
    Set-RestrictedDirectoryAcl $script:ProviderOriginalDir
}

function Get-ProviderSnapshotTargets {
    return [ordered]@{
        'config' = [pscustomobject]@{ Path = $script:ConfigFile; Kind = 'text' }
        'token' = [pscustomobject]@{ Path = $script:CpaTokenFile; Kind = 'binary' }
        'helper' = [pscustomobject]@{ Path = $script:ProviderHelperFile; Kind = 'text' }
        'marker' = [pscustomobject]@{ Path = $script:ProviderMarkerFile; Kind = 'text' }
        'deepseek-token' = [pscustomobject]@{ Path = $script:DeepSeekTokenFile; Kind = 'binary' }
        'deepseek-catalog' = [pscustomobject]@{ Path = $script:DeepSeekCatalogFile; Kind = 'text' }
    }
}

function Save-ProviderArtifactToSnapshot([string]$SnapshotDir, [string]$LogicalName, [string]$SourcePath, [string]$Kind) {
    $exists = Test-Path -LiteralPath $SourcePath -PathType Leaf
    $item = [ordered]@{
        name = $LogicalName
        source_path = $SourcePath
        kind = $Kind
        exists = $exists
        blob = ''
    }

    if ($exists) {
        if ($Kind -eq 'text') {
            $blobName = $LogicalName + '.text.dpapi'
            Save-ProtectedText -Path (Join-Path $SnapshotDir $blobName) -Text ([IO.File]::ReadAllText($SourcePath, [Text.Encoding]::UTF8)) -Entropy $script:ProviderDpapiEntropy -StateRoot $script:ProviderStateRoot
        } elseif ($Kind -eq 'binary') {
            $blobName = $LogicalName + '.bin'
            Write-BytesAtomic -Path (Join-Path $SnapshotDir $blobName) -Bytes ([IO.File]::ReadAllBytes($SourcePath))
            Set-RestrictedFileAcl -Path (Join-Path $SnapshotDir $blobName) -StateRoot $script:ProviderStateRoot
        } else {
            Stop-WithError "未知快照类型：$Kind"
        }
        $item.blob = $blobName
    }
    return [pscustomobject]$item
}

function New-ProviderStateSnapshot([string]$ParentDir, [string]$Reason, [switch]$FixedName) {
    if ($FixedName) {
        $snapshotDir = Join-Path $ParentDir 'snapshot'
        if (Test-Path -LiteralPath (Join-Path $snapshotDir 'meta.json') -PathType Leaf) {
            return $snapshotDir
        }
    } else {
        $safeReason = [regex]::Replace($Reason, '[^A-Za-z0-9_-]', '-')
        $snapshotDir = Join-Path $ParentDir ((Get-Date -Format 'yyyyMMdd-HHmmssfff') + '-' + $safeReason)
    }

    if (-not (Test-Path -LiteralPath $snapshotDir -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $snapshotDir -Force)
    }
    Set-RestrictedDirectoryAcl $snapshotDir

    $items = [System.Collections.Generic.List[object]]::new()
    $targets = Get-ProviderSnapshotTargets
    foreach ($name in $targets.Keys) {
        $target = $targets[$name]
        $items.Add((Save-ProviderArtifactToSnapshot $snapshotDir $name $target.Path $target.Kind))
    }

    $meta = [ordered]@{
        format = 2
        captured_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.ffffffZ')
        reason = $Reason
        codex_home = $script:CodexHome
        items = @($items)
    }
    Save-JsonMetadata -Path (Join-Path $snapshotDir 'meta.json') -Object $meta -StateRoot $script:ProviderStateRoot
    return $snapshotDir
}

function Restore-ProviderStateSnapshot([string]$SnapshotDir) {
    $metaPath = Join-Path $SnapshotDir 'meta.json'
    if (-not (Test-Path -LiteralPath $metaPath -PathType Leaf)) {
        Stop-WithError "快照元数据不存在：$SnapshotDir"
    }

    $meta = Read-JsonFile $metaPath
    $items = @($meta.items)
    $targets = Get-ProviderSnapshotTargets

    foreach ($name in $targets.Keys) {
        $target = $targets[$name]
        $item = $items | Where-Object { [string]$_.name -eq $name } | Select-Object -First 1

        # 兼容旧版快照：不存在的新逻辑项按 absent 处理。
        if ($null -eq $item -or $item.exists -ne $true) {
            Remove-Item -LiteralPath $target.Path -Force -ErrorAction SilentlyContinue
            continue
        }

        $blobPath = Join-Path $SnapshotDir ([string]$item.blob)
        if (-not (Test-Path -LiteralPath $blobPath -PathType Leaf)) {
            Stop-WithError "快照文件缺失：$blobPath"
        }

        if ([string]$item.kind -eq 'text') {
            Write-Utf8TextAtomic -Path $target.Path -Text (Load-ProtectedText $blobPath $script:ProviderDpapiEntropy)
        } elseif ([string]$item.kind -eq 'binary') {
            Write-BytesAtomic -Path $target.Path -Bytes ([IO.File]::ReadAllBytes($blobPath))
        } else {
            Stop-WithError "未知快照类型：$($item.kind)"
        }
        Set-RestrictedFileAcl -Path $target.Path -StateRoot $script:ProviderStateRoot
    }
}

function Prune-ProviderBackups([int]$BackupKeep) {
    if ($BackupKeep -lt 0) { return }
    $dirs = @(Get-ChildItem -LiteralPath $script:ProviderBackupsDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($dirs.Count -le $BackupKeep) { return }
    foreach ($dir in $dirs[$BackupKeep..($dirs.Count - 1)]) {
        Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Capture-ProviderOriginalOnce {
    $metaPath = Join-Path (Join-Path $script:ProviderOriginalDir 'snapshot') 'meta.json'
    if (Test-Path -LiteralPath $metaPath -PathType Leaf) { return }
    Write-Info '首次运行：保存切换前的原始 Codex 配置状态（含目前手动配置的 provider，如果有的话）。'
    [void](New-ProviderStateSnapshot -ParentDir $script:ProviderOriginalDir -Reason 'original-before-401' -FixedName)
}

function New-ProviderTimestampBackup([string]$Reason, [int]$BackupKeep) {
    $dir = New-ProviderStateSnapshot -ParentDir $script:ProviderBackupsDir -Reason $Reason
    Prune-ProviderBackups $BackupKeep
    return $dir
}

function Write-ProviderTokenHelper {
    $helper = @'
param(
    [Parameter(Mandatory = $true)]
    [string]$TokenFile
)
$ErrorActionPreference = 'Stop'
try {
    Add-Type -AssemblyName System.Security
    $entropy = [Text.Encoding]::UTF8.GetBytes('401-codex-cpa-win11-dpapi-v1')
    $cipher = [IO.File]::ReadAllBytes($TokenFile)
    $plain = [Security.Cryptography.ProtectedData]::Unprotect(
        $cipher,
        $entropy,
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    $token = [Text.Encoding]::UTF8.GetString($plain).Trim()
    if ([string]::IsNullOrWhiteSpace($token)) { exit 2 }
    [Console]::Out.Write($token)
} catch {
    [Console]::Error.WriteLine('Unable to read the provider bearer token.')
    exit 1
}
'@
    Write-Utf8TextAtomic -Path $script:ProviderHelperFile -Text ($helper.TrimStart() + [Environment]::NewLine)
    Set-RestrictedFileAcl -Path $script:ProviderHelperFile -StateRoot $script:ProviderStateRoot
}

function Save-ProviderApiKey([string]$Mode, [string]$Key) {
    if ($Key -match '[\r\n]') { Stop-WithError 'API Key 不得包含换行。' }
    $path = if ($Mode -eq 'cpa') { $script:CpaTokenFile } elseif ($Mode -eq 'deepseek') { $script:DeepSeekTokenFile } else { Stop-WithError "未知模式：$Mode" }
    Save-ProtectedText -Path $path -Text $Key.Trim() -Entropy $script:ProviderDpapiEntropy -StateRoot $script:ProviderStateRoot
}

function Get-SavedProviderApiKey([string]$Mode) {
    if ($Mode -eq 'cpa') { return (Load-ProtectedText $script:CpaTokenFile $script:ProviderDpapiEntropy).Trim() }
    if ($Mode -eq 'deepseek') { return (Load-ProtectedText $script:DeepSeekTokenFile $script:ProviderDpapiEntropy).Trim() }
    Stop-WithError "未知模式：$Mode"
}

function Write-DeepSeekCatalog([string]$Model) {
    $instructions = "You are Codex, an agentic coding assistant working in the user's repository. Inspect the workspace, use tools carefully, make the requested changes, verify them, and report concrete results. Follow AGENTS.md and user instructions when present."
    $catalog = [ordered]@{
        models = @(
            [ordered]@{
                slug = $Model
                prefer_websockets = $false
                support_verbosity = $true
                default_verbosity = 'low'
                apply_patch_tool_type = 'freeform'
                web_search_tool_type = 'text'
                input_modalities = @('text')
                supports_image_detail_original = $false
                truncation_policy = [ordered]@{ mode = 'tokens'; limit = 10000 }
                supports_parallel_tool_calls = $true
                tool_mode = $null
                multi_agent_version = 'v2'
                use_responses_lite = $false
                include_skills_usage_instructions = $false
                auto_review_model_override = $null
                context_window = 1048576
                max_context_window = 1048576
                effective_context_window_percent = 95
                auto_compact_token_limit = $null
                comp_hash = '3000'
                reasoning_summary_format = 'experimental'
                default_reasoning_summary = 'none'
                display_name = 'DeepSeek-V4-Flash'
                description = 'DeepSeek V4 Flash for the Responses API.'
                default_reasoning_level = 'high'
                supported_reasoning_levels = @(
                    [ordered]@{ effort = 'low'; description = 'Fast responses with lighter reasoning' },
                    [ordered]@{ effort = 'high'; description = 'Extra reasoning depth for complex problems' },
                    [ordered]@{ effort = 'max'; description = 'Maximum reasoning depth' }
                )
                shell_type = 'shell_command'
                visibility = 'list'
                minimal_client_version = '0.144.0'
                supported_in_api = $true
                availability_nux = $null
                upgrade = $null
                priority = 1
                model_messages = [ordered]@{
                    instructions_template = $instructions
                    instructions_variables = [ordered]@{
                        personality_default = ''
                        personality_friendly = ''
                        personality_pragmatic = ''
                    }
                    approvals = $null
                }
                experimental_supported_tools = @()
                supports_search_tool = $true
                default_service_tier = $null
                supports_reasoning_summaries = $true
                base_instructions = $instructions
            }
        )
    }
    $json = ($catalog | ConvertTo-Json -Depth 20) + [Environment]::NewLine
    Write-Utf8TextAtomic -Path $script:DeepSeekCatalogFile -Text $json
    Set-RestrictedFileAcl -Path $script:DeepSeekCatalogFile -StateRoot $script:ProviderStateRoot
}

function Write-ProviderConfig([string]$Mode, $Settings) {
    Write-ProviderTokenHelper

    $helperToml = ConvertTo-TomlString $script:ProviderHelperFile
    $ws = if ($Settings.SupportsWebsockets) { 'true' } else { 'false' }
    $lines = [System.Collections.Generic.List[string]]::new()

    $lines.Add('# Managed by Codex 接口管理 (provider module, 原 401)')

    if ($Mode -eq 'cpa') {
        $lines.Add('# Mode: CPA')
        $lines.Add('model = ' + (ConvertTo-TomlString $Settings.Model))
        $lines.Add('model_provider = "cliproxyapi"')
        $lines.Add('model_reasoning_effort = ' + (ConvertTo-TomlString $Settings.ReasoningEffort))
        $lines.Add('plan_mode_reasoning_effort = ' + (ConvertTo-TomlString $Settings.PlanReasoningEffort))
        $lines.Add('')
        $lines.Add('[model_providers.cliproxyapi]')
        $lines.Add('name = "CLIProxyAPI"')
        $lines.Add('base_url = ' + (ConvertTo-TomlString $Settings.BaseUrl))
        $lines.Add('wire_api = "responses"')
        $lines.Add('supports_websockets = ' + $ws)
        $lines.Add('request_max_retries = 4')
        $lines.Add('stream_max_retries = 5')
        $lines.Add('stream_idle_timeout_ms = 300000')
        $lines.Add('')
        $lines.Add('[model_providers.cliproxyapi.auth]')
        $lines.Add('command = "powershell.exe"')
        $lines.Add('args = ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", ' + $helperToml + ', "-TokenFile", ' + (ConvertTo-TomlString $script:CpaTokenFile) + ']')
        $lines.Add('timeout_ms = 5000')
        $lines.Add('refresh_interval_ms = 0')
    } elseif ($Mode -eq 'deepseek') {
        Write-DeepSeekCatalog $Settings.Model
        $lines.Add('# Mode: DeepSeek V4 Flash')
        $lines.Add('model = ' + (ConvertTo-TomlString $Settings.Model))
        $lines.Add('model_provider = "deepseek"')
        # 不写 preferred_auth_method：这不是 codex-rs ConfigToml 里的真实字段
        # （该 struct 是 #[schemars(deny_unknown_fields)]，未知字段会导致
        # config.toml 直接加载失败），实测会报
        # "unknown configuration field `preferred_auth_method`"。
        # 也不写 forced_login_method：这个字段管的是"Codex 自己（对 ChatGPT/
        # OpenAI 后端）用什么方式登录"，跟具体请求走哪个 model_provider 是
        # 两回事——DeepSeek 的密钥已经通过下面 [model_providers.deepseek.auth]
        # 的 command 机制独立注入，根本不需要这个字段。实测把它设成 "api"
        # 后，只要当前 auth.json 还是 ChatGPT 登录态，Codex 就会在任何一次
        # 调用（包括本工具自己做校验用的 codex exec）里检测到"要求 API Key
        # 登录但当前是 ChatGPT 登录"，然后**主动删除 auth.json 把用户登出**——
        # 这和本工具"CPA/DeepSeek 切换要能随时切回官方订阅"的设计目标直接
        # 冲突，所以这个字段对我们管理的任何 provider 都不应该写。
        $lines.Add('model_reasoning_effort = ' + (ConvertTo-TomlString $Settings.ReasoningEffort))
        $lines.Add('plan_mode_reasoning_effort = ' + (ConvertTo-TomlString $Settings.PlanReasoningEffort))
        $lines.Add('model_catalog_json = ' + (ConvertTo-TomlString $script:DeepSeekCatalogFile))
        $lines.Add('')
        $lines.Add('[model_providers.deepseek]')
        $lines.Add('name = "DeepSeek"')
        $lines.Add('base_url = ' + (ConvertTo-TomlString $Settings.BaseUrl))
        $lines.Add('wire_api = "responses"')
        $lines.Add('supports_websockets = false')
        $lines.Add('request_max_retries = 4')
        $lines.Add('stream_max_retries = 5')
        $lines.Add('stream_idle_timeout_ms = 300000')
        $lines.Add('')
        $lines.Add('[model_providers.deepseek.auth]')
        $lines.Add('command = "powershell.exe"')
        $lines.Add('args = ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", ' + $helperToml + ', "-TokenFile", ' + (ConvertTo-TomlString $script:DeepSeekTokenFile) + ']')
        $lines.Add('timeout_ms = 5000')
        $lines.Add('refresh_interval_ms = 0')
    } else {
        Stop-WithError "未知模式：$Mode"
    }

    $lines.Add('')
    Write-Utf8TextAtomic -Path $script:ConfigFile -Text ($lines -join [Environment]::NewLine)
    Set-RestrictedFileAcl -Path $script:ConfigFile
}

function Write-ProviderManagedMarker([string]$Mode, $Settings) {
    $provider = if ($Mode -eq 'cpa') { 'cliproxyapi' } else { 'deepseek' }
    $marker = [ordered]@{
        format = 2
        mode = $Mode
        provider = $provider
        base_url = $Settings.BaseUrl
        model = $Settings.Model
        changed_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.ffffffZ')
        config_file = $script:ConfigFile
        auth_json_modified = $false
    }
    Save-JsonMetadata -Path $script:ProviderMarkerFile -Object $marker -StateRoot $script:ProviderStateRoot
}

function Get-ProviderConfigSummary {
    if (-not (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf)) {
        return [pscustomobject]@{ Exists = $false; Provider = ''; Model = ''; BaseUrl = ''; Catalog = '' }
    }

    $text = [IO.File]::ReadAllText($script:ConfigFile, [Text.Encoding]::UTF8)
    $providerMatch = [regex]::Match($text, '(?m)^\s*model_provider\s*=\s*"([^"]+)"')
    $modelMatch = [regex]::Match($text, '(?m)^\s*model\s*=\s*"([^"]+)"')
    $baseMatch = [regex]::Match($text, '(?m)^\s*base_url\s*=\s*"([^"]+)"')
    $catalogMatch = [regex]::Match($text, '(?m)^\s*model_catalog_json\s*=\s*"([^"]+)"')

    return [pscustomobject]@{
        Exists = $true
        Provider = if ($providerMatch.Success) { $providerMatch.Groups[1].Value } else { 'openai(default/unknown)' }
        Model = if ($modelMatch.Success) { $modelMatch.Groups[1].Value } else { '' }
        BaseUrl = if ($baseMatch.Success) { $baseMatch.Groups[1].Value } else { '' }
        Catalog = if ($catalogMatch.Success) { $catalogMatch.Groups[1].Value.Replace('\\', '\') } else { '' }
    }
}

function Get-ManagedProviderMode {
    if (Test-Path -LiteralPath $script:ProviderMarkerFile -PathType Leaf) {
        try {
            $marker = Read-JsonFile $script:ProviderMarkerFile
            $modeProperty = $marker.PSObject.Properties['mode']
            if ($null -ne $modeProperty -and (Get-StringValue $modeProperty.Value) -in @('cpa', 'deepseek')) {
                return (Get-StringValue $modeProperty.Value)
            }
            $providerProperty = $marker.PSObject.Properties['provider']
            if ($null -ne $providerProperty) {
                $provider = Get-StringValue $providerProperty.Value
                if ($provider -eq 'cliproxyapi') { return 'cpa' }
                if ($provider -eq 'deepseek') { return 'deepseek' }
            }
        } catch {}
    }

    $summary = Get-ProviderConfigSummary
    if ($summary.Provider -eq 'cliproxyapi') { return 'cpa' }
    if ($summary.Provider -eq 'deepseek') { return 'deepseek' }
    return ''
}

function Test-ActiveProviderConfig([string]$Mode, $Settings) {
    if (-not (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $script:ProviderHelperFile -PathType Leaf)) { return $false }

    $summary = Get-ProviderConfigSummary
    $configText = [IO.File]::ReadAllText($script:ConfigFile, [Text.Encoding]::UTF8)
    if ($configText -notmatch '(?m)^\s*wire_api\s*=\s*"responses"') { return $false }

    if ($Mode -eq 'cpa') {
        if (-not (Test-Path -LiteralPath $script:CpaTokenFile -PathType Leaf)) { return $false }
        if ($summary.Provider -ne 'cliproxyapi' -or $summary.Model -ne $Settings.Model -or $summary.BaseUrl -ne $Settings.BaseUrl) { return $false }
        if ([string]::IsNullOrWhiteSpace((Get-SavedProviderApiKey 'cpa'))) { return $false }
        return $true
    }

    if ($Mode -eq 'deepseek') {
        if (-not (Test-Path -LiteralPath $script:DeepSeekTokenFile -PathType Leaf)) { return $false }
        if (-not (Test-Path -LiteralPath $script:DeepSeekCatalogFile -PathType Leaf)) { return $false }
        if ($summary.Provider -ne 'deepseek' -or $summary.Model -ne $Settings.Model -or $summary.BaseUrl -ne $Settings.BaseUrl) { return $false }
        if ([string]::IsNullOrWhiteSpace((Get-SavedProviderApiKey 'deepseek'))) { return $false }
        try {
            $catalog = Read-JsonFile $script:DeepSeekCatalogFile
            $found = @($catalog.models | Where-Object { [string]$_.slug -eq $Settings.Model }).Count -gt 0
            if (-not $found) { return $false }
        } catch { return $false }
        return $true
    }

    return $false
}

function Test-CodexMinimumVersionForDeepSeek {
    $command = Get-Command codex -ErrorAction SilentlyContinue
    if ($null -eq $command) { return }

    $output = & codex --version 2>$null
    $text = [string]($output -join ' ')
    $match = [regex]::Match($text, '(\d+\.\d+\.\d+)')
    if (-not $match.Success) {
        Write-Warn '无法解析 Codex 版本。DeepSeek 官方模型目录要求 Codex >= 0.144.0。'
        return
    }

    $current = [Version]::new($match.Groups[1].Value)
    $minimum = [Version]::new('0.144.0')
    if ($current -lt $minimum) {
        Stop-WithError "当前 Codex 版本为 $current；DeepSeek V4 Flash 官方模型目录要求至少 0.144.0。"
    }
}

function Invoke-ProviderHttpRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$ApiKey,
        [string]$Body = '',
        [int]$TimeoutSec = 60
    )

    $request = [Net.HttpWebRequest]::Create($Url)
    $request.Method = $Method
    $request.Timeout = $TimeoutSec * 1000
    $request.ReadWriteTimeout = $TimeoutSec * 1000
    $request.Headers['Authorization'] = 'Bearer ' + $ApiKey
    $request.Accept = 'application/json'
    $request.UserAgent = 'Codex-Interface-Manager-Win11/1.0'

    if ($Body) {
        $payload = [Text.Encoding]::UTF8.GetBytes($Body)
        $request.ContentType = 'application/json'
        $request.ContentLength = $payload.Length
        $stream = $request.GetRequestStream()
        try { $stream.Write($payload, 0, $payload.Length) } finally { $stream.Dispose() }
    }

    $response = $null
    try {
        $response = [Net.HttpWebResponse]$request.GetResponse()
    } catch [Net.WebException] {
        if ($null -eq $_.Exception.Response) { throw }
        $response = [Net.HttpWebResponse]$_.Exception.Response
    }

    try {
        $reader = [IO.StreamReader]::new($response.GetResponseStream(), [Text.Encoding]::UTF8)
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        return [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            Body = $text
        }
    } finally {
        $response.Dispose()
    }
}

function Get-SafeResponseExcerpt([string]$Body, [string]$ApiKey) {
    $text = ''
    if ($null -ne $Body) { $text = $Body }
    if ($ApiKey) { $text = $text.Replace($ApiKey, '[REDACTED]') }
    $text = $text -replace '[\r\n\t]+', ' '
    if ($text.Length -gt 800) { $text = $text.Substring(0, 800) + '...' }
    return $text
}

function Get-ModeLabel([string]$Mode) {
    if ($Mode -eq 'cpa') { return 'CPA' }
    if ($Mode -eq 'deepseek') { return 'DeepSeek' }
    Stop-WithError "未知模式：$Mode"
}

function Test-ModelsEndpoint([string]$Mode, $Settings, [string]$ApiKey) {
    $label = Get-ModeLabel $Mode
    $result = Invoke-ProviderHttpRequest -Method 'GET' -Url ($Settings.BaseUrl + '/models') -ApiKey $ApiKey -TimeoutSec $Settings.HttpTimeout
    if ($result.StatusCode -ne 200) {
        Stop-WithError ($label + ' GET /models 返回 HTTP ' + $result.StatusCode + '：' + (Get-SafeResponseExcerpt $result.Body $ApiKey))
    }

    try {
        $json = $result.Body | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Stop-WithError ($label + ' GET /models 返回 200，但响应不是合法 JSON。')
    }

    $exists = $false
    $dataProperty = $json.PSObject.Properties['data']
    $items = @()
    if ($null -ne $dataProperty) { $items = @($dataProperty.Value) }
    foreach ($item in $items) {
        if ($null -eq $item) { continue }
        $idProperty = $item.PSObject.Properties['id']
        if ($null -ne $idProperty -and (Get-StringValue $idProperty.Value) -eq $Settings.Model) {
            $exists = $true
            break
        }
    }

    if (-not $exists) { Stop-WithError ($label + ' /models 可访问，但未找到模型：' + $Settings.Model) }
    Write-Info ($label + ' /models 验证通过，模型存在：' + $Settings.Model)
}

function Test-ResponsesEndpoint([string]$Mode, $Settings, [string]$ApiKey) {
    $label = Get-ModeLabel $Mode
    $expectedApi = if ($Mode -eq 'cpa') { 'CPA_OK' } else { 'DEEPSEEK_OK' }
    $bodyObject = [ordered]@{
        model = $Settings.Model
        input = 'Reply with exactly: ' + $expectedApi
        stream = $false
    }
    $body = $bodyObject | ConvertTo-Json -Compress
    $result = Invoke-ProviderHttpRequest -Method 'POST' -Url ($Settings.BaseUrl + '/responses') -ApiKey $ApiKey -Body $body -TimeoutSec $Settings.HttpTimeout
    if ($result.StatusCode -lt 200 -or $result.StatusCode -ge 300) {
        Stop-WithError ($label + ' POST /responses 返回 HTTP ' + $result.StatusCode + '：' + (Get-SafeResponseExcerpt $result.Body $ApiKey))
    }
    try { [void]($result.Body | ConvertFrom-Json -ErrorAction Stop) } catch {
        Stop-WithError ($label + ' /responses 返回成功状态，但响应不是合法 JSON。')
    }
    if ($result.Body -notmatch [regex]::Escape($expectedApi)) {
        Stop-WithError ($label + ' /responses 未包含预期标记：' + $expectedApi)
    }
    Write-Info ($label + ' /responses 验证通过。')
}

function Invoke-CodexExecTest([string]$Mode, $Settings) {
    $command = Get-Command codex -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        Write-Warn '未检测到 codex 命令，跳过端到端测试；API 测试已完成。'
        return
    }

    $expectedCodex = if ($Mode -eq 'cpa') { 'CODEX_CPA_OK' } else { 'CODEX_DEEPSEEK_OK' }
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $env:ComSpec
    $psi.Arguments = '/d /s /c "codex exec --ephemeral --strict-config --skip-git-repo-check --sandbox read-only"'
    $psi.WorkingDirectory = [IO.Path]::GetTempPath()
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    if (-not $process.Start()) { Stop-WithError '无法启动 codex exec 测试。' }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.WriteLine('Do not use tools. Reply with exactly: ' + $expectedCodex)
    $process.StandardInput.Close()

    if (-not $process.WaitForExit($Settings.CodexTestTimeout * 1000)) {
        try { $process.Kill() } catch {}
        Stop-WithError "codex exec 测试超过 $($Settings.CodexTestTimeout) 秒，已终止。"
    }

    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $exitCode = $process.ExitCode
    $process.Dispose()

    $combined = $stdout + [Environment]::NewLine + $stderr
    $key = Get-SavedProviderApiKey $Mode
    if ($exitCode -ne 0) {
        Stop-WithError ("codex exec 测试失败，退出码 $exitCode：" + (Get-SafeResponseExcerpt $combined $key))
    }
    if ($combined -notmatch [regex]::Escape($expectedCodex)) {
        Stop-WithError ('codex exec 已结束，但未检测到 ' + $expectedCodex + '：' + (Get-SafeResponseExcerpt $combined $key))
    }
    Write-Info 'Codex 端到端验证通过；测试使用 --ephemeral，不保存测试会话。'
}

function Perform-ConfiguredProviderTests([string]$Mode, $Settings) {
    if ($Settings.TestMode -eq 'none') {
        Write-Warn 'test_mode=none：已跳过联网验证。'
        return
    }

    $key = Get-SavedProviderApiKey $Mode
    Test-ModelsEndpoint $Mode $Settings $key
    Test-ResponsesEndpoint $Mode $Settings $key
    if ($Settings.TestMode -eq 'full') {
        Invoke-CodexExecTest $Mode $Settings
    }
}

function Switch-ToProviderMode([string]$Mode) {
    $settings = Get-ProviderRuntimeSettings $Mode
    Assert-CodexNotRunning $settings.RefuseIfRunning
    if ($Mode -eq 'deepseek') { Test-CodexMinimumVersionForDeepSeek }

    $apiKey = Get-EffectiveSecret $Mode
    Capture-ProviderOriginalOnce
    $backup = New-ProviderTimestampBackup ('before-switch-' + $Mode) $settings.BackupKeep
    Write-Info "本次变更前备份：$backup"

    try {
        Save-ProviderApiKey $Mode $apiKey
        Write-ProviderConfig $Mode $settings
        Write-ProviderManagedMarker $Mode $settings

        if (-not (Test-ActiveProviderConfig $Mode $settings)) {
            Stop-WithError '配置写入后的本地校验失败。'
        }
        Perform-ConfiguredProviderTests $Mode $settings
    } catch {
        $failure = $_.Exception.Message
        Write-Warn '切换或验证失败，正在恢复本次变更前状态。'
        try { Restore-ProviderStateSnapshot $backup } catch { Write-Err "自动回滚也失败：$($_.Exception.Message)" }
        Stop-WithError ("切换失败，已执行回滚。原因：$failure")
    } finally {
        $apiKey = $null
        [GC]::Collect()
    }

    $label = Get-ModeLabel $Mode
    Write-Host ''
    Write-Host '========== Codex 供应商切换摘要 ==========' -ForegroundColor Green
    Write-Host ('状态：已切换到 ' + $label)
    Write-Host "Codex 配置：$script:ConfigFile"
    Write-Host ('地址：' + $settings.BaseUrl)
    Write-Host ('模型：' + $settings.Model)
    if ($Mode -eq 'cpa') {
        Write-Host "密钥：DPAPI 加密保存于 $script:CpaTokenFile"
    } else {
        Write-Host "密钥：DPAPI 加密保存于 $script:DeepSeekTokenFile"
        Write-Host "模型目录：$script:DeepSeekCatalogFile"
    }
    Write-Host "首次原配置：$(Join-Path $script:ProviderOriginalDir 'snapshot')"
    Write-Host "本次变更前备份：$backup"
    Write-Host "测试级别：$($settings.TestMode)"
    Write-Host 'auth.json：未修改'
    Write-Host '===========================================' -ForegroundColor Green
}

function Restore-ProviderOriginal {
    $settings = Get-ProviderRuntimeSettings (Get-ManagedProviderMode)
    Assert-CodexNotRunning $settings.RefuseIfRunning
    $original = Join-Path $script:ProviderOriginalDir 'snapshot'
    if (-not (Test-Path -LiteralPath (Join-Path $original 'meta.json') -PathType Leaf)) {
        Stop-WithError '尚未建立首次原始快照，无法恢复。'
    }

    $backup = New-ProviderTimestampBackup 'before-restore-original' $settings.BackupKeep
    try {
        Restore-ProviderStateSnapshot $original
    } catch {
        $failure = $_.Exception.Message
        try { Restore-ProviderStateSnapshot $backup } catch {}
        Stop-WithError "恢复原始配置失败，已尝试回滚：$failure"
    }

    $meta = Read-JsonFile (Join-Path $original 'meta.json')
    Write-Host ''
    Write-Host '========== 恢复原 Codex 配置摘要 ==========' -ForegroundColor Green
    Write-Host '状态：已恢复首次运行本工具前的配置状态'
    Write-Host '（若这台机器此前已手动配置过 provider，恢复的是那份手动配置，而不是纯官方默认值）'
    Write-Host "原始快照时间：$($meta.captured_at)"
    Write-Host "恢复前当前状态备份：$backup"
    Write-Host 'auth.json：未修改'
    Write-Host '原始快照继续保留，可重复切换和恢复。'
    Write-Host '=============================================' -ForegroundColor Green
}

function Get-ProviderBackupRows {
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($dir in @(Get-ChildItem -LiteralPath $script:ProviderBackupsDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        $metaPath = Join-Path $dir.FullName 'meta.json'
        if (-not (Test-Path -LiteralPath $metaPath -PathType Leaf)) { continue }
        try {
            $meta = Read-JsonFile $metaPath
            $rows.Add([pscustomobject]@{
                Directory = $dir.FullName
                Name = $dir.Name
                Reason = [string]$meta.reason
                CapturedAt = [string]$meta.captured_at
            })
        } catch {
            Write-Warn "忽略损坏备份：$($dir.Name)"
        }
    }
    return @($rows)
}

function Restore-ProviderTimestampBackup {
    $settings = Get-ProviderRuntimeSettings (Get-ManagedProviderMode)
    Assert-CodexNotRunning $settings.RefuseIfRunning
    $rows = @(Get-ProviderBackupRows)
    if ($rows.Count -eq 0) {
        Write-Warn '没有可恢复的供应商配置时间戳备份。'
        return
    }

    Write-Host ''
    Write-Host '========== 供应商配置时间戳备份 =========='
    for ($i = 0; $i -lt $rows.Count; $i++) {
        Write-Host ('[{0}] {1} | {2} | {3}' -f ($i + 1), $rows[$i].Name, $rows[$i].Reason, $rows[$i].CapturedAt)
    }
    Write-Host '[0] 取消'
    $choice = Read-Host '请选择备份编号'
    $index = 0
    if (-not [int]::TryParse($choice, [ref]$index)) { Write-Warn '输入不是有效编号。'; return }
    if ($index -eq 0) { Write-Info '已取消。'; return }
    if ($index -lt 1 -or $index -gt $rows.Count) { Write-Warn '备份编号超出范围。'; return }

    $selected = $rows[$index - 1]
    $preRestore = New-ProviderStateSnapshot -ParentDir $script:ProviderBackupsDir -Reason 'before-restore-timestamp-backup'
    try {
        Restore-ProviderStateSnapshot $selected.Directory
    } catch {
        $failure = $_.Exception.Message
        try { Restore-ProviderStateSnapshot $preRestore } catch {}
        Stop-WithError "恢复时间戳备份失败，已尝试回滚：$failure"
    }
    Prune-ProviderBackups $settings.BackupKeep
    Write-Info "已恢复备份：$($selected.Name)"
    Write-Info "恢复操作前状态保存在：$preRestore"
}

function Show-ProviderStatusAndTest {
    $summary = Get-ProviderConfigSummary
    $mode = Get-ManagedProviderMode
    $originalMetaPath = Join-Path (Join-Path $script:ProviderOriginalDir 'snapshot') 'meta.json'
    $originalTime = '未创建'
    if (Test-Path -LiteralPath $originalMetaPath -PathType Leaf) {
        try { $originalTime = [string](Read-JsonFile $originalMetaPath).captured_at } catch { $originalTime = '损坏/不可读' }
    }

    Write-Host ''
    Write-Host '========== Codex 供应商（provider）当前状态 =========='
    Write-Host "CODEX_HOME：$script:CodexHome"
    Write-Host "config.toml：$(if ($summary.Exists) { '存在' } else { '不存在' })"
    Write-Host "当前 provider：$($summary.Provider)"
    Write-Host "当前 model：$($summary.Model)"
    Write-Host "当前 base_url：$($summary.BaseUrl)"
    Write-Host "受管模式：$(if ($mode) { $mode } else { '未检测到（可能是官方或未知手动配置）' })"
    Write-Host "CPA DPAPI 密钥：$(if (Test-Path -LiteralPath $script:CpaTokenFile -PathType Leaf) { '存在' } else { '不存在' })"
    Write-Host "DeepSeek DPAPI 密钥：$(if (Test-Path -LiteralPath $script:DeepSeekTokenFile -PathType Leaf) { '存在' } else { '不存在' })"
    Write-Host "DeepSeek 模型目录：$(if (Test-Path -LiteralPath $script:DeepSeekCatalogFile -PathType Leaf) { '存在' } else { '不存在' })"
    Write-Host "首次原始快照：$originalTime"
    Write-Host "时间戳备份数：$(@(Get-ProviderBackupRows).Count)"
    Write-Host 'auth.json：provider 模块不管理、不修改'
    Write-Host '======================================================='

    if (-not $mode) {
        Write-Info '当前不是由本工具管理的 CPA/DeepSeek 配置，未执行联网测试。'
        return
    }
    $settings = Get-ProviderRuntimeSettings $mode
    if ($mode -eq 'deepseek') { Test-CodexMinimumVersionForDeepSeek }
    if (-not (Test-ActiveProviderConfig $mode $settings)) {
        Write-Warn '当前配置、密钥、helper 或模型目录不一致，跳过联网测试。'
        return
    }
    Perform-ConfiguredProviderTests $mode $settings
}

# 由 menu.ps1 在 $script:CodexHome / $script:ConfigFile 就绪后调用一次。
function Initialize-ProviderModule {
    $script:ProviderStateRoot = Join-Path $script:CodexHome 'cpa-switcher-401-win11'
    $script:ProviderBackupsDir = Join-Path $script:ProviderStateRoot 'backups'
    $script:ProviderOriginalDir = Join-Path $script:ProviderStateRoot 'original'
    $script:CpaTokenFile = Join-Path $script:ProviderStateRoot 'cpa-api-key.dpapi'
    $script:DeepSeekTokenFile = Join-Path $script:ProviderStateRoot 'deepseek-api-key.dpapi'
    $script:ProviderHelperFile = Join-Path $script:ProviderStateRoot 'Get-CpaBearerToken.ps1'
    $script:ProviderMarkerFile = Join-Path $script:ProviderStateRoot 'managed-by-401.json'
    $script:DeepSeekCatalogFile = Join-Path $script:CodexHome 'deepseek-v4-flash-models.json'
    Initialize-ProviderDirectories
}
