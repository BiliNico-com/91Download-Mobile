import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/video_info.dart';
import '../services/app_state.dart';
import '../services/followed_authors_service.dart';
import '../components/cover_image.dart';
import '../components/empty_state.dart';
import '../components/app_shell.dart';
import '../theme/app_tokens.dart';
import 'author_detail_page.dart';

/// 已关注作者页面
class FollowedPage extends StatefulWidget {
  const FollowedPage({super.key});

  @override
  State<FollowedPage> createState() => _FollowedPageState();
}

class _FollowedPageState extends State<FollowedPage>
    with AutomaticKeepAliveClientMixin {
  bool _isChecking = false;
  String _checkProgress = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // 首次进入本页时补一次静默检查。
    // 启动时的检查可能因为「当时站点还没配置好」而被跳过，
    // 进到这一页说明用户关心更新情况，是个合适的补检时机。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final appState = context.read<AppState>();
      appState.scheduleFollowedAuthorsAutoCheck();
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = AppTokens.of(context);
    final appState = context.watch<AppState>();
    final followedList = appState.followedAuthorsService.followedList;
    final newCount = appState.followedAuthorsService.newContentCount;

    return Scaffold(
      backgroundColor: t.bg,
      appBar: _buildAppBar(appState, t, followedList, newCount),
      body: followedList.isEmpty
          ? const EmptyState(
              icon: Icons.favorite_border_rounded,
              title: '还没有关注任何作者',
              subtitle: '在视频列表中点击作者名称即可关注',
              iconSize: 60,
            )
          : Stack(
              children: [
                Positioned.fill(
                  child: _buildAuthorGrid(followedList, appState, t),
                ),
                if (_isChecking && _checkProgress.isNotEmpty)
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: t.surface,
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                        border: Border.all(color: t.line),
                        boxShadow: t.cardShadow,
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: t.accent),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _checkProgress,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: t.text2),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  PreferredSizeWidget _buildAppBar(
    AppState appState,
    AppTokens t,
    List<FollowedAuthor> followedList,
    int newCount,
  ) {
    return AppBar(
      backgroundColor: t.surface,
      centerTitle: false,
      toolbarHeight: 88,
      titleSpacing: 0,
      elevation: 0,
      title: Padding(
        padding: const EdgeInsets.only(left: 14, right: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '已关注',
                  style: TextStyle(
                    fontSize: 23,
                    height: 1.15,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                    color: t.text1,
                  ),
                ),
                if (followedList.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  AppCountPill(
                    text: '${followedList.length}',
                    color: t.text3,
                  ),
                ],
                const Spacer(),
                if (_isChecking)
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.2, color: t.accent),
                  )
                else
                  AppIconBtn(
                    icon: Icons.refresh_rounded,
                    tooltip: '检查更新',
                    onTap: () => _checkForUpdates(appState),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Flexible(child: SitePill(appState: appState)),
                const SizedBox(width: 9),
                if (newCount > 0)
                  AppCountPill(text: '${newCount} 位有新内容', color: t.danger),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAuthorGrid(
    List<FollowedAuthor> followedList,
    AppState appState,
    AppTokens t,
  ) {
    return RefreshIndicator(
      color: t.accent,
      backgroundColor: t.surface,
      onRefresh: () async {
        await appState.followedAuthorsService.refresh();
      },
      child: GridView.builder(
        padding: EdgeInsets.fromLTRB(
            12, 12, 12, MediaQuery.of(context).padding.bottom + 84),
        // 卡片高度写死 mainAxisExtent，不再用 childAspectRatio 反推。
        // 之前 1.55 算出来只有 ~105dp，而内容（上下留白 25 + 头像 48 +
        // 名字 19 + 间距 4 + 状态 15）需要 ~111dp，Column 里的 Spacer
        // 在超高时会被压成 0、救不回布局，于是卡片底部稳定溢出 9.2px。
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisExtent: 122,
          crossAxisSpacing: 11,
          mainAxisSpacing: 11,
        ),
        itemCount: followedList.length,
        itemBuilder: (context, index) =>
            _buildAuthorCard(followedList[index], appState, t),
      ),
    );
  }

  Widget _buildAuthorCard(
      FollowedAuthor author, AppState appState, AppTokens t) {
    final hasUpdate = author.hasNewContent;
    final radius = BorderRadius.circular(AppRadius.xl);

    return Material(
      color: t.surface,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openAuthor(author, appState),
        child: Container(
          padding: const EdgeInsets.fromLTRB(13, 13, 10, 12),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: t.line),
          ),
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: CoverImage(
                        url: author.avatarUrl,
                        borderRadius: BorderRadius.zero,
                        fallbackIcon: Icons.person_rounded,
                        fallbackIconSize: 26,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    author.authorName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: t.text1,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    hasUpdate
                        ? '${author.newVideoCount ?? 0} 条新内容'
                        : '已关注',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: hasUpdate ? t.danger : t.text3,
                      fontWeight:
                          hasUpdate ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
              Positioned(
                top: 0,
                right: 0,
                child: GestureDetector(
                  onTap: () => _unfollowAuthor(author, appState),
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(Icons.favorite_rounded,
                        size: 17, color: t.danger),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openAuthor(FollowedAuthor author, AppState appState) async {
    // 清除新内容标记
    if (author.hasNewContent) {
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
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确定')),
        ],
      ),
    );

    if (confirmed == true) {
      await appState.followedAuthorsService.unfollow(author.authorId);
    }
  }
}
