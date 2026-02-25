# XPC 方案验证手册

本文用于验证当前实现是否走在目标终态：`shot -> XPC -> ShotCliXPCService`。

## 0. 前置

- 已安装 `ShotCli.app`（建议放在 `/Applications/ShotCli.app`）。
- 或者你已执行过 Debug 构建。
- 若终端里还不能直接执行 `shot`：
  - 打开 `ShotCli.app`
  - 在 `CLI Command (shot)` 卡片点击 `Install to ~/.local/bin`
  - 重新打开终端后执行 `shot version`
- 如需安装到 `/usr/local/bin`，可点 `Install to /usr/local/bin`，会弹出系统管理员授权框。

## 1. 快速自动验证（推荐）

运行：

```bash
scripts/verify-xpc-flow.sh
```

可选参数：

```bash
scripts/verify-xpc-flow.sh --display-id 4 --out ~/Downloads/lg-test.png
scripts/verify-xpc-flow.sh --display-name "LG ULTRAFINE"
```

预期：

- `doctor_exit=11`：表示当前缺屏幕录制权限（未授权阶段预期）。
- `displays_exit=0`：可以列出显示器。
- `capture_exit=11`：未授权阶段预期。
- 完成授权后再次执行，`capture_exit=0` 且输出文件存在。

## 2. 手工验证命令

```bash
shot doctor --pretty
shot displays --pretty
shot windows --pretty
shot capture --display <displayId> --out ~/Downloads/test.png --pretty
```

退出码预期：

- 未授权时：
  - `doctor` -> `11`
  - `windows` -> `11`
  - `capture` -> `11`
- 授权后：
  - `doctor` -> `0`
  - `capture` -> `0`

## 3. 验证权限引导是否由主界面承接

1. 打开 `ShotCli.app`。
2. 点击 `Screen Recording` 卡片里的 `Request Permission`。
3. 在系统隐私设置页给 ShotCli 开启屏幕录制。
4. 回到终端重新执行：

```bash
shot doctor --pretty
```

预期：`permissions.screenRecording` 从 `missing` 变为 `granted`。

## 4. 验证确实经过 XPC 服务

运行：

```bash
shot doctor --pretty
```

预期 JSON 中有：

- `service.endpoint = "xpc"`
- `service.name = "com.shshaoxia.ShotCli.CLIService"`

可选（深度验证，查看系统日志）：

```bash
/usr/bin/log show --last 2m --style compact \
  --predicate 'process CONTAINS "ShotCliXPCService" OR eventMessage CONTAINS "com.shshaoxia.ShotCli.CLIService"' | tail -n 120
```

你应看到 launchd 按需拉起 `ShotCliXPCService` 的记录。
