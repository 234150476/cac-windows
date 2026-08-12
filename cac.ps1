#Requires -Version 5.1
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$CAC_VERSION = "1.0.24"
$SUPPORTED_CC = "2.1.222"

$scriptDir = Split-Path $MyInvocation.MyCommand.Definition -Parent
. (Join-Path $scriptDir "scripts\lib.ps1")
. (Join-Path $scriptDir "scripts\menu.ps1")

# ── helpers ────────────────────────────────────────────────

function Get-CcVersion {
    $pkg = Join-Path $env:APPDATA "npm\node_modules\@anthropic-ai\claude-code\package.json"
    if (Test-Path $pkg) {
        try { return (Get-Content $pkg -Raw | ConvertFrom-Json).version } catch { return $null }
    }
    return $null
}

$script:_patchedCache = $null
function Test-Patched {
    if ($script:_patchedCache -ne $null) { return $script:_patchedCache }
    $exe = Join-Path $env:APPDATA "npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe"
    if (-not (Test-Path $exe)) { $script:_patchedCache = $false; return $false }
    $bytes = [System.IO.File]::ReadAllBytes($exe)
    $text = [System.Text.Encoding]::GetEncoding("iso-8859-1").GetString($bytes, 0, [Math]::Min($bytes.Length, 280000000))
    $script:_patchedCache = $text.Contains('mss=process.env.TZ')
    return $script:_patchedCache
}

function Reset-PatchCache { $script:_patchedCache = $null }

function Do-Patch {
    $ps = Join-Path $scriptDir "scripts\patch-cli.js"
    if (-not (Test-Path $ps)) { Write-Err "patch-cli.js 未找到"; return }
    $ccDir = Join-Path $env:APPDATA "npm\node_modules\@anthropic-ai\claude-code"
    & node $ps $ccDir 2>&1 | ForEach-Object { Write-Host "  $_" }
}

# ── auto init ──────────────────────────────────────────────

function Do-Init {
    $realFile = Join-Path $CAC_DIR "real_claude"
    if (Test-Path $realFile) { return $true }
    Write-Host ""
    Write-Host "  正在初始化..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $ENVS_DIR -Force | Out-Null
    $claude = Find-RealClaude
    if (-not $claude) {
        Write-Err "未找到 Claude Code"
        Write-Host "  请安装: npm i -g @anthropic-ai/claude-code@$SUPPORTED_CC" -ForegroundColor White
        Wait-AnyKey; return $false
    }
    Set-Content $realFile $claude
    Write-OK "Claude Code: $claude"
    Write-Wrapper
    Write-OK "Wrapper: $(Join-Path $CAC_DIR 'bin\claude.ps1')"
    Do-Patch
    Write-Host ""
    return $true
}

# ── actions ────────────────────────────────────────────────

function Action-Launch {
    $envName = Get-CurrentEnv
    if (-not $envName) { Write-Err "未激活环境"; Wait-AnyKey; return }
    $ed = Get-EnvDir $envName
    # 清理旧环境变量
    foreach ($v in @("HTTPS_PROXY","HTTP_PROXY","ALL_PROXY","NO_PROXY","TZ")) {
        Remove-Item "env:$v" -ErrorAction SilentlyContinue
    }
    $proxy = Read-FileValue (Join-Path $ed "proxy")
    if ($proxy) {
        $env:HTTPS_PROXY=$proxy; $env:HTTP_PROXY=$proxy
        $env:ALL_PROXY=$proxy; $env:NO_PROXY="localhost,127.0.0.1"
    }
    $tz = Read-FileValue (Join-Path $ed "tz")
    if ($tz) { $env:TZ = $tz }
    $env:LANG = Read-FileValue (Join-Path $ed "lang") "en_US.UTF-8"
    $sid = Read-FileValue (Join-Path $ed "stable_id")
    if ($sid) { Update-Statsig $sid }
    $uid = Read-FileValue (Join-Path $ed "user_id")
    if ($uid) { Update-ClaudeJsonUserId $uid }
    $real = (Get-Content (Join-Path $CAC_DIR "real_claude") -Raw).Trim()
    if (-not (Test-Path $real)) {
        Write-Err "claude 路径无效: $real"
        Write-Host "  请运行 '版本更新并应用补丁' 重新安装" -ForegroundColor White
        Wait-AnyKey; return
    }
    Clear-Host
    if ($real -like "*.js") { & node $real } else { & $real }
}

function Action-InstallAndPatch {
    Write-Host ""
    Write-Host "  将安装 Claude Code v$SUPPORTED_CC 并应用隐私补丁" -ForegroundColor Cyan
    $confirm = Read-Input "  继续? (y/N)"
    if ($confirm -ne "y") { return }
    Write-Host "  正在安装..." -ForegroundColor Cyan
    $npmOutput = & npm install -g "@anthropic-ai/claude-code@$SUPPORTED_CC" --registry https://registry.npmjs.org 2>&1
    $npmExit = $LASTEXITCODE
    $npmOutput | ForEach-Object { Write-Host "  $_" }
    if ($npmExit -ne 0) { Write-Err "安装失败"; Wait-AnyKey; return }
    $claude = Find-RealClaude
    if ($claude) {
        Set-Content (Join-Path $CAC_DIR "real_claude") $claude
        Write-Wrapper
    }
    Do-Patch
    Reset-PatchCache
    Write-OK "完成"
    Wait-AnyKey
}

function Action-Cleanup {
    Write-Host ""
    $confirm = Read-Input "  确认清理追踪数据? (y/N)"
    if ($confirm -ne "y") { return }
    $cs = Join-Path $scriptDir "scripts\cleanup.ps1"
    if (Test-Path $cs) { & $cs } else { Write-Err "cleanup.ps1 未找到" }
    Wait-AnyKey
}

function Action-Status {
    $envName = Get-CurrentEnv
    if (-not $envName) { Write-Warn "未激活环境"; Wait-AnyKey; return }
    $ed = Get-EnvDir $envName
    Write-Host ""
    Write-Host "  环境:      $envName" -ForegroundColor White
    Write-Host "  时区:      $(Read-FileValue (Join-Path $ed 'tz'))"
    Write-Host "  语言:      $(Read-FileValue (Join-Path $ed 'lang'))"
    Write-Host "  代理:      $(Read-FileValue (Join-Path $ed 'proxy') '(无)')"
    Write-Host "  主机名:    $(Read-FileValue (Join-Path $ed 'hostname'))"
    Write-Host "  Claude:    $(Read-FileValue (Join-Path $CAC_DIR 'real_claude'))"
    Wait-AnyKey
}

# ── env sub-menu ───────────────────────────────────────────

function Action-EnvSwitch {
    $envs = @(Get-ChildItem $ENVS_DIR -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    if ($envs.Count -eq 0) { Write-Warn "暂无环境"; Wait-AnyKey; return }
    $cur = Get-CurrentEnv
    $labels = $envs | ForEach-Object { if ($_ -eq $cur) { "$_ (当前)" } else { $_ } }
    Write-Host "  选择环境:" -ForegroundColor White
    Write-Host ""
    $idx = Show-Menu $labels
    if ($idx -lt 0) { return }
    $name = $envs[$idx]
    Set-Content (Join-Path $CAC_DIR "current") $name
    $sid = Read-FileValue (Join-Path (Get-EnvDir $name) "stable_id")
    if ($sid) { Update-Statsig $sid }
    $uid = Read-FileValue (Join-Path (Get-EnvDir $name) "user_id")
    if ($uid) { Update-ClaudeJsonUserId $uid }
    Write-OK "已切换到 $name"
    Wait-AnyKey
}

function Action-EnvCreate {
    Write-Host ""
    $name = Read-Input "  环境名称"
    if (-not $name) { return }
    $ed = Get-EnvDir $name
    if (Test-Path $ed) { Write-Err "环境 '$name' 已存在"; Wait-AnyKey; return }
    $rawProxy = Read-Input "  代理地址 (回车跳过)"
    $tzInput = Read-Input "  时区 (如 Pacific/Honolulu, 回车跳过)"
    New-Item -ItemType Directory -Path $ed -Force | Out-Null
    Set-Content (Join-Path $ed "uuid")       (New-Uuid)
    Set-Content (Join-Path $ed "stable_id")  (New-Sid)
    Set-Content (Join-Path $ed "user_id")    (New-UserId)
    Set-Content (Join-Path $ed "machine_id") (New-MachineId)
    Set-Content (Join-Path $ed "hostname")   (New-FakeHostname)
    Set-Content (Join-Path $ed "mac_address")(New-FakeMac)
    if ($tzInput) { $tzVal = $tzInput } else { $tzVal = "UTC" }
    Set-Content (Join-Path $ed "tz")         $tzVal
    Set-Content (Join-Path $ed "lang")       "en_US.UTF-8"
    if ($rawProxy) {
        $url = Parse-Proxy $rawProxy
        if ($url) { Set-Content (Join-Path $ed "proxy") $url }
        else { Write-Warn "代理格式无效，已跳过" }
    }
    Set-Content (Join-Path $CAC_DIR "current") $name
    $sid = Read-FileValue (Join-Path $ed "stable_id")
    Update-Statsig $sid
    Update-ClaudeJsonUserId (Read-FileValue (Join-Path $ed "user_id"))
    Write-OK "已创建 '$name'"
    Wait-AnyKey
}

function Action-EnvSetTz {
    $envName = Get-CurrentEnv
    if (-not $envName) { Write-Err "未激活环境"; Wait-AnyKey; return }
    $cur = Read-FileValue (Join-Path (Get-EnvDir $envName) "tz")
    Write-Host "  当前时区: $cur" -ForegroundColor DarkGray
    $tz = Read-Input "  新时区"
    if ($tz) {
        Set-Content (Join-Path (Get-EnvDir $envName) "tz") $tz
        Write-OK "时区 -> $tz"
    }
    Wait-AnyKey
}

function Action-EnvSetProxy {
    $envName = Get-CurrentEnv
    if (-not $envName) { Write-Err "未激活环境"; Wait-AnyKey; return }
    $cur = Read-FileValue (Join-Path (Get-EnvDir $envName) "proxy")
    if ($cur) { Write-Host "  当前代理: $cur" -ForegroundColor DarkGray }
    $raw = Read-Input "  代理地址 (留空移除)"
    $pf = Join-Path (Get-EnvDir $envName) "proxy"
    if ($raw) {
        $url = Parse-Proxy $raw
        if ($url) { Set-Content $pf $url; Write-OK "代理 -> $url" }
        else { Write-Err "代理格式无效" }
    } else {
        if (Test-Path $pf) { Remove-Item $pf -Force; Write-OK "代理已移除" }
        else { Write-Warn "当前无代理" }
    }
    Wait-AnyKey
}

function Action-EnvDelete {
    $envs = @(Get-ChildItem $ENVS_DIR -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    if ($envs.Count -eq 0) { Write-Warn "暂无环境"; Wait-AnyKey; return }
    $cur = Get-CurrentEnv
    $deletable = @($envs | Where-Object { $_ -ne $cur })
    if ($deletable.Count -eq 0) { Write-Warn "只有当前环境，无法删除"; Wait-AnyKey; return }
    Write-Host "  选择要删除的环境:" -ForegroundColor White
    Write-Host ""
    $idx = Show-Menu $deletable
    if ($idx -lt 0) { return }
    $name = $deletable[$idx]
    $confirm = Read-Input "  确认删除 '$name'? (y/N)"
    if ($confirm -ne "y") { return }
    $recycleDir = Join-Path $CAC_DIR "recycle"
    New-Item -ItemType Directory -Path $recycleDir -Force | Out-Null
    $dest = Join-Path $recycleDir "$name-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    try {
        Move-Item (Get-EnvDir $name) $dest -Force
        Write-OK "'$name' 已移至回收站"
    } catch {
        Write-Err "删除失败: $_"
    }
    Wait-AnyKey
}

function Action-EmptyRecycle {
    $recycleDir = Join-Path $CAC_DIR "recycle"
    if (-not (Test-Path $recycleDir)) { Write-Warn "回收站为空"; Wait-AnyKey; return }
    $items = @(Get-ChildItem $recycleDir -Directory -ErrorAction SilentlyContinue)
    if ($items.Count -eq 0) { Write-Warn "回收站为空"; Wait-AnyKey; return }
    Write-Host ""
    Write-Host "  回收站内容:" -ForegroundColor White
    foreach ($i in $items) { Write-Host "    $($i.Name)" }
    $confirm = Read-Input "  确认清空回收站? (y/N)"
    if ($confirm -ne "y") { return }
    try {
        Remove-Item $recycleDir -Recurse -Force
        Write-OK "回收站已清空"
    } catch {
        Write-Err "清空失败: $_"
    }
    Wait-AnyKey
}

function Menu-EnvManage {
    while ($true) {
        $envName = Get-CurrentEnv
        if ($envName) { $tz = Read-FileValue (Join-Path (Get-EnvDir $envName) "tz") } else { $tz = "" }
        $ccVer = Get-CcVersion
        Show-Header $CAC_VERSION $envName $tz $ccVer ($ccVer -eq $SUPPORTED_CC) (Test-Patched)
        Write-Host "  [ 环境管理 ]" -ForegroundColor White
        Write-Host ""
        $opts = @(
            "1. 切换环境"
            "2. 创建新环境"
            "3. 删除环境"
            "4. 设置当前环境时区"
            "5. 设置当前环境代理"
            "6. 清空回收站"
            "0. 返回主菜单"
        )
        $sel = Show-Menu $opts
        switch ($sel) {
            0 { Action-EnvSwitch }
            1 { Action-EnvCreate }
            2 { Action-EnvDelete }
            3 { Action-EnvSetTz }
            4 { Action-EnvSetProxy }
            5 { Action-EmptyRecycle }
            { $_ -eq 6 -or $_ -eq -1 } { return }
        }
    }
}

# ── main loop ──────────────────────────────────────────────

if (-not (Do-Init)) { exit 1 }

while ($true) {
    $envName = Get-CurrentEnv
    if ($envName) { $tz = Read-FileValue (Join-Path (Get-EnvDir $envName) "tz") } else { $tz = "" }
    $ccVer = Get-CcVersion
    $supported = $ccVer -eq $SUPPORTED_CC
    $patched = Test-Patched
    Show-Header $CAC_VERSION $envName $tz $ccVer $supported $patched

    $opts = @(
        "1. 启动 Claude Code"
        "2. 环境管理"
        "3. 版本更新并应用补丁"
        "4. 清理追踪数据"
        "5. 查看状态"
        "0. 退出"
    )
    $sel = Show-Menu $opts
    switch ($sel) {
        0 { Action-Launch; break }
        1 { Menu-EnvManage }
        2 { Action-InstallAndPatch }
        3 { Action-Cleanup }
        4 { Action-Status }
        { $_ -eq 5 -or $_ -eq -1 } { exit 0 }
    }
}
