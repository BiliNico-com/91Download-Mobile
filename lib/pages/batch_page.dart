import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../crawler/config.dart';
import '../models/video_info.dart';
import '../services/app_state.dart';
import '../utils/logger.dart';

class BatchPage extends StatefulWidget {
  const BatchPage({super.key});

  @override
  State<BatchPage> createState() => _BatchPageState();
}

class _BatchPageState extends State<BatchPage> with AutomaticKeepAliveClientMixin {
  String _selectedType = 'list';
  int _currentPage = 1;
  int _loadedPage = 0;
  bool _hasMore = true;
  List<VideoInfo> _videos = [];
  Set<String> _selectedIds = {};
  bool _isLoading = false;
  bool _isLoadingMore = false;
  String _status = '就绪';
  double _progress = 0.0;
  String _progressText = '';
  int _totalVideos = 0;

  // ─── 新增：滚动折叠比例 ───
  double _collapseRatio = 0.0;

  final ScrollController _scrollController = ScrollController();
  bool _showBackToTop = false;
  final TextEditingController _pageController = TextEditingController();

  // ─── 布局常量 ───
  static const double _kExpandedHeight = 130.0;
  static const double _kCollapsedHeight = 56.0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _pageController.text = '1';
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _onScroll() {
    // ─── 回顶部按钮显示/隐藏 ───
    final showBtn = _scrollController.offset > 500;
    if (showBtn != _showBackToTop) {
      setState(() => _showBackToTop = showBtn);
    }
    // ─── 瀑布流自动加载 ───
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      if (!_isLoading && !_isLoadingMore && _hasMore && _videos.isNotEmpty) {
        _loadMore();
      }
    }
    // ─── 折叠比例计算 ───
    final expandRange = _kExpandedHeight - _kCollapsedHeight;
    final offset = _scrollController.offset.clamp(0.0, expandRange);
    final ratio = offset / expandRange;
    if ((ratio - _collapseRatio).abs() > 0.01) {
      setState(() => _collapseRatio = ratio);
    }
  }

  Future<void> _loadMore() async {
    if (!_hasMore || _isLoading || _isLoadingMore) return;
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) return;

    setState(() => _isLoadingMore = true);
    final nextPage = _loadedPage + 1;
    final newVideos = await crawler.getVideoList(_selectedType, nextPage);

    if (newVideos.isEmpty) {
      setState(() {
        _hasMore = false;
        _isLoadingMore = false;
      });
    } else {
      setState(() {
        _videos.addAll(newVideos);
        _totalVideos = _videos.length;
        _loadedPage = nextPage;
        _hasMore = newVideos.length >= 24;
        _isLoadingMore = false;
      });
    }
  }

  void _scrollToTop() {
    _scrollController.animateTo(0, duration: Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  static const _typeNamesPorn91 = {
    'list': '视频',
    'ori': '91原创',
    'hot': '当前最热',
    'top': '本月最热',
    'topm': '每月最热',
    'long': '10分钟以上',
    'longer': '20分钟以上',
    'tf': '本月收藏',
    'rf': '最近加精',
    'hd': '高清',
    'md': '本月讨论',
    'mf': '收藏最多',
  };

  static const _typeNamesOriginal = {
    'list': '视频',
    'top7': '周榜',
    'top': '月榜',
    '5min': '5分钟+',
    'long': '10分钟+',
  };

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final statusBarH = MediaQuery.of(context).padding.top;
    return Consumer<AppState>(
      builder: (context, appState, _) {
        if (!appState.isSiteSelected) {
          return _buildNoSiteSelected();
        }
        // ─── 自动加载第一页 ───
        if (_videos.isEmpty && !_isLoading && appState.crawler != null) {
          Future.microtask(() => _goToPage());
        }
        return Scaffold(
          extendBodyBehindAppBar: true,
          body: Stack(
            children: [
              CustomScrollView(
                controller: _scrollController,
                slivers: [
                  // ══════════════════════════════════════
                  //  自定义 Header（替代原 SliverAppBar）
                  // ══════════════════════════════════════
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: _BatchHeaderDelegate(
                      statusBarHeight: statusBarH,
                      expandedHeight: _kExpandedHeight,
                      collapsedHeight: _kCollapsedHeight,
                      collapseRatio: _collapseRatio,
                      selectedType: _selectedType,
                      typeNames: _getTypeNames(appState.crawler?.siteType ?? 'original'),
                      videoCount: _videos.length,
                      selectedCount: _selectedIds.length,
                      totalCount: _videos.length,
                      status: _status,
                      privacyMode: appState.privacyMode,
                      onTypeChanged: (v) async {
                        if (v != null && v != _selectedType) {
                          setState(() {
                            _selectedType = v;
                            _videos.clear();
                            _selectedIds.clear();
                            _loadedPage = 0;
                          });
                          _pageController.text = '1';
                          await _goToPage();
                        }
                      },
                      onPrivacyToggle: () => appState.togglePrivacyMode(),
                      onSelectAll: () {
                        final isAllSelected = _selectedIds.length == _videos.length;
                        setState(() {
                          if (isAllSelected) {
                            _selectedIds.clear();
                          } else {
                            _selectedIds = _videos.map((v) => v.id).toSet();
                          }
                        });
                      },
                    ),
                  ),

                  // 视频列表
                  SliverPadding(
                    padding: EdgeInsets.all(8),
                    sliver: _buildSliverVideoGrid(appState),
                  ),

                  // 底部留白
                  SliverToBoxAdapter(
                    child: SizedBox(height: 100),
                  ),
                ],
              ),
              // 悬浮覆盖层
              ..._buildOverlays(appState),
            ],
          ),
        );
      },
    );
  }

  Widget _buildNoSiteSelected() {
    return Scaffold(
      appBar: AppBar(title: Text('批量爬取')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.language, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('请先选择站点', style: TextStyle(fontSize: 18, color: Colors.grey)),
            SizedBox(height: 8),
            Text('在设置页面选择要使用的站点', style: TextStyle(fontSize: 14, color: Colors.grey)),
            SizedBox(height: 24),
            Text('← 左滑到设置页面选择站点', style: TextStyle(fontSize: 14, color: Colors.blue)),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildOverlays(AppState appState) {
    return [
      _buildBottomPageNavigation(),
      if (_showBackToTop && appState.showBackToTop)
        Positioned(
          bottom: (appState.backToTopPosition == 'right' && _selectedIds.isNotEmpty) ? 160.0 : 80.0,
          left: appState.backToTopPosition == 'left' ? 16 : null,
          right: appState.backToTopPosition == 'right' ? 16 : null,
          child: FloatingActionButton(
            mini: true,
            heroTag: 'batch_back_to_top',
            onPressed: _scrollToTop,
            child: Icon(Icons.arrow_upward),
          ),
        ),
      if (_selectedIds.isNotEmpty)
        Positioned(
          bottom: 80,
          right: 16,
          child: FloatingActionButton.extended(
            onPressed: _startDownload,
            icon: Icon(Icons.download),
            label: Text('下载 (${_selectedIds.length})'),
          ),
        ),
    ];
  }

  Widget _buildSliverVideoGrid(AppState appState) {
    final isListMode = appState.videoDisplayMode == 'list';
    if (_isLoading && _videos.isEmpty) {
      return SliverToBoxAdapter(child: Center(child: CircularProgressIndicator()));
    }
    if (_videos.isEmpty) {
      return SliverToBoxAdapter(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.video_library_outlined, size: 64, color: Colors.grey),
              SizedBox(height: 16),
              Text('输入页码并点击跳转', style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );
    }
    if (isListMode) {
      return SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => _buildVideoListItem(_videos[index], appState),
          childCount: _videos.length,
        ),
      );
    } else {
      return SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 0.85,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) => _buildVideoGridItem(_videos[index], appState),
          childCount: _videos.length,
        ),
      );
    }
  }

  Widget _buildVideoListItem(VideoInfo video, AppState appState) {
    final isSelected = _selectedIds.contains(video.id);
    return GestureDetector(
      onTap: () {
        setState(() {
          if (isSelected) {
            _selectedIds.remove(video.id);
          } else {
            _selectedIds.add(video.id);
          }
        });
      },
      child: Card(
        color: isSelected ? Colors.blue.withOpacity(0.2) : null,
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: 120,
                  height: 68,
                  color: Colors.grey[800],
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (video.cover != null)
                        Image.network(
                          video.cover!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Icon(Icons.video_library, color: Colors.grey),
                        ),
                      if (appState.privacyMode)
                        BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                          child: Container(color: Colors.transparent),
                        ),
                      if (isSelected)
                        Positioned(top: 4, left: 4, child: Icon(Icons.check_circle, color: Colors.blue, size: 20)),
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: Container(
                          padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(4)),
                          child: Text(video.duration ?? '', style: TextStyle(color: Colors.white, fontSize: 10)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(video.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14)),
                    if (video.author != null) ...[
                      SizedBox(height: 4),
                      Text(video.author!, style: TextStyle(fontSize: 12, color: Colors.grey)),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideoGridItem(VideoInfo video, AppState appState) {
    final isSelected = _selectedIds.contains(video.id);
    return GestureDetector(
      onTap: () {
        setState(() {
          if (isSelected) {
            _selectedIds.remove(video.id);
          } else {
            _selectedIds.add(video.id);
          }
        });
      },
      child: Card(
        color: isSelected ? Colors.blue.withOpacity(0.2) : null,
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(color: Colors.grey[800]),
                  if (video.cover != null)
                    ClipRRect(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.network(
                            video.cover!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Center(child: Icon(Icons.video_library, color: Colors.grey)),
                          ),
                          if (appState.privacyMode)
                            Positioned.fill(
                              child: BackdropFilter(
                                filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                                child: Container(color: Colors.transparent),
                              ),
                            ),
                        ],
                      ),
                    ),
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: Container(
                      padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(4)),
                      child: Text(video.duration ?? '', style: TextStyle(color: Colors.white, fontSize: 10)),
                    ),
                  ),
                  if (isSelected)
                    Positioned(top: 4, right: 4, child: Icon(Icons.check_circle, color: Colors.blue)),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(video.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12)),
                  if (video.author != null) ...[
                    SizedBox(height: 2),
                    Text(video.author!, style: TextStyle(fontSize: 10, color: Colors.grey)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Map<String, String> _getTypeNames(String siteType) {
    return siteType == 'porn91' ? _typeNamesPorn91 : _typeNamesOriginal;
  }

  Widget _buildBottomPageNavigation() {
    final appState = Provider.of<AppState>(context, listen: false);
    final isDark = appState.isDarkMode;
    return Positioned(
      bottom: 16,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: isDark ? Colors.grey[850] : Colors.white.withOpacity(0.95),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 8, offset: Offset(0, 2))],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '第$_loadedPage页',
                style: TextStyle(fontSize: 12, color: isDark ? Colors.white70 : Colors.grey[800], fontWeight: FontWeight.w500),
              ),
              SizedBox(width: 12),
              GestureDetector(
                onTap: (_isLoading || _isLoadingMore || _loadedPage <= 1) ? null : () => _goToPageDirect(_loadedPage - 1),
                child: Container(
                  padding: EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: (_loadedPage <= 1) ? (isDark ? Colors.grey[700] : Colors.grey[300]) : (isDark ? Colors.blue[900] : Colors.blue[100]),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.arrow_left, size: 18, color: (_loadedPage <= 1) ? Colors.grey[500] : (isDark ? Colors.blue[300] : Colors.blue[700])),
                ),
              ),
              SizedBox(width: 8),
              Container(
                width: 60,
                height: 28,
                decoration: BoxDecoration(
                  color: isDark ? Colors.grey[800] : Colors.grey[100],
                  border: Border.all(color: isDark ? Colors.grey[700]! : Colors.grey[400]!),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: TextField(
                  controller: _pageController,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: isDark ? Colors.white70 : Colors.black87),
                  decoration: InputDecoration(
                    hintText: '回车',
                    hintStyle: TextStyle(fontSize: 10, color: isDark ? Colors.grey[500] : Colors.grey[600]),
                    contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  onSubmitted: (_) => _goToPage(),
                  textInputAction: TextInputAction.go,
                ),
              ),
              SizedBox(width: 8),
              GestureDetector(
                onTap: (_isLoading || _isLoadingMore) ? null : () => _goToPageDirect(_loadedPage + 1),
                child: Container(
                  padding: EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: isDark ? Colors.blue[900] : Colors.blue[100],
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.arrow_right, size: 18, color: isDark ? Colors.blue[300] : Colors.blue[700]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _goToPageDirect(int targetPage) async {
    if (targetPage < 1) return;
    _pageController.text = targetPage.toString();
    await _goToPage();
  }

  Future<void> _goToPage() async {
    final targetPage = int.tryParse(_pageController.text) ?? 1;
    if (targetPage < 1) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('请输入有效的页码')));
      return;
    }
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) {
      setState(() => _status = '请先选择站点');
      return;
    }

    setState(() {
      _status = '加载中...';
      _isLoading = true;
      _videos.clear();
      _selectedIds.clear();
      _hasMore = true;
    });

    final videos = await crawler.getVideoList(_selectedType, targetPage);
    setState(() {
      _videos = videos;
      _totalVideos = videos.length;
      _loadedPage = targetPage;
      _currentPage = targetPage;
      _isLoading = false;
      _status = videos.isEmpty ? '无结果' : '就绪';
      _hasMore = videos.length >= 24;
    });
    _scrollToTop();
  }

  Future<void> _startDownload() async {
    final appState = context.read<AppState>();
    final selectedVideos = _videos.where((v) => _selectedIds.contains(v.id)).toList();
    for (final video in selectedVideos) {
      appState.downloadManager.addTask(video);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已添加 ${selectedVideos.length} 个视频到下载队列'),
          action: SnackBarAction(label: '查看', onPressed: () => appState.navigateToPage?.call(2)),
        ),
      );
    }
    setState(() => _selectedIds.clear());
  }
}

// ════════════════════════════════════════════════════════════
//  核心：自定义 SliverPersistentHeaderDelegate
//  替换原有 SliverAppBar + flexibleSpace 实现滚动折叠动画
// ════════════════════════════════════════════════════════════
class _BatchHeaderDelegate extends SliverPersistentHeaderDelegate {
  final double statusBarHeight;
  final double expandedHeight;
  final double collapsedHeight;
  final double collapseRatio;
  final String selectedType;
  final Map<String, String> typeNames;
  final int videoCount;
  final int selectedCount;
  final int totalCount;
  final String status;
  final bool privacyMode;
  final ValueChanged<String?> onTypeChanged;
  final VoidCallback onPrivacyToggle;
  final VoidCallback onSelectAll;

  const _BatchHeaderDelegate({
    required this.statusBarHeight,
    required this.expandedHeight,
    required this.collapsedHeight,
    required this.collapseRatio,
    required this.selectedType,
    required this.typeNames,
    required this.videoCount,
    required this.selectedCount,
    required this.totalCount,
    required this.status,
    required this.privacyMode,
    required this.onTypeChanged,
    required this.onPrivacyToggle,
    required this.onSelectAll,
  });

  @override
  double get minExtent => statusBarHeight + collapsedHeight;
  @override
  double get maxExtent => statusBarHeight + expandedHeight;

  @override
  Widget build(BuildContext ctx, double shrinkOffset, bool overlapsContent) {
    final screenWidth = MediaQuery.of(ctx).size.width;
    final isDark = Theme.of(ctx).brightness == Brightness.dark;
    
    // 计算列表选择器的位置
    // 展开时 (collapseRatio=0)：左侧居中
    // 收起时 (collapseRatio=1)：左上角
    final chipWidth = 140.0; // 估算选择器宽度
    final chipLeftExpanded = 60.0;  // 展开时：左侧留出空间
    final chipLeftCollapsed = 16.0;  // 收起时：左上角
    final chipLeft = chipLeftExpanded + (chipLeftCollapsed - chipLeftExpanded) * collapseRatio;
    
    final chipTopExpanded = 75.0;   // 展开时：标题下方
    final chipTopCollapsed = 12.0;  // 收起时：顶部
    final chipTop = chipTopExpanded + (chipTopCollapsed - chipTopExpanded) * collapseRatio;
    
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          color: Colors.black.withOpacity(0.75),
          child: Column(
            children: [
              SizedBox(height: statusBarHeight),
              
              // ── 主内容区 ──
              Expanded(
                child: Stack(
                  children: [
                    // ── 标题和副标题：展开时显示，收起时淡出 ──
                    Opacity(
                      opacity: 1.0 - collapseRatio,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 8),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Text(
                              '批量爬取',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Text(
                              '已加载 $videoCount 个视频',
                              style: const TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                          ),
                        ],
                      ),
                    ),
                    
                    // ── 列表选择器：从居中滑动到左上角 ──
                    Positioned(
                      left: chipLeft,
                      top: chipTop,
                      child: _buildTypeChip(ctx, isDark),
                    ),
                    
                    // ── 右侧按钮：始终可见 ──
                    Positioned(
                      right: 16,
                      top: 8,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 已选数量
                          if (selectedCount > 0)
                            Container(
                              margin: const EdgeInsets.only(right: 8),
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
                          
                          // 全选按钮
                          if (selectedCount > 0)
                            GestureDetector(
                              onTap: onSelectAll,
                              child: Container(
                                margin: const EdgeInsets.only(right: 8),
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
                          
                          // 就绪标签
                          Container(
                            margin: const EdgeInsets.only(right: 8),
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
                          
                          // 隐私按钮
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
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  // 列表选择器组件 - 支持下拉点击
  Widget _buildTypeChip(BuildContext ctx, bool isDark) {
    final dropdownBg = isDark ? const Color(0xFF252525) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black87;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF252525) : Colors.white.withOpacity(0.95),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? const Color(0xFF333333) : Colors.grey[300]!,
          width: 0.5,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF4a9eff).withOpacity(0.1),
            blurRadius: 8,
            spreadRadius: 1,
          ),
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.list_alt, size: 16, color: const Color(0xFF4a9eff)),
          const SizedBox(width: 6),
          Theme(
            data: Theme.of(ctx).copyWith(canvasColor: dropdownBg),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: selectedType,
                isDense: true,
                icon: Icon(Icons.keyboard_arrow_down, size: 16, color: Colors.grey[600]),
                style: TextStyle(fontSize: 12, color: textColor),
                items: typeNames.entries.map((e) => DropdownMenuItem(
                  value: e.key,
                  child: Text(e.value, style: TextStyle(fontSize: 12, color: isDark ? Colors.grey[300] : Colors.black87)),
                )).toList(),
                onChanged: onTypeChanged,
                underline: const SizedBox(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(_BatchHeaderDelegate old) =>
      old.collapseRatio != collapseRatio ||
      old.selectedType != selectedType ||
      old.videoCount != videoCount ||
      old.selectedCount != selectedCount ||
      old.totalCount != totalCount ||
      old.status != status ||
      old.privacyMode != privacyMode;
}
