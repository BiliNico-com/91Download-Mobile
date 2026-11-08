import 'package:flutter/material.dart';
import '../theme/app_tokens.dart';
import '../services/app_state.dart';

/// 页面头（原型里的 .phead）
///
/// 五个主页面此前各写一套顶栏：批量页用 SliverAppBar + LayoutBuilder，
/// 搜索页手算 expandRatio，下载页用 AppBar.toolbarHeight，设置页用两行标题，
/// 已关注页用 centerTitle —— 同一位置五种观感、四种折叠算法。
/// 现在统一收口到这里：一行大标题 + 右侧图标按钮 + 一行站点胶囊。
class AppPageHead extends StatelessWidget {
  final String title;
  final List<Widget> actions;
  final Widget? below;
  final double topPadding;
  final Color? background;
  final bool showDivider;

  const AppPageHead({
    super.key,
    required this.title,
    this.actions = const [],
    this.below,
    this.topPadding = 0,
    this.background,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Container(
      padding: EdgeInsets.only(top: topPadding),
      decoration: BoxDecoration(
        color: background ?? t.surface,
        border: showDivider
            ? Border(bottom: BorderSide(color: t.line, width: 1))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 10, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 23,
                      height: 1.15,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                      color: t.text1,
                    ),
                  ),
                ),
                if (actions.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Row(children: actions),
                ],
              ],
            ),
          ),
          if (below != null) below!,
        ],
      ),
    );
  }
}

/// 顶栏右侧的方形图标按钮（原型 .ibtn：34x34 / r11 / surface2）
class AppIconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final Color? color;
  final Color? background;

  const AppIconBtn({
    super.key,
    required this.icon,
    this.onTap,
    this.tooltip,
    this.color,
    this.background,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final btn = GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: background ?? t.surface2,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Icon(icon, size: 19, color: color ?? t.text2),
      ),
    );
    if (tooltip == null) return btn;
    return Tooltip(message: tooltip!, child: btn);
  }
}

/// 站点胶囊（原型 .sitepill：高 30 / r999 / blue50 底）
///
/// 原型里它常驻每个主页面 —— 用户在看列表时就能知道「现在抓的是哪个站」，
/// 不必回设置页确认。点击直接跳到设置页的站点选择。
class SitePill extends StatelessWidget {
  final AppState appState;
  final int? latencyMs;
  final VoidCallback? onTap;

  const SitePill({
    super.key,
    required this.appState,
    this.latencyMs,
    this.onTap,
  });

  /// 站点家族的中文名（与设置页一致）
  static const Map<String, String> familyNames = {
    'porn91': '91porn 系',
    'jiuse': '九色系',
    'hifuli': '嗨碰系',
    'original': '原创系',
  };

  static String hostOf(String? site) {
    if (site == null || site.isEmpty) return '';
    final uri = Uri.tryParse(site);
    final host = uri?.host ?? '';
    final bare = host.replaceAll('www.', '');
    if (bare.isEmpty) return bare;
    // 非默认端口要显示，否则本地 8899 / 8901 两个 mock 站点看起来是同一个
    final port = (uri != null && uri.hasPort) ? uri.port : 0;
    if (port == 0 || port == 80 || port == 443) return bare;
    return '$bare:$port';
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final host = hostOf(appState.currentSite);
    final family = familyNames[appState.currentSiteType] ?? '自定义';
    final text = host.isEmpty ? '未选择站点' : '$family · $host';

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          color: t.accentSoft,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: t.success,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: t.success.withOpacity(0.16),
                    spreadRadius: 3,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: t.accent,
                ),
              ),
            ),
            if (latencyMs != null) ...[
              const SizedBox(width: 7),
              Text(
                latencyMs! < 0 ? '超时' : '${latencyMs}ms',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: latencyMs! < 0 ? t.danger : t.success,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 计数胶囊（原型 .pill.run / .pill.done）
class AppCountPill extends StatelessWidget {
  final String text;
  final Color color;

  const AppCountPill({super.key, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(t.dark ? 0.18 : 0.10),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

/// 分段控件（原型 .seg）—— 下载页页签、搜索页视频/作者、列表/网格切换共用
class AppSegmented extends StatelessWidget {
  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onChanged;
  final EdgeInsetsGeometry? margin;
  final double height;

  const AppSegmented({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onChanged,
    this.margin,
    this.height = 32,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Container(
      margin: margin,
      height: height + 6,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: t.surface2,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(i),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  height: height,
                  decoration: BoxDecoration(
                    color: i == selectedIndex ? t.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppRadius.sm + 1),
                    boxShadow: i == selectedIndex ? t.cardShadow : null,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    labels[i],
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: i == selectedIndex ? t.accent : t.text2,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 底部多选浮条（原型 .floatbar）
class AppFloatBar extends StatelessWidget {
  final int selectedCount;
  final String actionLabel;
  final VoidCallback onAction;
  final VoidCallback? onCancel;

  const AppFloatBar({
    super.key,
    required this.selectedCount,
    required this.actionLabel,
    required this.onAction,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    // 浮条两种模式都是「深底浅字」：深色模式用近黑，浅色模式用深蓝黑。
    // 文字颜色必须固定为浅色 —— 早前用 t.surface 当字色，深色模式下
    // t.surface(0xFF171C24) 与底 0xFF0A0E14 几乎同色，「已选 N 个」看不见。
    final bg = t.dark ? const Color(0xFF0A0E14) : t.text1;
    const fg = Colors.white;
    return Container(
      height: 52,
      padding: const EdgeInsets.only(left: 18, right: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: t.dark ? Border.all(color: t.line) : null,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(t.dark ? 0.5 : 0.10),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Text(
            '已选 $selectedCount 个',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
          const Spacer(),
          if (onCancel != null)
            GestureDetector(
              onTap: onCancel,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  '取消',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: fg.withOpacity(0.72),
                  ),
                ),
              ),
            ),
          GestureDetector(
            onTap: onAction,
            behavior: HitTestBehavior.opaque,
            child: Container(
              height: 38,
              padding: const EdgeInsets.symmetric(horizontal: 22),
              decoration: BoxDecoration(
                color: AppTokens.blue,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              alignment: Alignment.center,
              child: Text(
                actionLabel,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
