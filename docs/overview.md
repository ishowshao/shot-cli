# Shot CLI — macOS 14+ 非交互式截图工具（命令行规范）

> 目标：提供一个 **非交互式** 的截图/枚举工具，可在脚本、CI、自动化流程中使用。  
> 实现建议：`ShotCli.app`（原生权限与服务） + `shot`（CLI）通过 XPC 通讯；CLI 不直接触发 UI。

> 验证当前 XPC 实现是否可用：见 `docs/xpc-verification.md`。

---

## 1. 设计目标

- **非交互式**：不弹出选区/窗口选择 UI，不依赖鼠标点击。
- **可枚举**：能列出显示器信息、窗口信息，供后续拼参数截图。
- **脚本友好**：
  - 默认输出 JSON（或提供 `--json`）
  - 退出码稳定，便于 shell 判断
  - 错误输出结构化（JSON + 错误码）
- **坐标统一**：对外统一 **全局桌面坐标系 + 像素(px)**，支持多显示器拼接场景。

---

## 2. 安装与运行形态（建议）

- `ShotCli.app`：负责引导/检查权限（Screen Recording），并提供本地服务（XPC 推荐）。
- `shot`：CLI 可执行文件。推荐放在 `ShotCli.app/Contents/MacOS/shot` 并提供软链到 PATH：
  - `/usr/local/bin/shot` 或 `~/.local/bin/shot`

建议在 GUI 中提供 `Install "shot" Command` 一键安装（默认 `~/.local/bin`，无需管理员权限）。

CLI 行为建议：
- 如服务未运行，CLI 尝试启动/唤醒服务（或返回 `10`，并给出 hint）。
- 权限不足时，CLI 返回 `11`，提示用户打开 `ShotCli.app` 完成授权。

---

## 3. 坐标系与单位规范（关键）

### 3.1 坐标系
- 使用 **全局桌面坐标系**（多显示器拼接后的空间）。
- 原点：**全局空间左上角**（建议与 macOS 常见窗口/显示器 bounds 习惯对齐）。
- 允许出现负坐标（当某显示器在主屏左侧/上方）。

### 3.2 单位
- 对外统一：**像素(px)**。
- Retina/缩放：显示器会包含 `scale`（例如 2.0），但 rect 参数永远以 px 表达。

### 3.3 Rect 格式
- `x,y,w,h`（逗号分隔）
- 所有值为整数（向下取整/四舍五入由实现决定，但建议在输出中明确）。

---

## 4. 命令总览

```bash
shot --help
shot version
shot doctor

shot displays [--json] [--pretty]
shot windows [--json] [--pretty] [--onscreen|--all] [--app <bundleId|name>] [--frontmost]

shot capture ( --display <displayId> | --window <windowId> )
            [--rect <x,y,w,h>] [--crop <x,y,w,h>]
            [--format png|jpg|heic] [--quality 0-100]
            [--out <path>|--out-dir <dir>] [--name <template>]
            [--stdout base64|raw] [--meta]
```

---

## 5. `shot doctor` — 权限/服务自检

用于 CI/脚本在执行前确认环境。

### 用法

```bash
shot doctor [--json] [--pretty]
```

### 输出（JSON）

```json
{
  "ok": false,
  "service": { "running": true, "endpoint": "xpc" },
  "permissions": {
    "screenRecording": "missing",
    "accessibility": "notRequested"
  },
  "hints": [
    "Open ShotCli.app once and enable Screen Recording in System Settings > Privacy & Security."
  ]
}
```

### 退出码

* `0`：OK
* `10`：服务不可用/无法连接
* `11`：缺少 Screen Recording 权限（关键）
* `12`：缺少 Accessibility 权限（仅当使用 `--frontmost` / 强依赖标题等能力时）

---

## 6. `shot displays` — 列出显示器

### 用法

```bash
shot displays [--json] [--pretty]
```

### 输出字段建议

```json
{
  "displays": [
    {
      "displayId": 69733248,
      "name": "Built-in Retina Display",
      "isMain": true,
      "framePx": { "x": 0, "y": 0, "w": 3024, "h": 1964 },
      "scale": 2,
      "rotation": 0
    }
  ]
}
```

字段说明：

* `displayId`：用于后续 `shot capture --display <id>`
* `framePx`：该显示器在全局桌面坐标系中的像素矩形
* `scale`：缩放因子（如 1、2），用于调试/元信息展示

---

## 7. `shot windows` — 列出窗口

### 用法

```bash
shot windows [--json] [--pretty] [--onscreen|--all] [--app <bundleId|name>] [--frontmost]
```

### 参数语义

* `--onscreen`：只返回当前在屏幕上的窗口（默认）
* `--all`：尽可能包含不可见/最小化/隐藏窗口（是否可获得取决于系统）
* `--app`：按 app 过滤（bundleId 或 appName）
* `--frontmost`：只返回前台应用/最前窗口（可选实现；如依赖 Accessibility 可在 doctor 中提示）

### 输出字段建议

```json
{
  "windows": [
    {
      "windowId": 12345,
      "appName": "Safari",
      "bundleId": "com.apple.Safari",
      "title": "docs",
      "isOnScreen": true,
      "framePx": { "x": 120, "y": 80, "w": 1400, "h": 900 },
      "displayHint": 69733248
    }
  ]
}
```

注意事项：

* `title` 可能为空或不稳定（系统限制）。如强依赖标题，应提供降级策略或引导开启 Accessibility。
* `framePx` 为全局像素坐标，用于拼接 `--rect`。

---

## 8. `shot capture` — 非交互截图

### 8.1 按显示器截全屏

```bash
shot capture --display 69733248 --out /tmp/full.png
```

### 8.2 按显示器截指定区域（全局 rect）

```bash
shot capture --display 69733248 --rect 100,200,800,600 --out /tmp/area.png
```

> `--rect` 语义：全局桌面坐标系中的像素区域。实现时应先映射到指定 display 的局部区域并裁剪。

### 8.3 按 windowId 截窗口

```bash
shot capture --window 12345 --out /tmp/win.png
```

### 8.4 输出到 stdout（便于管道）

```bash
# base64 输出（JSON 内或纯输出二选一，建议：stdout=base64 时只输出 base64 内容）
shot capture --window 12345 --stdout base64

# raw 二进制输出（适合重定向）
shot capture --window 12345 --stdout raw > /tmp/win.png
```

### 8.5 输出命名模板（推荐）

```bash
shot capture --window 12345 --out-dir ~/Desktop --name "{date}_{app}_{id}.{ext}"
```

模板变量建议：

* `{date}`：`YYYYMMDD_HHMMSS`
* `{app}`：appName（需做文件名安全化）
* `{id}`：windowId / displayId
* `{ext}`：由 `--format` 推导（png/jpg/heic）

---

## 9. 输出格式与错误格式（统一）

### 9.1 成功输出（默认 JSON）

```json
{
  "ok": true,
  "output": {
    "path": "/tmp/win.png",
    "format": "png",
    "bytes": 381244
  },
  "source": {
    "type": "window",
    "windowId": 12345,
    "appName": "Safari",
    "title": "docs"
  },
  "image": {
    "width": 1400,
    "height": 900,
    "scale": 2
  },
  "timingMs": 38
}
```

### 9.2 失败输出（JSON）

```json
{
  "ok": false,
  "error": {
    "code": 11,
    "name": "ERR_PERMISSION_SCREEN_RECORDING",
    "message": "Screen Recording permission is required.",
    "hint": "Open ShotCli.app and enable Screen Recording in System Settings > Privacy & Security."
  }
}
```

### 9.3 pretty 输出

* `--pretty`：JSON 格式化缩进（便于人工阅读）

---

## 10. 退出码规范（建议固定）

* `0`：成功
* `2`：参数错误（缺参数/冲突/rect 格式非法）
* `10`：服务不可用（XPC 连接失败/ShotCli.app 未安装或未运行）
* `11`：缺少 Screen Recording 权限
* `12`：缺少 Accessibility 权限（仅当请求相关能力）
* `13`：目标不存在（windowId/displayId 找不到）
* `14`：捕获失败（系统拒绝/DRM/窗口不可捕获/内部错误）
* `15`：输出失败（路径不可写/磁盘满）
* `130`：用户取消（保留；非交互模式通常不会发生）

---

## 11. 互操作示例（“先列再截”）

### 11.1 按 app 找窗口并截图

```bash
# 找 Safari 的窗口 ID（示例使用 jq）
shot windows --app com.apple.Safari --json | jq '.windows[0].windowId'

# 截这个窗口
shot capture --window 12345 --out /tmp/safari.png
```

### 11.2 找主显示器并截某块区域

```bash
# 主显示器 frame
shot displays --json | jq '.displays[] | select(.isMain) | .framePx'

# 截主屏某块区域
shot capture --display 69733248 --rect 100,200,800,600 --out /tmp/roi.png
```

---

## 12. 已知限制与注意事项

* **DRM/受保护内容**：受保护的视频/窗口可能截到黑屏，这是系统策略。
* **窗口标题不稳定**：部分窗口拿不到 title，或 title 为空；如强需求，可能需要 Accessibility 权限辅助。
* **多显示器坐标**：全局坐标可能为负值；脚本拼接 rect 时需使用 `displays.framePx` 做基准。
* **最小化/隐藏窗口**：是否可枚举/可捕获依赖系统；建议在输出中用 `isOnScreen` 明确状态。

---

## 13. 兼容性

* 最低系统：**macOS 14+**
* 推荐截图/枚举后端：**ScreenCaptureKit**
* 建议通讯方式：**XPC（本地进程间通讯）**
