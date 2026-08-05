#requires -Version 5.1
<#
Codex 接口管理 - account.ps1（账号导入/切换模块）

改编自 402-Codex-Account-Switcher-Win11.ps1，业务逻辑不变，调整点：
- 依赖 common.ps1 提供的公共基础设施，本文件不再重复定义。
- 顶部行为开关（VERIFY_MODE / BACKUP_KEEP 等）改为从本地
  local.settings.json 的 "account" 分区读取，默认值与原脚本一致，
  不影响既有行为，只是可以被用户按需调整而不用改脚本正文。
- 不再包含独立菜单循环和单实例锁，改为暴露函数，由 menu.ps1 统一编排、
  统一持有单实例锁。
- 只读写 auth.json（以及为确保切换生效而管理的 config.toml 里
  cli_auth_credentials_store 这一项），从不修改 provider.ps1 管理的
  model_provider / model_providers.* 字段。

安全原则（沿用原 402）：
- 不在控制台打印 access_token、id_token 或 refresh_token
- 账号保险库、时间戳备份和首次快照均使用 DPAPI CurrentUser 加密
- 活动 auth.json 必须保持明文，因为 Codex 文件认证需要读取该文件
- 不调用 codex logout，不主动撤销任何账号令牌
- 不建议在多台机器同时复用同一 refresh_token

本文件不能单独运行，需在 common.ps1 之后被 menu.ps1 dot-source。
依赖 menu.ps1 预先设置好的共享变量：$script:CodexHome、$script:ConfigFile、$script:AuthFile。
#>

Set-StrictMode -Version 2.0

# 账号相关状态与 DPAPI entropy 沿用旧版 402 的路径/常量，
# 保证如果这台机器之前跑过独立版 402，其保险库/备份仍可被识别、解密。
$script:AccountDpapiEntropy = [Text.Encoding]::UTF8.GetBytes('Codex-Account-Switcher-402-Win11-v1')

function Get-AccountSettings {
    $verifyMode = Get-SettingValue 'account' 'verify_mode' 'status'
    $statusTimeout = [int](Get-SettingValue 'account' 'status_timeout_sec' 30)
    $refuseIfRunning = [bool](Get-SettingValue 'account' 'refuse_if_codex_running' $true)
    $autoSyncCurrent = [bool](Get-SettingValue 'account' 'auto_sync_current' $true)
    $backupKeep = [int](Get-SettingValue 'account' 'backup_keep' 30)
    $enforceFileAuthStore = [bool](Get-SettingValue 'account' 'enforce_file_auth_store' $true)
    $clearClipboard = [bool](Get-SettingValue 'account' 'clear_clipboard_after_import' $true)

    if ($verifyMode -notin @('status', 'local')) { Stop-WithError 'account.verify_mode 只能为 status 或 local。' }
    if ($statusTimeout -lt 5) { Stop-WithError 'account.status_timeout_sec 不能小于 5 秒。' }
    if ($backupKeep -lt 0) { Stop-WithError 'account.backup_keep 不能为负数。' }

    return [pscustomobject]@{
        VerifyMode = $verifyMode
        StatusTimeout = $statusTimeout
        RefuseIfRunning = $refuseIfRunning
        AutoSyncCurrent = $autoSyncCurrent
        BackupKeep = $backupKeep
        EnforceFileAuthStore = $enforceFileAuthStore
        ClearClipboard = $clearClipboard
    }
}

function Normalize-AuthJsonText([string]$JsonText, [string]$SourceName) {
    if ([string]::IsNullOrWhiteSpace($JsonText)) {
        Stop-WithError '输入 JSON 为空。'
    }

    try {
        $root = $JsonText | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Stop-WithError "JSON 语法错误：$($_.Exception.Message)"
    }

    if ($null -eq $root -or $root -is [System.Array]) {
        Stop-WithError '输入内容必须是 JSON 对象。'
    }

    $disabled = Get-ObjectProperty $root 'disabled'
    if ($disabled -eq $true) {
        Stop-WithError '该账号在输入 JSON 中标记为 disabled=true。'
    }

    $declaredType = Get-StringValue (Get-ObjectProperty $root 'type')
    if ($declaredType -and $declaredType -ine 'codex') {
        Stop-WithError "type=$declaredType，不是 codex。"
    }

    $authMode = Get-StringValue (Get-ObjectProperty $root 'auth_mode')
    if ($authMode -and $authMode -ine 'chatgpt') {
        Stop-WithError "auth_mode=$authMode，不是 chatgpt。"
    }

    $tokensProperty = Get-ObjectProperty $root 'tokens'
    if ($null -ne $tokensProperty) {
        $tokenSource = $tokensProperty
        $sourceKind = 'auth.json'
    } else {
        $tokenSource = $root
        $sourceKind = 'export'
    }

    $idToken = Get-StringValue (Get-ObjectProperty $tokenSource 'id_token')
    $accessToken = Get-StringValue (Get-ObjectProperty $tokenSource 'access_token')
    $refreshToken = Get-StringValue (Get-ObjectProperty $tokenSource 'refresh_token')

    if (-not $refreshToken) { Stop-WithError '缺少 refresh_token。' }

    $idClaims = Decode-JwtPayload $idToken 'id_token'
    $accessClaims = Decode-JwtPayload $accessToken 'access_token'

    $authNamespace = 'https://api.openai.com/auth'
    $profileNamespace = 'https://api.openai.com/profile'
    $idAuth = Get-ObjectProperty $idClaims $authNamespace
    $accessAuth = Get-ObjectProperty $accessClaims $authNamespace
    $accessProfile = Get-ObjectProperty $accessClaims $profileNamespace

    $accountId = Get-ConsistentValue -Values @(
        (Get-ObjectProperty $tokenSource 'account_id'),
        (Get-ObjectProperty $root 'account_id'),
        (Get-ObjectProperty $idAuth 'chatgpt_account_id'),
        (Get-ObjectProperty $accessAuth 'chatgpt_account_id')
    ) -FieldName 'account_id' -Required

    $email = Get-ConsistentValue -Values @(
        (Get-ObjectProperty $root 'email'),
        (Get-ObjectProperty $idClaims 'email'),
        (Get-ObjectProperty $accessProfile 'email')
    ) -FieldName 'email' -CaseInsensitive

    $userId = Get-ConsistentValue -Values @(
        (Get-ObjectProperty $idAuth 'chatgpt_user_id'),
        (Get-ObjectProperty $idAuth 'user_id'),
        (Get-ObjectProperty $accessAuth 'chatgpt_user_id'),
        (Get-ObjectProperty $accessAuth 'user_id')
    ) -FieldName 'user_id'

    $subject = Get-ConsistentValue -Values @(
        (Get-ObjectProperty $idClaims 'sub'),
        (Get-ObjectProperty $accessClaims 'sub')
    ) -FieldName 'JWT sub'

    if (-not $userId) { $userId = $subject }
    if (-not $email -and -not $userId) {
        Stop-WithError 'JWT 中既没有邮箱，也没有可用的用户标识，无法安全区分账号。'
    }

    $planType = Get-StringValue (Get-ObjectProperty $accessAuth 'chatgpt_plan_type')
    if (-not $planType) { $planType = Get-StringValue (Get-ObjectProperty $idAuth 'chatgpt_plan_type') }
    if (-not $planType) { $planType = 'unknown' }

    $nowUtc = [DateTime]::UtcNow
    $lastRefresh = Convert-Rfc3339ToUtcString (Get-ObjectProperty $root 'last_refresh')
    if (-not $lastRefresh) {
        $lastRefresh = Convert-EpochToUtcString (Get-ObjectProperty $accessClaims 'iat')
    }
    if (-not $lastRefresh) {
        $lastRefresh = Convert-EpochToUtcString (Get-ObjectProperty $idClaims 'iat')
    }
    if (-not $lastRefresh) {
        $lastRefresh = $nowUtc.ToString('yyyy-MM-ddTHH:mm:ss.ffffffZ')
    }

    $lastRefreshParsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($lastRefresh, [ref]$lastRefreshParsed)) {
        if ($lastRefreshParsed.UtcDateTime -gt $nowUtc.AddMinutes(5)) {
            Write-Warn 'last_refresh 晚于当前时间，已改为当前 UTC 时间。'
            $lastRefresh = $nowUtc.ToString('yyyy-MM-ddTHH:mm:ss.ffffffZ')
        }
    }

    $accessExpires = Convert-EpochToUtcString (Get-ObjectProperty $accessClaims 'exp')
    $idExpires = Convert-EpochToUtcString (Get-ObjectProperty $idClaims 'exp')
    $declaredExpires = Convert-Rfc3339ToUtcString (Get-ObjectProperty $root 'expired')

    $identity = @(
        $userId.ToLowerInvariant(),
        $subject.ToLowerInvariant(),
        $email.ToLowerInvariant(),
        $accountId
    ) -join '|'
    $fingerprint = (Get-Sha256Hex $identity).Substring(0, 20)

    $normalized = [ordered]@{
        auth_mode = 'chatgpt'
        OPENAI_API_KEY = $null
        tokens = [ordered]@{
            id_token = $idToken
            access_token = $accessToken
            refresh_token = $refreshToken
            account_id = $accountId
        }
        last_refresh = $lastRefresh
    }

    $meta = [ordered]@{
        schema_version = 1
        fingerprint = $fingerprint
        label = ''
        email = $(if ($email) { $email } else { '(JWT未提供邮箱)' })
        account_id = $accountId
        user_id = $userId
        subject = $subject
        plan_type = $planType
        access_expires = $accessExpires
        id_expires = $idExpires
        declared_expires = $declaredExpires
        last_refresh = $lastRefresh
        source_kind = $sourceKind
        source_name = $SourceName
        generated_at = $nowUtc.ToString('yyyy-MM-ddTHH:mm:ss.ffffffZ')
    }

    $normalizedJson = ($normalized | ConvertTo-Json -Depth 10)
    return [pscustomobject]@{
        AuthObject = $normalized
        AuthJson = $normalizedJson + [Environment]::NewLine
        Meta = [pscustomobject]$meta
    }
}

function Get-CurrentProvider {
    if (-not (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf)) { return 'openai' }
    $content = [IO.File]::ReadAllText($script:ConfigFile, [Text.Encoding]::UTF8)
    $match = [regex]::Match($content, '(?m)^\s*model_provider\s*=\s*"([^"]+)"')
    if ($match.Success) { return $match.Groups[1].Value }
    return 'openai'
}

function Get-CredentialStoreMode {
    if (-not (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf)) { return '' }
    $content = [IO.File]::ReadAllText($script:ConfigFile, [Text.Encoding]::UTF8)
    $matches = [regex]::Matches($content, '(?m)^\s*cli_auth_credentials_store\s*=\s*"([^"]+)"')
    if ($matches.Count -eq 0) { return '' }
    return $matches[$matches.Count - 1].Groups[1].Value
}

function Save-OriginalConfigSnapshot {
    if (Test-Path -LiteralPath $script:AccountConfigOriginalMeta -PathType Leaf) { return }
    $exists = Test-Path -LiteralPath $script:ConfigFile -PathType Leaf
    $meta = [ordered]@{
        exists = $exists
        captured_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.ffffffZ')
    }
    if ($exists) {
        Save-ProtectedText -Path $script:AccountConfigOriginalBlob -Text ([IO.File]::ReadAllText($script:ConfigFile, [Text.Encoding]::UTF8)) -Entropy $script:AccountDpapiEntropy -StateRoot $script:AccountStateRoot
    }
    Save-JsonMetadata -Path $script:AccountConfigOriginalMeta -Object $meta -StateRoot $script:AccountStateRoot
}

function Backup-Config([string]$Reason) {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $base = Join-Path $script:AccountConfigBackupsDir $timestamp
    $exists = Test-Path -LiteralPath $script:ConfigFile -PathType Leaf
    $meta = [ordered]@{
        exists = $exists
        captured_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.ffffffZ')
        reason = $Reason
    }
    if ($exists) {
        Save-ProtectedText -Path ($base + '.config.dpapi') -Text ([IO.File]::ReadAllText($script:ConfigFile, [Text.Encoding]::UTF8)) -Entropy $script:AccountDpapiEntropy -StateRoot $script:AccountStateRoot
    }
    Save-JsonMetadata -Path ($base + '.meta.json') -Object $meta -StateRoot $script:AccountStateRoot
}

function Ensure-FileCredentialStore($Settings) {
    $mode = Get-CredentialStoreMode
    if ($mode -eq 'file') { return }

    if (-not $Settings.EnforceFileAuthStore) {
        if ($mode -in @('auto', 'keyring')) {
            Stop-WithError "config.toml 当前 cli_auth_credentials_store=$mode；账号模块只管理 auth.json 文件模式。"
        }
        if (-not (Test-Path -LiteralPath $script:AuthFile -PathType Leaf)) {
            Stop-WithError '未找到 auth.json，且未强制文件认证模式。'
        }
        return
    }

    Save-OriginalConfigSnapshot
    Backup-Config 'set-cli-auth-credentials-store-file'

    $existing = if (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf) {
        [IO.File]::ReadAllText($script:ConfigFile, [Text.Encoding]::UTF8)
    } else {
        ''
    }

    $lines = @()
    if ($existing) {
        $lines = $existing -split '\r?\n' | Where-Object {
            $_ -notmatch '^\s*cli_auth_credentials_store\s*='
        }
    }

    $header = @(
        '# Managed by Codex 接口管理 (account module, 原 402) for deterministic auth.json switching',
        'cli_auth_credentials_store = "file"',
        ''
    )
    $newContent = (($header + $lines) -join [Environment]::NewLine).TrimEnd() + [Environment]::NewLine
    Write-Utf8TextAtomic -Path $script:ConfigFile -Text $newContent
    Set-RestrictedFileAcl -Path $script:ConfigFile

    if ((Get-CredentialStoreMode) -ne 'file') {
        Stop-WithError '无法将 cli_auth_credentials_store 设置为 file。'
    }
    Write-Info '已将 Codex 凭据存储模式设置为 file；原 config.toml 已备份。'
}

function Restore-OriginalConfig {
    if (-not (Test-Path -LiteralPath $script:AccountConfigOriginalMeta -PathType Leaf)) {
        Write-Warn '没有首次 config.toml 快照。'
        return
    }
    $settings = Get-AccountSettings
    Assert-CodexNotRunning $settings.RefuseIfRunning
    Backup-Config 'before-restore-original-config'
    $meta = Read-JsonFile $script:AccountConfigOriginalMeta
    if ($meta.exists -eq $true) {
        $text = Load-ProtectedText $script:AccountConfigOriginalBlob $script:AccountDpapiEntropy
        Write-Utf8TextAtomic -Path $script:ConfigFile -Text $text
        Set-RestrictedFileAcl -Path $script:ConfigFile
    } else {
        Remove-Item -LiteralPath $script:ConfigFile -Force -ErrorAction SilentlyContinue
    }
    Write-Info '已恢复首次运行前的 config.toml。'
    Write-Warn '如果 account.enforce_file_auth_store 仍为 true，下次启动本工具会再次把 cli_auth_credentials_store 设回 file；如需永久保留原模式，请把该设置改为 false。'
}

function Test-AuthText([string]$Text, [string]$SourceName) {
    return Normalize-AuthJsonText -JsonText $Text -SourceName $SourceName
}

function Get-ActiveAuthInfo {
    if (-not (Test-Path -LiteralPath $script:AuthFile -PathType Leaf)) { return $null }
    try {
        $text = [IO.File]::ReadAllText($script:AuthFile, [Text.Encoding]::UTF8)
        return Test-AuthText -Text $text -SourceName 'active-auth.json'
    } catch {
        return $null
    }
}

function Get-ActiveFingerprint {
    $info = Get-ActiveAuthInfo
    if ($null -eq $info) { return '' }
    return [string]$info.Meta.fingerprint
}

function Save-OriginalAuthSnapshot {
    if (Test-Path -LiteralPath $script:AuthOriginalMeta -PathType Leaf) { return }
    $exists = Test-Path -LiteralPath $script:AuthFile -PathType Leaf
    $meta = [ordered]@{
        exists = $exists
        captured_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.ffffffZ')
        fingerprint = ''
        email = ''
    }
    if ($exists) {
        $raw = [IO.File]::ReadAllText($script:AuthFile, [Text.Encoding]::UTF8)
        Save-ProtectedText -Path $script:AuthOriginalBlob -Text $raw -Entropy $script:AccountDpapiEntropy -StateRoot $script:AccountStateRoot
        try {
            $parsed = Test-AuthText -Text $raw -SourceName 'original-auth.json'
            $meta.fingerprint = $parsed.Meta.fingerprint
            $meta.email = $parsed.Meta.email
        } catch {}
    }
    Save-JsonMetadata -Path $script:AuthOriginalMeta -Object $meta -StateRoot $script:AccountStateRoot
}

function New-AuthBackup([string]$Reason, [int]$BackupKeep) {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $base = Join-Path $script:AuthBackupsDir $timestamp
    $exists = Test-Path -LiteralPath $script:AuthFile -PathType Leaf
    $meta = [ordered]@{
        exists = $exists
        captured_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.ffffffZ')
        reason = $Reason
        fingerprint = ''
        email = ''
    }
    if ($exists) {
        $raw = [IO.File]::ReadAllText($script:AuthFile, [Text.Encoding]::UTF8)
        Save-ProtectedText -Path ($base + '.auth.dpapi') -Text $raw -Entropy $script:AccountDpapiEntropy -StateRoot $script:AccountStateRoot
        try {
            $parsed = Test-AuthText -Text $raw -SourceName 'backup-auth.json'
            $meta.fingerprint = $parsed.Meta.fingerprint
            $meta.email = $parsed.Meta.email
        } catch {}
    }
    Save-JsonMetadata -Path ($base + '.meta.json') -Object $meta -StateRoot $script:AccountStateRoot
    Prune-AuthBackups $BackupKeep
    return [pscustomobject]@{
        BasePath = $base
        Exists = $exists
        Meta = [pscustomobject]$meta
    }
}

function Prune-AuthBackups([int]$BackupKeep) {
    if ($BackupKeep -lt 0) { return }
    $metas = @(Get-ChildItem -LiteralPath $script:AuthBackupsDir -Filter '*.meta.json' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($metas.Count -le $BackupKeep) { return }
    foreach ($metaFile in $metas[$BackupKeep..($metas.Count - 1)]) {
        $base = $metaFile.FullName.Substring(0, $metaFile.FullName.Length - '.meta.json'.Length)
        Remove-Item -LiteralPath $metaFile.FullName -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath ($base + '.auth.dpapi') -Force -ErrorAction SilentlyContinue
    }
}

function Restore-BackupObject($Backup) {
    if ($Backup.Exists -eq $true) {
        $text = Load-ProtectedText ($Backup.BasePath + '.auth.dpapi') $script:AccountDpapiEntropy
        Write-Utf8TextAtomic -Path $script:AuthFile -Text $text
        Set-RestrictedFileAcl -Path $script:AuthFile
    } else {
        Remove-Item -LiteralPath $script:AuthFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-AccountPaths([string]$Fingerprint) {
    return [pscustomobject]@{
        Blob = Join-Path $script:AccountsDir ($Fingerprint + '.auth.dpapi')
        Meta = Join-Path $script:AccountsDir ($Fingerprint + '.meta.json')
    }
}

function Save-AccountInfo($Info, [string]$Label, [string]$Reason) {
    $fingerprint = [string]$Info.Meta.fingerprint
    $paths = Get-AccountPaths $fingerprint
    $existingMeta = $null
    if (Test-Path -LiteralPath $paths.Meta -PathType Leaf) {
        try { $existingMeta = Read-JsonFile $paths.Meta } catch {}
    }

    $newTicks = Get-UtcTicksFromString ([string]$Info.Meta.last_refresh)
    $oldTicks = if ($null -ne $existingMeta) { Get-UtcTicksFromString ([string]$existingMeta.last_refresh) } else { [Int64]0 }
    if ($oldTicks -gt $newTicks) {
        Write-Warn "保险库中的账号凭据看起来更新，未被较旧 auth.json 覆盖：$($Info.Meta.email)"
        return $false
    }

    if (-not $Label -and $null -ne $existingMeta) { $Label = Get-StringValue $existingMeta.label }
    if (-not $Label) { $Label = Get-StringValue $Info.Meta.email }

    $meta = [ordered]@{}
    foreach ($property in $Info.Meta.PSObject.Properties) {
        $meta[$property.Name] = $property.Value
    }
    $meta.label = $Label
    $meta.saved_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.ffffffZ')
    $meta.save_reason = $Reason

    Save-ProtectedText -Path $paths.Blob -Text $Info.AuthJson -Entropy $script:AccountDpapiEntropy -StateRoot $script:AccountStateRoot
    Save-JsonMetadata -Path $paths.Meta -Object $meta -StateRoot $script:AccountStateRoot
    return $true
}

function Sync-CurrentAuth([string]$Reason, [switch]$Quiet) {
    if (-not (Test-Path -LiteralPath $script:AuthFile -PathType Leaf)) { return $false }
    try {
        $raw = [IO.File]::ReadAllText($script:AuthFile, [Text.Encoding]::UTF8)
        $info = Test-AuthText -Text $raw -SourceName 'active-auth.json'
        $saved = Save-AccountInfo -Info $info -Label '' -Reason $Reason
        if ($saved -and -not $Quiet) {
            Write-Info "已同步当前账号到 DPAPI 保险库：$($info.Meta.email)"
        }
        return $saved
    } catch {
        if (-not $Quiet) { Write-Warn "当前 auth.json 无法收录：$($_.Exception.Message)" }
        return $false
    }
}

function Get-SavedAccounts {
    $rows = New-Object System.Collections.Generic.List[object]
    $metaFiles = @(Get-ChildItem -LiteralPath $script:AccountsDir -Filter '*.meta.json' -File -ErrorAction SilentlyContinue)
    foreach ($file in $metaFiles) {
        try {
            $meta = Read-JsonFile $file.FullName
            $paths = Get-AccountPaths ([string]$meta.fingerprint)
            if (Test-Path -LiteralPath $paths.Blob -PathType Leaf) {
                $rows.Add([pscustomobject]@{
                    Fingerprint = [string]$meta.fingerprint
                    Label = [string]$meta.label
                    Email = [string]$meta.email
                    AccountId = [string]$meta.account_id
                    Plan = [string]$meta.plan_type
                    AccessExpires = [string]$meta.access_expires
                    LastRefresh = [string]$meta.last_refresh
                    BlobPath = $paths.Blob
                    MetaPath = $paths.Meta
                })
            }
        } catch {
            Write-Warn "忽略损坏的账号元数据：$($file.Name)"
        }
    }
    return @($rows | Sort-Object Label, Email, Fingerprint)
}

function Show-Accounts([switch]$ReturnRows) {
    $accounts = @(Get-SavedAccounts)
    $active = Get-ActiveFingerprint
    Write-Host ''
    Write-Host '================ 已保存账号 ================'
    if ($accounts.Count -eq 0) {
        Write-Host '(无)'
    } else {
        for ($i = 0; $i -lt $accounts.Count; $i++) {
            $a = $accounts[$i]
            $mark = if ($a.Fingerprint -eq $active) { '*' } else { ' ' }
            $accountShort = if ($a.AccountId.Length -gt 12) { $a.AccountId.Substring(0, 12) + '...' } else { $a.AccountId }
            $expires = if ($a.AccessExpires) { $a.AccessExpires } else { 'unknown' }
            Write-Host ('{0}[{1}] {2} | {3} | plan={4} | account={5} | access_exp={6}' -f $mark, ($i + 1), $a.Label, $a.Email, $a.Plan, $accountShort, $expires)
        }
    }
    Write-Host '* 表示当前 auth.json 对应账号'
    Write-Host '============================================='
    if ($ReturnRows) { return $accounts }
}

function Select-SavedAccount([string]$Prompt) {
    $accounts = @(Show-Accounts -ReturnRows)
    if ($accounts.Count -eq 0) { return $null }
    $choice = Read-Host $Prompt
    $number = 0
    if (-not [int]::TryParse($choice, [ref]$number) -or $number -lt 1 -or $number -gt $accounts.Count) {
        Write-Warn '选择无效。'
        return $null
    }
    return $accounts[$number - 1]
}

function Test-CodexLoginStatus($Settings) {
    if ($Settings.VerifyMode -eq 'local') { return $true }
    $command = Get-Command codex -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        Write-Warn '未在 PATH 中找到 codex；已完成本地结构校验，但跳过 codex login status。'
        return $true
    }

    $stdout = Join-Path $script:AccountStateRoot ('.status-out-' + [Guid]::NewGuid().ToString('N') + '.txt')
    $stderr = Join-Path $script:AccountStateRoot ('.status-err-' + [Guid]::NewGuid().ToString('N') + '.txt')
    try {
        $process = Start-Process -FilePath $env:ComSpec -ArgumentList '/d /s /c "codex login status"' -NoNewWindow -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        if (-not $process.WaitForExit($Settings.StatusTimeout * 1000)) {
            try { $process.Kill() } catch {}
            Write-Warn "codex login status 超过 $($Settings.StatusTimeout) 秒。"
            return $false
        }
        $process.WaitForExit()
        $output = ''
        if (Test-Path -LiteralPath $stdout) { $output += [IO.File]::ReadAllText($stdout) }
        if (Test-Path -LiteralPath $stderr) { $output += [IO.File]::ReadAllText($stderr) }
        $output = $output.Trim()
        if ($process.ExitCode -eq 0 -and $output -match '(?i)Logged in using ChatGPT') {
            Write-Info 'codex login status：Logged in using ChatGPT'
            return $true
        }
        if ($output) { Write-Warn "codex login status 返回：$output" }
        else { Write-Warn "codex login status 退出码：$($process.ExitCode)" }
        return $false
    } finally {
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    }
}

function Verify-ActiveAuth([string]$ExpectedFingerprint, $Settings) {
    if (-not (Test-Path -LiteralPath $script:AuthFile -PathType Leaf)) {
        Write-Warn 'auth.json 不存在。'
        return $false
    }
    try {
        $raw = [IO.File]::ReadAllText($script:AuthFile, [Text.Encoding]::UTF8)
        $info = Test-AuthText -Text $raw -SourceName 'verify-active-auth.json'
        if ($ExpectedFingerprint -and $info.Meta.fingerprint -ne $ExpectedFingerprint) {
            Write-Warn '写入后的账号指纹与目标账号不一致。'
            return $false
        }
        if (-not (Test-CodexLoginStatus $Settings)) { return $false }
        return $true
    } catch {
        Write-Warn "auth.json 本地校验失败：$($_.Exception.Message)"
        return $false
    }
}

function Apply-AuthText {
    param(
        [string]$AuthText,
        [string]$ExpectedFingerprint,
        [string]$Reason
    )
    $settings = Get-AccountSettings
    Assert-CodexNotRunning $settings.RefuseIfRunning
    [void](Sync-CurrentAuth -Reason 'before-switch' -Quiet)
    $backup = New-AuthBackup $Reason $settings.BackupKeep

    try {
        Write-Utf8TextAtomic -Path $script:AuthFile -Text $AuthText
        Set-RestrictedFileAcl -Path $script:AuthFile
        if (-not (Verify-ActiveAuth $ExpectedFingerprint $settings)) {
            throw '切换后验证失败。'
        }
        [void](Sync-CurrentAuth -Reason 'after-switch' -Quiet)
        return $true
    } catch {
        Write-Warn "切换失败，正在恢复修改前的 auth.json：$($_.Exception.Message)"
        Restore-BackupObject $backup
        if ($backup.Exists) { [void](Verify-ActiveAuth ([string]$backup.Meta.fingerprint) $settings) }
        return $false
    }
}

function Import-AndSwitch([string]$JsonText, [string]$SourceName) {
    $info = Test-AuthText -Text $JsonText -SourceName $SourceName
    $now = [DateTimeOffset]::UtcNow
    foreach ($field in @('access_expires', 'id_expires')) {
        $expiryText = [string](Get-ObjectProperty $info.Meta $field)
        if ($expiryText) {
            $expiry = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse($expiryText, [ref]$expiry) -and $expiry -lt $now) {
                Write-Warn "$field 已过期；Codex 需要依赖 refresh_token 在线刷新。"
            }
        }
    }

    $label = Read-Host "账号别名（留空则使用邮箱 $($info.Meta.email)）"
    if (-not $label) { $label = [string]$info.Meta.email }

    $saved = Save-AccountInfo -Info $info -Label $label -Reason 'import'
    if (-not $saved) {
        $paths = Get-AccountPaths ([string]$info.Meta.fingerprint)
        if (Test-Path -LiteralPath $paths.Blob -PathType Leaf) {
            $newerText = Load-ProtectedText $paths.Blob $script:AccountDpapiEntropy
            $info = Test-AuthText -Text $newerText -SourceName 'newer DPAPI vault copy'
            Write-Info '检测到保险库已有更新凭据，本次切换使用较新的保险库副本。'
        }
    }
    if (Apply-AuthText -AuthText $info.AuthJson -ExpectedFingerprint $info.Meta.fingerprint -Reason 'before-import-switch') {
        Write-Info "已导入并切换到：$label <$($info.Meta.email)>"
    } else {
        Write-Err '导入已保存到保险库，但活动账号切换失败并已回滚。'
    }
}

function Import-FromClipboard {
    $settings = Get-AccountSettings
    $text = ''
    try {
        $clipboardCommand = Get-Command Get-Clipboard -ErrorAction SilentlyContinue
        if ($null -eq $clipboardCommand) { Stop-WithError '当前 PowerShell 不支持 Get-Clipboard。' }
        $text = Get-Clipboard -Raw
        if ([string]::IsNullOrWhiteSpace($text)) { Stop-WithError '剪贴板为空。请先复制完整 JSON。' }
        Import-AndSwitch -JsonText $text -SourceName 'Windows Clipboard'
    } finally {
        $text = ''
        if ($settings.ClearClipboard) {
            try { Set-Clipboard -Value '' } catch { Write-Warn '无法自动清空剪贴板。' }
        }
    }
}

function Import-FromJsonFile {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = '选择包含 Codex 凭据的 JSON 文件'
    $dialog.Filter = 'JSON 文件 (*.json)|*.json|所有文件 (*.*)|*.*'
    $dialog.Multiselect = $false
    try {
        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
            Write-Info '已取消文件导入。'
            return
        }
        $text = [IO.File]::ReadAllText($dialog.FileName, [Text.Encoding]::UTF8)
        Import-AndSwitch -JsonText $text -SourceName $dialog.FileName
        $text = ''
    } finally {
        $dialog.Dispose()
    }
}

function Switch-ToSavedAccount {
    $account = Select-SavedAccount '输入要切换的账号序号'
    if ($null -eq $account) { return }
    $authText = Load-ProtectedText $account.BlobPath $script:AccountDpapiEntropy
    $info = Test-AuthText -Text $authText -SourceName 'DPAPI vault'
    if ($info.Meta.fingerprint -ne $account.Fingerprint) {
        Stop-WithError '账号保险库文件与元数据指纹不一致。'
    }
    if (Apply-AuthText -AuthText $info.AuthJson -ExpectedFingerprint $account.Fingerprint -Reason 'before-saved-account-switch') {
        Write-Info "已切换到：$($account.Label) <$($account.Email)>"
    } else {
        Write-Err '切换失败并已回滚。'
    }
}

function Show-AccountCurrentStatus {
    Write-Host ''
    Write-Host '================ Codex 账号（account）当前状态 ================='
    Write-Host "Codex Home：$script:CodexHome"
    Write-Host "auth.json：$script:AuthFile"
    Write-Host "保险库：$script:AccountsDir"
    Write-Host "认证存储模式：$(Get-CredentialStoreMode)"
    Write-Host "model_provider：$(Get-CurrentProvider)"
    $active = Get-ActiveAuthInfo
    if ($null -eq $active) {
        Write-Host '当前账号：(auth.json 不存在或无法解析)'
    } else {
        Write-Host "当前账号：$($active.Meta.email)"
        Write-Host "账号指纹：$($active.Meta.fingerprint)"
        Write-Host "计划类型：$($active.Meta.plan_type)"
        Write-Host "account_id：$($active.Meta.account_id)"
        Write-Host "last_refresh：$($active.Meta.last_refresh)"
        Write-Host "access_token 过期时间：$($active.Meta.access_expires)"
    }
    Write-Host '=================================================================='
    [void](Show-Accounts)
}

function Get-AuthBackupRows {
    $rows = New-Object System.Collections.Generic.List[object]
    $files = @(Get-ChildItem -LiteralPath $script:AuthBackupsDir -Filter '*.meta.json' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    foreach ($file in $files) {
        try {
            $meta = Read-JsonFile $file.FullName
            $base = $file.FullName.Substring(0, $file.FullName.Length - '.meta.json'.Length)
            $rows.Add([pscustomobject]@{
                BasePath = $base
                Exists = ($meta.exists -eq $true)
                CapturedAt = [string]$meta.captured_at
                Reason = [string]$meta.reason
                Email = [string]$meta.email
                Fingerprint = [string]$meta.fingerprint
            })
        } catch {}
    }
    return @($rows)
}

function Restore-AccountTimestampBackup {
    $settings = Get-AccountSettings
    $rows = @(Get-AuthBackupRows)
    if ($rows.Count -eq 0) {
        Write-Warn '没有 auth.json 时间戳备份。'
        return
    }
    Write-Host ''
    Write-Host '================ auth.json 备份 ============='
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $r = $rows[$i]
        $email = if ($r.Email) { $r.Email } else { '(无账号/无法识别)' }
        Write-Host ('[{0}] {1} | {2} | {3}' -f ($i + 1), $r.CapturedAt, $email, $r.Reason)
    }
    $choice = Read-Host '输入要恢复的备份序号'
    $number = 0
    if (-not [int]::TryParse($choice, [ref]$number) -or $number -lt 1 -or $number -gt $rows.Count) {
        Write-Warn '选择无效。'
        return
    }

    Assert-CodexNotRunning $settings.RefuseIfRunning
    [void](Sync-CurrentAuth -Reason 'before-restore-backup' -Quiet)
    $rollback = New-AuthBackup 'rollback-before-restore-backup' $settings.BackupKeep
    $selected = $rows[$number - 1]
    try {
        if ($selected.Exists) {
            $text = Load-ProtectedText ($selected.BasePath + '.auth.dpapi') $script:AccountDpapiEntropy
            Write-Utf8TextAtomic -Path $script:AuthFile -Text $text
            Set-RestrictedFileAcl -Path $script:AuthFile
            if (-not (Verify-ActiveAuth $selected.Fingerprint $settings)) { throw '恢复后的验证失败。' }
            [void](Sync-CurrentAuth -Reason 'after-restore-backup' -Quiet)
        } else {
            Remove-Item -LiteralPath $script:AuthFile -Force -ErrorAction SilentlyContinue
        }
        Write-Info '已恢复所选 auth.json 备份。'
    } catch {
        Write-Warn "恢复失败，正在回滚：$($_.Exception.Message)"
        Restore-BackupObject $rollback
    }
}

function Restore-OriginalAuth {
    if (-not (Test-Path -LiteralPath $script:AuthOriginalMeta -PathType Leaf)) {
        Write-Warn '没有首次 auth.json 快照。'
        return
    }
    $settings = Get-AccountSettings
    Assert-CodexNotRunning $settings.RefuseIfRunning
    [void](Sync-CurrentAuth -Reason 'before-restore-original' -Quiet)
    $rollback = New-AuthBackup 'rollback-before-restore-original' $settings.BackupKeep
    $meta = Read-JsonFile $script:AuthOriginalMeta
    try {
        if ($meta.exists -eq $true) {
            $text = Load-ProtectedText $script:AuthOriginalBlob $script:AccountDpapiEntropy
            Write-Utf8TextAtomic -Path $script:AuthFile -Text $text
            Set-RestrictedFileAcl -Path $script:AuthFile
            if (-not (Verify-ActiveAuth ([string]$meta.fingerprint) $settings)) { throw '首次快照恢复后验证失败。' }
            [void](Sync-CurrentAuth -Reason 'after-restore-original' -Quiet)
        } else {
            Remove-Item -LiteralPath $script:AuthFile -Force -ErrorAction SilentlyContinue
        }
        Write-Info '已恢复首次运行前的 auth.json。'
    } catch {
        Write-Warn "恢复失败，正在回滚：$($_.Exception.Message)"
        Restore-BackupObject $rollback
    }
}

function Delete-SavedAccount {
    $account = Select-SavedAccount '输入要从保险库删除的账号序号'
    if ($null -eq $account) { return }
    if ($account.Fingerprint -eq (Get-ActiveFingerprint)) {
        Write-Warn '不能删除当前活动账号；请先切换到其他账号。'
        return
    }
    $confirm = Read-Host "确认删除 $($account.Label) <$($account.Email)>？输入 DELETE"
    if ($confirm -cne 'DELETE') {
        Write-Info '已取消删除。'
        return
    }
    Remove-Item -LiteralPath $account.BlobPath, $account.MetaPath -Force -ErrorAction Stop
    Write-Info '已删除所选账号的 DPAPI 保险库副本。'
}

function Show-AccountSecurityWarnings {
    if (-not [string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)) {
        Write-Warn '当前用户环境中设置了 OPENAI_API_KEY；它可能改变 Codex 的认证选择。'
    }
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_API_KEY)) {
        Write-Warn '当前用户环境中设置了 CODEX_API_KEY；它可能覆盖 auth.json 认证。'
    }
    $provider = Get-CurrentProvider
    if ($provider -ne 'openai') {
        Write-Warn "当前 model_provider=$provider。账号可管理，但这些 ChatGPT OAuth 凭据通常只在 OpenAI 认证路径中使用。"
    }
}

# 由 menu.ps1 在 $script:CodexHome / $script:ConfigFile / $script:AuthFile 就绪后调用一次。
function Initialize-AccountModule {
    $script:AccountStateRoot = Join-Path $script:CodexHome 'account-switcher-402-win11'
    $script:AccountsDir = Join-Path $script:AccountStateRoot 'accounts'
    $script:AuthBackupsDir = Join-Path $script:AccountStateRoot 'auth-backups'
    $script:AccountConfigBackupsDir = Join-Path $script:AccountStateRoot 'config-backups'
    $script:AccountOriginalDir = Join-Path $script:AccountStateRoot 'original'
    $script:AuthOriginalBlob = Join-Path $script:AccountOriginalDir 'auth.original.dpapi'
    $script:AuthOriginalMeta = Join-Path $script:AccountOriginalDir 'auth.original.meta.json'
    $script:AccountConfigOriginalBlob = Join-Path $script:AccountOriginalDir 'config.original.dpapi'
    $script:AccountConfigOriginalMeta = Join-Path $script:AccountOriginalDir 'config.original.meta.json'

    foreach ($directory in @($script:AccountStateRoot, $script:AccountsDir, $script:AuthBackupsDir, $script:AccountConfigBackupsDir, $script:AccountOriginalDir)) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $directory -Force)
        }
    }
    foreach ($directory in @($script:AccountStateRoot, $script:AccountsDir, $script:AuthBackupsDir, $script:AccountConfigBackupsDir, $script:AccountOriginalDir)) {
        Set-RestrictedDirectoryAcl $directory
    }

    $settings = Get-AccountSettings
    Save-OriginalAuthSnapshot
    Ensure-FileCredentialStore $settings
    Show-AccountSecurityWarnings

    if ($settings.AutoSyncCurrent) {
        [void](Sync-CurrentAuth -Reason 'startup-auto-sync' -Quiet)
    }
}
