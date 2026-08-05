#requires -Version 5.1
<#
Codex 接口管理 - common.ps1（公共基础设施模块）

本文件不能单独运行，需被 menu.ps1 dot-source 后使用。
来源：从 401-Codex-CPA-DeepSeek-Switcher-Win11.ps1 与
402-Codex-Account-Switcher-Win11.ps1 中重复出现的基础设施函数合并去重而来，
逻辑与原脚本保持一致，仅做了以下必要调整：
- DPAPI 加密/解密、受限 ACL 判定不再依赖单一全局 $script:StateRoot /
  $script:DpapiEntropy（两个业务模块现在共存于同一进程/作用域，
  沿用原来的单一全局变量会互相覆盖），改为显式参数传入。
- 新增本地个性化设置（local.settings.json）读写辅助函数，
  用于把个人基础设施细节（如自建 CPA 的 base_url/model）从会被公开托管到
  GitHub 的脚本正文中移出。
#>

Set-StrictMode -Version 2.0

# ==================== 日志 / 错误 ====================
function Write-Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Warn([string]$Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Err([string]$Message) { Write-Host "[ERROR] $Message" -ForegroundColor Red }
function Stop-WithError([string]$Message) { throw $Message }

# ==================== 基础字符串 / 对象工具 ====================
function Get-StringValue($Value) {
    if ($null -eq $Value) { return '' }
    return ([string]$Value).Trim()
}

function Get-ObjectProperty($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-ObjectHasProperty($Object, [string]$Name) {
    if ($null -eq $Object) { return $false }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-ConsistentValue {
    param(
        [object[]]$Values,
        [string]$FieldName,
        [switch]$CaseInsensitive,
        [switch]$Required
    )

    # 注：用 ::new() 而不是 New-Object 构造，避免个别 PowerShell 5.1 运行时下
    # New-Object 构造出的泛型集合被 @() 包裹时触发 "Argument types do not match"
    # 的动态绑定器缺陷（已实测复现，::new() 构造不受影响）。
    $clean = [System.Collections.Generic.List[string]]::new()
    foreach ($value in $Values) {
        $text = Get-StringValue $value
        if ($text) { $clean.Add($text) }
    }

    if ($clean.Count -eq 0) {
        if ($Required) { Stop-WithError "无法取得 $FieldName。" }
        return ''
    }

    $comparison = if ($CaseInsensitive) {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }

    $first = $clean[0]
    foreach ($item in $clean) {
        if (-not [string]::Equals($first, $item, $comparison)) {
            Stop-WithError "输入 JSON 与 JWT 中的 $FieldName 不一致。"
        }
    }
    return $first
}

function Convert-SecureStringToPlainText([Security.SecureString]$SecureValue) {
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

# ==================== JWT / 哈希 ====================
function ConvertFrom-Base64Url([string]$Value) {
    $base64 = $Value.Replace('-', '+').Replace('_', '/')
    switch ($base64.Length % 4) {
        0 { }
        2 { $base64 += '==' }
        3 { $base64 += '=' }
        default { Stop-WithError 'JWT payload 的 Base64URL 长度无效。' }
    }
    try {
        return [Convert]::FromBase64String($base64)
    } catch {
        Stop-WithError '无法解码 JWT payload。'
    }
}

function Decode-JwtPayload([string]$Token, [string]$FieldName) {
    if ([string]::IsNullOrWhiteSpace($Token)) {
        Stop-WithError "缺少字段：$FieldName。"
    }
    $parts = $Token.Split('.')
    if ($parts.Count -ne 3) {
        Stop-WithError "$FieldName 不是三段式 JWT。"
    }
    $bytes = ConvertFrom-Base64Url $parts[1]
    try {
        $text = [Text.Encoding]::UTF8.GetString($bytes)
        return ($text | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        Stop-WithError "无法解析 $FieldName 的 JWT payload。"
    }
}

function Get-Sha256Hex([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $sha.Dispose()
    }
}

# ==================== 时间转换 ====================
function Convert-EpochToUtcString($Value) {
    if ($null -eq $Value) { return '' }
    try {
        $seconds = [Int64]$Value
        return [DateTimeOffset]::FromUnixTimeSeconds($seconds).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.ffffffZ')
    } catch {
        return ''
    }
}

function Convert-Rfc3339ToUtcString($Value) {
    $text = Get-StringValue $Value
    if (-not $text) { return '' }
    # Go/Rust timestamps may contain more than .NET's 7 fractional digits.
    $text = [regex]::Replace($text, '(\.\d{7})\d+(?=(Z|[+-]\d{2}:\d{2})$)', '$1')
    $parsed = [DateTimeOffset]::MinValue
    $ok = [DateTimeOffset]::TryParse(
        $text,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal,
        [ref]$parsed
    )
    if (-not $ok) { return '' }
    return $parsed.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.ffffffZ')
}

function Get-UtcTicksFromString([string]$Value) {
    if (-not $Value) { return [Int64]0 }
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($Value, [ref]$parsed)) {
        return $parsed.UtcDateTime.Ticks
    }
    return [Int64]0
}

# ==================== 路径 ====================
function Get-CodexHomePath {
    $candidate = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        [Environment]::ExpandEnvironmentVariables($env:CODEX_HOME)
    } else {
        Join-Path $env:USERPROFILE '.codex'
    }
    return [IO.Path]::GetFullPath($candidate)
}

function Normalize-Url([string]$Url) {
    $value = Get-StringValue $Url
    while ($value.EndsWith('/')) {
        $value = $value.Substring(0, $value.Length - 1)
    }
    return $value
}

function ConvertTo-TomlString([string]$Value) {
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    return '"' + $escaped + '"'
}

# ==================== ACL ====================
# $StateRoot 为空表示"这是 Codex 自身共享的文件"（如 auth.json / config.toml）：
# 保留继承 ACL，只额外确保当前用户有 FullControl，避免破坏 CLI/IDE/桌面端共享的登录缓存。
# $StateRoot 非空且 $Path 落在其下：视为本工具专属的密钥/备份文件，直接收紧成仅当前用户 + SYSTEM + Administrators。
function Set-RestrictedDirectoryAcl([string]$Path) {
    try {
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
        $adminsSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetOwner($currentSid)
        $acl.SetAccessRuleProtection($true, $false)
        $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        $propagation = [Security.AccessControl.PropagationFlags]::None
        foreach ($sid in @($currentSid, $systemSid, $adminsSid)) {
            $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                $sid,
                [Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance,
                $propagation,
                [Security.AccessControl.AccessControlType]::Allow
            )
            [void]$acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $Path -AclObject $acl
    } catch {
        Write-Warn "无法完全收紧目录 ACL：$Path；$($_.Exception.Message)"
    }
}

function Set-RestrictedFileAcl([string]$Path, [string]$StateRoot = '') {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    try {
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $isStateFile = $false
        if ($StateRoot) {
            $fullPath = [IO.Path]::GetFullPath($Path)
            $statePrefix = [IO.Path]::GetFullPath($StateRoot).TrimEnd('\') + '\'
            $isStateFile = $fullPath.StartsWith($statePrefix, [StringComparison]::OrdinalIgnoreCase)
        }

        if ($isStateFile) {
            $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
            $adminsSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
            $acl = [Security.AccessControl.FileSecurity]::new()
            $acl.SetOwner($currentSid)
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($sid in @($currentSid, $systemSid, $adminsSid)) {
                $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                    $sid,
                    [Security.AccessControl.FileSystemRights]::FullControl,
                    [Security.AccessControl.AccessControlType]::Allow
                )
                [void]$acl.AddAccessRule($rule)
            }
            Set-Acl -LiteralPath $Path -AclObject $acl
        } else {
            # 保留继承/系统 ACL，只补一条当前用户 FullControl，避免破坏
            # Codex CLI / IDE 扩展 / 桌面端共享的 auth.json、config.toml。
            $acl = Get-Acl -LiteralPath $Path
            $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                $currentSid,
                [Security.AccessControl.FileSystemRights]::FullControl,
                [Security.AccessControl.AccessControlType]::Allow
            )
            $acl.SetAccessRule($rule)
            Set-Acl -LiteralPath $Path -AclObject $acl
        }
    } catch {
        Write-Warn "无法确认文件 ACL：$Path；$($_.Exception.Message)"
    }
}

# ==================== 原子写入 ====================
function Write-BytesAtomic([string]$Path, [byte[]]$Bytes) {
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    $temp = Join-Path $directory ('.tmp-' + [Guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllBytes($temp, $Bytes)
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try {
                [IO.File]::Replace($temp, $Path, $null, $true)
            } catch {
                Remove-Item -LiteralPath $Path -Force
                [IO.File]::Move($temp, $Path)
            }
        } else {
            [IO.File]::Move($temp, $Path)
        }
    } finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-Utf8TextAtomic([string]$Path, [string]$Text) {
    $encoding = [System.Text.UTF8Encoding]::new($false)
    Write-BytesAtomic -Path $Path -Bytes $encoding.GetBytes($Text)
}

# ==================== DPAPI（entropy 显式传入，避免跨模块共享全局变量互相覆盖）====================
function Protect-TextForCurrentUser([string]$Text, [byte[]]$Entropy) {
    $plain = [Text.Encoding]::UTF8.GetBytes($Text)
    return [Security.Cryptography.ProtectedData]::Protect(
        $plain,
        $Entropy,
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
}

function Unprotect-TextForCurrentUser([byte[]]$CipherBytes, [byte[]]$Entropy) {
    $plain = [Security.Cryptography.ProtectedData]::Unprotect(
        $CipherBytes,
        $Entropy,
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [Text.Encoding]::UTF8.GetString($plain)
}

function Save-ProtectedText([string]$Path, [string]$Text, [byte[]]$Entropy, [string]$StateRoot = '') {
    Write-BytesAtomic -Path $Path -Bytes (Protect-TextForCurrentUser $Text $Entropy)
    Set-RestrictedFileAcl -Path $Path -StateRoot $StateRoot
}

function Load-ProtectedText([string]$Path, [byte[]]$Entropy) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-WithError "加密文件不存在：$Path"
    }
    try {
        return Unprotect-TextForCurrentUser ([IO.File]::ReadAllBytes($Path)) $Entropy
    } catch {
        Stop-WithError 'DPAPI 解密失败。该文件只能由创建它的同一 Windows 用户配置文件读取，或文件已损坏。'
    }
}

# ==================== JSON ====================
function Save-JsonMetadata([string]$Path, $Object, [string]$StateRoot = '') {
    $json = ($Object | ConvertTo-Json -Depth 20) + [Environment]::NewLine
    Write-Utf8TextAtomic -Path $Path -Text $json
    Set-RestrictedFileAcl -Path $Path -StateRoot $StateRoot
}

function Read-JsonFile([string]$Path) {
    return ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop)
}

# ==================== Codex 进程守卫 ====================
function Test-CodexProcessesRunning {
    try {
        $processes = Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            if ($_.ProcessId -eq $PID) { return $false }
            $name = ([string]$_.Name).ToLowerInvariant()
            $cmd = [string]$_.CommandLine
            if ($name -in @('codex.exe', 'codex-cli.exe')) { return $true }
            if ($name -eq 'node.exe' -and $cmd -match '(?i)(@openai[\\/]codex|node_modules[\\/].*codex|\bcodex(?:\.cmd|\.ps1)?\b)') {
                return $true
            }
            return $false
        }
        return @($processes)
    } catch {
        Write-Warn "无法完整检查 Codex 进程：$($_.Exception.Message)"
        return @()
    }
}

function Assert-CodexNotRunning([bool]$Enabled = $true) {
    if (-not $Enabled) { return }
    $running = @(Test-CodexProcessesRunning)
    if ($running.Count -gt 0) {
        $descriptions = $running | ForEach-Object { "$($_.Name)(PID=$($_.ProcessId))" }
        Stop-WithError ('检测到 Codex 仍在运行：' + ($descriptions -join ', ') + '。请先关闭 Codex CLI、IDE 扩展会话和 app-server。')
    }
}

# ==================== 本地个性化设置（local.settings.json）====================
# 仅存放非密钥类偏好（base_url、model、reasoning effort 等）。
# API Key 一律走各模块自己的 DPAPI 保险库，不进这个文件。
# 该文件只存在于本机 <CODEX_HOME>\codex-interface-manager\，不会出现在 GitHub 仓库里。
function ConvertTo-OrderedHashtable($InputObject) {
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $hash = [ordered]@{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $hash[$prop.Name] = ConvertTo-OrderedHashtable $prop.Value
        }
        return $hash
    }
    if (($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string])) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $InputObject) { $list.Add((ConvertTo-OrderedHashtable $item)) }
        return , $list
    }
    return $InputObject
}

function Get-ManagerLocalSettingsPath {
    return Join-Path $script:ManagerStateRoot 'local.settings.json'
}

function Import-LocalSettings {
    $path = Get-ManagerLocalSettingsPath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $json = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
            $script:LocalSettings = ConvertTo-OrderedHashtable $json
            if ($null -eq $script:LocalSettings) { $script:LocalSettings = [ordered]@{} }
            return
        } catch {
            Write-Warn "本地设置文件解析失败，将使用默认值：$path"
        }
    }
    $script:LocalSettings = [ordered]@{}
}

function Save-LocalSettings {
    $json = ($script:LocalSettings | ConvertTo-Json -Depth 10) + [Environment]::NewLine
    Write-Utf8TextAtomic -Path (Get-ManagerLocalSettingsPath) -Text $json
}

function Get-SettingValue([string]$Section, [string]$Key, $Default) {
    if (-not $script:LocalSettings.Contains($Section)) { return $Default }
    $sectionTable = $script:LocalSettings[$Section]
    if (($sectionTable -is [System.Collections.IDictionary]) -and $sectionTable.Contains($Key)) {
        $value = $sectionTable[$Key]
        if ($null -ne $value -and (Get-StringValue $value) -ne '') { return $value }
    }
    return $Default
}

function Set-SettingValue([string]$Section, [string]$Key, $Value) {
    if (-not $script:LocalSettings.Contains($Section)) { $script:LocalSettings[$Section] = [ordered]@{} }
    $script:LocalSettings[$Section][$Key] = $Value
    Save-LocalSettings
}

# 仅当本地设置里没有合法值时才提示输入；已配置过的值直接返回，不会每次运行都追问。
function Read-SettingOrPrompt {
    param(
        [string]$Section,
        [string]$Key,
        [string]$Default,
        [string]$PromptText,
        [scriptblock]$Validator = $null,
        [switch]$ForcePrompt
    )
    $current = Get-SettingValue $Section $Key $Default
    if (-not $ForcePrompt -and $current -and (-not $Validator -or (& $Validator $current))) {
        return $current
    }
    while ($true) {
        Write-Host ("$PromptText [$current]: ") -NoNewline -ForegroundColor Yellow
        $inputValue = Read-Host
        $value = if ([string]::IsNullOrWhiteSpace($inputValue)) { $current } else { $inputValue.Trim() }
        if (-not $Validator -or (& $Validator $value)) {
            Set-SettingValue $Section $Key $value
            return $value
        }
        Write-Warn '输入值不符合要求，请重新输入。'
    }
}
