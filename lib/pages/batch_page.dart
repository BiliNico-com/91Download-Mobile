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
  int _currentPage = 1;  // 当前输入的页码
  int _loadedPage = 0;   // 已加载的页码
  bool _hasMore = true;  // 是否还有更多（瀑布流用）
  List<VideoInfo> _videos = [];
  Set<String> _selectedIds = {};
  bool _isLoading = false;
  bool _isLoadingMore = false;  // 瀑布流加载状态（独立于翻页加载）
  String _status = '就绪';
  double _progress = 0.0;
  String _progressText = '';
  int _totalVideos = 0;  // 总视频数（用于显示"共Y页"的估算）
  
  // 滚动控制
  final ScrollController _scrollController = ScrollController();
  bool _showBackToTop = false;
  final TextEditingController _pageController = TextEditingController();
  
  @override
  bool get wantKeepAlive => true;  // 保持页面状态
  
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
    // 显示/隐藏回顶部按钮
    final showBtn = _scrollController.offset > 500;
    if (showBtn != _showBackToTop) {
      setState(() => _showBackToTop = showBtn);
    }
    
    // 瀑布流：滚动到底部自动加载下一页
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      if (!_isLoading && !_isLoadingMore && _hasMore && _videos.isNotEmpty) {
        _loadMore();
      }
    }
  }
  
  /// 瀑布流加载更多（追加到现有列表）
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
        _hasMore = newVideos.length >= 24;  // 每页24个，少于则没有更多
        _isLoadingMore = false;
      });
    }
  }
  
  void _scrollToTop() {
    _scrollController.animateTo(0, duration: Duration(milliseconds: 300), curve: Curves.easeOut);
  }
  
  
  // porn91 站点的列表类型（完整12个分类）
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
  
  // original 站点的列表类型
  static const _typeNamesOriginal = {
    'list': '视频',
    'top7': '周榜',
    'top': '月榜',
    '5min': '5分钟+',
    'long': '10分钟+',
  };
  
  @override
  Widget build(BuildContext context) {
    super.build(context);  // 必须调用，用于 AutomaticKeepAliveClientMixin
    return Consumer<AppState>(
      builder: (context, appState, _) {
        // 记录批量页面状态
        Future.microtask(() {
        });
        
        // 检查是否已选择站点
        if (!appState.isSiteSelected) {
          return _buildNoSiteSelected();
        }
        
        return _buildMainContent();
      },
    );
  }
  
  Widget _buildNoSiteSelected() {
    // 记录用户看到了"请先选择站点"提示
    Future.microtask(() {
    });
    
    return Scaffold(
      appBar: AppBar(
        title: Text('批量爬取'),
      ),
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
            Text('← 左滑到设置页面选择站点', 
              style: TextStyle(fontSize: 14, color: Colors.blue)),
          ],
        ),
      ),
    );
  }
  
  Widget _buildMainContent() {
    return Consumer<AppState>(
      builder: (context, appState, _) {
        return Scaffold(
          extendBodyBehindAppBar: true,
          body: Stack(
            children: [
              CustomScrollView(
                controller: _scrollController,
                slivers: [
                  // AppBar + 标签栏一体化，滚动时标题隐藏，标签栏吸附到顶部
                  SliverAppBar(
                    pinned: true,
                    floating: true,
                    snap: false,
                    expandedHeight: 112, // AppBar(56) + 标签栏(56)
                    backgroundColor: Colors.transparent,
                    elevation: 0,
                    scrolledUnderElevation: 0,
                    flexibleSpace: LayoutBuilder(
                      builder: (context, constraints) {
                        final expandRatio = ((constraints.maxHeight - 56) / 56).clamp(0.0, 1.0);
                        final isExpanded = expandRatio > 0.5;
                    
                    return ClipRect(
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                        child: Container(
                          color: Colors.black.withOpacity(0.5),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // 标题区域（滚动时隐藏）
                              AnimatedOpacity(
                                opacity: isExpanded ? 1.0 : 0.0,
                                duration: Duration(milliseconds: 150),
                                child: Container(
                                  height: 56,
                                  padding: EdgeInsets.only(left: 16, right: 8),
                                  child: Row(
                                    children: [
                                      Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text('批量爬取', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500)),
                                          Text('已加载 ${_videos.length} 个视频', 
                                            style: TextStyle(fontSize: 12, color: Colors.grey)),
                                        ],
                                      ),
                                      Spacer(),
                                      ..._buildAppBarActions(appState),
                                    ],
                                  ),
                                ),
                              ),
                              // 标签栏（始终可见）
                              Container(
                                height: 56,
                                color: Theme.of(context).scaffoldBackgroundColor.withOpacity(0.95),
                                child: _buildSettingsBar(appState),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              // 视频列表 - 使用 SliverGrid 直接渲染
              SliverPadding(
                padding: EdgeInsets.all(8),
                sliver: _buildSliverVideoGrid(appState),
              ),
              // 底部留白给翻页控件和浮动按钮
              SliverToBoxAdapter(
                child: SizedBox(height: 100),
              ),
            ],
          ),
          // 翻页控件和浮动按钮覆盖在上面
          ..._buildOverlays(appState),
        ],
      ),
    );
    },
  );
  }

  /// 覆盖层：翻页控件 + 浮动按钮
  List<Widget> _buildOverlays(AppState appState) {
    return [
      // 页码跳转悬浮胶囊
      _buildBottomPageNavigation(),
      // 回顶部按钮
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
      // 下载按钮
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

  /// SliverGrid 视频列表
  Widget _buildSliverVideoGrid(AppState appState) {
    final isListMode = appState.videoDisplayMode == 'list';
    
    // 初始加载时显示loading
    if (_isLoading && _videos.isEmpty) {
      return SliverToBoxAdapter(
        child: Center(child: CircularProgressIndicator()),
      );
    }
    
    // 无数据时显示提示
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

  /// 列表模式的单个视频项
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
              // 缩略图
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
                      // 时长
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: Container(
                          padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            video.duration ?? '',
                            style: TextStyle(color: Colors.white, fontSize: 10),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(width: 12),
              // 标题和作者
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      video.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14),
                    ),
                    if (video.author != null) ...[
                      SizedBox(height: 4),
                      Text(
                        video.author!,
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ],
                ),
              ),
              // 选中标记
              if (isSelected)
                Icon(Icons.check_circle, color: Colors.blue),
            ],
          ),
        ),
      ),
    );
  }

  /// 网格模式的单个视频项
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
            // 缩略图
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(color: Colors.grey[800]),
                  if (video.cover != null)
                    Image.network(
                      video.cover!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Center(
                        child: Icon(Icons.video_library, color: Colors.grey),
                      ),
                    ),
                  // 时长
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: Container(
                      padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        video.duration ?? '',
                        style: TextStyle(color: Colors.white, fontSize: 10),
                      ),
                    ),
                  ),
                  // 选中标记
                  if (isSelected)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Icon(Icons.check_circle, color: Colors.blue),
                    ),
                ],
              ),
            ),
            // 标题
            Padding(
              padding: EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    video.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12),
                  ),
                  if (video.author != null) ...[
                    SizedBox(height: 2),
                    Text(
                      video.author!,
                      style: TextStyle(fontSize: 10, color: Colors.grey),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  List<Widget> _buildAppBarActions(AppState appState) {
    return [
      // 已选数量
      if (_selectedIds.isNotEmpty)
        Container(
          margin: EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.blue.withOpacity(0.2),
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: Text(
            '已选 ${_selectedIds.length} 个',
            style: TextStyle(color: Colors.blue, fontSize: 12),
          ),
        ),
      // 全选勾选框
      if (_selectedIds.isNotEmpty)
        GestureDetector(
          onTap: () {
            final isAllSelected = _selectedIds.length == _videos.length;
            setState(() {
              if (isAllSelected) {
                _selectedIds.clear();
              } else {
                _selectedIds = _videos.map((v) => v.id).toSet();
              }
            });
          },
          child: Container(
            margin: EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            padding: EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: _selectedIds.length == _videos.length 
                  ? Colors.blue 
                  : Theme.of(context).scaffoldBackgroundColor,
              borderRadius: BorderRadius.circular(8),
              border: _selectedIds.length == _videos.length 
                  ? null 
                  : Border.all(color: Colors.blue, width: 2),
            ),
            child: Icon(
              Icons.check,
              color: _selectedIds.length == _videos.length 
                  ? Colors.white 
                  : Colors.blue,
              size: 20,
            ),
          ),
        ),
      // 就绪按钮
      Container(
        margin: EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: _status == '就绪' ? Colors.green.withOpacity(0.2) : Colors.orange.withOpacity(0.2),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          _status,
          style: TextStyle(
            color: _status == '就绪' ? Colors.green : Colors.orange,
            fontSize: 12,
          ),
        ),
      ),
      SizedBox(width: 4),
      // 隐私按钮
      IconButton(
        icon: Icon(
          appState.privacyMode ? Icons.visibility_off : Icons.visibility,
          color: appState.privacyMode ? Colors.red : Colors.grey,
        ),
        onPressed: () {
          appState.togglePrivacyMode();
        },
        tooltip: appState.privacyMode ? '取消模糊' : '模糊预览图',
      ),
    ];
  }
  
  /// 列表选择栏（吸顶内容）
  Widget _buildSettingsBar(AppState appState) {
    final siteType = appState.crawler?.siteType ?? "original";
    final typeNames = _getTypeNames(siteType);
    
    // 站点切换后，检查当前选择的类型是否有效
    if (!typeNames.containsKey(_selectedType)) {
      _selectedType = 'list';
    }
    
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Center(
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 8,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.list_alt, size: 18, color: Colors.blue),
              SizedBox(width: 8),
              Text('列表: ', style: TextStyle(fontSize: 14)),
              DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _selectedType,
                  isDense: true,
                  icon: Icon(Icons.keyboard_arrow_down, size: 18),
                  items: typeNames.entries.map((e) {
                    return DropdownMenuItem(value: e.key, child: Text(e.value, style: TextStyle(fontSize: 14)));
                  }).toList(),
                  onChanged: (v) async {
                    if (v != null && v != _selectedType) {
                      setState(() {
                        _selectedType = v;
                        _videos.clear();
                        _selectedIds.clear();
                        _loadedPage = 0;
                      });
                      // 加载第一页
                      _pageController.text = '1';
                      await _goToPage();
                    }
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 根据站点类型获取列表选项
  Map<String, String> _getTypeNames(String siteType) {
    return siteType == "porn91" ? _typeNamesPorn91 : _typeNamesOriginal;
  }
  
  /// 底部页码跳转区域（悬浮胶囊）
  Widget _buildBottomPageNavigation() {
    return Positioned(
      bottom: 16,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.grey.withOpacity(0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 当前页显示
              Text(
                '第$_loadedPage页',
                style: TextStyle(fontSize: 12, color: Colors.grey[700]),
              ),
              SizedBox(width: 12),
              // 上一页按钮
              GestureDetector(
                onTap: (_isLoading || _isLoadingMore || _loadedPage <= 1) 
                  ? null 
                  : () => _goToPageDirect(_loadedPage - 1),
                child: Icon(
                  Icons.arrow_left,
                  size: 20,
                  color: (_loadedPage <= 1) ? Colors.grey[400] : Colors.black,
                ),
              ),
              SizedBox(width: 8),
              // 跳转页输入框
              Container(
                width: 60,
                height: 28,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.withOpacity(0.3)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: TextField(
                  controller: _pageController,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    hintText: '回车跳转',
                    hintStyle: TextStyle(fontSize: 10, color: Colors.grey[400]),
                    contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  onSubmitted: (_) => _goToPage(),
                  textInputAction: TextInputAction.go,
                ),
              ),
              SizedBox(width: 8),
              // 下一页按钮
              GestureDetector(
                onTap: (_isLoading || _isLoadingMore) ? null : () => _goToPageDirect(_loadedPage + 1),
                child: Icon(
                  Icons.arrow_right,
                  size: 20,
                  color: Colors.black,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 跳转到指定页
  /// 直接跳转到指定页（通过上一页/下一页按钮调用）
  Future<void> _goToPageDirect(int targetPage) async {
    if (targetPage < 1) return;
    
    _pageController.text = targetPage.toString();
    await _goToPage();
  }

  Future<void> _goToPage() async {
    final targetPage = int.tryParse(_pageController.text) ?? 1;
    if (targetPage < 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('请输入有效的页码')),
      );
      return;
    }
    
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) {
      setState(() {
        _status = '请先选择站点';
      });
      return;
    }
    
    setState(() {
      _status = '加载中...';
      _isLoading = true;
      _videos.clear();
      _selectedIds.clear();
      _hasMore = true;  // 重置，允许瀑布流继续加载
    });
    
    final videos = await crawler.getVideoList(_selectedType, targetPage);
    
    setState(() {
      _videos = videos;
      _totalVideos = videos.length;
      _loadedPage = targetPage;
      _currentPage = targetPage;
      _isLoading = false;
      _status = videos.isEmpty ? '无结果' : '就绪';
      _hasMore = videos.length >= 24;  // 每页24个
    });
    
    // 滚动到顶部
    _scrollToTop();
  }

  Widget _buildProgress() {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          LinearProgressIndicator(value: _progress),
          SizedBox(height: 4),
          Text(_progressText, style: TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      ),
    );
  }

  /// 开始下载选中的视频
  Future<void> _startDownload() async {
    final appState = context.read<AppState>();
    
    // 获取选中的视频
    final selectedVideos = _videos.where((v) => _selectedIds.contains(v.id)).toList();
    
    // 添加到下载管理器
    for (final video in selectedVideos) {
      appState.downloadManager.addTask(video);
    }
    
    // 显示提示
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已添加 ${selectedVideos.length} 个视频到下载队列'),
          action: SnackBarAction(
            label: '查看',
            onPressed: () {
              // 切换到下载页面（索引2）
              appState.navigateToPage?.call(2);
            },
          ),
        ),
      );
    }
    
    // 清空选择
    setState(() {
      _selectedIds.clear();
    });
  }
}
