import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_state.dart';
import '../models/video_info.dart';
import '../utils/logger.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> with AutomaticKeepAliveClientMixin {
  final _keywordController = TextEditingController();
  List<VideoInfo> _results = [];
  List<AuthorInfo> _authorResults = [];  // 作者搜索结果
  Set<String> _selectedIds = {};
  bool _isLoading = false;
  bool _isAuthorMode = false;
  
  // 分页相关
  int _currentPage = 1;
  bool _hasMore = true;
  String _lastKeyword = '';
  String _sortBy = 'default';  // default, new, hot
  
  // 作者主页模式相关
  bool _isAuthorPageMode = false;  // 是否在作者主页模式
  String _currentAuthorId = '';    // 当前作者ID
  String _currentAuthorName = '';  // 当前作者名称
  List<VideoInfo> _authorVideos = [];  // 作者视频列表
  int _authorCurrentPage = 0;
  bool _authorHasMore = true;
  
  // 滚动控制
  final ScrollController _scrollController = ScrollController();
  bool _showPageIndicator = false;
  bool _showBackToTop = false;
  double _appBarOpacity = 0.5;  // AppBar透明度（初始较透明）
  
  // 设置区域收缩控制（参考批量页面）
  bool _showSettings = true;  // 是否显示搜索区域
  double _lastScrollOffset = 0;  // 上次滚动位置
  String _status = '就绪';  // 就绪状态
  
  @override
  bool get wantKeepAlive => true;  // 保持页面状态
  
  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }
  
  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }
  
  void _onScroll() {
    final showIndicator = _scrollController.offset > 300;
    if (showIndicator != _showPageIndicator) {
      setState(() {
        _showPageIndicator = showIndicator;
        _showBackToTop = showIndicator;
      });
    }
    
    // 计算AppBar透明度（滚动80像素后几乎完全透明）
    final opacity = (0.5 - _scrollController.offset / 80).clamp(0.0, 0.5);
    if (opacity != _appBarOpacity) {
      setState(() => _appBarOpacity = opacity);
    }
    
    // 滚动时隐藏/显示设置区域（搜索部分）
    final currentOffset = _scrollController.offset;
    if (currentOffset > _lastScrollOffset && currentOffset > 100) {
      // 向下滚动，隐藏设置区域
      if (_showSettings) {
        setState(() => _showSettings = false);
      }
    } else if (currentOffset < _lastScrollOffset || currentOffset < 100) {
      // 向上滚动或接近顶部，显示设置区域
      if (!_showSettings) {
        setState(() => _showSettings = true);
      }
    }
    _lastScrollOffset = currentOffset;
    
    // 自动加载更多
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      if (!_isLoading && !_isAuthorMode) {
        if (_isAuthorPageMode && _authorHasMore) {
          _loadMoreAuthorVideos();
        } else if (!_isAuthorPageMode && _hasMore && _results.isNotEmpty) {
          _loadMore();
        }
      }
    }
  }
  
  void _scrollToTop() {
    _scrollController.animateTo(0, duration: Duration(milliseconds: 300), curve: Curves.easeOut);
  }
  
  Future<void> _loadMore() async {
    if (!_hasMore || _isLoading || _lastKeyword.isEmpty) return;
    
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) return;
    
    setState(() => _isLoading = true);
    _currentPage++;
    
    
    final newResults = await crawler.searchVideos(_lastKeyword, page: _currentPage, sort: _sortBy);
    
    if (newResults.isEmpty) {
      _hasMore = false;
    } else {
      setState(() {
        _results.addAll(newResults);
      });
    }
    
    setState(() => _isLoading = false);
  }

  /// 加载更多作者视频
  Future<void> _loadMoreAuthorVideos() async {
    if (!_authorHasMore || _isLoading || _currentAuthorId.isEmpty) return;
    
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) return;
    
    setState(() => _isLoading = true);
    _authorCurrentPage++;
    
    final newVideos = await crawler.getAuthorVideos(_currentAuthorId, page: _authorCurrentPage);
    
    if (newVideos.isEmpty) {
      _authorHasMore = false;
    } else {
      setState(() {
        _authorVideos.addAll(newVideos);
      });
    }
    
    setState(() => _isLoading = false);
  }

  /// 退出作者主页模式
  void _exitAuthorPageMode() {
    if (_isAuthorPageMode) {
      setState(() {
        _isAuthorPageMode = false;
        _authorVideos.clear();
        _authorCurrentPage = 0;
        _authorHasMore = true;
      });
    }
  }

  /// 进入作者主页模式
  Future<void> _enterAuthorPageMode(AuthorInfo author) async {
    setState(() {
      _isAuthorPageMode = true;
      _currentAuthorId = author.id;
      _currentAuthorName = author.name;
      _authorVideos.clear();
      _authorCurrentPage = 0;
      _authorHasMore = true;
    });
    await _loadMoreAuthorVideos();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);  // 必须调用
    
    return WillPopScope(
      onWillPop: () async {
        // 作者主页模式下拦截返回键
        if (_isAuthorPageMode) {
          _exitAuthorPageMode();
          return false;  // 不退出页面
        }
        return true;  // 正常返回
      },
      child: Scaffold(
        extendBodyBehindAppBar: true,  // 让内容延伸到AppBar下方
        appBar: AppBar(
          backgroundColor: Colors.transparent,  // 透明背景
          elevation: 0,
          scrolledUnderElevation: 0,
          flexibleSpace: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                color: Colors.black.withOpacity(_appBarOpacity * 0.5),
              ),
            ),
          ),
          // 左侧文字跟随透明度隐藏
          title: Opacity(
            opacity: _appBarOpacity,
            child: _isAuthorPageMode 
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('作者: $_currentAuthorName'),
                    Text('点击作者主页查看视频',
                        style: TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('搜索'),
                    Text('通过关键词搜索并下载视频',
                        style: TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
          ),
          // 右侧按钮保持不透明（只有隐藏搜索/设置区域时才显示）
          actions: [
          // 已选数量（居中显示）
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
          // 全选勾选框（添加背景避免被毛玻璃覆盖）
          if (_selectedIds.isNotEmpty)
            GestureDetector(
              onTap: _toggleAll,
              child: Container(
                margin: EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                padding: EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: _selectedIds.length == _results.length 
                      ? Colors.blue 
                      : Theme.of(context).scaffoldBackgroundColor.withOpacity(0.85),
                  borderRadius: BorderRadius.circular(8),
                  border: _selectedIds.length == _results.length 
                      ? null 
                      : Border.all(color: Colors.blue, width: 2),
                ),
                child: Icon(
                  Icons.check,
                  color: _selectedIds.length == _results.length 
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
          Consumer<AppState>(
            builder: (context, appState, _) {
              return IconButton(
                icon: Icon(
                  appState.privacyMode ? Icons.visibility_off : Icons.visibility,
                  color: appState.privacyMode ? Colors.red : Colors.grey,
                ),
                onPressed: () {
                  appState.togglePrivacyMode();
                },
                tooltip: appState.privacyMode ? '取消模糊' : '模糊预览图',
              );
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          // 视频列表（从顶部开始，延伸到AppBar下方）
          Column(
            children: [
              // 搜索框区域（可收缩）
              AnimatedContainer(
                duration: Duration(milliseconds: 200),
                height: _showSettings ? null : 0,
                child: _showSettings ? _buildSearchArea() : SizedBox.shrink(),
              ),
              // 结果列表
              Expanded(
                child: Stack(
                  children: [
                    _isLoading && (_results.isEmpty && _authorVideos.isEmpty)
                        ? Center(child: CircularProgressIndicator())
                        : _isAuthorMode && !_isAuthorPageMode
                            ? _buildAuthorResults()
                            : _buildVideoResults(),
                
                // 悬浮按钮组（页码在上，返回按钮在中间，回顶部按钮在下）
                Consumer<AppState>(
                  builder: (context, appState, _) {
                    if (!_showPageIndicator || !appState.showBackToTop) {
                      return SizedBox.shrink();
                    }
                    // 右下角且选中视频时，需要避开下载按钮
                    final isRight = appState.backToTopPosition == 'right';
                    final hasSelection = _selectedIds.isNotEmpty;
                    final bottomOffset = (isRight && hasSelection) ? 80.0 : 16.0;
                    
                    return Positioned(
                      bottom: bottomOffset,
                      left: appState.backToTopPosition == 'left' ? 16 : null,
                      right: appState.backToTopPosition == 'right' ? 16 : null,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: appState.backToTopPosition == 'left' 
                            ? CrossAxisAlignment.start 
                            : CrossAxisAlignment.end,
                        children: [
                          // 返回搜索按钮（仅作者主页模式）
                          if (_isAuthorPageMode)
                            GestureDetector(
                              onTap: _exitAuthorPageMode,
                              child: Container(
                                margin: EdgeInsets.only(bottom: 8),
                                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.blue,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.arrow_back, color: Colors.white, size: 16),
                                    SizedBox(width: 4),
                                    Text('返回搜索', style: TextStyle(color: Colors.white, fontSize: 12)),
                                  ],
                                ),
                              ),
                            ),
                          // 悬浮页码显示
                          if (!_isAuthorPageMode && _currentPage > 0 && !_isAuthorMode)
                            Container(
                              margin: EdgeInsets.only(bottom: 8),
                              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: Colors.black87,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Text(
                                '第 $_currentPage 页',
                                style: TextStyle(color: Colors.white, fontSize: 12),
                              ),
                            ),
                          // 作者页码显示
                          if (_isAuthorPageMode && _authorCurrentPage > 0)
                            Container(
                              margin: EdgeInsets.only(bottom: 8),
                              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: Colors.black87,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Text(
                                '第 $_authorCurrentPage 页',
                                style: TextStyle(color: Colors.white, fontSize: 12),
                              ),
                            ),
                          // 搜索按钮（搜索区域隐藏时显示）
                          if (!_showSettings)
                            GestureDetector(
                              onTap: () {
                                setState(() => _showSettings = true);
                                _scrollToTop();
                              },
                              child: Container(
                                margin: EdgeInsets.only(bottom: 8),
                                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.blue,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.search, color: Colors.white, size: 16),
                                    SizedBox(width: 4),
                                    Text('搜索', style: TextStyle(color: Colors.white, fontSize: 12)),
                                  ],
                                ),
                              ),
                            ),
                          // 回顶部按钮
                          FloatingActionButton(
                            mini: true,
                            heroTag: 'search_back_to_top',
                            onPressed: _scrollToTop,
                            child: Icon(Icons.arrow_upward),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                // 下载按钮（右下角，仅选中后显示）
                if (_selectedIds.isNotEmpty)
                  Positioned(
                    bottom: 16,
                    right: 16,
                    child: FloatingActionButton.extended(
                      onPressed: _download,
                      icon: Icon(Icons.download),
                      label: Text('下载 (${_selectedIds.length})'),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ],
  ),
),
  );
}
  
  /// 搜索区域（可收缩）
  Widget _buildSearchArea() {
    return Column(
      children: [
        // 顶部空间（避免被AppBar遮挡）
        SizedBox(height: kToolbarHeight + MediaQuery.of(context).padding.top),
        // 搜索框
        Padding(
          padding: EdgeInsets.all(16),
          child: Row(
            children: [
              // 模式切换
              DropdownButton<bool>(
                value: _isAuthorMode,
                items: [
                  DropdownMenuItem(value: false, child: Text('搜视频')),
                  DropdownMenuItem(value: true, child: Text('搜作者')),
                ],
                onChanged: (v) => setState(() => _isAuthorMode = v!),
              ),
              SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _keywordController,
                  decoration: InputDecoration(
                    hintText: '输入关键词...',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
              ),
              SizedBox(width: 8),
              FilledButton(
                onPressed: _search,
                child: Text('搜索'),
              ),
            ],
          ),
        ),
        
        // 排序和页码控制（仅在视频搜索模式显示）
        if (!_isAuthorMode)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Spacer(),
                // 排序选择（仅 original CMS 支持）
                Consumer<AppState>(
                  builder: (context, appState, _) {
                    final siteType = appState.crawler?.siteType ?? 'original';
                    if (siteType == 'porn91') {
                      return SizedBox.shrink();  // porn91 不支持排序
                    }
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('排序: ', style: TextStyle(fontSize: 12)),
                        DropdownButton<String>(
                          value: _sortBy,
                          isDense: true,
                          items: [
                            DropdownMenuItem(value: 'default', child: Text('默认')),
                            DropdownMenuItem(value: 'new', child: Text('最新')),
                            DropdownMenuItem(value: 'hot', child: Text('最热')),
                          ],
                          onChanged: (v) {
                            if (v != null && v != _sortBy) {
                              setState(() => _sortBy = v);
                              if (_lastKeyword.isNotEmpty) {
                                _search();
                              }
                            }
                          },
                        ),
                      ],
                    );
                  },
                ),
                Spacer(),
                // 页码跳转
                if (_currentPage > 0)
                  Row(
                    children: [
                      Text('页码: ', style: TextStyle(fontSize: 12)),
                      IconButton(
                        icon: Icon(Icons.first_page, size: 20),
                        onPressed: _currentPage > 1 ? () => _goToPage(1) : null,
                        padding: EdgeInsets.zero,
                        constraints: BoxConstraints(),
                      ),
                      IconButton(
                        icon: Icon(Icons.chevron_left, size: 20),
                        onPressed: _currentPage > 1 ? () => _goToPage(_currentPage - 1) : null,
                        padding: EdgeInsets.zero,
                        constraints: BoxConstraints(),
                      ),
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.blue.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('$_currentPage', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      ),
                      IconButton(
                        icon: Icon(Icons.chevron_right, size: 20),
                        onPressed: _hasMore ? () => _goToPage(_currentPage + 1) : null,
                        padding: EdgeInsets.zero,
                        constraints: BoxConstraints(),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        SizedBox(height: 8),
        Divider(height: 1),
      ],
    );
  }

  void _toggleAll() {
    setState(() {
      if (_selectedIds.length == _results.length) {
        _selectedIds.clear();
      } else {
        _selectedIds = _results.map((v) => v.id).toSet();
      }
    });
  }
  
  /// 跳转到指定页
  Future<void> _goToPage(int page) async {
    if (page < 1 || _lastKeyword.isEmpty) return;
    
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) return;
    
    setState(() {
      _isLoading = true;
      _currentPage = page;
      _results.clear();
      _selectedIds.clear();
    });
    
    
    final results = await crawler.searchVideos(_lastKeyword, page: page, sort: _sortBy);
    
    setState(() {
      _results = results;
      _hasMore = results.isNotEmpty;
      _isLoading = false;
    });
    
    // 滚动到顶部
    _scrollController.animateTo(0, duration: Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  Future<void> _search() async {
    if (_keywordController.text.isEmpty) return;
    
    setState(() {
      _status = '搜索中...';
    });
    
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) {
      setState(() {
        _status = '请先选择站点';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('请先在设置页选择站点')),
        );
      }
      return;
    }
    
    setState(() {
      _isLoading = true;
      _results.clear();
      _authorResults.clear();
      _selectedIds.clear();
      // 重置分页
      _currentPage = 1;
      _hasMore = true;
      _lastKeyword = _keywordController.text;
    });
    
    if (_isAuthorMode) {
      // 搜索作者
      final authors = await crawler.searchAuthors(_keywordController.text);
      
      setState(() {
        _authorResults = authors;
        _isLoading = false;
        _status = authors.isEmpty ? '无结果' : '就绪';
      });
    } else {
      // 搜索视频
      final results = await crawler.searchVideos(_keywordController.text, sort: _sortBy);
      
      setState(() {
        _results = results;
        _selectedIds.clear();  // 默认不全选
        _isLoading = false;
        _status = results.isEmpty ? '无结果' : '就绪';
      });
    }
  }

  /// 构建视频搜索结果
  Widget _buildVideoResults() {
    final appState = context.read<AppState>();
    final isListMode = appState.videoDisplayMode == 'list';
    
    // 作者主页模式使用 _authorVideos，普通模式使用 _results
    final videos = _isAuthorPageMode ? _authorVideos : _results;
    final hasMore = _isAuthorPageMode ? _authorHasMore : _hasMore;
    
    if (videos.isEmpty) {
      if (_isAuthorPageMode) {
        return Center(child: Text('加载中...', style: TextStyle(color: Colors.grey)));
      }
      return Center(child: Text('输入关键词搜索', style: TextStyle(color: Colors.grey)));
    }
    
    // 返回支持分页的视频列表组件
    return _VideoResultsWidget(
      videos: videos,
      selectedIds: _selectedIds,
      hasMore: hasMore,
      isListMode: isListMode,
      scrollController: _scrollController,
      onToggleSelection: _toggleSelection,
      onLoadMore: _isAuthorPageMode ? _loadMoreAuthorVideos : _loadMore,
      showSettings: _showSettings,
    );
  }
  
  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  /// 作者搜索结果
  Widget _buildAuthorResults() {
    if (_authorResults.isEmpty) {
      return Center(child: Text('输入作者名搜索', style: TextStyle(color: Colors.grey)));
    }
    
    return ListView.builder(
      controller: _scrollController,
      padding: EdgeInsets.all(8),
      itemCount: _authorResults.length,
      itemBuilder: (context, index) {
        final author = _authorResults[index];
        return Card(
          child: ListTile(
            leading: CircleAvatar(
              backgroundImage: author.avatar != null ? NetworkImage(author.avatar!) : null,
              child: author.avatar == null ? Icon(Icons.person) : null,
            ),
            title: Text(author.name),
            subtitle: Text(author.videoCount > 0 ? '视频数: ${author.videoCount}' : '点击查看视频'),
            trailing: Icon(Icons.chevron_right),
            onTap: () => _enterAuthorPageMode(author),
          ),
        );
      },
    );
  }
  
  /// 下载选中的视频
  Future<void> _download() async {
    if (_selectedIds.isEmpty) return;
    
    final appState = context.read<AppState>();
    
    // 获取选中的视频（支持作者主页模式）
    final currentVideos = _isAuthorPageMode ? _authorVideos : _results;
    final selectedVideos = currentVideos.where((v) => _selectedIds.contains(v.id)).toList();
    
    if (selectedVideos.isEmpty) return;
    
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

/// 视频结果组件（支持列表/网格模式）
class _VideoResultsWidget extends StatelessWidget {
  final List<VideoInfo> videos;
  final Set<String> selectedIds;
  final bool hasMore;
  final bool isListMode;
  final ScrollController scrollController;
  final Function(String) onToggleSelection;
  final VoidCallback? onLoadMore;
  final bool showSettings;  // 设置区域是否显示

  _VideoResultsWidget({
    required this.videos,
    required this.selectedIds,
    required this.hasMore,
    required this.isListMode,
    required this.scrollController,
    required this.onToggleSelection,
    this.onLoadMore,
    this.showSettings = true,
  });

  @override
  Widget build(BuildContext context) {
    return isListMode ? _buildListView(context) : _buildGridView(context);
  }

  Widget _buildListView(BuildContext context) {
    // 顶部padding：AppBar高度 + 状态栏高度（因为内容延伸到AppBar下方）
    // 如果设置区域显示，则不需要额外padding（设置区域已经有了）
    final topPadding = showSettings 
        ? 8.0 
        : kToolbarHeight + MediaQuery.of(context).padding.top + 8;
    
    return Consumer<AppState>(
      builder: (context, appState, _) {
        return ListView.builder(
          controller: scrollController,
          padding: EdgeInsets.only(left: 8, right: 8, top: topPadding, bottom: 8),
          itemCount: videos.length + (hasMore ? 1 : 0),
          itemBuilder: (context, index) {
            // 加载更多指示器（跨整行居中显示）
            if (index == videos.length) {
              return Container(
                height: 80,  // 固定高度
                alignment: Alignment.center,
                child: CircularProgressIndicator(),
              );
            }
            
            final video = videos[index];
            final selected = selectedIds.contains(video.id);
            
            return GestureDetector(
              onTap: () => onToggleSelection(video.id),
              child: Card(
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: Row(
                    children: [
                      // 缩略图 + 时长 + 选中标记
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
                                      errorBuilder: (_, __, ___) => Icon(Icons.video_file, size: 32, color: Colors.white54)),
                                  ),
                                  // 毛玻璃模糊遮罩
                                  if (appState.privacyMode)
                                    Positioned.fill(
                                      child: ClipRect(
                                        child: BackdropFilter(
                                          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                                          child: Container(
                                            color: Colors.black.withOpacity(0.3),
                                          ),
                                        ),
                                      ),
                                    ),
                                  // 选中标记（左上角）
                                  if (selected)
                                    Positioned(
                                      top: 4,
                                      left: 4,
                                      child: Container(
                                        padding: EdgeInsets.all(2),
                                        decoration: BoxDecoration(
                                          color: Colors.blue,
                                          shape: BoxShape.circle,
                                        ),
                                        child: Icon(Icons.check, size: 12, color: Colors.white),
                                      ),
                                    ),
                                  // 时长标签（右下角）
                                  if (video.duration != null)
                                    Positioned(
                                      bottom: 4,
                                      right: 4,
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
                                ],
                              )
                            : Icon(Icons.video_file, size: 32, color: Colors.white54),
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
      },
    );
  }

  Widget _buildGridView(BuildContext context) {
    // 顶部padding：AppBar高度 + 状态栏高度（因为内容延伸到AppBar下方）
    // 如果设置区域显示，则不需要额外padding（设置区域已经有了）
    final topPadding = showSettings 
        ? 8.0 
        : kToolbarHeight + MediaQuery.of(context).padding.top + 8;
    
    return Consumer<AppState>(
      builder: (context, appState, _) {
        return GridView.builder(
          controller: scrollController,
          padding: EdgeInsets.only(left: 8, right: 8, top: topPadding, bottom: 8),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            childAspectRatio: 0.75,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: videos.length + (hasMore ? 1 : 0),
          itemBuilder: (context, index) {
            // 加载更多指示器（跨整行居中显示）
            if (index == videos.length) {
              return Container(
                height: 80,  // 固定高度
                alignment: Alignment.center,
                child: CircularProgressIndicator(),
              );
            }
            
            final video = videos[index];
            final selected = selectedIds.contains(video.id);
            
            return GestureDetector(
              onTap: () => onToggleSelection(video.id),
              child: Card(
                clipBehavior: Clip.antiAlias,
                color: selected ? Colors.blue.withOpacity(0.2) : null,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    video.cover != null
                        ? Image.network(video.cover!, fit: BoxFit.cover)
                        : Icon(Icons.video_file, size: 50, color: Colors.grey),
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
                    if (selected)
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
                    // 时长标签（右下角，在标题上方，在毛玻璃之上）
                    if (video.duration != null)
                      Positioned(
                        bottom: 50,  // 在标题区域上方
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
      },
    );
  }
}
