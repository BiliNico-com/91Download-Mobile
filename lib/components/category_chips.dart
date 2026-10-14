import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// 横向滚动的分类标签行
///
/// 替代原来批量页顶部的下拉选择器，解决三个问题：
///   1. 下拉需要展开才能看到选项，12 个分类时要滚动查找；
///      标签行把选项平铺出来，一眼可见、一次点击即可切换。
///   2. 原先「展开态」与「收起态」各写了一份下拉，样式已经不一致；
///      现在两种状态共用本组件，天然统一。
///   3. 下拉在点击前完全看不出当前有哪些分类。
///
/// 用法：把 [entries]（key → 中文名）与当前值传入即可。
class CategoryChips extends StatefulWidget {
  /// 分类映射：key 为内部标识，value 为展示名
  final Map<String, String> entries;

  /// 当前选中的 key
  final String selected;

  /// 选中回调
  final ValueChanged<String> onSelected;

  /// 是否深色模式
  final bool isDark;

  /// 内容左右内边距
  final double horizontalPadding;

  const CategoryChips({
    super.key,
    required this.entries,
    required this.selected,
    required this.onSelected,
    required this.isDark,
    this.horizontalPadding = 12,
  });

  @override
  State<CategoryChips> createState() => _CategoryChipsState();
}

class _CategoryChipsState extends State<CategoryChips> {
  final ScrollController _controller = ScrollController();

  /// 每个标签的估算宽度用于初始定位（粗略即可，只影响首屏是否露出选中项）
  static const double _approxChipWidth = 78;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToSelected());
  }

  @override
  void didUpdateWidget(CategoryChips oldWidget) {
    super.didUpdateWidget(oldWidget);

    // ① 换站点：分类集合整个变了（例如 12 项 → 5 项）。
    //    此时必须把横向滚动位置复位，否则旧的偏移量会让新的短列表
    //    整行滚出视野、看起来像"空白"。这是从下拉改成横滑标签后
    //    才出现的问题——下拉没有滚动位置的概念。
    final keysChanged = !_sameKeys(oldWidget.entries, widget.entries);
    if (keysChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_controller.hasClients) _controller.jumpTo(0);
      });
      return; // entries 变了就只需复位，不必再针对旧下标滚动
    }

    // ② 选中项变化：把它滚进可视区域，避免"切了但看不到"
    if (oldWidget.selected != widget.selected) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToSelected());
    }
  }

  /// 比较两个分类映射的键序列是否一致
  static bool _sameKeys(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    final ka = a.keys.toList();
    final kb = b.keys.toList();
    for (var i = 0; i < ka.length; i++) {
      if (ka[i] != kb[i]) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _scrollToSelected() {
    if (!_controller.hasClients) return;
    final keys = widget.entries.keys.toList();
    final idx = keys.indexOf(widget.selected);
    if (idx < 0) return;

    // 目标位置：让选中项大致居中
    final viewport = _controller.position.viewportDimension;
    final target = (idx * _approxChipWidth) - (viewport / 2) + (_approxChipWidth / 2);
    _controller.animateTo(
      target.clamp(0.0, _controller.position.maxScrollExtent),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final unselectedBg = isDark ? const Color(0xFF2E2E2E) : const Color(0xFFECEFF3);
    final unselectedFg = isDark ? Colors.white70 : const Color(0xFF444444);

    return SizedBox(
      height: 38,
      child: ListView.separated(
        // key 随分类集合变化，确保换站点时 ListView 重建，
        // 不残留旧的滚动偏移与缓存的 item
        key: ValueKey(widget.entries.keys.join(',')),
        controller: _controller,
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: widget.horizontalPadding),
        itemCount: widget.entries.length,
        separatorBuilder: (_, __) => const SizedBox(width: 7),
        itemBuilder: (context, i) {
          final key = widget.entries.keys.elementAt(i);
          final label = widget.entries[key] ?? key;
          final on = key == widget.selected;

          return Center(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: on ? null : () => widget.onSelected(key),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
                decoration: BoxDecoration(
                  color: on ? AppTheme.primaryColor : unselectedBg,
                  borderRadius: AppTheme.brPill,
                  boxShadow: on
                      ? [
                          BoxShadow(
                            color: AppTheme.primaryColor.withOpacity(0.30),
                            blurRadius: 7,
                            offset: const Offset(0, 2),
                          ),
                        ]
                      : null,
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: on ? Colors.white : unselectedFg,
                    fontWeight: on ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
