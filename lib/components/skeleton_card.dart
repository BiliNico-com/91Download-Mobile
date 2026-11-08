import 'package:flutter/material.dart';
import '../theme/app_tokens.dart';

/// 骨架屏 shimmer 效果组件
///
/// 用于列表加载时的占位，减少用户感知的加载时间
class ShimmerVideoCard extends StatefulWidget {
  final bool isListMode;

  const ShimmerVideoCard({
    super.key,
    this.isListMode = true,
  });

  @override
  State<ShimmerVideoCard> createState() => _ShimmerVideoCardState();
}

class _ShimmerVideoCardState extends State<ShimmerVideoCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _animation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        // 深色下把 surface2 → surface3 之间插值，浅色同理，
        // 保证占位块与卡片底色始终有可见但柔和的对比
        final shimmer = Color.lerp(t.surface2, t.surface3, _animation.value)!;

        return widget.isListMode
            ? _buildListSkeleton(t, shimmer)
            : _buildGridSkeleton(t, shimmer);
      },
    );
  }

  Widget _buildListSkeleton(AppTokens t, Color shimmer) {
    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: t.cardBorder,
        boxShadow: t.cardShadow,
      ),
      child: Row(
        children: [
          Container(
            width: 108,
            height: 70,
            decoration: BoxDecoration(
              color: shimmer,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  height: 13,
                  decoration: BoxDecoration(
                    color: shimmer,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: 120,
                  height: 10,
                  decoration: BoxDecoration(
                    color: t.surface2,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                ),
                const SizedBox(height: 7),
                Container(
                  width: 74,
                  height: 9,
                  decoration: BoxDecoration(
                    color: t.surface2,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGridSkeleton(AppTokens t, Color shimmer) {
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: t.cardBorder,
        boxShadow: t.cardShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Container(color: shimmer)),
          Padding(
            padding: const EdgeInsets.fromLTRB(9, 9, 9, 11),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  height: 12,
                  decoration: BoxDecoration(
                    color: shimmer,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                ),
                const SizedBox(height: 7),
                Container(
                  width: 60,
                  height: 9,
                  decoration: BoxDecoration(
                    color: t.surface2,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 骨架屏列表
class ShimmerVideoList extends StatelessWidget {
  final bool isListMode;
  final int count;

  const ShimmerVideoList({
    super.key,
    this.isListMode = true,
    this.count = 6,
  });

  @override
  Widget build(BuildContext context) {
    return isListMode
        ? ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 2),
            itemCount: count,
            itemBuilder: (_, __) => const ShimmerVideoCard(isListMode: true),
          )
        : GridView.builder(
            padding: const EdgeInsets.all(2),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              childAspectRatio: 16 / 14,
              crossAxisSpacing: 9,
              mainAxisSpacing: 9,
            ),
            itemCount: count,
            itemBuilder: (_, __) => const ShimmerVideoCard(isListMode: false),
          );
  }
}

/// 骨架屏内容块（不滚动，直接嵌在已有 ListView/Column 里）
///
/// author_detail / search 等页面已经自带滚动容器，
/// 再塞一个 ListView 会报 "Vertical viewport was given unbounded height"，
/// 所以另提供一个纯 Column 版本。
class ShimmerVideoInline extends StatelessWidget {
  final bool isListMode;
  final int count;

  const ShimmerVideoInline({
    super.key,
    this.isListMode = true,
    this.count = 6,
  });

  @override
  Widget build(BuildContext context) {
    if (isListMode) {
      return Column(
        children: List.generate(
          count,
          (_) => const ShimmerVideoCard(isListMode: true),
        ),
      );
    }
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 16 / 14,
        crossAxisSpacing: 9,
        mainAxisSpacing: 9,
      ),
      itemCount: count,
      itemBuilder: (_, __) => const ShimmerVideoCard(isListMode: false),
    );
  }
}
