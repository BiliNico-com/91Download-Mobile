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
    // 显示页码指示器和回顶部按钮
    final showIndicator = _scrollController.offset > 300;
    if (showIndicator != _showPageIndicator) {
      setState(() {
        _showPageIndicator = showIndicator;
        _showBackToTop = showIndicator;
      });
    }
    
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
                  // 排序选择
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
          
          // 结果列表
          Expanded(
            child: Stack(
              children: [
                _isLoading && _results.isEmpty
                    ? Center(child: CircularProgressIndicator())
                    : _isAuthorMode
                        ? _buildAuthorResults()
                        : _buildVideoResults(),
                
                // 回顶部按钮
                if (_showBackToTop)
                  Positioned(
                    bottom: 80,
                    right: 16,
                    child: FloatingActionButton(
                      mini: true,
                      onPressed: _scrollToTop,
                      child: Icon(Icons.arrow_upward),
                    ),
                  ),
                // 悬浮页码显示（在回顶部上方）
                if (_showPageIndicator && _currentPage > 0 && !_isAuthorMode)
                  Positioned(
                    bottom: 140,
                    right: 16,
                    child: Container(
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
                  ),
              ],
            ),
          ),
          
          // 底部操作栏
          if (_results.isNotEmpty)
            Container(
              padding: EdgeInsets.all(16),
              child: Row(
                children: [
                  // 只有选中了视频才显示全选按钮
                  if (_selectedIds.isNotEmpty)
                    TextButton(
                      onPressed: _toggleAll,
                      child: Text(_selectedIds.length == _results.length ? '取消全选' : '全选'),
                    ),
                  Spacer(),
                  FilledButton(
                    onPressed: _selectedIds.isEmpty ? null : _download,
                    child: Text('下载 (${_selectedIds.length})'),
                  ),
                ],
              ),
            ),
        ],
      ),
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
    
    await logger.i('Search', 'UI操作: 点击搜索按钮, 关键词: ${_keywordController.text}, 作者模式: $_isAuthorMode, 排序: $_sortBy');
    
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) {
      await logger.w('Search', '爬虫为空, 请先选择站点');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('请先在设置页选择站点')),
      );
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
    final appState = context.read<AppState>();
    
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
                                  errorBuilder: (_, __, ___) => Icon(Icons.video_file, size: 32, color: Colors.white54)),
                              ),
                              // 模糊遮罩
                              if (appState.privacyMode)
                                Positioned.fill(
                                  child: Container(
                                    color: Colors.black.withOpacity(0.95),
                                  ),
                                ),
                            ],
                          )
                        : Icon(Icons.video_file, size: 32, color: Colors.white54),
                    ),
                  ),
                  SizedBox(width: 12),
                  // 信息 - 按图3标准：第一行视频名称+作者，第二行时长
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 第一行：视频名称 - 作者
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                video.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                              ),
                            ),
                            if (video.author != null && video.author!.isNotEmpty) ...[
                              SizedBox(width: 8),
                              Text(
                                '- ${video.author}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12, color: Colors.grey),
                              ),
                            ],
                          ],
                        ),
                        // 第二行：时长
                        if (video.duration != null) ...[
                          SizedBox(height: 4),
                          Text(
                            video.duration!,
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ],
                      ],
                    ),
                  ),
                  // 选中图标
                  selected 
                    ? Icon(Icons.check_circle, color: Colors.blue)
                    : Icon(Icons.circle_outlined, color: Colors.grey),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
  
  /// 大图模式显示视频结果
  Widget _buildVideoGridResults() {
    return GridView.builder(
      padding: EdgeInsets.all(8),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.75,
      ),
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final video = _results[index];
        final selected = _selectedIds.contains(video.id);
        
        return GestureDetector(
          onTap: () => _toggleSelection(video.id),
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                video.cover != null
                    ? Image.network(video.cover!, fit: BoxFit.cover)
                    : Icon(Icons.video_file, size: 50, color: Colors.grey),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.black.withOpacity(0.8), Colors.transparent],
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
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
                          style: TextStyle(fontSize: 12, color: Colors.white),
                        ),
                        if (video.author != null && video.author!.isNotEmpty)
                          Text(
                            video.author!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 10, color: Colors.white70),
                          ),
                      ],
                    ),
                  ),
                ),
                // 时长标签
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
                // 选中标记
                if (selected)
                  Positioned(
                    top: 4,
                    left: 4,
                    child: Container(
                      padding: EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.blue,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.check, color: Colors.white, size: 16),
                    ),
                  ),
              ],
            )
          )
        );
      },
    );
  }
  
  /// 构建作者搜索结果
  Widget _buildAuthorResults() {
    if (_authorResults.isEmpty) {
      return Center(child: Text('输入关键词搜索作者', style: TextStyle(color: Colors.grey)));
    }
    
    return ListView.builder(
      padding: EdgeInsets.all(16),
      itemCount: _authorResults.length,
      itemBuilder: (context, index) {
        final author = _authorResults[index];
        return Card(
          child: ListTile(
            leading: CircleAvatar(
              child: Icon(Icons.person),
            ),
            title: Text(author.name),
            subtitle: Text('视频数: ${author.videoCount}'),
            trailing: Icon(Icons.arrow_forward_ios, size: 16),
            onTap: () => _showAuthorVideos(author),
          ),
        );
      },
    );
  }
  
  /// 显示作者的所有视频
  void _showAuthorVideos(AuthorInfo author) async {
    await logger.i('Search', '点击作者: ${author.name}');
    
    // TODO: 跳转到作者视频列表页或弹窗显示
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('作者功能开发中: ${author.name} (${author.videoCount}个视频)')),
      );
    }
  }

  void _download() async {
    await logger.i('Search', 'UI操作: 点击下载按钮, 选中 ${_selectedIds.length} 个视频');
    
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('请先在设置页选择站点')),
      );
      return;
    }
    
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
