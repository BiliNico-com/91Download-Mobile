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
  
  // 滚动控制
  final ScrollController _scrollController = ScrollController();
  bool _showPageIndicator = false;
  bool _showBackToTop = false;
  
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
      if (!_isLoading && _hasMore && _results.isNotEmpty && !_isAuthorMode) {
        _loadMore();
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
    
    await logger.i('Search', '加载更多: 第 $_currentPage 页, 排序: $_sortBy');
    
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

  @override
  Widget build(BuildContext context) {
    super.build(context);  // 必须调用
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('搜索'),
            Text('通过关键词搜索并下载视频',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
        actions: [
          // 全选按钮（选中任意视频后显示）
          if (_selectedIds.isNotEmpty)
            IconButton(
              icon: Icon(
                _selectedIds.length == _results.length 
                  ? Icons.check_box 
                  : Icons.check_box_outline_blank,
                color: Colors.blue,
              ),
              onPressed: _toggleAll,
              tooltip: _selectedIds.length == _results.length ? '取消全选' : '全选',
            ),
          // 就绪状态按钮（功能与批量页一致）
          Container(
            margin: EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: _status == '就绪' ? Colors.green.withOpacity(0.2) : Colors.orange.withOpacity(0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Text(
                _status,
                style: TextStyle(
                  color: _status == '就绪' ? Colors.green : Colors.orange,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          SizedBox(width: 4),
          // 隐私模式按钮
          Consumer<AppState>(
            builder: (context, appState, _) {
              return IconButton(
                icon: Icon(
                  appState.privacyMode ? Icons.visibility_off : Icons.visibility,
                  color: appState.privacyMode ? Colors.red : Colors.grey,
                ),
                onPressed: () {
                  appState.togglePrivacyMode();
                  logger.i('Search', 'UI操作: 切换隐私模式 -> ${appState.privacyMode}');
                },
                tooltip: appState.privacyMode ? '取消模糊' : '模糊预览图',
              );
            },
          ),
        ],
      ),
      body: Column(
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
                _isLoading && _results.isEmpty
                    ? Center(child: CircularProgressIndicator())
                    : _isAuthorMode
                        ? _buildAuthorResults()
                        : _buildVideoResults(),
                
                // 悬浮下载按钮
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
                
                // 悬浮页码显示 + 回顶部按钮（与批量页一致，挨着且受按钮位置控制）
                Consumer<AppState>(
                  builder: (context, appState, _) {
                    if (!_showPageIndicator || !appState.showBackToTop) {
                      return SizedBox.shrink();
                    }
                    return Positioned(
                      bottom: 16,
                      left: appState.backToTopPosition == 'left' ? 16 : null,
                      right: appState.backToTopPosition == 'right' ? 16 : null,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 悬浮页码显示
                          if (_currentPage > 0 && !_isAuthorMode)
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
              ],
            ),
          ),
        ],
      ),
    );
  }
  
  /// 搜索区域（可收缩）
  Widget _buildSearchArea() {
    return Column(
      children: [
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
                // 全选按钮（仅在有结果时显示）
                if (_results.isNotEmpty)
                  TextButton(
                    onPressed: _toggleAll,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size(0, 32),
                    ),
                    child: Text(_selectedIds.length == _results.length ? '取消全选' : '全选'),
                  ),
                Spacer(),
                // 就绪状态
                if (_selectedIds.isNotEmpty)
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '已选 ${_selectedIds.length} 个',
                      style: TextStyle(fontSize: 12, color: Colors.blue),
                    ),
                  ),
                SizedBox(width: 8),
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

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
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
    
    await logger.i('Search', '跳转到第 $page 页');
    
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
    
    await logger.i('Search', 'UI操作: 点击搜索按钮, 关键词: ${_keywordController.text}, 作者模式: $_isAuthorMode, 排序: $_sortBy');
    
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) {
      await logger.w('Search', '爬虫为空, 请先选择站点');
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
      await logger.d('Search', '开始搜索作者...');
      final authors = await crawler.searchAuthors(_keywordController.text);
      await logger.i('Search', '作者搜索完成, 结果数: ${authors.length}');
      
      setState(() {
        _authorResults = authors;
        _isLoading = false;
        _status = authors.isEmpty ? '无结果' : '就绪';
      });
    } else {
      // 搜索视频
      await logger.d('Search', '开始搜索视频...');
      final results = await crawler.searchVideos(_keywordController.text);
      await logger.i('Search', '视频搜索完成, 结果数: ${results.length}');
      
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
    
    if (_results.isEmpty) {
      return Center(child: Text('输入关键词搜索', style: TextStyle(color: Colors.grey)));
    }
    
    return isListMode ? _buildVideoListResults() : _buildVideoGridResults();
  }
  
  /// 列表模式显示视频结果
  Widget _buildVideoListResults() {
    return Consumer<AppState>(
      builder: (context, appState, _) {
        return ListView.builder(
          controller: _scrollController,
          padding: EdgeInsets.all(8),
          itemCount: _results.length + (_hasMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == _results.length) {
              return Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(),
                ),
              );
            }
            
            final video = _results[index];
            final selected = _selectedIds.contains(video.id);
            
            return GestureDetector(
              onTap: () => _toggleSelection(video.id),
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
                      // 信息：视频名称 - 作者
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              video.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                            ),
                            if (video.author != null && video.author!.isNotEmpty) [
                              SizedBox(height: 4),
                              Text(
                                video.author!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12, color: Colors.grey),
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
  
  /// 大图模式显示视频结果
  Widget _buildVideoGridResults() {
    return Consumer<AppState>(
      builder: (context, appState, _) {
        return GridView.builder(
          controller: _scrollController,
          padding: EdgeInsets.all(8),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            childAspectRatio: 0.75,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: _results.length + (_hasMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == _results.length) {
              return Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(),
                ),
              );
            }
            
            final video = _results[index];
            final selected = _selectedIds.contains(video.id);
            
            return GestureDetector(
              onTap: () => _toggleSelection(video.id),
              child: Card(
                clipBehavior: Clip.antiAlias,
                color: selected ? Colors.blue.withOpacity(0.2) : null,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    video.cover != null
                        ? Image.network(video.cover!, fit: BoxFit.cover)
                        : Icon(Icons.video_file, size: 50, color: Colors.grey),
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
                    // 选中标记
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
                    // 时长标签
                    if (video.duration != null)
                      Positioned(
                        bottom: 50,
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
                            if (video.author != null && video.author!.isNotEmpty) [
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
            onTap: () {
              // TODO: 跳转到作者视频列表
              logger.i('Search', '点击作者: ${author.name}');
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('作者: ${author.name}')),
              );
            },
          ),
        );
      },
    );
  }
  
  /// 下载选中的视频
  Future<void> _download() async {
    if (_selectedIds.isEmpty) return;
    
    await logger.i('Search', 'UI操作: 点击下载按钮, 选中 ${_selectedIds.length} 个视频');
    
    final appState = context.read<AppState>();
    
    // 获取选中的视频
    final selectedVideos = _results.where((v) => _selectedIds.contains(v.id)).toList();
    
    await logger.i('Search', '添加 ${selectedVideos.length} 个视频到下载队列');
    
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
