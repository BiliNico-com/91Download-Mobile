import 'dart:ui';
import 'package:flutter/material.dart';

/// 作者主页公共头部组件
/// 
/// 三个页面共用：search_page.dart / batch_page.dart / follow_page.dart
/// 
/// 功能：
/// - 返回按钮（退出作者模式/关闭页面）
/// - 作者名称 + 关注/取消关注按钮
/// - 已选数量/全选/就绪状态/隐私模式切换
/// - 展开/收起自适应布局
class AuthorPageHeader extends SliverPersistentHeaderDelegate {
  final double statusBarHeight;
  final double expandedHeight;
  final double collapsedHeight;
  final double collapseRatio;
  
  // 作者信息
  final String authorName;
  final bool isFollowed;
  final VoidCallback? onBack;
  final VoidCallback? onFollowToggle;
  
  // 视频状态
  final int videoCount;
  
  // 批量操作
  final int selectedCount;
  final int totalCount;
  final String status;
  final bool privacyMode;
  final VoidCallback? onPrivacyToggle;
  final VoidCallback? onSelectAll;

  AuthorPageHeader({
    required this.statusBarHeight,
    required this.expandedHeight,
    required this.collapsedHeight,
    required this.collapseRatio,
    required this.authorName,
    this.isFollowed = false,
    this.onBack,
    this.onFollowToggle,
    required this.videoCount,
    this.selectedCount = 0,
    this.totalCount = 0,
    required this.status,
    required this.privacyMode,
    this.onPrivacyToggle,
    this.onSelectAll,
  });

  @override
  double get minExtent => statusBarHeight + collapsedHeight;
  
  @override
  double get maxExtent => statusBarHeight + expandedHeight;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? Colors.black.withOpacity(0.75) : Colors.white.withOpacity(0.9);
    final textColor = isDark ? Colors.white : Colors.black87;
    final subTextColor = isDark ? Colors.grey : Colors.black54;
    
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          color: bgColor,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(height: statusBarHeight),
              
              // ── 第一行：返回 + 作者名 + 关注 + 隐私 ──
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // 返回按钮
                    if (onBack != null)
                      GestureDetector(
                        onTap: onBack,
                        child: Container(
                          margin: const EdgeInsets.only(right: 8),
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Colors.blue.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(Icons.arrow_back, size: 20, color: Colors.blue),
                        ),
                      ),
                    
                    // 作者名
                    Expanded(
                      child: Text(
                        '作者: $authorName',
                        style: TextStyle(
                          fontSize: collapseRatio < 0.5 ? 20 : 16,
                          fontWeight: FontWeight.w600,
                          color: textColor,
                        ),
                      ),
                    ),
                    
                    // 关注按钮
                    if (onFollowToggle != null)
                      GestureDetector(
                        onTap: onFollowToggle,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: collapseRatio < 0.5 ? 12 : 10,
                            vertical: collapseRatio < 0.5 ? 6 : 4,
                          ),
                          decoration: BoxDecoration(
                            color: isFollowed 
                                ? Colors.red.withOpacity(0.2) 
                                : Colors.blue.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(collapseRatio < 0.5 ? 16 : 12),
                            border: Border.all(
                              color: isFollowed ? Colors.red : Colors.blue,
                              width: 1,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isFollowed ? Icons.favorite : Icons.favorite_border,
                                size: collapseRatio < 0.5 ? 16 : 14,
                                color: isFollowed ? Colors.red : Colors.blue,
                              ),
                              SizedBox(width: 4),
                              Text(
                                isFollowed ? '已关注' : '关注',
                                style: TextStyle(
                                  fontSize: collapseRatio < 0.5 ? 13 : 12,
                                  color: isFollowed ? Colors.red : Colors.blue,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    
                    SizedBox(width: 8),
                    
                    // 隐私按钮
                    if (onPrivacyToggle != null)
                      IconButton(
                        icon: Icon(
                          privacyMode ? Icons.visibility_off : Icons.visibility,
                          color: privacyMode ? Colors.red : Colors.grey,
                          size: 20,
                        ),
                        onPressed: onPrivacyToggle,
                        tooltip: privacyMode ? '取消模糊' : '模糊预览图',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                  ],
                ),
              ),
              
              // ── 第二行：副标题（展开时显示）──
              if (collapseRatio < 0.5)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Text(
                    '已加载 $videoCount 个视频 (作者主页)',
                    style: TextStyle(fontSize: 12, color: subTextColor),
                  ),
                ),
              
              // ── 第三行：批量操作按钮（展开时显示，有选择时显示）──
              if (collapseRatio < 0.5 && selectedCount > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Row(
                    children: [
                      // 已选数量
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.blue.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '已选 $selectedCount 个',
                          style: const TextStyle(color: Colors.blue, fontSize: 11),
                        ),
                      ),
                      
                      SizedBox(width: 8),
                      
                      // 全选按钮
                      if (onSelectAll != null)
                        GestureDetector(
                          onTap: onSelectAll,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: selectedCount == totalCount
                                  ? Colors.blue
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(8),
                              border: selectedCount == totalCount
                                  ? null
                                  : Border.all(color: Colors.blue, width: 2),
                            ),
                            child: Icon(
                              Icons.check,
                              color: selectedCount == totalCount
                                  ? Colors.white
                                  : Colors.blue,
                              size: 18,
                            ),
                          ),
                        ),
                      
                      Spacer(),
                      
                      // 就绪状态
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: status == '就绪'
                              ? Colors.green.withOpacity(0.2)
                              : Colors.orange.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          status,
                          style: TextStyle(
                            color: status == '就绪' ? Colors.green : Colors.orange,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant AuthorPageHeader oldDelegate) {
    return oldDelegate.collapseRatio != collapseRatio
        || oldDelegate.authorName != authorName
        || oldDelegate.isFollowed != isFollowed
        || oldDelegate.videoCount != videoCount
        || oldDelegate.selectedCount != selectedCount
        || oldDelegate.status != status
        || oldDelegate.privacyMode != privacyMode;
  }
}
