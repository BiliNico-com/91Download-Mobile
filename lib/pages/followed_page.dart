import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/video_info.dart';
import '../services/app_state.dart';
import '../services/followed_authors_service.dart';
import '../services/floating_video_service.dart';
import '../utils/logger.dart';

/// 已关注作者页面
class FollowedPage extends StatefulWidget {
  const FollowedPage({super.key});

  @override
  State<FollowedPage> createState() => _FollowedPageState();
}

class _FollowedPageState extends State<FollowedPage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  // 作者模式状态
  bool _isAuthorMode = false;
  String _currentAuthorId = '';
  String _currentAuthorName = '';
  List<VideoInfo> _authorVideos = [];
  bool _isLoading = false;
  bool _hasMore = true;
  int _currentPage = 0;
  Set<String> _selectedIds = {};
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    // 清除返回回调
    final appState = context.read<AppState>();
    if (appState.onWillPopCallback == _handleBackPress) {
      appState.onWillPopCallback = null;
    }
    super.dispose();
  }
  
  /// 处理返回事件（供 MainPage 调用）
  bool _handleBackPress() {
    if (_isAuthorMode) {
      _exitAuthorMode();
      return true; // 已处理
    }
    return false; // 未处理
  }

  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      if (!_isLoading && _hasMore && _isAuthorMode) {
        _loadMoreVideos();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final appState = context.watch<AppState>();
    final followedList = appState.followedAuthorsService.followedList;

    return Scaffold(
      appBar: AppBar(
        title: _isAuthorMode 
            ? Row(
                children: [
                  Icon(Icons.arrow_back, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(_currentAuthorName, 
                      style: TextStyle(fontSize: 16),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              )
            : Text('已关注 (${followedList.length})'),
        centerTitle: true,
      ),
      body: followedList.isEmpty
          ? _buildEmptyState()
          : _isAuthorMode 
              ? _buildAuthorVideoList(appState)
              : _buildAuthorGrid(followedList, appState),
      floatingActionButton: _isAuthorMode && _selectedIds.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: () => _downloadSelected(appState),
              icon: Icon(Icons.download),
              label: Text('下载 (${_selectedIds.length})'),
              backgroundColor: Colors.blue,
            )
          : null,
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.favorite_border, size: 80, color: Colors.grey),
          SizedBox(height: 16),
          Text('暂无关注的作者', style: TextStyle(fontSize: 18, color: Colors.grey)),
          SizedBox(height: 8),
          Text('进入作者主页后点击关注按钮即可关注', style: TextStyle(fontSize: 14, color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _buildAuthorGrid(List<FollowedAuthor> followedList, AppState appState) {
    return RefreshIndicator(
      onRefresh: () async {
        await appState.followedAuthorsService.refresh();
      },
      child: GridView.builder(
        padding: EdgeInsets.all(8),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          childAspectRatio: 0.75,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        itemCount: followedList.length,
        itemBuilder: (context, index) => _buildAuthorCard(followedList[index], appState),
      ),
    );
  }

  Widget _buildAuthorCard(FollowedAuthor author, AppState appState) {
    return GestureDetector(
      onTap: () => _enterAuthorMode(author.authorId, author.authorName, appState),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 头像
            Expanded(
              child: Container(
                color: Colors.grey[800],
                child: author.avatarUrl != null && author.avatarUrl!.isNotEmpty
                    ? Image.network(
                        author.avatarUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Icon(Icons.person, size: 48, color: Colors.grey),
                      )
                    : Icon(Icons.person, size: 48, color: Colors.grey),
              ),
            ),
            // 作者名和取消关注按钮
            Padding(
              padding: EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      author.authorName,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  GestureDetector(
                    onTap: () {
                      _unfollowAuthor(author, appState);
                    },
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.favorite, size: 18, color: Colors.red),
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

  Widget _buildAuthorVideoList(AppState appState) {
    if (_isLoading && _authorVideos.isEmpty) {
      return Center(child: CircularProgressIndicator());
    }

    if (_authorVideos.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.video_library_outlined, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('该作者暂无视频', style: TextStyle(fontSize: 16, color: Colors.grey)),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async {
        setState(() {
          _currentPage = 0;
          _hasMore = true;
          _authorVideos.clear();
        });
        await _loadMoreVideos();
      },
      child: ListView.builder(
        controller: _scrollController,
        padding: EdgeInsets.all(8),
        itemCount: _authorVideos.length + (_hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == _authorVideos.length) {
            return Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          return _buildVideoCard(_authorVideos[index], appState);
        },
      ),
    );
  }

  Widget _buildVideoCard(VideoInfo video, AppState appState) {
    final isSelected = _selectedIds.contains(video.id);
    
    return GestureDetector(
      onTap: () async {
        // 如果悬浮窗正在播放，且该视频已下载，则切换到该视频
        if (FloatingVideoService.isFloating) {
          final crawler = appState.crawler;
          final localPath = await crawler?.getDownloadedPath(video.id);
          
          if (localPath != null && localPath.isNotEmpty) {
            await FloatingVideoService.switchVideo(
              videoPath: localPath,
              title: video.title,
            );
            return;
          }
        }
        // 切换选择状态
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
        margin: EdgeInsets.symmetric(vertical: 4),
        child: Padding(
          padding: EdgeInsets.all(8),
          child: Row(
            children: [
              // 封面图
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  width: 120,
                  height: 68,
                  color: Colors.grey[800],
                  child: video.cover != null
                      ? Image.network(video.cover!, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(color: Colors.grey[800]))
                      : null,
                ),
              ),
              SizedBox(width: 12),
              // 标题和时长
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      video.title,
                      style: TextStyle(fontSize: 14),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (video.duration != null && video.duration!.isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text(
                          video.duration!,
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ),
                  ],
                ),
              ),
              // 选择指示器
              Icon(
                isSelected ? Icons.check_circle : Icons.circle_outlined,
                color: isSelected ? Colors.blue : Colors.grey,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 进入作者模式
  Future<void> _enterAuthorMode(String authorId, String authorName, AppState appState) async {
    final crawler = appState.crawler;
    if (crawler == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('请先选择站点')),
      );
      return;
    }

    setState(() {
      _isAuthorMode = true;
      _currentAuthorId = authorId;
      _currentAuthorName = authorName;
      _authorVideos.clear();
      _currentPage = 0;
      _hasMore = true;
      _selectedIds.clear();
      _isLoading = true;
    });
    
    // 设置返回回调
    appState.onWillPopCallback = _handleBackPress;

    // 直接加载第一页
    try {
      Logger().log('FollowedPage', '开始加载作者 $authorId');
      final videos = await crawler.getAuthorVideos(authorId, page: 1);
      Logger().log('FollowedPage', '获取到 ${videos.length} 个视频');
      
      if (mounted) {
        setState(() {
          if (videos.isNotEmpty) {
            _authorVideos.addAll(videos);
            _currentPage = 1;
          }
          _hasMore = videos.isNotEmpty;
          _isLoading = false;
        });
      }
    } catch (e, stack) {
      Logger().log('FollowedPage', '加载作者视频失败: $e');
      Logger().log('FollowedPage', '堆栈: $stack');
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载失败: $e')),
        );
      }
    }
  }

  /// 退出作者模式
  void _exitAuthorMode() {
    // 清除返回回调
    final appState = context.read<AppState>();
    if (appState.onWillPopCallback == _handleBackPress) {
      appState.onWillPopCallback = null;
    }
    
    setState(() {
      _isAuthorMode = false;
      _currentAuthorId = '';
      _currentAuthorName = '';
      _authorVideos.clear();
      _selectedIds.clear();
    });
  }

  /// 加载更多视频
  Future<void> _loadMoreVideos() async {
    if (_isLoading || !_hasMore) return;

    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) {
      Logger().log('FollowedPage', 'crawler 为 null，无法加载');
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('请先选择站点')),
        );
      }
      return;
    }

    setState(() => _isLoading = true);
    Logger().log('FollowedPage', '开始加载作者 $_currentAuthorId 第 ${_currentPage + 1} 页');

    try {
      final nextPage = _currentPage + 1;
      final videos = await crawler.getAuthorVideos(_currentAuthorId, page: nextPage);
      
      Logger().log('FollowedPage', '获取到 ${videos.length} 个视频');
      
      if (mounted) {
        setState(() {
          if (videos.isNotEmpty) {
            _authorVideos.addAll(videos);
            _currentPage = nextPage;
          }
          _hasMore = videos.isNotEmpty;
          _isLoading = false;
        });
      }
    } catch (e, stack) {
      Logger().log('FollowedPage', '加载作者视频失败: $e');
      Logger().log('FollowedPage', '堆栈: $stack');
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载失败: $e')),
        );
      }
    }
  }

  /// 下载选中的视频
  Future<void> _downloadSelected(AppState appState) async {
    final videos = _authorVideos.where((v) => _selectedIds.contains(v.id)).toList();
    if (videos.isEmpty) return;

    int added = 0;
    for (final video in videos) {
      final result = await appState.downloadManager.addTask(video);
      if (result == 'new') added++;
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已添加 $added 个任务到下载队列')),
      );
      setState(() => _selectedIds.clear());
    }
  }

  Future<void> _unfollowAuthor(FollowedAuthor author, AppState appState) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('取消关注'),
        content: Text('确定取消关注 ${author.authorName} 吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text('确定')),
        ],
      ),
    );

    if (confirmed == true) {
      await appState.followedAuthorsService.unfollow(author.authorId);
    }
  }
}
