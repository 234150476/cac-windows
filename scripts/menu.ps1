# cac-windows — TUI menu engine
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Show-Menu {
    param([string[]]$Options, [int]$Default = 0)
    $sel = $Default
    $top = [Console]::CursorTop

    function Draw {
        [Console]::SetCursorPosition(0, $top)
        for ($i = 0; $i -lt $Options.Count; $i++) {
            if ($i -eq $sel) { $line = "  > $($Options[$i])" } else { $line = "    $($Options[$i])" }
            $pad = [Math]::Max(0, 50 - $line.Length)
            if ($i -eq $sel) {
                Write-Host "$line$(' ' * $pad)" -ForegroundColor Cyan -NoNewline
                Write-Host ""
            } else {
                Write-Host "$line$(' ' * $pad)"
            }
        }
        Write-Host ""
        Write-Host "  上下键选择  回车确认  Esc返回" -ForegroundColor DarkGray
    }

    Draw
    while ($true) {
        $key = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        switch ($key.VirtualKeyCode) {
            38 { if ($sel -gt 0) { $sel = $sel - 1 } else { $sel = $Options.Count - 1 } }
            40 { if ($sel -lt $Options.Count - 1) { $sel = $sel + 1 } else { $sel = 0 } }
            13 { return $sel }
            27 { return -1 }
        }
        Draw
    }
}

function Show-Header {
    param([string]$Version, [string]$EnvName, [string]$Tz,
          [string]$CcVersion, [bool]$Supported, [bool]$Patched)
    Clear-Host
    Write-Host ""
    Write-Host "  cac-windows $Version" -ForegroundColor White
    Write-Host "  $('=' * 40)" -ForegroundColor DarkGray
    Write-Host ""
    if ($EnvName) {
        $info = "  当前环境: $EnvName"
        if ($Tz) { $info += " | 时区: $Tz" }
        Write-Host $info -ForegroundColor Green
    } else {
        Write-Host "  当前环境: (未创建)" -ForegroundColor Yellow
    }
    if ($CcVersion) {
        $ccLine = "  Claude Code: v$CcVersion"
        if ($Supported) {
            if ($Patched) { $pStatus = "已应用" } else { $pStatus = "未应用" }
            $ccLine += " | 补丁: $pStatus"
            if ($Patched) { $color = "Green" } else { $color = "Yellow" }
        } else {
            $ccLine += " | 不受支持"
            $color = "Red"
        }
        Write-Host $ccLine -ForegroundColor $color
    } else {
        Write-Host "  Claude Code: 未安装" -ForegroundColor Red
    }
    Write-Host ""
}

function Read-Input {
    param([string]$Prompt)
    return Read-Host $Prompt
}

function Wait-AnyKey {
    param([string]$Msg = "  按任意键继续...")
    Write-Host ""
    Write-Host $Msg -ForegroundColor DarkGray
    $null = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
