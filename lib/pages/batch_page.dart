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
  int _pageStart = 1;
  int _pageEnd = 3;
  int _currentPage = 0;  // 当前加载到的页码
  bool _hasMore = true;  // 是否还有更多
  List<VideoInfo> _videos = [];
  Set<String> _selectedIds = {};
  bool _isLoading = false;
  String _status = '就绪';
  double _progress = 0.0;
  String _progressText = '';
  
  // 滚动控制
  final ScrollController _scrollController = ScrollController();
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
    // 显示/隐藏回顶部按钮
    final showBtn = _scrollController.offset > 500;
    if (showBtn != _showBackToTop) {
      setState(() => _showBackToTop = showBtn);
    }
    
    // 自动加载更多
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      if (!_isLoading && _hasMore && _videos.isNotEmpty) {
        _loadMore();
      }
    }
  }
  
  void _scrollToTop() {
    _scrollController.animateTo(0, duration: Duration(milliseconds: 300), curve: Curves.easeOut);
  }
  
  Future<void> _loadMore() async {
    if (!_hasMore || _isLoading) return;
    
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) return;
    
    setState(() => _isLoading = true);
    
    _currentPage++;
    await logger.i('Batch', '自动加载更多: 第 $_currentPage 页');
    
    final newVideos = await crawler.getVideoList(_selectedType, _currentPage);
    
    if (newVideos.isEmpty) {
      _hasMore = false;
    } else {
      setState(() {
        _videos.addAll(newVideos);
        // 不再自动全选
      });
    }
    
    setState(() => _isLoading = false);
  }
  
  // porn91 站点的列表类型（完整12个分类）
  static const _typeNamesPorn91 = {
    'list': '视频',
    'ori': '91原创',
    'hot': '当前最热',
    'topm': '本月最热',
    'top': '每月最热',
    'longer': '10分钟以上',
    'long': '20分钟以上',
    'rf': '本月收藏',
    'tf': '最近加精',
    'hd': '高清',
    'mf': '本月讨论',
    'md': '收藏最多',
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
          logger.d('Batch', 'build: isSiteSelected=${appState.isSiteSelected}, currentSite=${appState.currentSite}');
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
      logger.w('Batch', '当前未选择站点, 显示提示界面');
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
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('批量爬取'),
                Text('已加载 ${_videos.length} 个视频', 
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
            actions: [
              // 隐私模式按钮
              IconButton(
                icon: Icon(
                  appState.privacyMode ? Icons.visibility_off : Icons.visibility,
                  color: appState.privacyMode ? Colors.red : Colors.grey,
                ),
                onPressed: () {
                  appState.togglePrivacyMode();
                  logger.i('Batch', 'UI操作: 切换隐私模式 -> ${appState.privacyMode}');
                },
                tooltip: appState.privacyMode ? '取消模糊' : '模糊预览图',
              ),
              SizedBox(width: 8),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(_status, style: TextStyle(color: Colors.green)),
              ),
              SizedBox(width: 8),
            ],
          ),
          body: Stack(
            children: [
              Column(
                children: [
                  _buildSettings(),
                  Expanded(child: _buildVideoGrid()),
                  _buildBottomBar(),
                ],
              ),
              // 悬浮页码显示
              if (_showBackToTop && _currentPage > 0)
                Positioned(
                  bottom: appState.backToTopPosition == 'left' ? 16 : 80,
                  left: appState.backToTopPosition == 'left' ? null : 16,
                  right: appState.backToTopPosition == 'left' ? 80 : null,
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
              // 回顶部按钮
              if (_showBackToTop && appState.showBackToTop)
                Positioned(
                  bottom: 80,
                  left: appState.backToTopPosition == 'left' ? 16 : null,
                  right: appState.backToTopPosition == 'right' ? 16 : null,
                  child: FloatingActionButton(
                    mini: true,
                    onPressed: _scrollToTop,
                    child: Icon(Icons.arrow_upward),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// 根据站点类型获取列表选项
  Map<String, String> _getTypeNames(String siteType) {
    return siteType == "porn91" ? _typeNamesPorn91 : _typeNamesOriginal;
  }
  
  Widget _buildSettings() {
    return Consumer<AppState>(
      builder: (context, appState, _) {
        final siteType = appState.crawler?.siteType ?? "original";
        final typeNames = _getTypeNames(siteType);
        
        return Card(
          margin: EdgeInsets.all(16),
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    Text('列表: '),
                    Expanded(
                      child: DropdownButtonFormField(
                        value: _selectedType,
                        items: typeNames.entries.map((e) {
                          return DropdownMenuItem(value: e.key, child: Text(e.value));
                        }).toList(),
                        onChanged: (v) async {
                          if (v != null) {
                            await logger.i('Batch', 'UI操作: 选择列表类型 -> ${typeNames[v]}');
                            setState(() => _selectedType = v);
                          }
                        },
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 16),
                Row(
                  children: [
                    Text('页码: '),
                    SizedBox(width: 50, child: TextFormField(
                      initialValue: '1',
                      onChanged: (v) {
                        _pageStart = int.tryParse(v) ?? 1;
                      },
                    )),
                    Text(' ~ '),
                    SizedBox(width: 50, child: TextFormField(
                      initialValue: '3',
                      onChanged: (v) {
                        _pageEnd = int.tryParse(v) ?? 3;
                      },
                    )),
                    Spacer(),
                    FilledButton(
                      onPressed: _isLoading ? null : () async {
                        print('[Batch] 加载按钮被点击');
                        await _loadVideos();
                      },
                      child: _isLoading 
                        ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text('加载'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
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

  Widget _buildVideoGrid() {
    final appState = context.read<AppState>();
    final isListMode = appState.videoDisplayMode == 'list';
    
    if (_isLoading && _videos.isEmpty) {
      return Center(child: CircularProgressIndicator());
    }
    
    if (_videos.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.video_library_outlined, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('点击加载获取视频列表', style: TextStyle(color: Colors.grey)),
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
      controller: _scrollController,
      padding: EdgeInsets.all(8),
      itemCount: _videos.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _videos.length) {
          return Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            ),
          );
        }
        
        final video = _videos[index];
        final isSelected = _selectedIds.contains(video.id);
        
        return GestureDetector(
          onTap: () async {
            final action = isSelected ? '取消选择' : '选择';
            await logger.d('Batch', 'UI操作: $action视频 [${video.title}]');
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
                              // 模糊遮罩
                              if (appState.privacyMode)
                                Positioned.fill(
                                  child: Container(
                                    color: Colors.black.withOpacity(0.8),
                                    child: Center(
                                      child: Icon(Icons.lock, color: Colors.white54, size: 24),
                                    ),
                                  ),
                                ),
                            ],
                          )
                        : Icon(Icons.play_circle, size: 32, color: Colors.white54),
                    ),
                  ),
                  SizedBox(width: 12),
                  // 信息
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          video.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                        ),
                        if (video.author != null && video.author!.isNotEmpty) ...[
                          SizedBox(height: 4),
                          Text(
                            '作者: ${video.author}',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ],
                        if (video.duration != null) ...[
                          SizedBox(height: 4),
                          Text(
                            '时长: ${video.duration}',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ],
                      ],
                    ),
                  ),
                  // 选中图标
                  isSelected 
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
  
  /// 大图模式
  Widget _buildGridView() {
    final appState = context.read<AppState>();
    
    return GridView.builder(
      controller: _scrollController,
      padding: EdgeInsets.all(8),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.75,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: _videos.length + (_hasMore ? 1 : 0),  // 加载更多指示器
      itemBuilder: (context, index) {
        // 加载更多指示器
        if (index == _videos.length) {
          return Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            ),
          );
        }
        
        final video = _videos[index];
        final isSelected = _selectedIds.contains(video.id);
        
        return GestureDetector(
          onTap: () async {
            final action = isSelected ? '取消选择' : '选择';
            await logger.d('Batch', 'UI操作: $action视频 [${video.title}]');
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Stack(
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
                      if (isSelected)
                        Positioned(
                          top: 4,
                          right: 4,
                          child: Container(
                            padding: EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.blue,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(Icons.check, color: Colors.white, size: 16),
                          ),
                        ),
                      // 模糊遮罩
                      if (appState.privacyMode)
                        Positioned.fill(
                          child: Container(
                            color: Colors.black.withOpacity(0.8),
                            child: Center(
                              child: Icon(Icons.lock, color: Colors.white54, size: 48),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
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
                      if (video.author != null && video.author!.isNotEmpty) ...[
                        SizedBox(height: 2),
                        Text(
                          video.author!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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
      },
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 8)],
      ),
      child: Row(
        children: [
          // 只有选中了视频才显示全选按钮
          if (_selectedIds.isNotEmpty)
            TextButton(
              onPressed: () async {
                final isAllSelected = _selectedIds.length == _videos.length;
                await logger.i('Batch', 'UI操作: ${isAllSelected ? "取消全选" : "全选"}');
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
          FilledButton(
            onPressed: _selectedIds.isEmpty ? null : _startDownload,
            child: Text('下载 (${_selectedIds.length})'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadVideos() async {
    print('[Batch] _loadVideos 开始执行');
    print('[Batch] _isLoading=$_isLoading, _selectedType=$_selectedType');
    
    await logger.i('Batch', 'UI操作: 点击加载按钮, 类型=$_selectedType, 页码=$_pageStart-$_pageEnd');
    
    setState(() {
      _isLoading = true;
      _status = '加载中...';
      _videos.clear();
    });
    print('[Batch] 状态已更新: _isLoading=$_isLoading, _status=$_status');
    
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    print('[Batch] crawler=${crawler != null ? "存在" : "null"}, currentSite=${appState.currentSite}');
    
    if (crawler == null) {
      await logger.e('Batch', '爬虫为空, 请先选择站点');
      setState(() {
        _isLoading = false;
        _status = '请先选择站点';
      });
      return;
    }
    
    final videos = <VideoInfo>[];
    for (var p = _pageStart; p <= _pageEnd; p++) {
      print('[Batch] 开始加载第 $p 页');
      await logger.i('Batch', '网络请求: 加载第 $p 页');
      final list = await crawler.getVideoList(_selectedType, p);
      print('[Batch] 第 $p 页返回 ${list.length} 个视频');
      videos.addAll(list);
    }
    
    await logger.i('Batch', '加载完成, 共 ${videos.length} 个视频');
    
    setState(() {
      _videos = videos;
      _selectedIds.clear();  // 默认不全选
      _isLoading = false;
      _status = '就绪';
      _currentPage = _pageEnd;  // 记录当前页码
      _hasMore = videos.length == (_pageEnd - _pageStart + 1) * 24;  // 假设每页24个
    });
    print('[Batch] 加载完成, _videos.length=${_videos.length}');
  }

  Future<void> _startDownload() async {
    await logger.i('Batch', 'UI操作: 点击下载按钮, 选中 ${_selectedIds.length} 个视频');
    
    final appState = context.read<AppState>();
    
    // 获取选中的视频
    final selectedVideos = _videos.where((v) => _selectedIds.contains(v.id)).toList();
    
    await logger.i('Batch', '添加 ${selectedVideos.length} 个视频到下载队列');
    
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
