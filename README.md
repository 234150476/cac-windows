# cac-windows

Claude Code 的 Windows 环境管理工具 — 身份隔离、指纹伪装、时区对齐。

基于 [cac](https://github.com/nmhjklnm/cac) 的 Windows 原生 PowerShell 版本，不依赖 Bash / WSL。

## 功能

- **环境隔离** — 每个环境独立的主机名、MAC、机器ID、UUID、Git 信息
- **时区对齐** — 系统提示词日期自动跟随 TZ 设置（补丁 claude.exe，安装时自动完成）
- **遥测控制** — stealth / paranoid / transparent 三档可选
- **终端伪装** — 4 种 persona 预设（VSCode / Cursor / iTerm / Linux Desktop）
- **代理支持** — HTTP / SOCKS5 代理，可选（软路由用户不需要配）
- **零依赖** — 只需要 Node.js 和 PowerShell

## 环境要求

- Windows 10 / 11
- Node.js ≥ 14
- PowerShell 5.1（系统自带）或 PowerShell 7（推荐）
- Claude Code 2.1.77 或 2.1.202（`npm i -g @anthropic-ai/claude-code@2.1.202`）

> ⚠️ **版本说明：** TZ 时区补丁支持 2.1.77（cli.js）和 2.1.202（SEA 二进制）。其他版本的环境隔离、遥测拦截功能正常，但时区对齐可能被跳过。可通过 `cac env set version <ver>` 切换版本。

## 安装

```powershell
npm i -g cac-windows
```

## 快速开始

```powershell
# 1. 初始化（首次使用）
cac setup

# 2. 把 .cac\bin 加到 PATH（只需执行一次）
$p = [Environment]::GetEnvironmentVariable("PATH", "User")
$cacBin = "$env:USERPROFILE\.cac\bin"
if ($p -notlike "*$cacBin*") { [Environment]::SetEnvironmentVariable("PATH", "$cacBin;$p", "User") }

# 3. 重启终端，然后创建环境
cac env create myenv

# 4. 启动 Claude Code
claude
```

## 命令参考

### 初始化

```powershell
cac setup                    # 首次初始化，找到 claude.exe，生成 wrapper
```

### 环境管理

```powershell
cac env create <name>        # 创建环境（自动激活）
cac env create <name> -p <proxy>   # 创建环境并配置代理
cac env ls                   # 列出所有环境
cac env rm <name>            # 删除环境（不能删当前激活的）
cac <name>                   # 切换到指定环境
```

### 环境配置

```powershell
cac env set tz <timezone>              # 设置时区（如 Pacific/Honolulu）
cac env set lang <locale>              # 设置语言（如 en_US.UTF-8）
cac env set proxy <url>                # 设置代理
cac env set proxy --remove             # 移除代理
cac env set telemetry <mode>           # 遥测模式：stealth / paranoid / transparent
cac env set persona <preset>           # 终端伪装：macos-vscode / macos-cursor / macos-iterm / linux-desktop
cac env set persona --remove           # 移除伪装
cac env set version <ver>              # 切换 Claude Code 版本（如 2.1.77）
```

以上命令默认操作当前激活的环境，也可以指定环境名：

```powershell
cac env set myenv tz Asia/Tokyo
```

### 状态与控制

```powershell
cac check                    # 查看当前环境状态
cac stop                     # 暂停 cac（claude 直连，不注入任何东西）
cac -c                       # 恢复
```

### 帮助

```powershell
cac help                     # 总帮助
cac env                      # 环境子命令帮助
cac env set                  # 可设置的 key 列表
```

## 时区说明

cac 在安装时会自动补丁 Claude Code，让系统提示词里的日期跟随 `TZ` 环境变量。例如你的代理出口在夏威夷：

```powershell
cac env set tz Pacific/Honolulu
```

Claude Code 的 `Today's date is ...` 会显示夏威夷当地日期，与你的出口 IP 地理位置一致。

支持两种入口：SEA 二进制（`claude.exe`，2.1.202+）和 `cli.js`（2.1.77）。原文件自动备份。

## 版本切换

Pro 订阅用户在新版本可能遇到 1M 上下文被锁的问题。2.1.77 版本可正常使用 1M 上下文：

```powershell
cac env set version 2.1.77      # 切到旧版，享受 1M 上下文
cac env set version 2.1.202     # 切回新版
```

cac 自动处理版本间的会话兼容性问题（新版会话在旧版打开不会崩溃）。

## 遥测模式

| 模式 | 说明 |
|------|------|
| `stealth` | 默认。仅屏蔽 1p_event，GrowthBook / 功能开关正常，行为与普通用户无异 |
| `paranoid` | 全部关闭。12 层遥测全杀，零回传 |
| `transparent` | 不干预。用于指纹覆盖已足够完整的场景 |

## 身份伪装覆盖范围

| 维度 | 方式 |
|------|------|
| 主机名 | 随机生成 + Node.js hook + shim |
| MAC 地址 | 随机生成 + Node.js hook + shim |
| 机器 ID | 随机生成 + Node.js hook |
| UUID (macOS) | 随机生成 + ioreg shim |
| 用户名 | 按环境名派生 |
| Git 仓库地址 | 随机假地址 |
| Git 邮箱 | 随机假邮箱 |
| 时区 | TZ 环境变量 + claude.exe 补丁 |
| 语言 / 地区 | LANG 环境变量 |
| DNS 泄露 | cac-dns-guard.js 拦截 |
| 系统提示词日期 | claude.exe byo() 补丁 |

## 文件结构

```
%USERPROFILE%\.cac\
├── bin\
│   ├── claude.cmd        # CMD wrapper
│   └── claude.ps1        # PowerShell wrapper（主入口）
├── fingerprint-hook.js   # Node.js API 拦截
├── cac-dns-guard.js      # DNS 拦截
├── current               # 当前激活的环境名
└── envs\
    └── <name>\
        ├── uuid, hostname, mac_address, machine_id
        ├── tz, lang
        ├── proxy           # 可选
        ├── telemetry_mode
        └── persona         # 可选
```

## 致谢

本项目基于 [cac](https://github.com/nmhjklnm/cac) 改造，原项目提供了完整的 macOS / Linux 支持。

## License

MIT
