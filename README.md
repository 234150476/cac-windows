# cac-windows

Claude Code 的 Windows 隐私保护工具 — 二进制补丁抹除中国特征，遥测正常流转。

## 功能

- **隐私补丁** — 自动补丁 claude.exe，抹除时区（Asia/Shanghai → TZ）、语言（zh → en）、UTC 偏移（+08:00 → +00:00）
- **时区对齐** — 系统提示词日期和时区跟随 TZ 环境变量
- **代理支持** — HTTP / SOCKS5 代理配置
- **环境切换** — 多环境管理（换号用）
- **封号清理** — `cac cleanup` 清除追踪数据
- **零依赖** — 只需要 Node.js 和 PowerShell

## 环境要求

- Windows 10 / 11
- Node.js ≥ 14
- PowerShell 5.1（系统自带）或 PowerShell 7（推荐）
- Claude Code 2.1.222+（`npm i -g @anthropic-ai/claude-code@2.1.222`）

## 安装

```powershell
npm i -g cac-windows --registry https://registry.npmjs.org --force
```

安装时自动补丁 claude.exe（TZ + 隐私）。

## 快速开始

```powershell
# 1. 初始化
cac setup

# 2. 把 .cac\bin 加到 PATH（只需执行一次）
$p = [Environment]::GetEnvironmentVariable("PATH", "User")
$cacBin = "$env:USERPROFILE\.cac\bin"
if ($p -notlike "*$cacBin*") { [Environment]::SetEnvironmentVariable("PATH", "$cacBin;$p", "User") }

# 3. 创建环境
cac env create myenv

# 4. 设置时区（按你的代理出口选）
cac env set tz Pacific/Honolulu

# 5. 重启终端，启动 Claude Code
claude
```

## 命令参考

```powershell
cac setup                              # 首次初始化
cac env create <name> [-p <proxy>]     # 创建环境
cac env ls                             # 列出环境
cac env rm <name>                      # 删除环境
cac <name>                             # 切换环境
cac env set tz <timezone>              # 设置时区
cac env set lang <locale>              # 设置语言
cac env set proxy <url>                # 设置代理
cac env set proxy --remove             # 移除代理
cac env set version <ver>              # 切换 Claude Code 版本
cac check                              # 查看状态
cac cleanup                            # 清理追踪数据（换号用）
```

## 隐私补丁覆盖范围

| 泄露点 | 补丁方式 |
|--------|---------|
| 系统提示词日期 | fys() → 跟随 TZ 环境变量 |
| 系统提示词时区 | resolvedOptions().timeZone → TZ 环境变量 |
| 系统时区名缓存 | yss() → TZ 环境变量 |
| 系统语言检测 | Zsu() → 固定 "en" |
| UTC 偏移 | getTimezoneOffset() → 固定 +00:00 |
| 日期格式化 locale | toLocaleDateString → 固定 "en" |
| 语言环境变量 | LANG = en_US.UTF-8 |

## 致谢

本项目基于 [cac](https://github.com/nmhjklnm/cac) 改造，原项目提供了完整的 macOS / Linux 支持。

## License

MIT
