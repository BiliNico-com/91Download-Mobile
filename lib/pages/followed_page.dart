import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_state.dart';
import '../services/followed_authors_service.dart';
import 'batch_page.dart';

/// 已关注作者页面
class FollowedPage extends StatefulWidget {
  const FollowedPage({super.key});

  @override
  State<FollowedPage> createState() => _FollowedPageState();
}

class _FollowedPageState extends State<FollowedPage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final appState = context.watch<AppState>();
    final followedList = appState.followedAuthorsService.followedList;

    return Scaffold(
      appBar: AppBar(
        title: Text('已关注 (${followedList.length})'),
        centerTitle: true,
      ),
      body: followedList.isEmpty
          ? _buildEmptyState()
          : _buildAuthorGrid(followedList, appState),
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
      onTap: () => _enterAuthorPage(author.authorId, author.authorName),
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
                      // 阻止事件冒泡到父级卡片
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

  void _enterAuthorPage(String authorId, String authorName) {
    // 导航到批量页面并进入作者主页
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => _AuthorPageWrapper(
          authorId: authorId,
          authorName: authorName,
        ),
      ),
    );
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

/// 作者主页包装器 - 独立页面显示作者视频
class _AuthorPageWrapper extends StatefulWidget {
  final String authorId;
  final String authorName;

  const _AuthorPageWrapper({
    required this.authorId,
    required this.authorName,
  });

  @override
  State<_AuthorPageWrapper> createState() => _AuthorPageWrapperState();
}

class _AuthorPageWrapperState extends State<_AuthorPageWrapper> {
  List<dynamic> _videos = [];
  bool _isLoading = false;
  bool _hasMore = true;
  int _currentPage = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 使用 WidgetsBinding 在第一帧后加载
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadVideos();
    });
  }

  Future<void> _loadVideos() async {
    if (!_hasMore || _isLoading) return;

    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) {
      setState(() {
        _error = '爬虫未初始化';
        _isLoading = false;
      });
      return;
    }

    setState(() => _isLoading = true);
    _currentPage++;

    try {
      final newVideos = await crawler.getAuthorVideos(widget.authorId, page: _currentPage);
      
      if (mounted) {
        setState(() {
          if (newVideos.isEmpty) {
            _hasMore = false;
          } else {
            _videos.addAll(newVideos);
            if (newVideos.length < 20) _hasMore = false;
          }
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final isFollowed = appState.followedAuthorsService.followedList
        .any((a) => a.authorId == widget.authorId);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.authorName),
        actions: [
          // 关注按钮
          TextButton.icon(
            onPressed: () async {
              if (isFollowed) {
                await appState.followedAuthorsService.unfollow(widget.authorId);
              } else {
                await appState.followedAuthorsService.follow(
                  widget.authorId,
                  widget.authorName,
                );
              }
            },
            icon: Icon(
              isFollowed ? Icons.favorite : Icons.favorite_border,
              color: isFollowed ? Colors.red : null,
            ),
            label: Text(
              isFollowed ? '已关注' : '关注',
              style: TextStyle(color: isFollowed ? Colors.red : null),
            ),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading && _videos.isEmpty) {
      return Center(child: CircularProgressIndicator());
    }

    if (_error != null && _videos.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.grey),
            SizedBox(height: 16),
            Text('加载失败: $_error'),
            SizedBox(height: 16),
            ElevatedButton(onPressed: _loadVideos, child: Text('重试')),
          ],
        ),
      );
    }

    if (_videos.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.video_library_outlined, size: 48, color: Colors.grey),
            SizedBox(height: 16),
            Text('该作者暂无视频'),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: EdgeInsets.all(8),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.75,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: _videos.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _videos.length) {
          _loadVideos();
          return Center(child: CircularProgressIndicator());
        }

        final video = _videos[index];
        return _buildVideoCard(video);
      },
    );
  }

  Widget _buildVideoCard(dynamic video) {
    String title = '';
    String? cover;
    String? duration;
    int? views;

    // 兼容 VideoInfo 或 Map
    try {
      if (video is Map) {
        title = video['title'] ?? video['name'] ?? '';
        cover = video['cover'] ?? video['thumbnail'];
        duration = video['duration']?.toString();
        views = video['views'];
      } else {
        title = video.title ?? '';
        cover = video.cover;
        duration = video.duration?.toString();
        views = video.views;
      }
    } catch (e) {
      title = video.toString();
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                cover != null && cover.isNotEmpty
                    ? Image.network(cover, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(color: Colors.grey[800]))
                    : Container(color: Colors.grey[800], child: Icon(Icons.play_circle_outline, size: 48, color: Colors.white)),
                if (duration != null)
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: Container(
                      padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.7),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(duration, style: TextStyle(color: Colors.white, fontSize: 10)),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.all(8),
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
