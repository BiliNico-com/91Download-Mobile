import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// 封面图专用缓存管理器
///
/// 用独立 key 与默认缓存隔离，便于在「缓存管理」里单独统计与清空
/// （见 CacheService.getCoverCacheSize / clearCoverCache）。
class CoverCacheManager {
  static const key = 'coverImageCache';

  static final CacheManager instance = CacheManager(
    Config(
      key,
      stalePeriod: CoverTokens.cacheStalePeriod,
      maxNrOfCacheObjects: 2000,
      repo: JsonCacheInfoRepository(databaseName: key),
      fileSystem: IOFileSystem(key),
      fileService: HttpFileService(),
    ),
  );
}

/// 封面图统一样式常量
///
/// 抽出来的目的：让各页面的封面占位、错误回退保持一致，
/// 避免每处各写一套导致观感不统一。
class CoverTokens {
  /// 占位/错误背景（深灰，图片加载出来前不闪白）
  static const Color placeholderColor = Color(0xFF2A2A2A);

  /// 圆角
  static const double radius = 8;

  /// 磁盘缓存上限（字节）
  ///
  /// 封面多为几十 KB 的缩略图，300MB 可容纳上万张；
  /// 超出后 flutter_cache_manager 会按 LRU 自动淘汰最旧的。
  static const int maxCacheBytes = 300 * 1024 * 1024;

  /// 缓存有效期（超过则视为过期，但仍可离线展示）
  static const Duration cacheStalePeriod = Duration(days: 30);

  /// 单张图片在内存缓存中的最长存活时间
  static const Duration maxCacheAge = Duration(days: 30);
}

/// 统一封面图组件
///
/// 相比 `Image.network` 的关键差异：**使用磁盘缓存**。
/// Image.network 只有很小的内存 LRU，App 重启或滚动淘汰后
/// 就要重新下载；本组件会把图片持久化到本地，二次打开直接命中。
class CoverImage extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final radius = borderRadius ??
        const BorderRadius.all(Radius.circular(CoverTokens.radius));

    Widget content;
    if (url == null || url!.isEmpty) {
      content = _buildPlaceholder();
    } else {
      content = CachedNetworkImage(
        imageUrl: url!,
        width: width,
        height: height,
        fit: fit,
        // 使用独立缓存管理器：受 maxNrOfCacheObjects 限制，自动 LRU 淘汰
        cacheManager: CoverCacheManager.instance,
        // 磁盘+内存双缓存的关键配置
        maxWidthDiskCache: 600,
        maxHeightDiskCache: 600,
        fadeInDuration: const Duration(milliseconds: 150),
        placeholder: (context, _) => _buildPlaceholder(),
        errorWidget: (context, _, __) => _buildPlaceholder(isError: true),
      );
    }

    if (blur) {
      content = Stack(
        fit: StackFit.passthrough,
        children: [
          content,
          // 隐私模式：模糊预览，点开才看清
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

    if (borderRadius == null) {
      // 不裁剪，交给父级
      return SizedBox(width: width, height: height, child: content);
    }

    return ClipRRect(
      borderRadius: radius,
      child: SizedBox(width: width, height: height, child: content),
    );
  }

  Widget _buildPlaceholder({bool isError = false}) {
    return Container(
      width: width,
      height: height,
      color: CoverTokens.placeholderColor,
      alignment: Alignment.center,
      child: Icon(
        isError ? Icons.broken_image_outlined : fallbackIcon,
        color: Colors.grey,
        size: fallbackIconSize,
      ),
    );
  }
}
