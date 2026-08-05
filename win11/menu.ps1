#requires -Version 5.1
<#
Codex 接口管理 - menu.ps1（统一入口）

编排 provider.ps1（原 401：CPA / DeepSeek 供应商切换，只改 config.toml）
与 account.ps1（原 402：账号导入/切换，只改 auth.json）两个模块，
提供一个统一菜单。本文件业务逻辑很薄，主要做参数初始化和菜单调度，
真正的业务函数都在 provider.ps1 / account.ps1 里。

调用约定：由本地 bootstrap 脚本（403-Codex-Interface-Manager-Win11.ps1）
依次 dot-source common.ps1 -> provider.ps1 -> account.ps1 -> menu.ps1，
再调用 Show-UnifiedMenu 进入主循环。

安全边界（沿用原 401/402 的既有约定，未改变）：
- provider 相关操作只碰 config.toml 的 provider 字段 + cpa-switcher-401-win11 状态目录
- account 相关操作只碰 auth.json + account-switcher-402-win11 状态目录
- 两者互不覆盖对方的备份/快照
#>

Set-StrictMode -Version 2.0

function Enter-ManagerSingleInstance {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $nameMaterial = ($identity + '|' + $script:CodexHome).ToLowerInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($nameMaterial))
        $hex = (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $sha.Dispose()
    }
    $createdNew = $false
    $script:ManagerMutex = [Threading.Mutex]::new($true, ('Local\CodexInterfaceManagerWin11_' + $hex.Substring(0, 24)), [ref]$createdNew)
    if (-not $createdNew) { Stop-WithError '检测到另一个 Codex 接口管理实例正在运行。' }
}

function Exit-ManagerSingleInstance {
    if ($null -ne $script:ManagerMutex) {
        try { $script:ManagerMutex.ReleaseMutex() } catch {}
        try { $script:ManagerMutex.Dispose() } catch {}
        $script:ManagerMutex = $null
    }
}

# 由 bootstrap 脚本在 dot-source 完 4 个模块文件之后调用一次。
function Initialize-UnifiedManager {
    if ($env:OS -ne 'Windows_NT') { Stop-WithError '本工具仅支持 Windows 11。' }
    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { Stop-WithError 'USERPROFILE 环境变量为空。' }

    try {
        [Console]::OutputEncoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
        [Console]::InputEncoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    } catch {}
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch {}

    $script:CodexHome = Get-CodexHomePath
    $script:ConfigFile = Join-Path $script:CodexHome 'config.toml'
    $script:AuthFile = Join-Path $script:CodexHome 'auth.json'
    $script:ManagerStateRoot = Join-Path $script:CodexHome 'codex-interface-manager'

    if (-not (Test-Path -LiteralPath $script:ManagerStateRoot -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $script:ManagerStateRoot -Force)
    }
    Set-RestrictedDirectoryAcl $script:ManagerStateRoot

    Import-LocalSettings
    Enter-ManagerSingleInstance

    Initialize-ProviderModule
    Initialize-AccountModule
}

function Show-AccountSwitchSubmenu {
    while ($true) {
        Write-Host ''
        Write-Host '---- 官方登录 / 账号切换 ----'
        Write-Host '1) 从剪贴板导入 JSON 并立即切换（推荐：先在网页/App 复制完整登录导出 JSON）'
        Write-Host '2) 从 JSON 文件导入并立即切换'
        Write-Host '3) 切换到已保存账号'
        Write-Host '4) 删除已保存账号'
        Write-Host '0) 返回上级菜单'
        $choice = Read-Host '请选择'
        switch ($choice) {
            '1' { Import-FromClipboard; return }
            '2' { Import-FromJsonFile; return }
            '3' { Switch-ToSavedAccount; return }
            '4' { Delete-SavedAccount; return }
            '0' { return }
            default { Write-Warn "无效选项：$choice" }
        }
    }
}

function Show-BackupManagementSubmenu {
    while ($true) {
        Write-Host ''
        Write-Host '---- 备份管理 ----'
        Write-Host '1) 恢复账号（auth.json）时间戳备份'
        Write-Host '2) 恢复首次运行前的 auth.json'
        Write-Host '3) 恢复首次运行前的 config.toml（账号模块视角，即 cli_auth_credentials_store 相关备份）'
        Write-Host '4) 恢复供应商（config.toml）配置时间戳备份'
        Write-Host '5) 手动同步当前 auth.json 到账号保险库'
        Write-Host '0) 返回上级菜单'
        $choice = Read-Host '请选择'
        switch ($choice) {
            '1' { Restore-AccountTimestampBackup; return }
            '2' { Restore-OriginalAuth; return }
            '3' { Restore-OriginalConfig; return }
            '4' { Restore-ProviderTimestampBackup; return }
            '5' {
                $settings = Get-AccountSettings
                Assert-CodexNotRunning $settings.RefuseIfRunning
                if (-not (Sync-CurrentAuth -Reason 'manual-sync')) { Write-Warn '没有可同步的有效 auth.json。' }
                return
            }
            '0' { return }
            default { Write-Warn "无效选项：$choice" }
        }
    }
}

function Show-UnifiedStatus {
    Show-AccountCurrentStatus
    Show-ProviderStatusAndTest
}

function Invoke-ManagerUpdateCheck {
    $updateCommand = Get-Command Sync-ManagerModulesFromGitHub -ErrorAction SilentlyContinue
    if ($null -eq $updateCommand) {
        Write-Warn '当前运行方式不支持在线检查更新（未找到同步函数，可能是离线/独立文件运行模式）。'
        return
    }
    & Sync-ManagerModulesFromGitHub
}

function Show-UnifiedMenu {
    Write-Host ''
    Write-Host '========================================================' -ForegroundColor White
    Write-Host ' Codex 接口管理（Windows 11）' -ForegroundColor White
    Write-Host " CODEX_HOME: $script:CodexHome"
    Write-Host '========================================================' -ForegroundColor White

    while ($true) {
        Write-Host ''
        Write-Host '1) 官方登录 / 账号切换'
        Write-Host '2) 切换到 CPA 接口'
        Write-Host '3) 切换到 DeepSeek V4 Flash'
        Write-Host '4) 恢复官方订阅（还原 config.toml 到切换前状态，不影响账号）'
        Write-Host '5) 修改供应商参数（CPA / DeepSeek 的地址、模型、推理强度）'
        Write-Host '6) 状态总览（当前账号 + 当前供应商 + 连通性测试）'
        Write-Host '7) 备份管理'
        Write-Host '8) 检查更新'
        Write-Host '0) 退出'
        $choice = Read-Host '请选择 [0-8]'

        try {
            switch ($choice) {
                '1' { Show-AccountSwitchSubmenu }
                '2' { Switch-ToProviderMode 'cpa' }
                '3' { Switch-ToProviderMode 'deepseek' }
                '4' { Restore-ProviderOriginal }
                '5' {
                    $modeChoice = Read-Host '修改哪个供应商的参数？[1=CPA / 2=DeepSeek]'
                    if ($modeChoice -eq '1') { Edit-ProviderSettings 'cpa' }
                    elseif ($modeChoice -eq '2') { Edit-ProviderSettings 'deepseek' }
                    else { Write-Warn '无效选择。' }
                }
                '6' { Show-UnifiedStatus }
                '7' { Show-BackupManagementSubmenu }
                '8' { Invoke-ManagerUpdateCheck }
                '0' { Write-Info '已退出。'; return }
                default { Write-Warn "无效选项：$choice" }
            }
        } catch {
            Write-Err $_.Exception.Message
        }
    }
}
