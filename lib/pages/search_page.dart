import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_state.dart';
import '../models/video_info.dart';
import '../components/video_list_items.dart';
import '../components/app_shell.dart';
import '../components/empty_state.dart';
import '../components/cover_image.dart';
import '../utils/debouncer.dart';
import '../utils/logger.dart';
import '../theme/app_tokens.dart';
import 'streaming_page.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> with AutomaticKeepAliveClientMixin {
  final _keywordController = TextEditingController();
  final _pageController = TextEditingController();
  List<VideoInfo> _results = [];
  List<AuthorInfo> _authorResults = [];  // 作者搜索结果
  Set<String> _selectedIds = {};
  bool _isLoading = false;
  bool _isLoadingMore = false;  // 是否正在加载更多
  bool _isAuthorMode = false;
  
  // 分页相关
  int _currentPage = 1;
  int _loadedPage = 0;  // 已加载的页码（用于瀑布流加载）
  bool _hasMore = true;
  String _lastKeyword = '';

  /// 上一次渲染时的站点地址，用于检测"更换网址"并清掉旧站结果
  String? _lastSiteUrl;
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
  // 页码输入框焦点（用于判断能否安全写入页码）
  final FocusNode _pageFocusNode = FocusNode();
  // 关键词输入框焦点（聚焦时展示搜索历史）
  final FocusNode _keywordFocusNode = FocusNode();
  // 是否展示搜索历史下拉
  bool _showHistory = false;
  bool _showBackToTop = false;
  String _status = '就绪';  // 就绪状态
  
  // 进入作者主页前的滚动位置（返回时恢复）
  double _savedScrollOffset = 0;
  
  // 搜索防抖器
  late final Debouncer _searchDebouncer;
  
  @override
  bool get wantKeepAlive => true;  // 保持页面状态
  
  // 更新返回键回调
  void _updateWillPopCallback() {
    final appState = context.read<AppState>();
    if (_isAuthorPageMode || _isAuthorMode) {
      appState.onWillPopCallback = () {
        if (_isAuthorPageMode) {
          _exitAuthorPageMode();
          return true;
        }
        if (_isAuthorMode) {
          setState(() {
            _isAuthorMode = false;
            _authorResults.clear();
            _selectedIds.clear();
          });
          appState.onWillPopCallback = null;
          return true;
        }
        return false;
      };
    } else {
      appState.onWillPopCallback = null;
    }
  }
  
  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _pageController.text = '1';
    _searchDebouncer = Debouncer(milliseconds: 500);
    _keywordFocusNode.addListener(_onKeywordFocusChange);
  }

  /// 输入框获得焦点且历史非空时展示历史下拉
  void _onKeywordFocusChange() {
    final focused = _keywordFocusNode.hasFocus;
    if (focused) {
      final appState = context.read<AppState>();
      final has = appState.searchHistory.isNotEmpty;
      if (has && !_showHistory) {
        setState(() => _showHistory = true);
      }
    } else if (_showHistory) {
      setState(() => _showHistory = false);
    }
  }

  /// 点击历史条目：填充并立即搜索
  void _applyHistory(AppState appState, String keyword) {
    _keywordController.text = keyword;
    // 输入框处于焦点时直接赋值 controller.text 不会同步光标位置，
    // 这里用 setState 让 TextField 重新读取 controller 值。
    setState(() {
      _showHistory = false;
      _isAuthorPageMode = false;
      _currentPage = 1;
    });
    _keywordFocusNode.unfocus();
    _search();
  }

  /// 从输入框内容记录一条历史
  void _rememberKeyword(AppState appState, String keyword) {
    final k = keyword.trim();
    if (k.isEmpty) return;
    appState.searchHistory.add(k);
  }
  
  @override
  void dispose() {
    _searchDebouncer.dispose();
    // 清除返回键回调
    try {
      context.read<AppState>().onWillPopCallback = null;
    } catch (_) {}
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _pageFocusNode.dispose();
    _keywordFocusNode.removeListener(_onKeywordFocusChange);
    _keywordFocusNode.dispose();
    _keywordController.dispose();
    _pageController.dispose();
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
      if (!_isLoading && !_isLoadingMore) {
        // 作者主页模式
        if (_isAuthorPageMode && _authorHasMore) {
          _loadMoreAuthorVideos();
        // 视频搜索模式（非作者搜索模式）
        } else if (!_isAuthorPageMode && !_isAuthorMode && _hasMore && _results.isNotEmpty) {
          _loadMore();
        }
      }
    }
  }
  
  void _scrollToTop() {
    _scrollController.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }
  
  /// 下拉刷新
  Future<void> _onRefresh() async {
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) return;

    // 作者主页模式
    if (_isAuthorPageMode) {
      setState(() {
        _authorVideos.clear();
        _selectedIds.clear();
        _authorCurrentPage = 0;
        _authorHasMore = true;
      });
      await _loadMoreAuthorVideos();
      return;
    }

    // 作者搜索模式 — 重新搜索
    if (_isAuthorMode) {
      setState(() {
        _authorResults.clear();
        _isLoading = false;
      });
      final authors = await crawler.searchAuthors(_keywordController.text);
      if (mounted) {
        setState(() {
          _authorResults = authors;
          _status = authors.isEmpty ? '无结果' : '就绪';
        });
      }
      return;
    }
    
    // 视频搜索模式
    if (_lastKeyword.isEmpty) return;
    
    final results = await crawler.searchVideos(_lastKeyword, page: 1, sort: _sortBy);
    if (mounted) {
      setState(() {
        _results = results;
        _currentPage = 1;  // 下拉刷新回到第1页
        _loadedPage = 1;
        _hasMore = results.isNotEmpty;
      });
      // 同步页码输入框显示（放在 setState 之外）
      _syncPageController('1');
    }
  }
  
  Future<void> _loadMore() async {
    if (!_hasMore || _isLoading || _isLoadingMore || _lastKeyword.isEmpty) return;
    
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) return;

    setState(() => _isLoadingMore = true);
    final nextPage = _loadedPage + 1;
    
    final newResults = await crawler.searchVideos(_lastKeyword, page: nextPage, sort: _sortBy);
    
    if (newResults.isEmpty) {
      setState(() {
        _hasMore = false;
        _isLoadingMore = false;
      });
    } else {
      // 由爬虫依据站点"下一页"控件判定是否还有更多（条数不固定时更可靠）
      final siteHasMore = crawler.lastRequestHasMore;
      setState(() {
        // 去重：过滤掉已存在的视频
        final existingIds = _results.map((v) => v.id).toSet();
        final uniqueNewResults = newResults.where((v) => !existingIds.contains(v.id)).toList();
        _results.addAll(uniqueNewResults);
        _loadedPage = nextPage;
        _currentPage = nextPage;
        _hasMore = siteHasMore;
        _isLoadingMore = false;
      });
      // 同步页码输入框显示
      _syncPageController('$nextPage');
    }
  }

  /// 把页码同步到胶囊输入框
  ///
  /// 注意：仅在输入框「未获得焦点」时直接赋值。TextField 处于焦点时
  /// Flutter 会用其内部编辑态覆盖 controller.text，导致滚动加载后
  /// 页码显示不更新（手动点翻页时输入框通常已失焦，所以看起来是好的）。
  /// 聚焦时先收起键盘并解焦，再在下一帧写入，确保显示以代码为准。
  void _syncPageController(String value) {
    if (!mounted) return;
    final node = _pageFocusNode;
    if (node.hasFocus) {
      node.unfocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _pageController.text = value;
      });
    } else {
      _pageController.text = value;
    }
  }

  /// 加载更多作者视频
  Future<void> _loadMoreAuthorVideos() async {
    if (!_authorHasMore || _isLoading || _isLoadingMore || _currentAuthorId.isEmpty) return;
    
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) return;
    
    setState(() => _isLoadingMore = true);
    _authorCurrentPage++;
    
    final newVideos = await crawler.getAuthorVideos(_currentAuthorId, page: _authorCurrentPage);
    
    if (newVideos.isEmpty) {
      _authorHasMore = false;
    } else {
      // 由爬虫依据站点"下一页"控件判定（条数不固定时更可靠）
      final siteHasMore = crawler.lastRequestHasMore;
      setState(() {
        // 去重：过滤掉已存在的视频
        final existingIds = _authorVideos.map((v) => v.id).toSet();
        final uniqueNewVideos = newVideos.where((v) => !existingIds.contains(v.id)).toList();
        _authorVideos.addAll(uniqueNewVideos);
        _authorHasMore = siteHasMore;
      });
    }
    
    setState(() => _isLoadingMore = false);
  }

  /// 退出作者主页模式
  void _exitAuthorPageMode() {
    if (_isAuthorPageMode) {
      final savedOffset = _savedScrollOffset;
      setState(() {
        _isAuthorPageMode = false;
        _authorVideos.clear();
        _authorCurrentPage = 0;
        _authorHasMore = true;
        _selectedIds.clear();
      });
      // 更新返回键回调
      _updateWillPopCallback();
      // 恢复进入前的滚动位置
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scrollController.hasClients) {
          final maxOffset = _scrollController.position.maxScrollExtent;
          if (savedOffset <= maxOffset) {
            _scrollController.jumpTo(savedOffset);
          }
        }
      });
    }
  }

  /// 进入作者主页模式
  Future<void> _enterAuthorPageMode(AuthorInfo author) async {
    // 保存当前滚动位置
    _savedScrollOffset = _scrollController.offset;
    setState(() {
      _isAuthorPageMode = true;
      _currentAuthorId = author.id;
      _currentAuthorName = author.name;
      _authorVideos.clear();
      _authorCurrentPage = 0;
      _authorHasMore = true;
      _selectedIds.clear();
    });
    // 更新返回键回调
    _updateWillPopCallback();
    // 滚动到顶部加载作者视频
    _scrollController.jumpTo(0);
    await _loadMoreAuthorVideos();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);  // 必须调用

    return Consumer<AppState>(
      builder: (context, appState, _) {
        final t = AppTokens.of(context);

        // ── 更换网址处理 ──
        // 本页被 KeepAlive 保活，换站后旧站的搜索结果会一直留在这里，
        // 用户看到的是"另一个网站的内容"。以网址为准清空一次。
        // 首次构建只记录，不触发（否则会与自动搜索重复）。
        final siteUrl = appState.currentSite ?? '';
        if (_lastSiteUrl == null) {
          _lastSiteUrl = siteUrl;
        } else if (_lastSiteUrl != siteUrl) {
          _lastSiteUrl = siteUrl;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() {
              _results.clear();
              _authorResults.clear();
              _selectedIds.clear();
              _currentPage = 1;
              _loadedPage = 0;
              _hasMore = true;
              _status = '就绪';
              // 站点都换了，作者主页模式必然失效
              _isAuthorPageMode = false;
            });
            _syncPageController('1');
          });
        }

        return Scaffold(
          // 顶栏改为普通 AppBar（不再折叠），内容从顶栏下方开始，
          // 因此不再需要 extendBodyBehindAppBar。
          backgroundColor: t.bg,
          appBar: _buildAppBar(appState, t),
          body: Stack(
            children: [
              RefreshIndicator(
                onRefresh: _onRefresh,
                color: t.accent,
                backgroundColor: t.surface,
                displacement: 40,
                child: CustomScrollView(
                  controller: _scrollController,
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                      sliver: _isAuthorMode && !_isAuthorPageMode
                          ? _buildAuthorResultsSliver()
                          : _buildVideoResultsSliver(appState),
                    ),
                    // 底部留白给翻页控件和浮动按钮
                    const SliverToBoxAdapter(child: SizedBox(height: 110)),
                  ],
                ),
              ),
              // 覆盖层：翻页控件 + 浮动按钮
              ..._buildOverlays(appState),
            ],
          ),
        );
      },
    );
  }

  /// 顶栏：标题 + 站点胶囊 + 搜索框 + 视频/作者分段
  PreferredSizeWidget _buildAppBar(AppState appState, AppTokens t) {
    return AppBar(
      backgroundColor: t.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      toolbarHeight: _isAuthorPageMode ? 58 : 86,
      titleSpacing: 0,
      shape: Border(bottom: BorderSide(color: t.line, width: 1)),
      title: Padding(
        padding: const EdgeInsets.only(left: 14, right: 12),
        child: _isAuthorPageMode
            ? _buildAuthorModeTitle(appState, t)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '搜索',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 23,
                            height: 1.15,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.4,
                            color: t.text1,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ..._buildAppBarActions(appState),
                    ],
                  ),
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      Flexible(child: SitePill(appState: appState)),
                      const Spacer(),
                    ],
                  ),
                ],
              ),
      ),
      bottom: PreferredSize(
        preferredSize: Size.fromHeight(
            _isAuthorPageMode ? 0 : 95),
        child: _isAuthorPageMode
            ? const SizedBox.shrink()
            : _buildSearchBar(appState, t),
      ),
    );
  }

  /// 作者主页模式下的标题行：返回 + 作者名 + 关注
  Widget _buildAuthorModeTitle(AppState appState, AppTokens t) {
    return Row(
      children: [
        AppIconBtn(
          icon: Icons.arrow_back_rounded,
          tooltip: '返回',
          onTap: _exitAuthorPageMode,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            '作者: $_currentAuthorName',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
              color: t.text1,
            ),
          ),
        ),
        const SizedBox(width: 8),
        _buildFollowButton(appState, t),
      ],
    );
  }
  
  /// 覆盖层：翻页控件 + 浮动按钮
  /// 覆盖层：翻页控件 + 浮动按钮
  List<Widget> _buildOverlays(AppState appState) {
    final t = AppTokens.of(context);
    final navInset = MediaQuery.of(context).padding.bottom;
    final hasSelection = _selectedIds.isNotEmpty;

    return [
      // 搜索历史下拉：必须是 Stack 里的独立一层。
      // 早前它挂在 SliverAppBar.flexibleSpace 内部，而 expandedHeight
      // 只算到「标题区 + 搜索框」，下拉撑开的部分落在 sliver 的
      // ClipRect 之外 —— 那块区域不属于任何控件，点击会直接穿到下层
      // 视频卡片上。移到 Stack 里作为独立层后命中测试才正确。
      if (_showHistory && appState.searchHistory.isNotEmpty && !_isAuthorPageMode)
        _buildHistoryOverlay(appState, t),
      // 页码跳转悬浮胶囊（仅视频搜索模式显示，作者主页模式隐藏）
      if (!_isAuthorMode && !_isAuthorPageMode && !hasSelection)
        _buildBottomPageNavigation(appState, t),
      // 回顶部按钮
      if (_showBackToTop && appState.showBackToTop)
        Positioned(
          bottom: hasSelection
              ? navInset + 84
              : (appState.backToTopPosition == 'right'
                  ? navInset + 16
                  : navInset + 74),
          left: appState.backToTopPosition == 'left' ? 12 : null,
          right: appState.backToTopPosition == 'right' ? 12 : null,
          child: GestureDetector(
            onTap: _scrollToTop,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: t.surface,
                shape: BoxShape.circle,
                border: Border.all(color: t.line),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(t.dark ? 0.4 : 0.12),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Icon(Icons.arrow_upward_rounded, size: 19, color: t.text2),
            ),
          ),
        ),
      // 选中浮条
      if (hasSelection)
        Positioned(
          left: 12,
          right: 12,
          bottom: navInset + 12,
          child: AppFloatBar(
            selectedCount: _selectedIds.length,
            actionLabel: '开始下载',
            onAction: _download,
            onCancel: () => setState(() => _selectedIds.clear()),
          ),
        ),
    ];
  }

  /// 搜索历史覆盖层
  ///
  /// 用 GestureDetector(behavior: opaque) 铺满全屏来截住所有落在列表上的点击，
  /// 点空白处收起历史，点条目则应用关键词 —— 不再穿透到下层视频卡片。
  Widget _buildHistoryOverlay(AppState appState, AppTokens t) {
    return Positioned.fill(
      child: GestureDetector(
        // 拦截整层命中，避免点到下方列表
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _showHistory = false),
        child: Stack(
          children: [
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              right: 0,
              child: Align(
                alignment: Alignment.topCenter,
                child: GestureDetector(
                  // 下拉本体自己消费点击，不让它冒泡到收起逻辑
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: _buildSearchHistoryDropdown(appState, t),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建关注按钮
  Widget _buildFollowButton(AppState appState, AppTokens t) {
    final isFollowed = appState.followedAuthorsService.followedList
        .any((a) => a.authorId == _currentAuthorId);

    return GestureDetector(
      // 这个胶囊里只有图标和文字，命中区不外扩；opaque 保证点文字与
      // 图标之间的空隙也算点中（此前只有文字本身能触发，点边缘没反应）。
      behavior: HitTestBehavior.opaque,
      onTap: () async {
        final String? error;
        if (isFollowed) {
          error = await appState.followedAuthorsService
              .unfollow(_currentAuthorId);
        } else {
          error = await appState.followedAuthorsService
              .follow(_currentAuthorId, _currentAuthorName);
        }
        if (!mounted) return;
        setState(() {});
        // 失败时把原因说出来：以前返回值被直接丢掉，写库失败时
        // 用户看到的就是「按钮点了一下，什么都不发生」。
        if (error != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(error)),
          );
        }
      },
      child: Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: isFollowed ? t.dangerSoft : t.accentSoft,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isFollowed ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              size: 13,
              color: isFollowed ? t.danger : t.accent,
            ),
            const SizedBox(width: 4),
            Text(
              isFollowed ? '已关注' : '关注',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: isFollowed ? t.danger : t.accent,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶栏右侧操作：已选数量 / 全选 / 状态 / 隐私
  List<Widget> _buildAppBarActions(AppState appState) {
    final t = AppTokens.of(context);
    final total = _isAuthorPageMode ? _authorVideos.length : _results.length;
    final allSelected = _selectedIds.isNotEmpty && _selectedIds.length == total;
    final statusColor = _status == '就绪'
        ? t.success
        : (_status == '无结果' ? t.text3 : t.warning);

    return [
      if (_selectedIds.isNotEmpty) ...[
        AppCountPill(text: '已选 ${_selectedIds.length}', color: t.accent),
        const SizedBox(width: 6),
        GestureDetector(
          onTap: _toggleAll,
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: allSelected ? AppTokens.blue : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadius.sm + 1),
              border: allSelected
                  ? null
                  : Border.all(color: AppTokens.blue, width: 1.6),
            ),
            child: Icon(
              Icons.check_rounded,
              size: 18,
              color: allSelected ? Colors.white : AppTokens.blue,
            ),
          ),
        ),
        const SizedBox(width: 6),
      ],
      if (!_isAuthorPageMode)
        AppCountPill(text: _status, color: statusColor),
      const SizedBox(width: 6),
      AppIconBtn(
        icon: appState.privacyMode
            ? Icons.visibility_off_rounded
            : Icons.visibility_rounded,
        tooltip: appState.privacyMode ? '取消模糊' : '模糊预览图',
        color: appState.privacyMode ? t.danger : t.text2,
        background: appState.privacyMode ? t.dangerSoft : t.surface2,
        onTap: () => appState.togglePrivacyMode(),
      ),
    ];
  }

  /// 搜索框（顶栏底部固定区域：搜索框 + 视频/作者分段）
  Widget _buildSearchBar(AppState appState, AppTokens t) {
    final siteType = appState.crawler?.siteType ?? 'original';
    final showSort = !_isAuthorMode && siteType != 'porn91';

    // 搜索栏本体用 opaque 的 GestureDetector 包住，避免点空白穿透到列表
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        // 点搜索栏空白处：收起历史下拉
        if (_showHistory) setState(() => _showHistory = false);
      },
      child: Container(
        color: t.surface,
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 42,
              decoration: BoxDecoration(
                // 只留描边，不铺底色（深色模式下 surface2 会比页底亮一档，显得像贴了色块）
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(AppRadius.lg),
                border: Border.all(color: t.line),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  Icon(Icons.search_rounded, size: 17, color: t.text3),
                  const SizedBox(width: 7),
                  // 输入框
                  Expanded(
                    child: TextField(
                      controller: _keywordController,
                      focusNode: _keywordFocusNode,
                      style: TextStyle(
                        color: t.text1,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                      decoration: InputDecoration(
                        // 关掉全局 inputDecorationTheme 的 filled，否则输入区会盖一层
                        // darkInputFill 色块，和外层透明描边框对不上
                        filled: false,
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                        hintText: '输入关键词搜索',
                        hintStyle: TextStyle(
                          color: t.text3,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      onChanged: (value) {
                        if (value.trim().isNotEmpty) {
                          _searchDebouncer.run(() => _search());
                        }
                      },
                      onSubmitted: (_) => _search(),
                      onTap: () {
                        // 点回输入框时重新展开历史（焦点未变化时 listener 不会触发）
                        final appState = context.read<AppState>();
                        if (appState.searchHistory.isNotEmpty && !_showHistory) {
                          setState(() => _showHistory = true);
                        }
                      },
                      textInputAction: TextInputAction.search,
                    ),
                  ),
                  // 排序下拉（仅视频搜索模式 + original CMS）
                  if (showSort) _buildSearchDropdown(t),
                  // 搜索按钮
                  GestureDetector(
                    onTap: _search,
                    child: Container(
                      width: 32,
                      height: 32,
                      margin: const EdgeInsets.only(right: 5),
                      decoration: BoxDecoration(
                        color: AppTokens.blue,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: const Icon(Icons.search_rounded,
                          color: Colors.white, size: 18),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 9),
            // 视频 / 作者：贴着搜索框的整行分段。
            // 早前它被塞进顶栏标题的第二行（与站点胶囊挤在一行）：SitePill 用
            // Flexible、分段控件内部又全是 Expanded，两个都要靠父级给宽度，结果
            // 整行内容一个都没画出来，看上去就像「搜作者和视频合并了」。
            AppSegmented(
              labels: const ['视频', '作者'],
              selectedIndex: _isAuthorMode ? 1 : 0,
              height: 28,
              onChanged: (i) => _onSearchTypeChanged(i == 1),
            ),
          ],
        ),
      ),
    );
  }

  /// 搜索历史下拉
  ///
  /// 展示在搜索栏下方，点击条目直接搜索；右侧 × 删除单条；右上角清空全部。
  Widget _buildSearchHistoryDropdown(AppState appState, AppTokens t) {
    final entries = appState.searchHistory.entries;
    final radius = BorderRadius.circular(AppRadius.xl);

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: radius,
        border: Border.all(color: t.line),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(t.dark ? 0.45 : 0.12),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题行 + 清空
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 2),
            child: Row(
              children: [
                Icon(Icons.history_rounded, size: 13, color: t.text3),
                const SizedBox(width: 6),
                Text(
                  '搜索历史',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: t.text3,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () async {
                    await appState.searchHistory.clear();
                    if (!mounted) return;
                    setState(() => _showHistory = false);
                  },
                  style: TextButton.styleFrom(
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    '清空',
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: t.text3),
                  ),
                ),
              ],
            ),
          ),
          // 历史条目（最多展示 8 条，避免下拉过高遮挡结果）
          ...entries.take(8).map((keyword) => InkWell(
                onTap: () => _applyHistory(appState, keyword),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          keyword,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13.5, color: t.text1),
                        ),
                      ),
                      // 单条删除
                      GestureDetector(
                        onTap: () => appState.searchHistory.remove(keyword),
                        behavior: HitTestBehavior.opaque,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Icon(Icons.close_rounded,
                              size: 15, color: t.text3),
                        ),
                      ),
                    ],
                  ),
                ),
              )),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  /// 排序下拉菜单
  Widget _buildSearchDropdown(AppTokens t) {
    return Theme(
      data: Theme.of(context).copyWith(canvasColor: t.surface),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _sortBy,
          isDense: true,
          icon: Icon(Icons.keyboard_arrow_down_rounded,
              size: 15, color: t.text3),
          style: TextStyle(
            color: t.text2,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          items: const [
            DropdownMenuItem(value: 'default', child: Text('默认')),
            DropdownMenuItem(value: 'new', child: Text('最新')),
            DropdownMenuItem(value: 'hot', child: Text('最热')),
          ],
          onChanged: (v) {
            if (v != null && v != _sortBy) {
              setState(() => _sortBy = v);
              // 切换排序必然重置到第 1 页，明确告知避免"我明明在第 5 页"的困惑
              const labels = {'default': '默认', 'new': '最新', 'hot': '最热'};
              _showSearchToast('已按「${labels[v] ?? v}」排序，已回到第 1 页');
              if (_lastKeyword.isNotEmpty) _search();
            }
          },
        ),
      ),
    );
  }

  /// 切换搜索类型
  ///
  /// 原来的实现只改标志位、不动结果，会出现"切到搜作者后，
  /// 屏幕上还留着上一次的视频结果"。这里让状态与结果保持一致：
  /// 输入框有内容就立刻按新类型重搜，没有就清空结果并提示输入。
  void _onSearchTypeChanged(bool toAuthor) {
    if (_isAuthorMode == toAuthor) return;

    final keyword = _keywordController.text.trim();

    setState(() {
      _isAuthorMode = toAuthor;
      _selectedIds.clear();
      // 结果与当前类型不再匹配，先清空，避免闪出错误内容
      _results.clear();
      _authorResults.clear();
      _currentPage = 1;
      _hasMore = true;
      _status = '就绪';
    });
    _syncPageController('1');
    _updateWillPopCallback();

    if (keyword.isNotEmpty) {
      _showSearchToast('已切换到搜${toAuthor ? "作者" : "视频"}，正在重新搜索');
      _search(); // _search 内部会按 _isAuthorMode 分流
    } else {
      _showSearchToast('已切换到搜${toAuthor ? "作者" : "视频"}，请输入关键词');
    }
  }

  /// 搜索页轻提示
  ///
  /// 统一封装，避免各处重复写 ScaffoldMessenger（并确保先 hide 掉上一条，
  /// 否则连续切换时提示会排队、显示滞后）。
  void _showSearchToast(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(milliseconds: 1600),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 80),
      ),
    );
  }

  /// 底部页码跳转区域（悬浮胶囊）
  Widget _buildBottomPageNavigation(AppState appState, AppTokens t) {
    // 底栏被遮住的原因：main_page 的 Scaffold 用了 extendBody: true
    // （底栏做毛玻璃需要内容透上来），body 的坐标系会延伸到屏幕底部。
    // extendBody 为 true 时，body 内的 MediaQuery.padding.bottom 恰好等于
    // 底栏总高，直接拿它当偏移量即可。
    final navInset = MediaQuery.of(context).padding.bottom;
    final canPrev = !_isLoading && !_isLoadingMore && _currentPage > 1;
    final canNext = !_isLoading && !_isLoadingMore;

    Widget arrow(IconData icon, bool enabled, VoidCallback onTap) {
      return GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: enabled ? t.accentSoft : t.surface2,
            borderRadius: BorderRadius.circular(AppRadius.sm + 1),
          ),
          child: Icon(icon,
              size: 18, color: enabled ? t.accent : t.text3),
        ),
      );
    }

    return Positioned(
      bottom: navInset + 16,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: t.line),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(t.dark ? 0.4 : 0.1),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              arrow(Icons.chevron_left_rounded, canPrev,
                  () => _goToPage(_currentPage - 1)),
              const SizedBox(width: 8),
              // 当前页码输入框 —— 既是页码显示器也是跳转输入器
              Container(
                width: 58,
                height: 30,
                decoration: BoxDecoration(
                  color: t.surface2,
                  borderRadius: BorderRadius.circular(AppRadius.sm + 1),
                ),
                child: Center(
                  child: TextField(
                    controller: _pageController,
                    focusNode: _pageFocusNode,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: t.text1,
                    ),
                    decoration: const InputDecoration(
                      hintText: '',
                      // 外层 Container 已铺 surface2 底，这里再 filled 会多盖一层深灰块
                      filled: false,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    onSubmitted: (_) {
                      final page = int.tryParse(_pageController.text);
                      if (page != null && page > 0) {
                        _goToPage(page);
                      }
                    },
                    textInputAction: TextInputAction.go,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              arrow(Icons.chevron_right_rounded, canNext,
                  () => _goToPage(_currentPage + 1)),
            ],
          ),
        ),
      ),
    );
  }

  void _toggleAll() {    setState(() {
      final currentVideos = _isAuthorPageMode ? _authorVideos : _results;
      if (_selectedIds.length == currentVideos.length) {
        _selectedIds.clear();
      } else {
        _selectedIds = currentVideos.map((v) => v.id).toSet();
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
      _loadedPage = page;  // 更新已加载页码
      _hasMore = results.isNotEmpty;
      _isLoading = false;
    });

    // 同步页码输入框显示
    _syncPageController('$page');
    
    // 滚动到顶部
    _scrollController.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  Future<void> _search() async {
    if (_keywordController.text.isEmpty) return;
    logger.mark('搜索', '${_isAuthorMode ? "作者" : "视频"}: ${_keywordController.text}');
    
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
      _loadedPage = 0;
      _hasMore = true;
      _lastKeyword = _keywordController.text;
    });
    // 同步页码输入框显示（放在 setState 之外，与 _goToPage/_loadMore 保持一致）
    _syncPageController('1');

    // 记录搜索历史（自动去重并置顶；空白词已在 service 内过滤）
    _rememberKeyword(appState, _keywordController.text);
    // 搜索后收起历史下拉
    if (_showHistory) {
      setState(() => _showHistory = false);
    }
    
    if (_isAuthorMode) {
      // 搜索作者
      final authors = await crawler.searchAuthors(_keywordController.text);
      logger.logSync('Search', '作者搜索 "${_keywordController.text}" 返回 ${authors.length} 个');

      setState(() {
        _authorResults = authors;
        _isLoading = false;
        _status = authors.isEmpty ? '无结果' : '就绪';
      });
    } else {
      // 搜索视频
      final results = await crawler.searchVideos(_keywordController.text, sort: _sortBy);
      logger.logSync('Search', '视频搜索 "${_keywordController.text}" (排序 $_sortBy) 返回 ${results.length} 条');

      setState(() {
        _results = results;
        _loadedPage = 1;  // 第一次搜索后，已加载第1页
        _selectedIds.clear();  // 默认不全选
        _isLoading = false;
        _status = results.isEmpty ? '无结果' : '就绪';
      });
    }
  }

  /// 构建视频搜索结果的 Sliver 版本
  Widget _buildVideoResultsSliver(AppState appState) {
    final t = AppTokens.of(context);
    final isListMode = appState.videoDisplayMode == 'list';

    // 作者主页模式使用 _authorVideos，普通模式使用 _results
    final videos = _isAuthorPageMode ? _authorVideos : _results;

    // 加载中
    if (_isLoading && videos.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: 120),
          child: Column(
            children: [
              CircularProgressIndicator(color: t.accent, strokeWidth: 2.5),
              const SizedBox(height: 16),
              Text('搜索中...',
                  style: TextStyle(fontSize: 13, color: t.text3)),
            ],
          ),
        ),
      );
    }

    // 无数据
    if (videos.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: 80),
          child: _lastKeyword.isEmpty
              ? EmptyState(
                  icon: Icons.search_rounded,
                  title: '输入关键词开始搜索',
                  subtitle: '支持搜索视频标题与作者名',
                  iconSize: 56,
                )
              : EmptyState(
                  icon: Icons.search_off_rounded,
                  title: '未找到“${_lastKeyword}”相关结果',
                  subtitle: '换个关键词试试',
                  iconSize: 56,
                ),
        ),
      );
    }

    if (isListMode) {
      return SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) =>
              _buildVideoListItem(videos[index], appState, videos.length),
          childCount: videos.length,
        ),
      );
    } else {
      return SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 0.82,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) => _buildVideoGridItem(videos[index], appState),
          childCount: videos.length,
        ),
      );
    }
  }

  /// 作者搜索结果的 Sliver 版本
  Widget _buildAuthorResultsSliver() {
    final t = AppTokens.of(context);

    if (_authorResults.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: 80),
          child: EmptyState(
            icon: Icons.person_search_rounded,
            title: '输入作者名搜索',
            subtitle: '搜索后可进入作者主页批量下载',
            iconSize: 56,
          ),
        ),
      );
    }

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final author = _authorResults[index];
          final radius = BorderRadius.circular(AppRadius.lg);
          return Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: Material(
              color: t.surface,
              borderRadius: radius,
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => _enterAuthorPageMode(author),
                child: Container(
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    border: Border.all(color: t.line),
                  ),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                        child: SizedBox(
                          width: 42,
                          height: 42,
                          child: CoverImage(
                            url: author.avatar,
                            borderRadius: BorderRadius.zero,
                            fallbackIcon: Icons.person_rounded,
                            blur: false,
                          ),
                        ),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              author.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                                color: t.text1,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              author.videoCount > 0
                                  ? '${author.videoCount} 个视频'
                                  : '点击查看视频',
                              style: TextStyle(fontSize: 11, color: t.text3),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded,
                          size: 20, color: t.text3),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
        childCount: _authorResults.length,
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

  /// 列表模式的单个视频项（与批量页保持一致）
  /// 列表模式的单个视频项
  ///
  /// 呈现逻辑已抽到共用组件 [VideoListItem]，这里只提供本页特有的交互
  /// （选中切换、封面点击在线播放、作者跳转）。
  Widget _buildVideoListItem(VideoInfo video, AppState appState, int totalCount) {
    final isSelected = _selectedIds.contains(video.id);
    final authorId = video.authorId;

    return VideoListItem(
      video: video,
      appState: appState,
      isSelected: isSelected,
      showUploadDate: true,
      onTap: () => _toggleSelection(video.id),
      onCoverTap: appState.streamingMode
          ? () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => StreamingPage(video: video)),
              )
          : null,
      onAuthorTap: (authorId != null && authorId.isNotEmpty)
          ? () => _enterAuthorPageMode(
                AuthorInfo(id: authorId, name: video.author ?? '', profileUrl: ''),
              )
          : null,
      isAuthorFollowed: (authorId != null && authorId.isNotEmpty)
          ? appState.followedAuthorsService.isFollowedSync(authorId)
          : false,
    );
  }

  /// 网格模式的单个视频项
  /// 网格模式的单个视频项 —— 呈现抽到共用组件
  Widget _buildVideoGridItem(VideoInfo video, AppState appState) {
    final isSelected = _selectedIds.contains(video.id);

    return VideoGridItem(
      video: video,
      appState: appState,
      isSelected: isSelected,
      onTap: () => _toggleSelection(video.id),
      onCoverTap: appState.streamingMode
          ? () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => StreamingPage(video: video)),
              )
          : null,
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
    
    // 检测哪些视频已经下载过
    final alreadyDownloaded = <VideoInfo>[];
    final newVideos = <VideoInfo>[];
    final inQueue = <VideoInfo>[];
    
    for (final video in selectedVideos) {
      if (appState.downloadManager.isVideoInQueue(video.id)) {
        inQueue.add(video);
      } else if (await appState.downloadManager.isVideoDownloaded(video.id)) {
        alreadyDownloaded.add(video);
      } else {
        newVideos.add(video);
      }
    }
    
    // 队列中已存在的视频，直接跳过并提示
    if (inQueue.isNotEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${inQueue.length} 个视频已在下载队列中，已跳过'),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
    
    // 上面的循环里 await 过（isVideoDownloaded），页面可能已被销毁。
    // 之后还要用 context 弹窗，这里必须先确认仍然挂载。
    if (!mounted) return;

    // 如果有已下载的视频，弹窗询问是否覆盖
    bool overwriteConfirmed = false;
    if (alreadyDownloaded.isNotEmpty) {
      if (newVideos.isEmpty && alreadyDownloaded.isNotEmpty) {
        // 全部已下载，询问是否全部覆盖
        overwriteConfirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('视频已下载'),
            content: Text('选中的 ${alreadyDownloaded.length} 个视频已经下载过了，是否覆盖重新下载？'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('覆盖下载')),
            ],
          ),
        ) ?? false;
        if (!overwriteConfirmed) {
          setState(() => _selectedIds.clear());
          return;
        }
      } else {
        // 部分已下载，询问是否覆盖已下载的部分
        final result = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('检测到已下载视频'),
            content: Text(
              '选中的 ${selectedVideos.length} 个视频中：\n'
              '• ${newVideos.length} 个新视频\n'
              '• ${alreadyDownloaded.length} 个已下载\n'
              '• ${inQueue.length} 个在队列中\n\n'
              '是否覆盖已下载的 ${alreadyDownloaded.length} 个视频？',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('取消')),
              TextButton(onPressed: () => Navigator.pop(ctx, 'new_only'), child: const Text('只下载新的')),
              TextButton(onPressed: () => Navigator.pop(ctx, 'all'), child: const Text('全部下载')),
            ],
          ),
        );
        
        if (result == null || result == 'cancel') {
          setState(() => _selectedIds.clear());
          return;
        }
        if (result == 'all') {
          overwriteConfirmed = true;
        }
        // result == 'new_only' 时 overwriteConfirmed 保持 false
      }
    }
    
    // 添加新视频到下载队列
    final toDownload = <VideoInfo>[...newVideos];
    if (overwriteConfirmed) {
      toDownload.addAll(alreadyDownloaded);
    }
    
    if (toDownload.isNotEmpty) {
      final result = await appState.downloadManager.addTasks(toDownload, forceRestart: overwriteConfirmed);
      if (mounted) {
        final msg = '已添加 ${result['new']} 个视频到下载队列'
            '${result['duplicate']! > 0 ? '，${result['duplicate']} 个已跳过' : ''}';
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
            action: SnackBarAction(
              label: '查看',
              onPressed: () {
                // 切换到下载页面（索引3）
                appState.navigateToPage?.call(3);
              },
            ),
          ),
        );
      }
    }
    
    // 清空选择
    setState(() {
      _selectedIds.clear();
    });
  }
}
