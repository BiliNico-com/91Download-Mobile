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
  int _loadedPage = 0;   // 已加载的页码（用于判断是否还有更多）
  bool _hasMore = true;  // 是否还有更多
  List<VideoInfo> _videos = [];
  Set<String> _selectedIds = {};
  bool _isLoading = false;
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
    
    // 自动加载更多（仅在滚动到接近底部时触发）
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      if (!_isLoading && _hasMore && _videos.isNotEmpty) {
        _loadMore();
      }
    }
  }
  
  void _scrollToTop() {
    _scrollController.animateTo(0, duration: Duration(milliseconds: 300), curve: Curves.easeOut);
  }
  
  /// 加载更多（下一页）
  Future<void> _loadMore() async {
    if (!_hasMore || _isLoading) return;
    
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) return;
    
    setState(() => _isLoading = true);
    
    _loadedPage++;
    
    final newVideos = await crawler.getVideoList(_selectedType, _loadedPage);
    
    if (newVideos.isEmpty) {
      _hasMore = false;
    } else {
      setState(() {
        _videos.addAll(newVideos);
        _totalVideos = _videos.length;
        // 如果返回结果少于每页数量，说明没有更多了
        if (newVideos.length < 24) {
          _hasMore = false;
        }
      });
    }
    
    setState(() => _isLoading = false);
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
          body: CustomScrollView(
            controller: _scrollController,
            slivers: [
              // AppBar - 添加毛玻璃效果
              SliverAppBar(
                pinned: true,
                floating: true,
                backgroundColor: Colors.transparent,
                elevation: 0,
                scrolledUnderElevation: 0,
                flexibleSpace: ClipRect(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Container(
                      color: Colors.black.withOpacity(0.5),
                    ),
                  ),
                ),
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('批量爬取'),
                    Text('已加载 ${_videos.length} 个视频', 
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
                actions: _buildAppBarActions(appState),
              ),
              // 列表选择栏（吸顶）
              SliverPersistentHeader(
                pinned: true,
                delegate: _StickySettingsDelegate(
                  child: _buildSettingsBar(appState),
                ),
              ),
              // 视频列表 - 使用 SliverFillRemaining 替代 SliverToBoxAdapter + SizedBox
              SliverFillRemaining(
                hasScrollBody: true,
                child: _buildVideoListContent(appState),
              ),
            ],
          ),
        );
      },
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
                        _hasMore = true;
                      });
                      await _loadMore();
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
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.15),
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 当前页显示
              if (_loadedPage > 0)
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '第$_loadedPage页',
                    style: TextStyle(fontSize: 12, color: Colors.blue, fontWeight: FontWeight.w500),
                  ),
                ),
              if (_loadedPage > 0) SizedBox(width: 12),
              // 分隔线
              Container(width: 1, height: 16, color: Theme.of(context).dividerColor.withOpacity(0.3)),
              SizedBox(width: 12),
              // 跳转页输入
              Text('跳转', style: TextStyle(fontSize: 12)),
              SizedBox(width: 8),
              SizedBox(
                width: 50,
                child: TextField(
                  controller: _pageController,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: Theme.of(context).scaffoldBackgroundColor,
                    isDense: true,
                  ),
                  onChanged: (v) {
                    _currentPage = int.tryParse(v) ?? 1;
                  },
                ),
              ),
              SizedBox(width: 8),
              // 跳转按钮
              Material(
                color: Colors.blue,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  onTap: _isLoading ? null : _goToPage,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: _isLoading 
                      ? SizedBox(width: 14, height: 14, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : Icon(Icons.arrow_forward, color: Colors.white, size: 16),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 跳转到指定页
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
    });
    
    final videos = await crawler.getVideoList(_selectedType, targetPage);
    
    setState(() {
      _videos = videos;
      _totalVideos = videos.length;
      _loadedPage = targetPage;
      _currentPage = targetPage;
      _isLoading = false;
      _status = videos.isEmpty ? '无结果' : '就绪';
      _hasMore = videos.length >= 24;  // 假设每页24个
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

  /// 视频列表内容（包含视频网格和悬浮按钮）
  Widget _buildVideoListContent(AppState appState) {
    return Stack(
      children: [
        _buildVideoGrid(),
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
      ],
    );
  }

  Widget _buildVideoGrid() {
    final appState = context.read<AppState>();
    final isListMode = appState.videoDisplayMode == 'list';
    
    // 初始加载时显示loading
    if (_isLoading && _videos.isEmpty) {
      return Center(child: CircularProgressIndicator());
    }
    
    // 无数据时显示提示
    if (_videos.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.video_library_outlined, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('输入页码并点击跳转', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }
    
    // 根据模式选择显示方式
    return isListMode ? _buildListView() : _buildGridView();
  }
  
  /// 列表模式
  Widget _buildListView() {
    final appState = context.read<AppState>();
    
    return ListView.builder(
      padding: EdgeInsets.all(8),
      itemCount: _videos.length,
      itemBuilder: (context, index) {
        final video = _videos[index];
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
                      height: 80,
                      color: Colors.grey[800],
                      child: video.cover != null
                        ? Stack(
                            children: [
                              Center(
                                child: Image.network(video.cover!, width: 120, height: 80, fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => Icon(Icons.play_circle, size: 32, color: Colors.white54)),
                              ),
                              // 毛玻璃模糊遮罩
                              if (appState.privacyMode)
                                Positioned.fill(
                                  child: BackdropFilter(
                                    filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                                    child: Container(
                                      color: Colors.black.withOpacity(0.3),
                                    ),
                                  ),
                                ),
                              // 选中标记（左上角，参考搜索页面）
                              if (isSelected)
                                Positioned(
                                  top: 4,
                                  left: 4,
                                  child: Container(
                                    padding: EdgeInsets.all(3),
                                    decoration: BoxDecoration(
                                      color: Colors.blue,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(Icons.check, color: Colors.white, size: 12),
                                  ),
                                ),
                              // 时长标签（右下角）
                              if (video.duration != null)
                                Positioned(
                                  bottom: 4,
                                  right: 4,
                                  child: Container(
                                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: Colors.black87,
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                    child: Text(
                                      video.duration!,
                                      style: TextStyle(color: Colors.white, fontSize: 9),
                                    ),
                                  ),
                                ),
                            ],
                          )
                        : Icon(Icons.play_circle, size: 32, color: Colors.white54),
                    ),
                  ),
                  SizedBox(width: 12),
                  // 信息：视频名称 + 作者（左上对齐，标题2行）
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: [
                        Text(
                          video.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                        ),
                        if (video.author != null && video.author!.isNotEmpty) ...[
                          SizedBox(height: 4),
                          Text(
                            video.author!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
  
  /// 大图模式（网格视图）
  Widget _buildGridView() {
    final appState = context.read<AppState>();
    const double childAspectRatio = 0.85;
    
    return GridView.builder(
      padding: EdgeInsets.all(8),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: childAspectRatio,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: _videos.length,
      itemBuilder: (context, index) {
        final video = _videos[index];
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
            clipBehavior: Clip.antiAlias,
            color: isSelected ? Colors.blue.withOpacity(0.2) : null,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 封面
                Positioned.fill(
                  child: video.cover != null
                    ? Image.network(video.cover!, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: Colors.grey[800],
                          child: Icon(Icons.play_circle, size: 48, color: Colors.white54),
                        ))
                    : Container(
                        color: Colors.grey[800],
                        child: Icon(Icons.play_circle, size: 48, color: Colors.white54),
                      ),
                ),
                // 毛玻璃模糊遮罩（仅模糊封面）
                if (appState.privacyMode)
                  Positioned.fill(
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                      child: Container(
                        color: Colors.black.withOpacity(0.3),
                      ),
                    ),
                  ),
                // 选中标记（右上角，在毛玻璃之上）
                if (isSelected)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      padding: EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.blue,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.check, color: Colors.white, size: 16),
                    ),
                  ),
                // 时长标签（右下角，在标题上方）
                if (video.duration != null)
                  Positioned(
                    bottom: 50,
                    right: 8,
                    child: Container(
                      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        video.duration!,
                        style: TextStyle(color: Colors.white, fontSize: 10),
                      ),
                    ),
                  ),
                // 标题和作者
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black.withOpacity(0.7)],
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          video.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                        if (video.author != null && video.author!.isNotEmpty) ...[
                          SizedBox(height: 2),
                          Text(
                            video.author!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: Colors.grey, fontSize: 10),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        boxShadow: [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 4,
            offset: Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: Row(
          children: [
            // 全选按钮
            if (_selectedIds.isNotEmpty)
              TextButton(
                onPressed: () {
                  final isAllSelected = _selectedIds.length == _videos.length;
                  setState(() {
                    if (isAllSelected) {
                      _selectedIds.clear();
                    } else {
                      _selectedIds = _videos.map((v) => v.id).toSet();
                    }
                  });
                },
                child: Text(_selectedIds.length == _videos.length ? '取消全选' : '全选'),
              ),
            Spacer(),
          ],
        ),
      ),
    );
  }

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

/// 吸顶列表选择栏的 Header Delegate
class _StickySettingsDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;

  _StickySettingsDelegate({required this.child});

  @override
  double get minExtent => 56.0;

  @override
  double get maxExtent => 56.0;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return child;
  }

  @override
  bool shouldRebuild(_StickySettingsDelegate oldDelegate) => child != oldDelegate.child;
}
