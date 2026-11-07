import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// 封面图统一样式与缓存参数
class CoverTokens {
  /// 占位/错误背景（深灰，图片加载出来前不闪白）
  static const Color placeholderColor = Color(0xFF2A2A2A);

  /// 圆角
  static const double radius = 8;

  /// 缓存文件数量上限（超出按最旧优先淘汰）
  static const int maxCacheFiles = 2000;

  /// 缓存有效期，超过则重新下载
  static const Duration cacheStalePeriod = Duration(days: 30);

  /// 解析图片时的目标宽度上限（避免整张大图进内存）
  static const int decodeWidth = 600;
}

/// 封面图磁盘缓存
///
/// 为什么自己实现而不用 cached_network_image：
/// 该项目 CI 使用 Flutter 3.16（Dart 3.2），而 cached_network_image 3.4.x
/// 依赖 cached_network_image_web → web ^1.0.0，web 1.x 要求 Dart ≥ 3.4，
/// 会导致 `pub get` 解析失败、CI 构建中断。
/// 这里用项目已有的 dio + path_provider + crypto 实现等价能力，
/// 不新增任何依赖，依赖图与历史可用版本保持一致。
class CoverCache {
  CoverCache._();

  static const String _dirName = 'cover_cache';

  /// 同一 URL 的并发请求复用同一个 Future，避免重复下载
  static final Map<String, Future<File?>> _inflight = {};

  /// 目录句柄（只解析一次）
  static Future<Directory>? _dirFuture;

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 20),
    responseType: ResponseType.bytes,
    headers: {
      // 部分 CDN 会拒绝非浏览器 UA
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
    },
  ));

  static Future<Directory> _dir() {
    return _dirFuture ??= () async {
      final tmp = await getTemporaryDirectory();
      final d = Directory('${tmp.path}/$_dirName');
      if (!await d.exists()) {
        await d.create(recursive: true);
      }
      return d;
    }();
  }

  /// URL → 文件名（md5 避免非法字符与过长文件名）
  static String _keyOf(String url) =>
      md5.convert(utf8.encode(url)).toString();

  /// 取缓存文件；不存在或已过期返回 null
  static Future<File?> _cachedFile(String url) async {
    try {
      final d = await _dir();
      final f = File('${d.path}/${_keyOf(url)}');
      if (!await f.exists()) return null;

      final stat = await f.stat();
      if (stat.size <= 0) {
        // 上次写入中断留下的空文件
        await f.delete();
        return null;
      }
      if (DateTime.now().difference(stat.modified) > CoverTokens.cacheStalePeriod) {
        await f.delete();
        return null;
      }
      return f;
    } catch (_) {
      return null;
    }
  }

  /// 获取封面文件：命中缓存直接返回，否则下载并落盘
  ///
  /// 返回 null 表示失败（调用方展示占位图）。
  static Future<File?> fetch(String url) {
    return _inflight.putIfAbsent(url, () async {
      try {
        final hit = await _cachedFile(url);
        if (hit != null) return hit;

        final resp = await _dio.get<List<int>>(url);
        final bytes = resp.data;
        if (bytes == null || bytes.isEmpty) return null;

        final d = await _dir();
        final f = File('${d.path}/${_keyOf(url)}');
        await f.writeAsBytes(bytes, flush: true);

        // 写完后视情况清理，避免无限增长
        unawaited(_pruneIfNeeded());

        return f;
      } catch (_) {
        return null;
      } finally {
        _inflight.remove(url);
      }
    });
  }

  /// 仅从缓存读取（不触发下载），用于预热判断
  static Future<File?> peek(String url) => _cachedFile(url);

  static DateTime _lastPrune = DateTime.fromMillisecondsSinceEpoch(0);

  /// 文件数超过上限时，删除最旧的一批
  static Future<void> _pruneIfNeeded() async {
    // 10 分钟内最多清理一次，避免每次下载都全目录扫描
    if (DateTime.now().difference(_lastPrune) < const Duration(minutes: 10)) {
      return;
    }
    _lastPrune = DateTime.now();

    try {
      final d = await _dir();
      final files = <File>[];
      await for (final e in d.list(followLinks: false)) {
        if (e is File) files.add(e);
      }
      if (files.length <= CoverTokens.maxCacheFiles) return;

      // 按修改时间升序，删除最旧的，直到降到上限的 80%
      final withTime = <MapEntry<File, DateTime>>[];
      for (final f in files) {
        try {
          withTime.add(MapEntry(f, (await f.stat()).modified));
        } catch (_) {}
      }
      withTime.sort((a, b) => a.value.compareTo(b.value));

      final target = (CoverTokens.maxCacheFiles * 0.8).round();
      final removeCount = withTime.length - target;
      for (var i = 0; i < removeCount; i++) {
        try {
          await withTime[i].key.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 缓存目录占用字节数
  static Future<int> sizeBytes() async {
    try {
      final d = await _dir();
      var total = 0;
      await for (final e in d.list(followLinks: false)) {
        if (e is File) {
          try {
            total += await e.length();
          } catch (_) {}
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// 清空缓存目录
  static Future<void> clear() async {
    try {
      final d = await _dir();
      await for (final e in d.list(followLinks: false)) {
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
      _inflight.clear();
    } catch (_) {}
  }
}

/// 统一封面图组件
///
/// 与 `Image.network` 的关键差异：**带磁盘缓存**。
/// Image.network 只有很小的内存 LRU，App 重启或滚动淘汰后就要重新下载；
/// 本组件把图片落到本地，二次打开直接命中，不再重复下载。
class CoverImage extends StatefulWidget {
  final String? url;

  /// 宽度，null 表示由父级约束决定
  final double? width;
  final double? height;

  /// 圆角；传 null 不加圆角
  final BorderRadius? borderRadius;

  final BoxFit fit;

  /// 加载中与失败时显示的图标
  final IconData fallbackIcon;
  final double fallbackIconSize;

  /// 是否模糊（隐私模式）
  final bool blur;

  const CoverImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.borderRadius,
    this.fit = BoxFit.cover,
    this.fallbackIcon = Icons.video_library,
    this.fallbackIconSize = 24,
    this.blur = false,
  });

  @override
  State<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<CoverImage> {
  File? _file;
  bool _loading = false;
  bool _failed = false;

  /// 隐私模式下长按临时解除模糊。
  /// 用组件内部状态而非回调，是为了让所有用到 CoverImage 的页面
  /// 自动获得「长按看清」能力，不必每处各写一套手势。
  bool _revealed = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _file = null;
      _failed = false;
      _resolve();
    }
    // 隐私模式被关掉时，清掉临时的长按状态
    if (oldWidget.blur && !widget.blur) {
      _revealed = false;
    }
  }

  Future<void> _resolve() async {
    final url = widget.url;
    if (url == null || url.isEmpty) return;

    setState(() => _loading = true);
    final f = await CoverCache.fetch(url);
    if (!mounted) return;
    setState(() {
      _file = f;
      _loading = false;
      _failed = f == null;
    });
  }

  void _setRevealed(bool v) {
    if (!widget.blur || _revealed == v) return;
    setState(() => _revealed = v);
  }

  @override
  Widget build(BuildContext context) {
    final radius = widget.borderRadius ??
        const BorderRadius.all(Radius.circular(CoverTokens.radius));

    Widget content;
    if (widget.url == null || widget.url!.isEmpty) {
      content = _placeholder();
    } else if (_file != null) {
      content = Image.file(
        _file!,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        // 控制解码尺寸，避免大图整张进内存
        cacheWidth: CoverTokens.decodeWidth,
        errorBuilder: (_, __, ___) => _placeholder(isError: true),
      );
    } else if (_loading) {
      content = _placeholder();
    } else {
      content = _placeholder(isError: _failed);
    }

    // 隐私模式：默认模糊，长按期间解除模糊，松手恢复
    if (widget.blur && !_revealed) {
      content = Stack(
        fit: StackFit.passthrough,
        children: [
          content,
          Positioned.fill(
            child: ClipRRect(
              borderRadius: radius,
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                child: Container(color: Colors.transparent),
              ),
            ),
          ),
        ],
      );
    }

    Widget result;
    if (widget.borderRadius == null) {
      result = SizedBox(
          width: widget.width, height: widget.height, child: content);
    } else {
      result = ClipRRect(
        borderRadius: radius,
        child: SizedBox(
            width: widget.width, height: widget.height, child: content),
      );
    }

    // 只有隐私模式才接管长按；否则完全不插手手势，
    // 避免和上层的点击播放/选中逻辑抢事件
    if (!widget.blur) return result;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressStart: (_) => _setRevealed(true),
      onLongPressEnd: (_) => _setRevealed(false),
      onLongPressCancel: () => _setRevealed(false),
      child: result,
    );
  }

  Widget _placeholder({bool isError = false}) {
    return Container(
      width: widget.width,
      height: widget.height,
      color: CoverTokens.placeholderColor,
      alignment: Alignment.center,
      child: Icon(
        isError ? Icons.broken_image_outlined : widget.fallbackIcon,
        color: Colors.grey,
        size: widget.fallbackIconSize,
      ),
    );
  }
}
