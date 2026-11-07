import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

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
    _animation = Tween<double>(begin: 0.3, end: 0.7).animate(
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
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final baseColor = isDark ? const Color(0xFF2C2C2C) : const Color(0xFFE0E0E0);
        final shimmerColor = isDark
            ? Color.lerp(const Color(0xFF2C2C2C), const Color(0xFF3C3C3C), _animation.value)!
            : Color.lerp(const Color(0xFFE0E0E0), const Color(0xFFF5F5F5), _animation.value)!;

        return widget.isListMode
            ? _buildListSkeleton(shimmerColor, baseColor)
            : _buildGridSkeleton(shimmerColor, baseColor);
      },
    );
  }

  Widget _buildListSkeleton(Color shimmerColor, Color baseColor) {
    return Card(
      margin: const EdgeInsets.symmetric(
        horizontal: AppTheme.spacingSm,
        vertical: AppTheme.spacingXs,
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.spacingMd),
        child: Row(
          children: [
            Container(
              width: 120,
              height: 68,
              decoration: BoxDecoration(
                color: shimmerColor,
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              ),
            ),
            const SizedBox(width: AppTheme.spacingMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    height: 16,
                    decoration: BoxDecoration(
                      color: shimmerColor,
                      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                    ),
                  ),
                  const SizedBox(height: AppTheme.spacingSm),
                  Container(
                    width: 120,
                    height: 12,
                    decoration: BoxDecoration(
                      color: baseColor,
                      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                    ),
                  ),
                  const SizedBox(height: AppTheme.spacingSm),
                  Container(
                    width: 80,
                    height: 10,
                    decoration: BoxDecoration(
                      color: baseColor,
                      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGridSkeleton(Color shimmerColor, Color baseColor) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              color: shimmerColor,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppTheme.spacingSm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  height: 14,
                  decoration: BoxDecoration(
                    color: shimmerColor,
                    borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                  ),
                ),
                const SizedBox(height: AppTheme.spacingXs),
                Container(
                  width: 60,
                  height: 10,
                  decoration: BoxDecoration(
                    color: baseColor,
                    borderRadius: BorderRadius.circular(AppTheme.radiusSm),
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
            padding: const EdgeInsets.symmetric(vertical: AppTheme.spacingSm),
            itemCount: count,
            itemBuilder: (_, __) => const ShimmerVideoCard(isListMode: true),
          )
        : GridView.builder(
            padding: const EdgeInsets.all(AppTheme.spacingSm),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              childAspectRatio: 16 / 14,
              crossAxisSpacing: AppTheme.spacingSm,
              mainAxisSpacing: AppTheme.spacingSm,
            ),
            itemCount: count,
            itemBuilder: (_, __) => const ShimmerVideoCard(isListMode: false),
          );
  }
}
