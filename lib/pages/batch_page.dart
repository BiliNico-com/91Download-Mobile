import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/video_info.dart';
import '../services/app_state.dart';
import '../services/floating_video_service.dart';
import '../components/empty_state.dart';
import '../components/video_list_items.dart';
import '../components/category_chips.dart';
import '../components/app_shell.dart';
import '../theme/app_tokens.dart';
import '../theme/ui_style.dart';
import '../utils/logger.dart';
import 'streaming_page.dart';

class BatchPage extends StatefulWidget {
  const BatchPage({super.key});

  @override
  State<BatchPage> createState() => _BatchPageState();
}

class _BatchPageState extends State<BatchPage> with AutomaticKeepAliveClientMixin {
  String _selectedType = 'list';

  /// 上一次渲染时的站点地址，用于检测"更换网址"
  ///
  /// 用**网址**而不是 siteType：两个不同网址可能属于同一类型
  /// （例如都在 original CMS 体系下），那时 siteType 不变，
  /// 只比较 siteType 会漏判，页面会继续显示上一个网址的数据。
  String? _lastSiteUrl;

  int _currentPage = 1;
  int _loadedPage = 0;
  bool _hasMore = true;
  List<VideoInfo> _videos = [];
  Set<String> _selectedIds = {};
  bool _isLoading = false;
  bool _isLoadingMore = false;
  String _status = '就绪';
  double _progress = 0.0;
  String _progressText = '';
  int _totalVideos = 0;
  
  // 作者主页模式
  bool _isAuthorPageMode = false;
  String _currentAuthorId = '';
  String _currentAuthorName = '';
  List<VideoInfo> _authorVideos = [];
  int _authorCurrentPage = 0;
  bool _authorHasMore = true;
  
  // 进入作者主页前的滚动位置（返回时恢复）
  double _savedScrollOffset = 0;

  final ScrollController _scrollController = ScrollController();
  bool _showBackToTop = false;
  final TextEditingController _pageController = TextEditingController();
  // 页码输入框焦点（用于判断能否安全写入页码）
  final FocusNode _pageFocusNode = FocusNode();

  // ─── 布局常量 ───
  // 展开态内容实际高度：标题行(48) + 副标题(19) + 分类标签行(52) = 119，
  // 但内容里还补了一次状态栏占位，两者叠加才是顶栏偏高的来源。
  // 这里只保留内容本身需要的高度（111）再略加余量，
  // 避免 mainAxisAlignment.end 把富余高度堆到顶部、把标题下推。
  static const double _kExpandedHeight = 138.0;
  static const double _kCollapsedHeight = 52.0;

  @override
  bool get wantKeepAlive => true;

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
    _pageFocusNode.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _onScroll() {
    // ─── 回顶部按钮显示/隐藏 ───
    final showBtn = _scrollController.offset > 500;
    if (showBtn != _showBackToTop) {
      setState(() => _showBackToTop = showBtn);
    }
    // ─── 瀑布流自动加载 ───
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      if (!_isLoading && !_isLoadingMore) {
        // 作者主页模式
        if (_isAuthorPageMode && _authorHasMore && _authorVideos.isNotEmpty) {
          _loadMoreAuthorVideos();
        }
        // 普通模式
        else if (!_isAuthorPageMode && _hasMore && _videos.isNotEmpty) {
          _loadMore();
        }
      }
    }
  }

  Future<void> _loadMore() async {
    if (!_hasMore || _isLoading || _isLoadingMore) return;
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) return;

    setState(() => _isLoadingMore = true);
    final nextPage = _loadedPage + 1;
    final newVideos = await crawler.getVideoList(_selectedType, nextPage);
    logger.logSync(
      'Batch',
      '列表「$_selectedType」第 $nextPage 页返回 ${newVideos.length} 条'
      '（站点类型 ${crawler.siteType}，还有下一页: ${crawler.lastRequestHasMore}）',
    );

    if (newVideos.isEmpty) {
      setState(() {
        _hasMore = false;
        _isLoadingMore = false;
      });
    } else {
      // 由爬虫依据站点"下一页"控件判定（条数不固定时更可靠）
      final siteHasMore = crawler.lastRequestHasMore;
      setState(() {
        // 去重：过滤掉已存在的视频
        final existingIds = _videos.map((v) => v.id).toSet();
        final uniqueNewVideos = newVideos.where((v) => !existingIds.contains(v.id)).toList();
        _videos.addAll(uniqueNewVideos);
        _totalVideos = _videos.length;
        _loadedPage = nextPage;
        _hasMore = siteHasMore;
        _isLoadingMore = false;
      });
      // 同步页码显示（滚动加载后胶囊/输入框需要跟着变）
      _syncPageController('$nextPage');
    }
  }

  /// 把页码同步到输入框
  ///
  /// 仅在输入框「未获得焦点」时直接赋值：TextField 聚焦时 Flutter 会用
  /// 内部编辑态覆盖 controller.text，导致滚动加载后页码不更新。
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

  void _scrollToTop() {
    _scrollController.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }
  
  /// 进入作者主页模式
  Future<void> _enterAuthorPageMode(String authorId, String authorName) async {
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) return;
    
    logger.mark('进入作者主页', '$authorName ($authorId)');

    // 保存当前滚动位置
    _savedScrollOffset = _scrollController.offset;
    
    // 设置返回键回调，让 MainPage 能处理作者模式的返回
    appState.onWillPopCallback = () {
      if (_isAuthorPageMode) {
        _exitAuthorPageMode();
        return true;
      }
      return false;
    };
    
    setState(() {
      _isAuthorPageMode = true;
      _currentAuthorId = authorId;
      _currentAuthorName = authorName;
      _authorVideos.clear();
      _authorCurrentPage = 0;
      _authorHasMore = true;
      _selectedIds.clear();
    });
    
    // 滚动到顶部加载作者视频
    _scrollController.jumpTo(0);
    await _loadMoreAuthorVideos();
  }
  
  /// 退出作者主页模式
  void _exitAuthorPageMode() {
    final appState = context.read<AppState>();
    // 清除返回键回调
    appState.onWillPopCallback = null;
    
    final savedOffset = _savedScrollOffset;
    setState(() {
      _isAuthorPageMode = false;
      _authorVideos.clear();
      _currentAuthorId = '';
      _currentAuthorName = '';
      _selectedIds.clear();
    });
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
  
  /// 加载更多作者视频
  Future<void> _loadMoreAuthorVideos() async {
    if (!_authorHasMore || _isLoading) return;
    
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) return;
    
    setState(() => _isLoading = true);
    _authorCurrentPage++;
    
    final newVideos = await crawler.getAuthorVideos(_currentAuthorId, page: _authorCurrentPage);
    logger.logSync(
      'Batch',
      '作者 $_currentAuthorName 第 $_authorCurrentPage 页返回 ${newVideos.length} 条',
    );
    
    if (newVideos.isEmpty) {
      setState(() {
        _authorHasMore = false;
        _isLoading = false;
      });
    } else {
      // 由爬虫依据站点"下一页"控件判定（条数不固定时更可靠）
      final siteHasMore = crawler.lastRequestHasMore;
      setState(() {
        // 去重：过滤掉已存在的视频
        final existingIds = _authorVideos.map((v) => v.id).toSet();
        final uniqueNewVideos = newVideos.where((v) => !existingIds.contains(v.id)).toList();
        _authorVideos.addAll(uniqueNewVideos);
        _isLoading = false;
        _authorHasMore = siteHasMore;
      });
    }
  }
  
  /// 下拉刷新（只在顶部时触发）
  Future<void> _onRefresh() async {
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) return;
    
    if (_isAuthorPageMode) {
      // 作者模式下刷新作者视频
      setState(() {
        _authorVideos.clear();
        _selectedIds.clear();
        _authorCurrentPage = 0;
        _authorHasMore = true;
      });
      await _loadMoreAuthorVideos();
    } else {
      // 重新加载第一页
      setState(() {
        _videos.clear();
        _selectedIds.clear();
        _loadedPage = 0;
        _hasMore = true;
      });
      await _goToPage();
    }
  }

  /// 切换悬浮窗到指定视频
  Future<void> _switchToFloatingVideo(VideoInfo video) async {
    try {
      // 从下载历史获取本地文件路径
      final appState = context.read<AppState>();
      final crawler = appState.crawler;
      final localPath = await crawler?.getDownloadedPath(video.id);

      if (localPath != null && localPath.isNotEmpty) {
        // 直接切换视频
        await FloatingVideoService.switchVideo(
          videoPath: localPath,
          title: video.title,
        );
        debugPrint('[BatchPage] 已切换悬浮窗到: ${video.title}');
      } else {
        // 显示提示：需要先下载才能在悬浮窗播放
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('请先下载视频才能在悬浮窗播放'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('[BatchPage] 切换悬浮窗失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('切换视频失败'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

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

  static const _typeNamesOriginal = {
    'list': '视频',
    'top7': '周榜',
    'top': '月榜',
    '5min': '5分钟+',
    'long': '10分钟+',
  };

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final statusBarH = MediaQuery.of(context).padding.top;
    final theme = Theme.of(context);
    return Consumer<AppState>(
      builder: (context, appState, _) {
        if (!appState.isSiteSelected) {
          return _buildNoSiteSelected();
        }

        final siteType = appState.crawler?.siteType ?? 'original';
        final typeNames = _getTypeNames(siteType);

        // ── 更换网址处理 ──
        // 两个站点常共用同一个分类键 'list'（视频），所以换站后
        // 「当前选中项是否仍存在」往往是 true，只靠 containsKey 会漏掉——
        // 结果是页面上还显示着上一个网址的数据。
        //
        // 这里以**网址**为准（而不是 siteType）：同一 CMS 体系下的两个不同
        // 网址 siteType 相同，但内容完全不同，同样需要重置。
        //
        // 注意：首次构建时 _lastSiteUrl 为 null，那只是"第一次见到"，
        // 不是切换，不能触发重置（否则会和下面的"自动加载第一页"重复请求）。
        final siteUrl = appState.currentSite ?? '';
        if (_lastSiteUrl == null) {
          _lastSiteUrl = siteUrl;
        } else if (_lastSiteUrl != siteUrl) {
          _lastSiteUrl = siteUrl;
          // 新站点若不含当前分类，先回落第一个
          final fallback =
              typeNames.containsKey(_selectedType) ? _selectedType : typeNames.keys.first;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() {
              _selectedType = fallback;
              _videos.clear();
              _selectedIds.clear();
              _loadedPage = 0;
              _currentPage = 1;
              _hasMore = true;
              _status = '就绪';
            });
            _syncPageController('1');
            _scrollToTop();
            _goToPage();
          });
        } else if (!typeNames.containsKey(_selectedType)) {
          // 同一站点内分类集合变化（如自定义站点调整）时的兜底
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() {
                _selectedType = typeNames.keys.first;
                _videos.clear();
                _selectedIds.clear();
                _loadedPage = 0;
                _hasMore = true;
              });
              _syncPageController('1');
              _goToPage();
            }
          });
        }
        // ─── 自动加载第一页 ───
        if (_videos.isEmpty && !_isLoading && appState.crawler != null) {
          Future.microtask(() => _goToPage());
        }
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
            extendBodyBehindAppBar: true,
            // 跟随主题，别写死白色：
            // 列表区只有卡片的 Card.margin 露底，写死白色时
            // 顶栏玻璃边界到首张卡片之间会是一条突兀的白带，
            // 深色模式下更明显（卡片深灰、四周纯白）。
            backgroundColor: theme.scaffoldBackgroundColor,
            body: Stack(
              children: [
                RefreshIndicator(
                  onRefresh: _onRefresh,
                  color: Colors.blue,
                  backgroundColor: theme.cardColor,
                  displacement: 40,
                  child: CustomScrollView(
                  controller: _scrollController,
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    // ══════════════════════════════════════
                    //  顶部折叠栏（SliverAppBar）
                    //  与搜索页使用同一套机制：floating + snap 让任意滚动位置
                    //  下拉都能把顶栏拽出来，松手自动补完/弹回
                    // ══════════════════════════════════════
                    SliverAppBar(
                      pinned: true,
                      floating: true,
                      snap: true,
                      expandedHeight: statusBarH + _kExpandedHeight,
                      backgroundColor: Colors.transparent,
                      elevation: 0,
                      scrolledUnderElevation: 0,
                      automaticallyImplyLeading: false,
                      flexibleSpace: LayoutBuilder(
                        builder: (ctx, constraints) {
                          // 由 SliverAppBar 的实际高度反推折叠进度，
                          // 不再依赖 _onScroll 手动计算
                          final range = _kExpandedHeight - _kCollapsedHeight;
                          final collapsed = (constraints.maxHeight -
                                  statusBarH -
                                  _kCollapsedHeight)
                              .clamp(0.0, range);
                          final ratio = 1.0 - collapsed / range;
                          return _BatchHeader(
                            statusBarHeight: statusBarH,
                            expandedHeight: _kExpandedHeight,
                            collapsedHeight: _kCollapsedHeight,
                            collapseRatio: ratio,
                            selectedType: _selectedType,
                            typeNames: _getTypeNames(
                                appState.crawler?.siteType ?? 'original'),
                            videoCount: _isAuthorPageMode
                                ? _authorVideos.length
                                : _videos.length,
                            selectedCount: _selectedIds.length,
                            totalCount: _isAuthorPageMode
                                ? _authorVideos.length
                                : _videos.length,
                            status: _status,
                            privacyMode: appState.privacyMode,
                            isAuthorPageMode: _isAuthorPageMode,
                            authorName: _currentAuthorName,
                            isFollowed: _isAuthorPageMode &&
                                appState.followedAuthorsService
                                    .isFollowedSync(_currentAuthorId),
                            sitePill: SitePill(
                              appState: appState,
                              onTap: () => appState.navigateToPage?.call(4),
                            ),
                            onBack:
                                _isAuthorPageMode ? _exitAuthorPageMode : null,
                            onFollowToggle: _isAuthorPageMode
                                ? () async {
                                    final currentlyFollowed = appState
                                        .followedAuthorsService
                                        .isFollowedSync(_currentAuthorId);
                                    final String? error;
                                    if (currentlyFollowed) {
                                      error = await appState
                                          .followedAuthorsService
                                          .unfollow(_currentAuthorId);
                                    } else {
                                      error = await appState
                                          .followedAuthorsService
                                          .follow(_currentAuthorId,
                                              _currentAuthorName);
                                    }
                                    if (!mounted) return;
                                    logger.mark(
                                      currentlyFollowed ? '取消关注' : '关注作者',
                                      '$_currentAuthorName ($_currentAuthorId)'
                                      '${error == null ? "" : " 失败: $error"}',
                                    );
                                    setState(() {});
                                    // 写库失败必须让用户看见，否则按钮
                                    // 看上去就是「点了没反应」。
                                    if (error != null) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(SnackBar(
                                              content: Text(error)));
                                    }
                                  }
                                : null,
                            onTypeChanged: (v) async {
                              if (v != _selectedType) {
                                setState(() {
                                  _selectedType = v;
                                  _videos.clear();
                                  _selectedIds.clear();
                                  _loadedPage = 0;
                                });
                                _pageController.text = '1';
                                final label = _getTypeNames(
                                        appState.crawler?.siteType ??
                                            'original')[v] ??
                                    v;
                                logger.mark('切换分类', '$label ($v)');
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('已切换到「$label」，正在加载'),
                                    duration: const Duration(seconds: 1),
                                    behavior: SnackBarBehavior.floating,
                                  ),
                                );
                                await _goToPage();
                              }
                            },
                            onPrivacyToggle: () =>
                                appState.togglePrivacyMode(),
                            onSelectAll: () {
                              final currentVideos =
                                  _isAuthorPageMode ? _authorVideos : _videos;
                              final isAllSelected =
                                  _selectedIds.length == currentVideos.length;
                              setState(() {
                                if (isAllSelected) {
                                  _selectedIds.clear();
                                } else {
                                  _selectedIds =
                                      currentVideos.map((v) => v.id).toSet();
                                }
                              });
                            },
                          );
                        },
                      ),
                    ),

                  // 内容区域 - 视频列表
                  // 顶部不再额外留 8：贴顶栏更紧凑，间距交给 Card 自带 margin
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    sliver: _buildSliverVideoGrid(appState),
                  ),

                  // 底部留白
                  SliverToBoxAdapter(
                    child: SizedBox(height: 100),
                  ),
                ],
                ),
              ),
              // 悬浮覆盖层
              ..._buildOverlays(appState),
            ],
          ),
        ),
        );  // WillPopScope
      },
    );
  }

  Widget _buildNoSiteSelected() {
    final t = AppTokens.of(context);
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        toolbarHeight: 62,
        titleSpacing: 16,
        title: Text(
          '批量爬取',
          style: TextStyle(
            fontSize: 23,
            height: 1.15,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.4,
            color: t.text1,
          ),
        ),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: t.accentSoft,
                borderRadius: BorderRadius.circular(AppRadius.xxl),
              ),
              child: Icon(Icons.language, size: 30, color: t.accent),
            ),
            const SizedBox(height: 16),
            Text('请先选择站点',
                style: TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w700, color: t.text1)),
            const SizedBox(height: 8),
            Text('在设置页面选择要使用的站点',
                style: TextStyle(fontSize: 13, color: t.text3)),
            const SizedBox(height: 20),
            GestureDetector(
              onTap: () => context.read<AppState>().navigateToPage?.call(4),
              behavior: HitTestBehavior.opaque,
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppTokens.blue,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: const Text(
                  '去选择站点',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildOverlays(AppState appState) {
    final t = AppTokens.of(context);
    final navInset = MediaQuery.of(context).padding.bottom;
    final hasSelection = _selectedIds.isNotEmpty;
    return [
      // 页码跳转（作者主页模式隐藏；多选时让位给底部浮条，否则两者叠在一起）
      if (!_isAuthorPageMode && !hasSelection) _buildBottomPageNavigation(),
      if (_showBackToTop && appState.showBackToTop)
        Positioned(
          bottom: hasSelection
              ? navInset + 84
              : (appState.backToTopPosition == 'right' ? navInset + 16 : navInset + 74),
          left: appState.backToTopPosition == 'left' ? 14 : null,
          right: appState.backToTopPosition == 'right' ? 14 : null,
          child: GestureDetector(
            onTap: _scrollToTop,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: t.surface,
                shape: BoxShape.circle,
                border: Border.all(color: t.line),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(t.dark ? 0.4 : 0.08),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Icon(Icons.arrow_upward_rounded, size: 19, color: t.text2),
            ),
          ),
        ),
      // 底部多选浮条（原型 .floatbar）
      if (hasSelection)
        Positioned(
          left: 12,
          right: 12,
          bottom: navInset + 12,
          child: AppFloatBar(
            selectedCount: _selectedIds.length,
            actionLabel: '开始下载',
            onAction: _startDownload,
            onCancel: () => setState(() => _selectedIds.clear()),
          ),
        ),
    ];
  }

  Widget _buildSliverVideoGrid(AppState appState) {
    final isListMode = appState.videoDisplayMode == 'list';
    // ✅ 修复：根据作者页面模式切换数据源
    final videos = _isAuthorPageMode ? _authorVideos : _videos;
    if (_isLoading && videos.isEmpty) {
      return SliverToBoxAdapter(child: Center(child: CircularProgressIndicator()));
    }
    if (videos.isEmpty) {
      return SliverToBoxAdapter(
        child: EmptyState(
          icon: Icons.video_library_outlined,
          title: _isAuthorPageMode ? '该作者暂无视频' : '暂无视频',
          subtitle: _isAuthorPageMode ? null : '输入页码并点击跳转按钮开始浏览',
        ),
      );
    }
    if (isListMode) {
      return SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => _buildVideoListItem(videos[index], appState),
          childCount: videos.length,
        ),
      );
    } else {
      return SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 0.85,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) => _buildVideoGridItem(videos[index], appState),
          childCount: videos.length,
        ),
      );
    }
  }

  // 说明：作者行（含「已关注」角标）已统一到共用组件 VideoListItem，
  // 原 _buildAuthorRowWithFollow / _buildGridAuthorRow 已移除。


  /// 列表模式的单个视频项 —— 呈现抽到共用组件
  ///
  /// 本页特有交互：
  ///   · 点击时若悬浮窗正在播放且该视频已下载，则切换悬浮窗视频
  ///   · 点击作者名进入页内作者主页模式
  Widget _buildVideoListItem(VideoInfo video, AppState appState) {
    final isSelected = _selectedIds.contains(video.id);
    final authorId = video.authorId;
    final hasAuthor = video.author != null &&
        video.author!.isNotEmpty &&
        authorId != null &&
        authorId.isNotEmpty;

    return VideoListItem(
      video: video,
      appState: appState,
      isSelected: isSelected,
      showUploadDate: true,
      onTap: () async {
        // 如果悬浮窗正在播放，且该视频已下载，则切换到该视频
        // （用原生真实状态判断，本地标记在用户关闭悬浮窗后会失效）
        if (await FloatingVideoService.isActuallyRunning()) {
          final crawler = appState.crawler;
          final localPath = await crawler?.getDownloadedPath(video.id);

          if (localPath != null && localPath.isNotEmpty) {
            await _switchToFloatingVideo(video);
            return;
          }
          // 未下载，继续执行勾选逻辑
        }
        if (!mounted) return;
        setState(() {
          if (isSelected) {
            _selectedIds.remove(video.id);
          } else {
            _selectedIds.add(video.id);
          }
        });
      },
      onCoverTap: appState.streamingMode
          ? () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => StreamingPage(video: video)),
              )
          : null,
      onAuthorTap: hasAuthor
          ? () => _enterAuthorPageMode(authorId, video.author!)
          : null,
      isAuthorFollowed:
          hasAuthor && appState.followedAuthorsService.isFollowedSync(authorId),
    );
  }

  /// 网格模式的单个视频项 —— 呈现抽到共用组件
  Widget _buildVideoGridItem(VideoInfo video, AppState appState) {
    final isSelected = _selectedIds.contains(video.id);

    return VideoGridItem(
      video: video,
      appState: appState,
      isSelected: isSelected,
      showUpdateDateBadge: true,
      onTap: () async {
        // 悬浮窗在播且该视频已下载 → 切换悬浮窗视频（与列表模式一致）
        if (await FloatingVideoService.isActuallyRunning()) {
          final crawler = appState.crawler;
          final localPath = await crawler?.getDownloadedPath(video.id);

          if (localPath != null && localPath.isNotEmpty) {
            await _switchToFloatingVideo(video);
            return;
          }
        }
        if (!mounted) return;
        setState(() {
          if (isSelected) {
            _selectedIds.remove(video.id);
          } else {
            _selectedIds.add(video.id);
          }
        });
      },
      onCoverTap: appState.streamingMode
          ? () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => StreamingPage(video: video)),
              )
          : null,
    );
  }

  /// jiuse 站点（91porny / jiuse.icu）的分类
  ///
  /// 来源有两个，都要有：
  ///   ① 顶部导航 /videos(蝌蚪) /vod(精品)
  ///   ② 视频列表页的分区面板 —— 移动端「选择分类」折叠面板与桌面端
  ///      左侧栏是同一份 14 项 data-href，网页上两者内容完全一致。
  /// 之前只做了 ①，分类标签只有 3 个，用户看到网页上十几个分区却没有。
  ///
  /// 高清（/video 与 /video/category/hd）被有意剔除：这两个入口的卡片全是
  /// /video/viewhd/，未登录下载只会拿到所有视频共用的 12 秒样片或 6 秒 VIP 占位。
  /// 'list' 因此改指首页。
  static const _typeNamesJiuse = {
    // ① 顶部导航
    'list': '首页',
    'videos': '蝌蚪',
    'vod': '精品',
    // ② 分区面板（顺序与网页一致，去掉「高清视频」）
    'latest': '最近更新',
    'rf': '最近加精',
    'hot': '当前最热',
    'rating': '最近得分',
    'nonpaid': '非付费',
    'ori': '91原创',
    'long': '10分钟以上',
    'longer': '20分钟以上',
    'discuss': '本月讨论',
    'tf': '本月收藏',
    'mf': '收藏最多',
    'top': '本月最热',
    'last': '上月最热',
  };

  /// 嗨碰（hifuli.com）的分区
  ///
  /// 只列真正能翻页的 4 个入口：
  /// 首页与 /video 每次请求内容都会随机重排、且没有分页控件，因此只取第 1 页。
  /// 站点导航里的 /tag/guochan、/Aiface、/me/favorites 不是普通分区
  /// （/Aiface 实测 0 条视频），不放进分类栏。
  static const _typeNamesHifuli = {
    'list': '首页',
    'video': '最新视频',
    'recommend': '推荐',
    'hot': '热榜',
  };

  Map<String, String> _getTypeNames(String siteType) {
    if (siteType == 'jiuse') return _typeNamesJiuse;
    if (siteType == 'hifuli') return _typeNamesHifuli;
    return siteType == 'porn91' ? _typeNamesPorn91 : _typeNamesOriginal;
  }

  /// 页码跳转浮条（原型 .pager：30x30 / r9 / 描边）
  ///
  /// 原来是一个白底胶囊里塞两个蓝色圆钮 + 64 宽输入框，阴影很重；
  /// 现在收成一块贴着底栏的轻量卡片，三个控件统一 30 高、9 圆角，
  /// 与任务卡、分段控件同一套圆角语言。
  Widget _buildBottomPageNavigation() {
    final t = AppTokens.of(context);
    // 底栏被遮住的原因：main_page 的 Scaffold 用了 extendBody: true
    // （底栏做毛玻璃需要内容透上来），body 的坐标系会延伸到屏幕底部。
    // extendBody 为 true 时，body 内的 MediaQuery.padding.bottom 恰好等于
    // 底栏总高，直接拿它当偏移量即可。
    final navBarHeight = MediaQuery.of(context).padding.bottom;
    final canPrev = !_isLoading && !_isLoadingMore && _loadedPage > 1;
    final canNext = !_isLoading && !_isLoadingMore;

    Widget arrow(IconData icon, bool enabled, VoidCallback onTap) {
      return GestureDetector(
        onTap: enabled ? onTap : null,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: enabled ? t.accentSoft : t.surface2,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(
            icon,
            size: 18,
            color: enabled ? t.accent : t.text3,
          ),
        ),
      );
    }

    return Positioned(
      bottom: navBarHeight + 14,
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
                color: Colors.black.withOpacity(t.dark ? 0.45 : 0.07),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              arrow(Icons.chevron_left_rounded, canPrev,
                  () => _goToPageDirect(_loadedPage - 1)),
              const SizedBox(width: 8),
              Container(
                width: 58,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: t.surface2,
                  borderRadius: BorderRadius.circular(9),
                ),
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
                    contentPadding: EdgeInsets.symmetric(horizontal: 4),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  onSubmitted: (_) => _goToPage(),
                  textInputAction: TextInputAction.go,
                ),
              ),
              const SizedBox(width: 8),
              arrow(Icons.chevron_right_rounded, canNext,
                  () => _goToPageDirect(_loadedPage + 1)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _goToPageDirect(int targetPage) async {
    if (targetPage < 1) return;
    _pageController.text = targetPage.toString();
    await _goToPage();
  }

  Future<void> _goToPage() async {
    final targetPage = int.tryParse(_pageController.text) ?? 1;
    if (targetPage < 1) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('请输入有效的页码')));
      return;
    }
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) {
      setState(() => _status = '请先选择站点');
      return;
    }

    setState(() {
      _status = '加载中...';
      _isLoading = true;
      _videos.clear();
      _selectedIds.clear();
      _hasMore = true;
    });

    final videos = await crawler.getVideoList(_selectedType, targetPage);
    // 由爬虫依据站点"下一页"控件判定是否还有更多（条数不固定时更可靠）
    final siteHasMore = crawler.lastRequestHasMore;
    setState(() {
      _videos = videos;
      _totalVideos = videos.length;
      _loadedPage = targetPage;
      _currentPage = targetPage;
      _isLoading = false;
      _status = videos.isEmpty ? '无结果' : '就绪';
      _hasMore = videos.isEmpty ? false : siteHasMore;
    });
    _syncPageController('$targetPage');
    _scrollToTop();
  }

  Future<void> _startDownload() async {
    final appState = context.read<AppState>();
    // ✅ 修复：根据作者页面模式使用正确的视频列表
    final currentVideos = _isAuthorPageMode ? _authorVideos : _videos;
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
    
    // 队列中已存在的视频（正在下载/等待/暂停），直接跳过并提示
    if (inQueue.isNotEmpty) {
      if (mounted) {
        // 先 hide 再 show：ScaffoldMessenger 是队列语义，不 hide 的话
        // 上一条还没走完，新提示会排在后面，用户感觉「弹了但没反应」。
        // 样式（悬浮 + 距底 70）由 AppTheme.snackBarThemeData 统一给。
        final messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(SnackBar(
          content: Text('${inQueue.length} 个视频已在下载队列中，已跳过'),
          duration: const Duration(seconds: 2),
        ));
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
        final messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            content: Text(msg),
            duration: const Duration(seconds: 3),
            action: SnackBarAction(label: '查看', onPressed: () => appState.navigateToPage?.call(3)),
          ),
        );
      }
    }
    
    setState(() => _selectedIds.clear());
  }
}

// ════════════════════════════════════════════════════════════
//  顶部折叠栏内容组件
//  由 SliverAppBar.flexibleSpace 里的 LayoutBuilder 反推折叠进度后渲染，
//  与搜索页共用 SliverAppBar + floating/snap 这一套折叠机制。
// ════════════════════════════════════════════════════════════
class _BatchHeader extends StatelessWidget {
  final double statusBarHeight;
  final double expandedHeight;
  final double collapsedHeight;
  final double collapseRatio;
  final String selectedType;
  final Map<String, String> typeNames;
  final int videoCount;
  final int selectedCount;
  final int totalCount;
  final String status;
  final bool privacyMode;
  final bool isAuthorPageMode;
  final String authorName;
  final bool isFollowed;
  final Widget? sitePill;
  final VoidCallback? onBack;
  final VoidCallback? onFollowToggle;
  final ValueChanged<String> onTypeChanged;
  final VoidCallback onPrivacyToggle;
  final VoidCallback onSelectAll;

  const _BatchHeader({
    super.key,
    required this.statusBarHeight,
    required this.expandedHeight,
    required this.collapsedHeight,
    required this.collapseRatio,
    required this.selectedType,
    required this.typeNames,
    required this.videoCount,
    required this.selectedCount,
    required this.totalCount,
    required this.status,
    required this.privacyMode,
    this.isAuthorPageMode = false,
    this.authorName = '',
    this.isFollowed = false,
    this.sitePill,
    this.onBack,
    this.onFollowToggle,
    required this.onTypeChanged,
    required this.onPrivacyToggle,
    required this.onSelectAll,
  });

  @override
  Widget build(BuildContext ctx) {
    // 顶部栏背后是滚动的视频列表 —— 这里最能体现毛玻璃开关的差异：
    //   开启 → 半透明，内容从栏下穿过时可见模糊
    //   关闭 → 完全不透明，内容被挡住
    //
    // 底色统一由 UiStyle 计算，与搜索页顶栏、底部导航栏共用同一套公式，
    // 这样两侧不会出现深浅不一的情况；同时监听浓度滑块。
    return ValueListenableBuilder<bool>(
      valueListenable: UiStyle.glassEnabled,
      builder: (context, glass, _) {
        return ValueListenableBuilder<double>(
          valueListenable: UiStyle.glassOpacity,
          builder: (context, _, __) {
            final t = AppTokens.of(ctx);
            final bgColor = glass
                ? UiStyle.headerGlassFill(t.dark, collapseRatio)
                : t.surface;

            final header = Container(
              color: bgColor,
              // flexibleSpace 拿到的是 appbar 的固定高度（含状态栏）。
              // 内容排布：状态栏占位 + 标题行 + 站点行 + 分类标签行。
              // 若容器高度小于内容总高，Column 会溢出并把多余部分挤到
              // 列表上方，表现为分类标签与第一个视频之间一大片空白。
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  SizedBox(height: statusBarHeight),
                  _buildTitleRow(t, collapsed: collapseRatio >= 0.5),
                  if (collapseRatio < 0.5) _buildMetaRow(t),
                  if (collapseRatio < 0.5 && !isAuthorPageMode)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: CategoryChips(
                        entries: typeNames,
                        selected: selectedType,
                        onSelected: onTypeChanged,
                        isDark: t.dark,
                      ),
                    ),
                  if (collapseRatio < 0.5) const SizedBox(height: 4),
                ],
              ),
            );

            // 玻璃关闭时直接返回实心容器，完全省掉 BackdropFilter 的开销
            if (!glass) return header;

            return ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: header,
              ),
            );
          },
        );
      },
    );
  }

  /// 第一行：大标题（折叠时缩到 17）+ 右侧操作
  Widget _buildTitleRow(AppTokens t, {required bool collapsed}) {
    final title = isAuthorPageMode ? authorName : '批量爬取';
    return Padding(
      padding: EdgeInsets.fromLTRB(14, collapsed ? 4 : 5, 10, collapsed ? 10 : 6),
      child: Row(
        children: [
          if (isAuthorPageMode && onBack != null) ...[
            // 与全站 AppIconBtn 同尺寸（34x34 / r11 / 图标 19）；
            // 底色仍用 accentSoft，因为这里在浅底标题行上，不是播放页的深色浮层。
            GestureDetector(
              onTap: onBack,
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 34,
                height: 34,
                margin: const EdgeInsets.only(right: 10),
                decoration: BoxDecoration(
                  color: t.accentSoft,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.arrow_back_rounded, size: 19, color: t.accent),
              ),
            ),
          ],
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    isAuthorPageMode ? '作者: $title' : title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: collapsed ? 17 : 23,
                      height: 1.15,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                      color: t.text1,
                    ),
                  ),
                ),
                if (isAuthorPageMode && onFollowToggle != null) ...[
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: onFollowToggle,
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      height: collapsed ? 24 : 26,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: isFollowed ? t.dangerSoft : t.accentSoft,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isFollowed
                                ? Icons.favorite_rounded
                                : Icons.favorite_border_rounded,
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
                  ),
                ],
              ],
            ),
          ),
          if (!isAuthorPageMode && selectedCount > 0) ...[
            GestureDetector(
              onTap: onSelectAll,
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 32,
                height: 32,
                margin: const EdgeInsets.only(right: 7),
                decoration: BoxDecoration(
                  color: selectedCount == totalCount
                      ? AppTokens.blue
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppRadius.sm + 1),
                  border: selectedCount == totalCount
                      ? null
                      : Border.all(color: AppTokens.blue, width: 1.6),
                ),
                child: Icon(
                  Icons.check_rounded,
                  size: 18,
                  color: selectedCount == totalCount
                      ? Colors.white
                      : AppTokens.blue,
                ),
              ),
            ),
          ],
          GestureDetector(
            onTap: onPrivacyToggle,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: privacyMode ? t.dangerSoft : t.surface2,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Icon(
                privacyMode ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                size: 18,
                color: privacyMode ? t.danger : t.text2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 第二行：站点胶囊 + 数量 + 状态
  Widget _buildMetaRow(AppTokens t) {
    final statusColor = status == '就绪'
        ? t.success
        : (status == '无结果' ? t.text3 : t.warning);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 2),
      child: Row(
        children: [
          if (!isAuthorPageMode && sitePill != null)
            Flexible(child: sitePill!),
          const SizedBox(width: 9),
          Text(
            isAuthorPageMode ? '已加载 $videoCount 个视频' : '共 $totalCount 条',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: t.text3,
            ),
          ),
          const Spacer(),
          if (!isAuthorPageMode && status != '就绪')
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: statusColor.withOpacity(t.dark ? 0.18 : 0.10),
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: Text(
                status,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: statusColor,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
