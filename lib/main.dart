/// wasm_copy —— Flutter WebAssembly 图片复制/分享示例。
///
/// 本文件是应用的全部 UI 与业务逻辑入口。核心能力是：把打包进 app 的图片
/// 资源（JPG）通过浏览器 API 发送出去，按以下三级降级策略选择最合适的途径：
///
/// 1. **Clipboard API**（`navigator.clipboard.write`）—— 桌面 Chrome / Edge /
///    Safari 优先走这条。把图片写入系统剪贴板，用户可在微信对话框里直接粘贴。
/// 2. **Web Share API**（`navigator.share({files})`）—— 移动端 Chrome / Safari
///    优先走这条。弹出系统分享面板，可直接选择微信发送。
/// 3. **下载文件** —— 上述两条都不通时，触发浏览器下载，用户手动发送。
///
/// 关键约束：浏览器的 Clipboard API 仅支持 `image/png`，因此 JPG 必须先转码。
/// 此外 Clipboard API 仅在**安全上下文**（HTTPS 或 localhost）下可用，本应用
/// 在调用前会做完整的能力诊断并给出可读的中文错误提示。
///
/// 项目依赖：`package:web`（WASM 兼容的浏览器绑定）、`package:image`（纯 Dart
/// 图像编解码）。因此本文件**只能在 Web 平台编译**，不能在 Flutter VM 测试
/// 环境中加载。
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:web/web.dart' as web;

void main() {
  runApp(const MyApp());
}

/// 顶层 MaterialApp，配置主题与首页。
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '复制图片',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(title: '复制图片到剪贴板'),
    );
  }
}

/// 主页面，承载图片预览与「复制 / 分享」按钮。
class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  /// 被复制/分享的图片资源路径，对应 pubspec.yaml 中声明的 asset。
  static const _assetPath = 'image/DA7D255646C02B32A7EF54A2798EF383.jpg';

  /// 标识当前是否正在执行复制/分享，用于禁用按钮并显示 loading。
  bool _busy = false;

  /// 与图片一起复制/分享的文字内容，用户可自行编辑。
  final TextEditingController _textController = TextEditingController(
    text: '来自 wasm_copy 的图片',
  );

  /// 预加载并转码好的 PNG 字节缓存。
  ///
  /// 关键用途：Android Chrome 调用 `navigator.share()` 必须在用户手势的
  /// **同步上下文**中执行，从点击到 share() 之间不能有任何 `await`。
  /// 否则抛 `NotAllowedError: Must be handling a user gesture to perform
  /// a share request.`。而 [_loadPngBytes] 包含 asset 加载 + JPG 解码 +
  /// PNG 编码，全是耗时操作，必须放在 [initState] 中提前完成，点击按钮
  /// 时直接取用本缓存，保证 share() 调用前无 await。
  Uint8List? _cachedPngBytes;

  @override
  void initState() {
    super.initState();
    _preloadPngBytes();
  }

  /// 后台预加载 PNG 字节，不阻塞 UI；完成后触发一次重建以更新按钮状态。
  Future<void> _preloadPngBytes() async {
    try {
      _cachedPngBytes = await _loadPngBytes();
    } catch (_) {
      // 忽略：用户点击按钮时会再次尝试加载并报错。
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  /// 加载 [_assetPath] 指向的 JPG 资源，解码后重新编码为 PNG 字节。
  ///
  /// 浏览器 Clipboard API 仅支持 `image/png`，所以必须做这次转码。
  /// 抛出 [StateError] 表示 JPG 数据无法解码。
  Future<Uint8List> _loadPngBytes() async {
    final byteData = await rootBundle.load(_assetPath);
    final jpgBytes = byteData.buffer.asUint8List(
      byteData.offsetInBytes,
      byteData.lengthInBytes,
    );
    final decoded = img.decodeImage(jpgBytes);
    if (decoded == null) {
      throw StateError('图片解码失败（JPG 数据损坏或格式不支持）');
    }
    return Uint8List.fromList(img.encodePng(decoded));
  }

  /// 判断全局对象 [name] 是否存在（如 `ClipboardItem`、`navigator.share`）。
  ///
  /// 用 `dart:js_interop_unsafe` 的 `has` 在 [globalContext] 上做 `in` 检查，
  /// 避免直接访问未定义标识符导致的 ReferenceError。
  bool _hasGlobal(String name) => globalContext.has(name);

  /// 通过 UA 粗略判断是否为移动端浏览器。
  ///
  /// 用于在「复制图片+文字」流程中分流：手机 Chrome 的 Clipboard API 写入
  /// 双类型时，Android 系统剪贴板与微信客户端协同存在缺陷，常见现象是
  /// 粘贴时只剩文字、图片丢失。因此在移动端直接跳过 Clipboard API，改走
  /// Web Share API（系统分享面板），这是手机上同时发图+文字最可靠的路径。
  ///
  /// **UA 伪装兜底**：夸克浏览器等内置「浏览器 UA 标识」切换功能，可一键
  /// 把 UA 改成「Chrome 桌面版」。此时 UA 不再含 android/iphone，但设备
  /// 本身仍是手机。若仅靠 UA 判断，会错误走桌面分支的 Clipboard API 双
  /// 类型写入——Android 上图片被静默丢弃，只剩文字（即用户反馈的现象）。
  /// 因此在 UA 检测之外，再用「主输入方式」做一层兜底：设备有触摸
  /// （coarse pointer）且没有鼠标（fine pointer）时，也判定为移动端。
  ///   • 纯触屏手机 → coarse=yes, fine=no → 命中
  ///   • 触屏笔记本 → coarse=yes, fine=yes → 不命中（有鼠标）
  ///   • 桌面台式机 → coarse=no,  fine=yes → 不命中
  bool _isMobile() {
    final ua = web.window.navigator.userAgent.toLowerCase();
    if (ua.contains('android') ||
        ua.contains('iphone') ||
        ua.contains('ipad') ||
        ua.contains('ipod')) {
      return true;
    }
    try {
      if (web.window
          .matchMedia('(any-pointer: coarse) and (not any-pointer: fine)')
          .matches) {
        return true;
      }
    } catch (_) {
      // matchMedia 不可用或不支持该语法，忽略。
    }
    return false;
  }

  /// 诊断 Clipboard API 是否可用，返回 `null` 表示就绪，否则返回中文错误说明。
  ///
  /// 检查顺序与失败原因：
  /// 1. **安全上下文** —— Clipboard API 仅在 HTTPS 或 localhost 下可用。
  ///    这是手机用局域网 IP 访问时最常踩的坑。
  /// 2. **navigator.clipboard** —— 浏览器可能整体禁用剪贴板 API。
  /// 3. **ClipboardItem 构造器** —— 旧浏览器不支持，需要升级。
  /// 4. **ClipboardItem.supports('image/png')** —— 部分浏览器只支持 text。
  String? _diagnoseClipboard() {
    // 1. 安全上下文检查（HTTPS 或 localhost）。
    if (!web.window.isSecureContext) {
      final href = web.window.location.href;
      return '当前页面不是「安全上下文」。\n'
          '地址: $href\n'
          '浏览器要求 Clipboard API 必须在 HTTPS 或 localhost 下使用。\n'
          '\n'
          '解决方法（任选其一）:\n'
          ' • 安卓: 用 USB 调试 + adb reverse tcp:8080 tcp:8080，\n'
          '   然后手机访问 http://localhost:8080\n'
          ' • 用 ngrok / cloudflared 等做 HTTPS 隧道\n'
          ' • 部署到任意 HTTPS 静态托管（GitHub Pages / Vercel 等）';
    }

    // 2. navigator.clipboard 存在性。
    final nav = web.window.navigator as JSObject;
    if (!nav.has('clipboard')) {
      return 'navigator.clipboard 不存在。\n'
          '浏览器禁用了剪贴板 API，请检查权限设置或换用最新版 Chrome/Edge。';
    }

    // 3. ClipboardItem 构造器存在性。
    if (!_hasGlobal('ClipboardItem')) {
      return '当前浏览器不支持 ClipboardItem 构造器。\n'
          '请升级 Chrome (≥109) / Edge (≥109) / Safari (≥16.4)，\n'
          '或改用下面的「分享」按钮（系统分享面板）。';
    }

    // 4. ClipboardItem 是否支持 image/png。
    try {
      if (!web.ClipboardItem.supports('image/png')) {
        return '当前浏览器的 ClipboardItem 不支持 image/png 类型。';
      }
    } catch (e) {
      return 'ClipboardItem.supports 调用异常: $e';
    }

    return null; // 一切就绪
  }

  /// 把文字复制到剪贴板，依次尝试多种方法。
  ///
  /// 调用顺序：
  /// 1. **异步 Clipboard API** (`navigator.clipboard.writeText`) —— 标准、
  ///    跨平台，但需要 `clipboard-write` 权限。夸克浏览器等即使在安全
  ///    上下文下也会拒绝权限，抛 `NotAllowedError: Write permission denied`。
  /// 2. **`document.execCommand('copy')` + 隐藏 textarea** —— 旧版 API，
  ///    权限模型不同，只需在用户手势上下文中调用即可。在夸克等拒绝
  ///    Clipboard API 的浏览器上仍可工作。
  ///
  /// 返回 `true` 表示任一方法成功。
  Future<bool> _copyText(String text) async {
    // 方法 1：异步 Clipboard API
    try {
      await web.window.navigator.clipboard.writeText(text).toDart;
      return true;
    } catch (_) {
      // 夸克等浏览器在这里抛 NotAllowedError，继续降级
    }

    // 方法 2：execCommand('copy') 兜底
    return _legacyCopyText(text);
  }

  /// 用隐藏 textarea + `document.execCommand('copy')` 复制文字。
  ///
  /// 这是 Clipboard API 普及前的经典方案。权限模型只要求用户手势上下文，
  /// 不需要显式 `clipboard-write` 权限，因此在夸克等浏览器上仍可工作。
  ///
  /// 注意：必须在用户手势上下文中调用，否则 `execCommand` 会返回
  /// `false` 而不报错。`await navigator.clipboard.writeText` 失败后的
  /// 微任务 continuation 中仍处于 transient activation 窗口（5 秒），
  /// 可以正常工作。
  bool _legacyCopyText(String text) {
    final doc = web.document;
    final body = doc.body;
    if (body == null) return false;
    final textarea = doc.createElement('textarea') as web.HTMLTextAreaElement;
    try {
      textarea.value = text;
      // readonly 避免在移动端弹出软键盘
      textarea.setAttribute('readonly', '');
      final style = textarea.style;
      style.position = 'fixed';
      style.left = '-9999px';
      style.top = '0';
      // 防止 iOS Safari 自动缩放
      style.fontSize = '16px';
      body.appendChild(textarea);
      textarea.focus();
      textarea.select();
      // 部分移动浏览器（特别是 iOS）需要 setSelectionRange 才能真正选中
      textarea.setSelectionRange(0, text.length);
      return doc.execCommand('copy');
    } catch (_) {
      return false;
    } finally {
      textarea.remove();
    }
  }

  /// 用户点击主按钮的入口，按三级降级策略执行：剪贴板 → 系统分享 → 下载。
  ///
  /// 任何一级成功后立即 `return`；失败则继续尝试下一级，并用 SnackBar 实时
  /// 反馈进度。最终仍未成功时弹窗显示错误详情（含调用栈与环境信息）。
  ///
  /// **移动端注意**：Android Chrome 调用 `navigator.share()` 必须在用户
  /// 手势同步上下文中，从点击到 share() 之间不能有任何 `await`。因此
  /// 移动端必须使用 [_cachedPngBytes] 预缓存，不能在 share 之前 await
  /// [_loadPngBytes]。
  Future<void> _shareOrCopy() async {
    setState(() => _busy = true);
    try {
      // 移动端：使用预缓存避免丢失 user gesture；桌面端可宽松。
      final pngBytes = _isMobile()
          ? (_cachedPngBytes ?? await _loadPngBytes())
          : await _loadPngBytes();

      // === 1. 优先：剪贴板写入 ===
      final issue = _diagnoseClipboard();
      if (issue == null) {
        try {
          final blob = web.Blob(
            [pngBytes.toJS].toJS,
            web.BlobPropertyBag(type: 'image/png'),
          );
          final item = web.ClipboardItem(
            {'image/png': blob}.jsify() as JSObject,
          );
          await web.window.navigator.clipboard.write([item].toJS).toDart;
          _toast('✅ 已复制到剪贴板，可在微信对话框直接粘贴');
          return;
        } catch (e) {
          // 诊断通过但运行时失败（如用户拒绝权限），降级到分享。
          _toast('剪贴板写入失败（$e），尝试使用系统分享…',
              duration: const Duration(seconds: 3));
        }
      } else {
        // 不满足剪贴板前置条件，直接降级。
        _toast('剪贴板不可用，切换到分享模式…', duration: const Duration(seconds: 2));
      }

      // === 2. 降级：Web Share API（系统分享面板，可直接分享到微信）===
      final nav = web.window.navigator as JSObject;
      final hasShare = nav.has('share') && nav.has('canShare');
      if (hasShare && _canShareFile(pngBytes)) {
        final file = web.File(
          [pngBytes.toJS].toJS,
          'image.png',
          web.FilePropertyBag(type: 'image/png'),
        );
        final shareData = web.ShareData(
          title: '分享图片',
          text: '来自 wasm_copy 的图片',
          files: [file].toJS,
        );
        final result = await _callShare(shareData);
        if (result == 'success') {
          _toast('✅ 已通过系统分享发送');
          return;
        }
        if (result == 'cancelled') {
          return; // 用户主动取消，不再走兜底
        }
        // failed：浏览器未拉起分享面板（夸克等），继续走下载兜底。
        _toast('系统分享未拉起，尝试下载…', duration: const Duration(seconds: 3));
      }

      // === 3. 兜底：触发浏览器下载 ===
      _downloadPng(pngBytes);
      _toast('已触发下载，请在下载列表中找到 image.png，再手动发送到微信');
    } catch (e, st) {
      _showErrorDialog('分享/复制失败', e, st);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 用户点击「复制图片+文字」按钮的入口。
  ///
  /// 同时把文字和图片发送出去，按设备类型走不同路径：
  ///
  /// **桌面端**（Chrome/Edge/Safari）：
  ///   1. **Clipboard API** —— 单个 [web.ClipboardItem] 同时包含 `text/plain`
  ///      和 `image/png` 两种类型，写入系统剪贴板。微信桌面端粘贴时会取
  ///      图片，文字可粘到纯文本输入框。
  ///   2. 失败则降级：[_copyText] 复制文字 + [_shareImageOnly] 分享图片。
  ///   3. 兜底：[_copyText] 复制文字 + 下载图片；若文字也复制失败，弹窗
  ///      让用户长按手动复制。
  ///
  /// **移动端**（Android/iOS Chrome/Safari）：
  ///   1. **[_copyText] + Web Share API** —— Android Chrome 调用
  ///      `navigator.share({text, files})` 时微信会丢弃 `text` 字段，
  ///      因此改为：先用 [_copyText] 把文字写入剪贴板（多种方法兜底），
  ///      再 `navigator.share({files: [image]})` 只分享图片。
  ///      ⚠️ 不走 Clipboard API 双类型的原因：手机 Chrome 写入双类型
  ///      `ClipboardItem` 时，Android 系统剪贴板与微信客户端协同存在
  ///      缺陷，常见现象是粘贴时只剩文字、图片丢失。
  ///      ⚠️ 必须使用 [_cachedPngBytes] 预缓存：Android Chrome 要求
  ///      `navigator.share()` 在用户手势同步上下文中执行，任何耗时
  ///      `await` 都会丢失手势并抛 `NotAllowedError`。[_copyText] 内部
  ///      只做快速操作（writeText 失败后立即同步 execCommand），仍在
  ///      5 秒 transient activation 窗口内，不影响后续 `share()`。
  ///   2. 兜底：[_copyText] 复制文字 + 下载图片；若文字也复制失败，
  ///      弹窗让用户长按手动复制。
  ///
  /// **夸克浏览器等特殊场景**：夸克暴露 Clipboard API 但运行时拒绝
  /// `writeText` 权限（抛 `NotAllowedError: Write permission denied`），
  /// 同时 `canShare` 误报 `true` 但 `share` 不拉起面板。本方法通过
  /// [_copyText] 内部的 `document.execCommand('copy')` 兜底来绕过
  /// Clipboard API 权限限制；若 execCommand 也失败，弹窗让用户长按
  /// 手动复制文字，至少保证图片能下载。
  Future<void> _copyImageAndText() async {
    setState(() => _busy = true);
    try {
      // 空文本会导致 Blob 为空，部分浏览器拒绝写入，这里兜底为单空格。
      final text = _textController.text.isEmpty ? ' ' : _textController.text;

      if (_isMobile()) {
        // === 移动端 ===
        // 关键：不能在 share() 之前 await 任何耗时操作，否则 Android Chrome
        // 丢失 user gesture context，share() 抛 NotAllowedError。必须使用
        // initState 中预缓存的 PNG 字节。
        final pngBytes = _cachedPngBytes;
        if (pngBytes == null) {
          // 极少数情况：用户在预加载完成前就点击。share 路径必失败，
          // 直接走下载兜底；文字走 [_copyText]（多种方法）。
          final freshBytes = await _loadPngBytes();
          _downloadPng(freshBytes);
          final textCopied = await _copyText(text);
          if (textCopied) {
            _toast('图片预加载未完成，已下载图片；文字已复制');
          } else {
            _toast('图片预加载未完成，已下载图片；文字复制失败');
            _showTextFallbackDialog(text);
          }
          return;
        }

        // 1. 先复制文字（多种方法兜底，应对夸克等拒绝 Clipboard API 的浏览器）
        final textCopied = await _copyText(text);

        // 2. 再分享图片（不带 text，避免被微信丢弃）
        final shareOK = await _shareImageOnly(pngBytes);
        if (shareOK) {
          if (textCopied) {
            _toast('✅ 图片已分享；文字已复制到剪贴板\n可在微信对话框直接粘贴');
          } else {
            _toast('✅ 图片已分享；文字复制失败，请手输');
          }
          return;
        }

        // 3. 分享也失败（夸克等），下载图片；文字若没复制成功，弹窗手动复制
        _downloadPng(pngBytes);
        if (textCopied) {
          _toast('文字已复制到剪贴板，图片已下载');
        } else {
          _toast('图片已下载；文字复制失败，请长按下方文字手动复制',
              duration: const Duration(seconds: 3));
          _showTextFallbackDialog(text);
        }
        return;
      }

      // === 桌面端：优先 Clipboard API 双类型 ===
      // 桌面 Chrome 对 user gesture 要求较宽松，可以直接 await 加载。
      final pngBytes = _cachedPngBytes ?? await _loadPngBytes();
      final issue = _diagnoseClipboard();
      if (issue == null) {
        try {
          final imageBlob = web.Blob(
            [pngBytes.toJS].toJS,
            web.BlobPropertyBag(type: 'image/png'),
          );
          final textBlob = web.Blob(
            [text.toJS].toJS,
            web.BlobPropertyBag(type: 'text/plain'),
          );
          final item = web.ClipboardItem(
            {
              'text/plain': textBlob,
              'image/png': imageBlob,
            }.jsify() as JSObject,
          );
          await web.window.navigator.clipboard.write([item].toJS).toDart;
          _toast('✅ 图片和文字已同时写入剪贴板\n'
              '微信粘贴通常只取图片，发文字请粘到纯文本输入框');
          return;
        } catch (e) {
          _toast('剪贴板写入失败（$e），尝试其他方式…',
              duration: const Duration(seconds: 3));
        }
      } else {
        _toast('剪贴板不可用，切换到分享模式…', duration: const Duration(seconds: 2));
      }

      // 桌面端降级：复制文字 + 分享图片
      final textCopied = await _copyText(text);
      if (await _shareImageOnly(pngBytes)) {
        _toast(textCopied
            ? '✅ 图片已分享；文字已复制到剪贴板'
            : '✅ 图片已分享；文字复制失败');
        return;
      }

      // 兜底：下载图片 + 复制文字
      _downloadPng(pngBytes);
      if (textCopied) {
        _toast('文字已复制到剪贴板，图片已下载');
      } else {
        _toast('图片已下载；文字复制失败，请长按下方文字手动复制',
            duration: const Duration(seconds: 3));
        _showTextFallbackDialog(text);
      }
    } catch (e, st) {
      _showErrorDialog('复制图片和文字失败', e, st);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 调用 `navigator.share({files})` 仅分享图片。
  ///
  /// 返回 `true` 表示分享已完成（成功或用户取消）；`false` 表示当前
  /// 环境不支持，或浏览器未拉起分享面板，调用方应继续走兜底逻辑。
  ///
  /// **设计原因**：Android Chrome 调用 `navigator.share({text, files})`
  /// 同时传文件和文字时，微信的 share intent 只接收图片、丢弃 `text`
  /// 字段，导致文字无法送达。因此本方法只分享图片，文字由调用方通过
  /// [_copyText] 单独写入剪贴板。
  Future<bool> _shareImageOnly(Uint8List pngBytes) async {
    final nav = web.window.navigator as JSObject;
    final hasShare = nav.has('share') && nav.has('canShare');
    if (!hasShare || !_canShareFile(pngBytes)) {
      return false;
    }

    final file = web.File(
      [pngBytes.toJS].toJS,
      'image.png',
      web.FilePropertyBag(type: 'image/png'),
    );
    final shareData = web.ShareData(
      title: '分享图片',
      files: [file].toJS,
    );
    final result = await _callShare(shareData);
    if (result == 'success') {
      return true;
    }
    if (result == 'cancelled') {
      return true; // 用户主动取消，视为已完成
    }
    // failed：浏览器未拉起分享面板（夸克等），调用方继续走兜底。
    _toast('系统分享未拉起，尝试下载…', duration: const Duration(seconds: 3));
    return false;
  }

  /// 调用 `navigator.share(data)` 并对异常做精细化分类。
  ///
  /// 返回值：
  /// - `'success'` —— 分享成功 resolve。
  /// - `'cancelled'` —— 用户在系统分享面板里主动取消（典型表现：share()
  ///   调用数百毫秒甚至数秒后才 reject `AbortError`，期间用户能看到面板）。
  /// - `'failed'` —— 分享未拉起 UI 就直接失败，或抛出非 Abort 异常。调用方
  ///   应继续走兜底。
  ///
  /// **为什么需要时间差判断**：夸克等浏览器对 `navigator.share({files})`
  /// 不真正支持，但 `canShare` 误报 `true`。调用 `share()` 后会立即
  /// reject `AbortError` 而不拉起任何 UI。如果按"AbortError = 用户取消"
  /// 处理，就会错误地停止后续兜底（用户实际现象：提示"已取消分享"，
  /// 但根本没看到分享面板）。这里用 200ms 阈值区分：用户主动取消至少
  /// 有数百毫秒 UI 交互时间，浏览器拒绝拉起通常是同步或几十毫秒内 reject。
  Future<String> _callShare(web.ShareData data) async {
    final sw = Stopwatch()..start();
    try {
      await web.window.navigator.share(data).toDart;
      return 'success';
    } catch (e) {
      final elapsed = sw.elapsedMilliseconds;
      final s = e.toString();
      final isAbort = s.contains('AbortError') || s.contains('abort');
      if (isAbort && elapsed > 200) {
        return 'cancelled';
      }
      return 'failed';
    }
  }

  /// 调用 `navigator.canShare({files})` 验证当前环境是否能分享图片文件。
  ///
  /// 这一步会真实构造一个 [web.File] 并调用 [web.Navigator.canShare]，因此
  /// 任何异常都会被捕获并视为「不可分享」。
  bool _canShareFile(Uint8List pngBytes) {
    try {
      final file = web.File(
        [pngBytes.toJS].toJS,
        'image.png',
        web.FilePropertyBag(type: 'image/png'),
      );
      return web.window.navigator.canShare(
        web.ShareData(files: [file].toJS),
      );
    } catch (_) {
      return false;
    }
  }

  /// 触发浏览器下载 PNG 文件（最后的兜底方案）。
  ///
  /// 通过创建 `Blob` + 临时 `<a download>` 标签模拟点击实现，无需任何后端。
  void _downloadPng(Uint8List pngBytes) {
    final blob = web.Blob(
      [pngBytes.toJS].toJS,
      web.BlobPropertyBag(type: 'image/png'),
    );
    final url = web.URL.createObjectURL(blob);
    final anchor = web.document.createElement('a') as web.HTMLAnchorElement;
    anchor.href = url;
    anchor.download = 'image.png';
    anchor.click();
    web.URL.revokeObjectURL(url);
  }

  /// 显示一个 [SnackBar] 提示。
  void _toast(String msg, {Duration duration = const Duration(seconds: 2)}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: duration),
    );
  }

  /// 弹窗展示文字内容，供用户长按手动复制。
  ///
  /// 当所有自动复制方案都失败时（如夸克浏览器禁用 `clipboard-write`
  /// 权限且 `execCommand('copy')` 也被禁用），这是最后的兜底。图片仍
  /// 通过下载方式给到用户，文字至少能在对话框里被选中复制。
  void _showTextFallbackDialog(String text) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('请手动复制文字'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('自动复制到剪贴板失败。请长按下方文字，选择「复制」：'),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                text,
                style: const TextStyle(fontSize: 15),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 弹窗展示失败详情：错误类型、消息、调用栈，以及关键环境信息。
  ///
  /// 环境信息包括 URL、是否安全上下文、UA、是否支持 ClipboardItem / share，
  /// 方便用户在提 issue 时一键复制粘贴。
  void _showErrorDialog(String title, Object e, StackTrace st) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('错误类型: ${e.runtimeType}'),
              const SizedBox(height: 8),
              Text('错误信息: $e'),
              const SizedBox(height: 8),
              Text('调用栈:\n$st',
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 12)),
              const SizedBox(height: 12),
              const Text(
                '环境信息',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(
                ' • URL: ${web.window.location.href}\n'
                ' • 安全上下文: ${web.window.isSecureContext}\n'
                ' • UA: ${web.window.navigator.userAgent}\n'
                ' • ClipboardItem: ${_hasGlobal("ClipboardItem")}\n'
                ' • navigator.share: '
                    '${(web.window.navigator as JSObject).has("share")}',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 弹窗展示当前浏览器的能力诊断报告，方便用户排查问题。
  ///
  /// 报告内容包括：URL / UA / isSecureContext，Clipboard API 与 Web Share API
  /// 的逐项能力检测结果，以及 [_diagnoseClipboard] 给出的最终结论。
  Future<void> _showDiagnostics() async {
    final nav = web.window.navigator as JSObject;
    final buf = StringBuffer();
    buf.writeln('=== 环境 ===');
    buf.writeln('URL: ${web.window.location.href}');
    buf.writeln('UA: ${web.window.navigator.userAgent}');
    buf.writeln('isSecureContext: ${web.window.isSecureContext}');
    buf.writeln();
    buf.writeln('=== Clipboard API ===');
    buf.writeln(
        'navigator.clipboard: ${(web.window.navigator as JSObject).has("clipboard")}');
    buf.writeln('ClipboardItem: ${_hasGlobal("ClipboardItem")}');
    try {
      buf.writeln(
          'ClipboardItem.supports(image/png): ${web.ClipboardItem.supports("image/png")}');
    } catch (e) {
      buf.writeln('ClipboardItem.supports 抛错: $e');
    }
    buf.writeln();
    buf.writeln('=== Web Share API ===');
    buf.writeln('navigator.share: ${nav.has("share")}');
    buf.writeln('navigator.canShare: ${nav.has("canShare")}');
    buf.writeln();
    buf.writeln('=== 诊断结论 ===');
    final issue = _diagnoseClipboard();
    buf.writeln(issue ?? '剪贴板 API 就绪，可直接复制。');
    buf.writeln();
    buf.writeln('注：即使 API 就绪，部分浏览器（如夸克）仍可能在运行时'
        '拒绝 writeText 权限。\n本应用已加 execCommand+手动复制两层兜底。');

    if (!mounted) return;
    final diagText = buf.toString();
    final messenger = ScaffoldMessenger.of(context);
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('诊断信息'),
        content: SingleChildScrollView(
          child: Text(
            diagText,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('复制'),
            onPressed: () async {
              try {
                await Clipboard.setData(ClipboardData(text: diagText));
                messenger
                    .showSnackBar(const SnackBar(content: Text('诊断信息已复制到剪贴板')));
              } catch (e) {
                messenger.showSnackBar(SnackBar(content: Text('复制失败：$e')));
              }
            },
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.bug_report_outlined),
            tooltip: '诊断剪贴板/分享能力',
            onPressed: _showDiagnostics,
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.asset(_assetPath, width: 240),
                ),
                const SizedBox(height: 24),
            // 与图片一起复制的文字内容，用户可自行编辑。
            SizedBox(
              width: 320,
              child: TextField(
                controller: _textController,
                decoration: const InputDecoration(
                  labelText: '附加文字',
                  hintText: '输入要和图片一起复制的文字',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                maxLines: 2,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : _shareOrCopy,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.share),
              label: Text(_busy ? '处理中…' : '复制 / 分享图片'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : _copyImageAndText,
              icon: const Icon(Icons.content_copy),
              label: Text(_busy ? '处理中…' : '复制图片 + 文字'),
            ),
            const SizedBox(height: 12),
            Text(
              '「复制 / 分享图片」: 仅图片\n'
              '「复制图片 + 文字」:\n'
              '  • 桌面 Chrome → 剪贴板双类型，微信可粘贴\n'
              '  • 手机 Chrome → 图片走系统分享，文字同时入剪贴板\n'
              '    （微信粘贴图片后，再粘一次剪贴板的文字）\n'
              '  • 都不支持时 → 文字入剪贴板 + 图片下载',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
        ),
      ),
    );
  }
}
