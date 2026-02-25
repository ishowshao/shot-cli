# ShotCli

ShotCli 是一个面向 macOS 的非交互式截图工具，提供 GUI 权限引导与 `shot` 命令行能力，适合脚本、自动化和 CI 场景。

## 核心能力

- 非交互截图：不依赖鼠标框选 UI。
- 显示器/窗口枚举：先查目标，再按 ID 截图。
- 结构化输出：JSON + 稳定退出码，便于脚本处理。
- XPC 架构：`shot` 通过本地 XPC 调用 `ShotCliXPCService` 执行截图逻辑。

## 架构概览

- `ShotCli.app`：主应用，负责权限引导、CLI 命令安装入口。
- `shot`：CLI 入口（位于 `ShotCli.app/Contents/MacOS/shot`）。
- `ShotCliXPCService.xpc`：内嵌 XPC 服务，执行 `doctor/displays/windows/capture`。
- `ShotCliCore`：CLI 核心实现与 XPC 协议共享代码。

## 环境要求

- macOS 14+
- Xcode 26+

## 快速开始

### 1. 构建

```bash
xcodebuild -project ShotCli.xcodeproj -scheme ShotCli -configuration Debug -destination 'platform=macOS' build
```

### 2. 安装/打开 App

建议将 `ShotCli.app` 放到 `/Applications` 后打开一次。

### 3. 安装 `shot` 命令

推荐在 GUI 中完成：

- 打开 `ShotCli.app`
- 在 `CLI Command (shot)` 卡片点击：
  - `Install to ~/.local/bin`（推荐，无需管理员权限）
  - 或 `Install to /usr/local/bin`（会弹管理员授权）

也可用脚本安装：

```bash
scripts/install-shot-link.sh --app /Applications/ShotCli.app
```

### 4. 验证命令可用

```bash
shot version
shot doctor --pretty
```

## 命令示例

```bash
shot displays --pretty
shot windows --pretty
shot capture --display 4 --out ~/Downloads/lg-ultrafine.png --pretty
```

## 权限说明

截图与窗口枚举依赖 Screen Recording 权限：

- 首次可在 GUI 点击 `Request Permission`
- 然后在系统设置中允许 ShotCli
- 未授权时，相关命令返回退出码 `11`

## 退出码（常用）

- `0`：成功
- `10`：服务不可用
- `11`：缺少 Screen Recording 权限
- `14`：截图/枚举失败
- `15`：输出写入失败

## 验证与排障

详细验证手册见：

- `docs/xpc-verification.md`

快速自动验证：

```bash
scripts/verify-xpc-flow.sh --display-name "LG ULTRAFINE"
```

## 目录结构

- `ShotCli/`：主应用（SwiftUI UI、IPC 客户端）
- `ShotCliCore/`：CLI 核心逻辑与共享协议
- `ShotCliXPCService/`：XPC 服务入口
- `scripts/`：辅助脚本
- `docs/`：设计与验证文档

## 许可证

当前仓库未声明许可证，默认保留所有权利。
