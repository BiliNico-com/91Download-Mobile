import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/video_info.dart';
import '../services/app_state.dart';
import '../services/followed_authors_service.dart';
import 'author_detail_page.dart';

/// 已关注作者页面
class FollowedPage extends StatefulWidget {
  const FollowedPage({super.key});

  @override
  State<FollowedPage> createState() => _FollowedPageState();
}

class _FollowedPageState extends State<FollowedPage> with AutomaticKeepAliveClientMixin {
  bool _isChecking = false;
  String _checkProgress = '';

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final appState = context.watch<AppState>();
    final followedList = appState.followedAuthorsService.followedList;
    final newCount = appState.followedAuthorsService.newContentCount;

    return Scaffold(
      appBar: AppBar(
        title: Text('已关注 (${followedList.length})'),
        centerTitle: true,
        actions: followedList.isNotEmpty
            ? [
                if (_isChecking)
                  const Padding(
                    padding: EdgeInsets.only(right: 12),
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  )
                else
                  IconButton(
                    icon: Badge(
                      isLabelVisible: newCount > 0,
                      label: Text('$newCount'),
                      child: const Icon(Icons.refresh),
                    ),
                    tooltip: '检查更新',
                    onPressed: _isChecking ? null : () => _checkForUpdates(appState),
                  ),
              ]
            : null,
      ),
      body: followedList.isEmpty
          ? _buildEmptyState()
          : Column(
              children: [
                // 进度提示
                if (_isChecking && _checkProgress.isNotEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    color: Theme.of(context).colorScheme.primaryContainer,
                    child: Text(
                      _checkProgress,
                      style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onPrimaryContainer),
                      textAlign: TextAlign.center,
                    ),
                  ),
                // 作者网格
                Expanded(child: _buildAuthorGrid(followedList, appState)),
              ],
            ),
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
        padding: const EdgeInsets.all(8),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
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
    final hasUpdate = author.hasNewContent;

    return GestureDetector(
      onTap: () async {
        // 清除新内容标记
        if (hasUpdate) {
          await appState.followedAuthorsService.clearNewFlag(author.authorId);
        }
        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AuthorDetailPage(
              author: AuthorInfo(
                id: author.authorId,
                name: author.authorName,
                avatar: author.avatarUrl,
                profileUrl: '',
              ),
            ),
          ),
        );
      },
      child: Stack(
        children: [
          Card(
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
                            errorBuilder: (_, __, ___) => const Icon(Icons.person, size: 48, color: Colors.grey),
                          )
                        : const Icon(Icons.person, size: 48, color: Colors.grey),
                  ),
                ),
                // 作者名和取消关注
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          author.authorName,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      GestureDetector(
                        onTap: () => _unfollowAuthor(author, appState),
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          child: const Icon(Icons.favorite, size: 18, color: Colors.red),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // 新内容小红点
          if (hasUpdate)
            Positioned(
              top: 4,
              right: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  author.newVideoCount! > 99 ? '99+' : '${author.newVideoCount}',
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _checkForUpdates(AppState appState) async {
    final crawler = appState.crawler;
    if (crawler == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先在设置中选择站点')),
        );
      }
      return;
    }

    setState(() {
      _isChecking = true;
      _checkProgress = '正在检查更新...';
    });

    final updatedAuthors = await appState.followedAuthorsService.checkForUpdates(
      crawler,
      onProgress: (current, total, name) {
        if (mounted) {
          setState(() {
            _checkProgress = '正在检查: $name ($current/$total)';
          });
        }
      },
    );

    if (mounted) {
      setState(() {
        _isChecking = false;
        _checkProgress = '';
      });

      final count = updatedAuthors.length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(count > 0 ? '发现 $count 位作者有新内容' : '所有作者暂无更新'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _unfollowAuthor(FollowedAuthor author, AppState appState) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('取消关注'),
        content: Text('确定取消关注 ${author.authorName} 吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('确定')),
        ],
      ),
    );

    if (confirmed == true) {
      await appState.followedAuthorsService.unfollow(author.authorId);
    }
  }
}
