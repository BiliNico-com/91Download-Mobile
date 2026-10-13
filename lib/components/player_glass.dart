import 'dart:ui';
import 'package:flutter/material.dart';

/// 播放器可选倍速档位
///
/// 内置播放器与在线播放页共用，保证两处档位一致。
const List<double> kPlayerSpeedOptions = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

/// 播放器控件的玻璃拟态（glassmorphism）视觉规范
///
/// 设计参考自 BiliPai（jay3-yy/BiliPai）的播放器控件：
/// - 半透明 + 背景模糊，让控件浮在画面上而不完全遮挡内容
/// - 胶囊形（pill）容器，圆形按钮
/// - 控件 4 秒后自动淡出，淡入淡出 300ms
///
/// 说明：BiliPai 使用 Miuix 的液态玻璃（含折射/透镜效果），
/// Flutter 侧用 BackdropFilter 实现的是"模糊毛玻璃"，
/// 观感接近但不会有液态折射，这是平台能力差异。
class PlayerGlassTokens {
  /// 控件区外边距
  static const double edgePadding = 12;

  /// 圆形按钮尺寸
  static const double circularButtonSize = 48;

  /// 按钮之间的间距
  static const double actionGap = 8;

  /// 控件自动隐藏延时
  static const Duration autoHideDelay = Duration(seconds: 4);

  /// 控件淡入淡出时长
  static const Duration fadeDuration = Duration(milliseconds: 300);

  /// 背景模糊强度
  static const double blurSigma = 18;

  /// 玻璃底色（深色场景下的半透明黑）
  static Color glassFill(Brightness brightness) {
    return brightness == Brightness.dark
        ? Colors.white.withOpacity(0.10)
        : Colors.white.withOpacity(0.16);
  }

  /// 玻璃描边，用于勾勒边界、提升可读性
  static Color glassStroke(Brightness brightness) {
    return Colors.white.withOpacity(brightness == Brightness.dark ? 0.16 : 0.24);
  }
}

/// 玻璃拟态容器
///
/// 用于承载播放器控件（底部栏、顶部栏、浮层等），
/// 内部会做背景模糊 + 半透明填充 + 细描边。
class GlassSurface extends StatelessWidget {
  final Widget child;

  /// 圆角；传入 [BorderRadius.circular(50)] 之类可得到胶囊形
  final BorderRadius borderRadius;

  /// 是否使用更暗的底色（用于需要更强对比度的场合，如进度条轨道）
  final bool darker;

  /// 内边距
  final EdgeInsetsGeometry? padding;

  /// 附加设置，例如约束宽度
  final BoxConstraints? constraints;

  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(14)),
    this.darker = false,
    this.padding,
    this.constraints,
  });

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;

    Widget content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: darker
            ? Colors.black.withOpacity(0.45)
            : PlayerGlassTokens.glassFill(brightness),
        borderRadius: borderRadius,
        border: Border.all(
          color: PlayerGlassTokens.glassStroke(brightness),
          width: 0.8,
        ),
      ),
      child: child,
    );

    if (constraints != null) {
      content = ConstrainedBox(constraints: constraints!, child: content);
    }

    // 背景模糊：让控件与画面产生"透光"关系，而不是贴一块纯色板
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: PlayerGlassTokens.blurSigma,
          sigmaY: PlayerGlassTokens.blurSigma,
        ),
        child: content,
      ),
    );
  }
}

/// 胶囊形玻璃容器（用于底部控制栏等横向排列的控件）
class GlassPill extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool darker;

  const GlassPill({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    this.darker = false,
  });

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      borderRadius: const BorderRadius.all(Radius.circular(50)),
      padding: padding,
      darker: darker,
      child: child,
    );
  }
}

/// 方形（圆角矩形）玻璃按钮
///
/// 与圆形按钮相比更贴合长方形底栏的视觉语言，边角比例与底栏一致。
class GlassIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final String? tooltip;
  final bool filled;

  const GlassIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.size = PlayerGlassTokens.circularButtonSize,
    this.tooltip,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(8));

    final button = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: radius,
        child: SizedBox(
          width: size,
          height: size,
          child: Center(
            child: Icon(
              icon,
              size: size * 0.52,
              // 控件长期显示在视频上，统一用白色保证可读性
              color: onPressed == null ? Colors.white38 : Colors.white,
            ),
          ),
        ),
      ),
    );

    final wrapped = filled
        ? GlassSurface(borderRadius: radius, child: button)
        : button;

    return tooltip == null ? wrapped : Tooltip(message: tooltip!, child: wrapped);
  }
}

/// 把时长格式化成 mm:ss / h:mm:ss
///
/// 播放器里多处需要，统一放这里避免重复实现。
String formatPlayerDuration(Duration d) {
  final totalSeconds = d.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;

  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');

  return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
}
