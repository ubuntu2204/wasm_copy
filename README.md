# wasm_copy

> 一个基于 Flutter WebAssembly 的图片复制/分享示例应用。把打包进 app 的图片
> 一键复制到剪贴板或通过系统分享面板发送到微信，内置三级降级策略与完整的
> 浏览器能力诊断 UI。

[![Flutter](https://img.shields.io/badge/Flutter-3.44-stable?logo=flutter)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.12-blue?logo=dart)](https://dart.dev)
[![WASM](https://img.shields.io/badge/Flutter%20Web-WASM-orange)](https://docs.flutter.dev/platform-integration/web/wasm)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

---

## 目录

- [功能演示](#功能演示)
- [背景与动机](#背景与动机)
- [特性](#特性)
- [技术栈](#技术栈)
- [快速开始](#快速开始)
- [运行方式](#运行方式)
- [部署到生产](#部署到生产)
- [浏览器兼容性](#浏览器兼容性)
- [降级策略工作原理](#降级策略工作原理)
- [常见问题排查](#常见问题排查)
- [项目结构](#项目结构)
- [开发指南](#开发指南)
- [贡献](#贡献)
- [许可证](#许可证)

---

## 功能演示

| 桌面 Chrome | 手机 Chrome |
| --- | --- |
| 点击按钮 → 图片写入剪贴板 → 微信对话框粘贴 | 点击按钮 → 弹出系统分享面板 → 选择微信发送 |

> 应用截图占位：可放置 `docs/screenshot-desktop.png` 与 `docs/screenshot-mobile.png`。

## 背景与动机

在 Web 端把一张图片「发到微信」看起来简单，实际上要跨过几道坎：

1. **Clipboard API 仅支持 `image/png`** —— 用户提供的 JPG 必须先转码。
2. **Clipboard API 仅在安全上下文可用** —— HTTPS 或 localhost，局域网 IP 访问会
   直接抛 `ReferenceError: ClipboardItem is not defined`。
3. **移动端剪贴板写入受限** —— 部分安卓浏览器不允许写图片到剪贴板，但支持
   `navigator.share` 系统分享面板。
4. **WASM 兼容性** —— Flutter WebAssembly 编译产物对 `dart:html` 不友好，必须
   改用 `package:web` + `dart:js_interop`。

本项目演示如何把这些问题一次性解决：用 `package:image` 做 JPG→PNG 转码，用
`package:web` 调用浏览器 API，加上三级降级策略与可视化诊断面板。

## 特性

- ✅ **一键复制/分享** —— 桌面走剪贴板，手机走系统分享，全平台兜底走下载。
- ✅ **WASM 编译** —— 使用 `package:web`，完全兼容 Flutter WebAssembly 产物。
- ✅ **三级降级** —— Clipboard API → Web Share API → 下载文件，自动选择。
- ✅ **能力诊断面板** —— AppBar 虫子图标，一键查看当前浏览器的各项能力与失败
  原因，方便提 issue 时附上环境信息。
- ✅ **中文错误提示** —— 不再是冷冰冰的 `ReferenceError`，而是直接告诉用户
  「不是安全上下文，请用 HTTPS 或 localhost」。
- ✅ **零后端** —— 纯前端实现，可部署到任意静态托管。

## 技术栈

| 层 | 技术 | 用途 |
| --- | --- | --- |
| 框架 | [Flutter 3.44](https://flutter.dev) (stable) | UI 框架 |
| 编译目标 | Flutter Web **WASM** | 浏览器中运行 Dart |
| 浏览器互操作 | [`package:web` 1.1](https://pub.dev/packages/web) | 调用 Clipboard / Web Share API |
| 图像处理 | [`package:image` 4.9](https://pub.dev/packages/image) | JPG → PNG 转码 |
| JS 互操作工具 | `dart:js_interop` + `dart:js_interop_unsafe` | 安全的运行时能力检测 |

## 快速开始

### 环境要求

- Flutter ≥ 3.44（stable channel）
- Dart ≥ 3.12
- 现代浏览器（Chrome / Edge ≥ 109，Safari ≥ 16.4）

### 安装与运行

```bash
# 1. 克隆仓库
git clone <your-repo-url>
cd wasm_copy

# 2. 拉取依赖
flutter pub get

# 3. 以 WASM 模式运行（推荐）
flutter run -d chrome --wasm

# 或不指定 --wasm，让 Flutter 自动选择
flutter run -d chrome
```

应用启动后会在 `http://localhost:xxxxx` 打开，**localhost 是安全上下文**，
所以剪贴板 API 可以直接使用。

## 运行方式

### 本机调试

```bash
flutter run -d chrome --web-port 8080
```

固定端口方便后续 adb reverse。

### 让安卓手机访问本机调试服务器

由于 Clipboard API 要求安全上下文，手机不能直接通过 `http://192.168.x.x:8080`
访问。推荐用 **adb reverse** 把手机的 localhost 端口映射到电脑：

```bash
# 1. 手机用 USB 连接电脑，开启 USB 调试
# 2. 反向端口映射
adb reverse tcp:8080 tcp:8080

# 3. 电脑上启动 flutter run
flutter run -d chrome --web-port 8080

# 4. 手机 Chrome 访问
#    http://localhost:8080
```

此时手机访问的也是 `localhost`，满足安全上下文要求。

## 部署到生产

### 构建

```bash
flutter build web --wasm
# 产物在 build/web/
```

### 部署到静态托管

任何能托管静态文件的服务都可以，**只要走 HTTPS**：

- **GitHub Pages** —— 仓库 Settings → Pages → 选 `build/web` 目录
- **Vercel / Netlify / Cloudflare Pages** —— 连接 Git 仓库，构建命令
  `flutter build web --wasm`，输出目录 `build/web`
- **Nginx / Caddy** —— 把 `build/web` 上传到服务器，配置 HTTPS 证书

> ⚠️ 必须是 HTTPS。HTTPS 是 Clipboard API 的硬性要求。

### 本地预览构建产物

```bash
cd build/web
python3 -m http.server 8080
# 访问 http://localhost:8080
```

## 浏览器兼容性

| 浏览器 | 剪贴板写入 | 系统分享 | 下载兜底 |
| --- | :---: | :---: | :---: |
| Chrome (桌面) ≥ 109 | ✅ | ❌（无 share UI） | ✅ |
| Edge (桌面) ≥ 109 | ✅ | ❌ | ✅ |
| Safari (macOS) ≥ 16.4 | ✅ | ✅ | ✅ |
| Chrome (安卓) ≥ 109 | ⚠️ 受限 | ✅ | ✅ |
| Safari (iOS) ≥ 16.4 | ⚠️ 受限 | ✅ | ✅ |
| 微信内置浏览器 | ❌ | ⚠️ | ✅ |
| 旧版浏览器 | ❌ | ❌ | ✅ |

> 「⚠️ 受限」表示在该环境下剪贴板写入可能因权限/安全策略失败，应用会自动
> 降级到下一级策略。

## 降级策略工作原理

```
用户点击「复制 / 分享图片」
        │
        ▼
[1] 诊断 Clipboard API
    ├─ 是安全上下文？
    ├─ navigator.clipboard 存在？
    ├─ ClipboardItem 构造器存在？
    └─ ClipboardItem.supports('image/png')？
        │
        ├─ 全部通过 → 尝试 clipboard.write
        │              ├─ 成功 → SnackBar 提示「已复制」，return
        │              └─ 失败 → 继续 [2]
        └─ 任一项不通过 → 继续 [2]
        │
        ▼
[2] Web Share API
    ├─ navigator.share / canShare 存在？
    └─ canShare({files: [png]}) 返回 true？
        ├─ 是 → 调用 navigator.share
        │       ├─ 成功 → SnackBar 提示「已分享」，return
        │       └─ 失败 → 继续 [3]
        └─ 否 → 继续 [3]
        │
        ▼
[3] 下载兜底
    创建 <a download> 触发浏览器下载
    SnackBar 提示「已触发下载」
```

实现见 `lib/main.dart:_shareOrCopy`。

## 常见问题排查

### Q1. 安卓 Chrome 报 `ReferenceError: ClipboardItem is not defined`

**原因**：访问的是非安全上下文（如 `http://192.168.x.x:8080`）。

**解决**：
- 推荐：用 `adb reverse tcp:8080 tcp:8080` 让手机通过 `localhost` 访问
- 或：部署到 HTTPS 静态托管
- 或：用 ngrok / cloudflared 做 HTTPS 隧道

### Q2. 桌面 Chrome 复制成功，但微信对话框里粘贴不出来

**原因**：微信桌面版的剪贴板支持有限，部分版本不支持粘贴 PNG。

**解决**：
- 改用 Web Share API（系统分享面板）
- 或直接走下载，再把图片拖进微信

### Q3. `flutter run -d chrome --wasm` 报 `FlutterLoader could not find a build compatible with configuration and environment`

**原因**：旧版构建产物里 `flutter_bootstrap.js` 的 `builds` 数组只包含 wasm
构建，浏览器不支持 WasmGC 时无降级。

**解决**：
```bash
flutter clean
flutter pub get
flutter run -d chrome --wasm
```

`flutter build web --wasm`（Flutter ≥ 3.22）会同时生成 wasm 与 dart2js 两套
构建，自动降级。

### Q4. 应用右上角的虫子图标是干什么的？

点击它会弹出一个**能力诊断面板**，列出当前浏览器的：
- URL / UA / isSecureContext
- Clipboard API 各项能力（navigator.clipboard / ClipboardItem / supports）
- Web Share API 各项能力（share / canShare）
- 最终诊断结论

提 issue 时请把这份诊断信息一并贴上。

### Q5. 我可以把这个集成到现有 Flutter Web 项目吗？

可以。核心逻辑在 `lib/main.dart` 的以下方法中，直接复制即可：
- `_loadPngBytes()` —— JPG → PNG 转码
- `_diagnoseClipboard()` —— 能力诊断
- `_shareOrCopy()` —— 三级降级主流程
- `_canShareFile()` / `_downloadPng()` —— 辅助方法

依赖只需在 `pubspec.yaml` 中添加：
```yaml
dependencies:
  web: ^1.1.1
  image: ^4.9.1
```

## 项目结构

```
wasm_copy/
├── LICENSE                         # MIT 许可证
├── README.md                       # 本文件
├── pubspec.yaml                    # 依赖与资源声明
├── analysis_options.yaml           # Dart 分析器配置
├── image/
│   └── DA7D255646C02B32A7EF54A2798EF383.jpg   # 示例图片
├── lib/
│   └── main.dart                   # 应用入口与全部逻辑
├── test/
│   └── widget_test.dart            # 冒烟测试
├── web/
│   ├── index.html                  # Web 入口 HTML
│   ├── manifest.json               # PWA manifest
│   └── icons/                      # PWA 图标
└── android/ ios/ macos/ windows/ linux/   # 各平台壳工程（未使用）
```

> 本项目只针对 Web 平台，其它平台的目录是 Flutter 模板自动生成的，未做任何
> 适配。如需移动端原生剪贴板能力，建议使用
> [`super_clipboard`](https://pub.dev/packages/super_clipboard)。

## 开发指南

### 代码风格

项目使用 [`flutter_lints`](https://pub.dev/packages/flutter_lints) 的推荐规则。
提交前请运行：

```bash
flutter analyze   # 应该 0 issues
flutter test      # 冒烟测试通过
```

### 替换示例图片

1. 把你的图片放到 `image/` 目录
2. 修改 `lib/main.dart` 中的 `_assetPath` 常量
3. 修改 `pubspec.yaml` 中 `flutter.assets` 的路径
4. 如果图片本身就是 PNG，可以删掉 `package:image` 的转码逻辑，直接使用原字节

### 添加自定义分享渠道

`navigator.share` 会调用系统原生的分享面板，分享目标由系统决定（微信、QQ、
微博、邮件等）。如果需要直接分享到某个特定应用，需要使用对应平台的 URL
Scheme，例如微信：`weixin://share?...`（受限且不稳定，不推荐）。

## 贡献

欢迎提 issue 与 PR！

提 issue 时请附上：
1. 浏览器与版本（在应用里访问 `chrome://version` 或点应用右上角虫子图标）
2. 复现步骤
3. 期望行为 vs 实际行为
4. 应用诊断面板的完整输出（虫子图标 → 复制粘贴）

## 许可证

[MIT](./LICENSE)
