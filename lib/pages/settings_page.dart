import 'dart:io';
import 'dart:ui' show FontFeature;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import '../crawler/config.dart';
import '../services/app_state.dart';
import '../services/version_service.dart';

import '../services/pin_service.dart';
import '../utils/logger.dart';
import '../utils/open_directory.dart';
import '../theme/ui_style.dart';
import '../theme/app_tokens.dart';
import '../components/app_shell.dart';
import '../theme/app_theme.dart';
import 'pin_input_dialog.dart';
import 'cache_manager_page.dart';
import 'search_history_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> with AutomaticKeepAliveClientMixin {
  final PinService _pinService = PinService();

  /// 作者更新自动检查开关（默认开）
  bool _followedAutoCheck = true;

  /// 「手动输入网址」弹窗用的 controller。
  ///
  /// 由 State 持有、在 dispose() 里统一释放，而不是在弹窗 Future 返回后
  /// 立刻 dispose —— 那时关闭动画仍在跑，TextField 还会读它。
  TextEditingController? _customSiteController;

  /// 播放节点测速结果：host -> 延迟毫秒（-1 表示超时/失败）
  final Map<String, int> _cdnLatency = {};

  /// 测速用的探测路径，取自站点 fastest_cdn.js 里的兜底值
  static const String _cdnTestPath = '/hls/813941/index0.ts';

  /// 九色系的探测路径：站点上的公开样片播放列表
  ///
  /// cdn2/cdn3.jiuse2.cloud 与 cdn2/cdn3.jiuse3.cloud 上这个路径都是 200，
  /// 而根路径是 403，用根路径测会让所有线路都显示成「超时」。
  static const String _cdnTestPathJiuse = '/hlsd/js10/index.m3u8';
  bool _cdnTesting = false;

  // ==================== 站点选择器状态 ====================

  /// 站点测速结果：host -> 延迟毫秒（-1 表示超时/不可达）
  final Map<String, int> _siteLatency = {};
  bool _siteTesting = false;

  /// 站点测速探测路径：直接打根路径，只用来判断域名是否可达
  static const String _siteTestPath = '/';

  /// 站点页是 push 出来的独立路由，父 State 的 setState 建不到它，
  /// 测速结果只能靠这个 notifier 主动触发二级页重建。
  final ValueNotifier<int> _siteRevision = ValueNotifier<int>(0);

  /// 站点家族的展示顺序
  static const List<String> _siteFamilyOrder = [
    'porn91',
    'jiuse',
    'hifuli',
    'original',
  ];

  /// 站点家族的中文名，键取自 CrawlerConfig.siteTypes 的值
  static const Map<String, String> _siteFamilyNames = {
    'porn91': '91porn 系',
    'jiuse': '九色系',
    'hifuli': '嗨碰系',
    'original': '原创系',
  };

  @override
  bool get wantKeepAlive => true;  // 保持状态
  
  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      final appState = context.read<AppState>();
      await appState.init();
      final enabled = await appState.followedAuthorsService.isAutoCheckEnabled();
      if (mounted) setState(() => _followedAutoCheck = enabled);
    });
  }
  
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
  }

  @override
  void dispose() {
    _customSiteController?.dispose();
    _customSiteController = null;
    _siteRevision.dispose();
    super.dispose();
  }

  @override
  @override
  Widget build(BuildContext context) {
    super.build(context);  // 必须调用，启用AutomaticKeepAliveClientMixin
    final t = AppTokens.of(context);
    return Consumer<AppState>(
      builder: (context, appState, _) {
        return Scaffold(
          backgroundColor: t.bg,
          appBar: _buildAppBar(appState, t),
          body: ListView(
            padding: EdgeInsets.fromLTRB(
                12, 12, 12, MediaQuery.of(context).padding.bottom + 90),
            children: [
              _buildGroup(t, '抓取与下载', [
                _buildRow(
                  t,
                  icon: Icons.language_rounded,
                  color: AppTokens.blue,
                  title: '站点与线路',
                  subtitle: _siteSummary(appState),
                  onTap: () => _openSitePage(appState),
                ),
                _buildRow(
                  t,
                  icon: Icons.folder_rounded,
                  color: const Color(0xFFB26B00),
                  title: '下载目录',
                  subtitle: appState.downloadDir.isEmpty
                      ? '正在初始化...'
                      : appState.downloadDir,
                  onTap: () => _pushSubPage(
                      '下载目录', (context) => _buildDownloadDirContent(appState)),
                ),
                _buildRow(
                  t,
                  icon: Icons.speed_rounded,
                  color: t.success,
                  title: '并发与限速',
                  subtitle:
                      '${appState.maxConcurrentTasks} 个任务 · ${appState.maxConcurrentSegments} 切片 · 播放节点',
                  onTap: () => _pushSubPage('下载设置',
                      (context) => _buildDownloadConcurrencyContent(appState)),
                ),
              ]),
              _buildGroup(t, '外观与浏览', [
                _buildRow(
                  t,
                  icon: Icons.palette_rounded,
                  color: const Color(0xFF7E57C2),
                  title: '主题模式',
                  subtitle: _themeSummary(appState),
                  onTap: () => _pushSubPage(
                      '主题模式', (context) => _buildThemeContent(appState)),
                ),
                _buildRow(
                  t,
                  icon: Icons.view_module_rounded,
                  color: AppTokens.blue2,
                  title: '浏览设置',
                  subtitle:
                      '${appState.videoDisplayMode == 'list' ? '列表模式' : '大图模式'} · ${appState.privacyMode ? '隐私模式开' : '隐私模式关'}',
                  onTap: () => _pushSubPage(
                      '浏览设置', (context) => _buildBrowseContent(appState)),
                ),
                _buildRow(
                  t,
                  icon: Icons.lock_rounded,
                  color: t.danger,
                  title: '应用锁',
                  subtitle: appState.appLockEnabled
                      ? '已开启，启动时需输入 PIN 码'
                      : '未开启，点击设置 4 位 PIN 码',
                  onTap: () => _pushSubPage(
                      '应用锁', (context) => _buildAppLockContent(appState)),
                ),
              ]),
              _buildGroup(t, '权限与其他', [
                _buildRow(
                  t,
                  icon: Icons.security_rounded,
                  color: t.success,
                  title: '权限状态',
                  subtitle:
                      '${appState.permissionGranted ? '存储权限已授权' : '存储权限未授权'} · ${appState.overlayPermissionGranted ? '悬浮窗已授权' : '悬浮窗未授权'}',
                  onTap: () => _pushSubPage('权限状态',
                      (context) => _buildPermissionContent(appState)),
                ),
                _buildRow(
                  t,
                  icon: Icons.bug_report_rounded,
                  color: const Color(0xFF7E57C2),
                  title: '调试设置',
                  subtitle:
                      '${appState.debugMode ? 'Debug 已开启' : 'Debug 已关闭'} · ${appState.realtimeLogEnabled ? '实时日志开' : '实时日志关'}',
                  onTap: () => _pushSubPage(
                      '调试设置', (context) => _buildDebugContent(appState)),
                ),
              ]),
              // 版本号做成页脚小字：它只是「当前版本 + 检查更新」的入口，
              // 单独占一行卡片太占版面，用户也会觉得多出来一个按钮。
              const SizedBox(height: 18),
              Center(
                child: InkWell(
                  onTap: () => _pushSubPage(
                      '关于', (context) => _buildAboutContent()),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Text(
                      '91Download 移动端 · ${VersionService.fullVersion}',
                      style: TextStyle(fontSize: 11.5, color: t.text3),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar(AppState appState, AppTokens t) {
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
                  '设置',
                  style: TextStyle(
                    fontSize: 23,
                    height: 1.15,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                    color: t.text1,
                  ),
                ),
                // 这里曾放一个「关于」图标按钮，与下方列表里的「关于」整行重复，
                // 去掉后顶栏右侧留白，与其它主页面（批量/搜索/已关注）保持一致。
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Flexible(child: SitePill(appState: appState)),
                if (_siteLatency.isNotEmpty) ...[
                  const SizedBox(width: 9),
                  AppCountPill(
                    text: _fastestSiteLatency == null
                        ? '测速超时'
                        : '最快 ${_fastestSiteLatency}ms',
                    color: _fastestSiteLatency == null
                        ? t.danger
                        : t.success,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _siteSummary(AppState appState) {
    if (!appState.isSiteSelected) return '未选择站点，点击进入选择';
    final host = _siteHost(appState.currentSite ?? '');
    final family = _siteFamilyNames[appState.currentSiteType] ?? '自定义站点';
    return '$family · $host';
  }

  String _themeSummary(AppState appState) {
    final mode = appState.themeMode == 0
        ? '浅色'
        : appState.themeMode == 1
            ? '深色'
            : '跟随系统';
    final glass = UiStyle.glassEnabled.value ? '毛玻璃开' : '毛玻璃关';
    return '$mode · $glass';
  }

  Widget _buildGroup(AppTokens t, String title, List<Widget> rows) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: t.text3,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: BorderRadius.circular(AppRadius.xl),
            border: Border.all(color: t.line),
            boxShadow: t.cardShadow,
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(children: rows),
        ),
        const SizedBox(height: 14),
      ],
    );
  }

  Widget _buildRow(
    AppTokens t, {
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool last = false,
  }) {
    return Column(
      children: [
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(13, 12, 10, 12),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: color.withOpacity(t.dark ? 0.18 : 0.10),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Icon(icon, size: 18, color: color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: t.text1,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: t.text3),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, size: 20, color: t.text3),
              ],
            ),
          ),
        ),
        if (!last)
          Divider(
            height: 1,
            thickness: 1,
            indent: 59,
            color: t.line,
          ),
      ],
    );
  }


  Future<void> _pushSubPage(
    String title,
    WidgetBuilder body, {
    List<Widget> Function(BuildContext context)? actions,
    bool plain = false,
    Listenable? listenable,
  }) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _SettingsSubPage(
          title: title,
          body: body,
          actions: actions,
          plain: plain,
          listenable: listenable,
        ),
      ),
    );
  }

  /// 打开「站点与线路」二级页，首次进入自动测一次延迟
  void _openSitePage(AppState appState) {
    if (_siteLatency.isEmpty && !_siteTesting) {
      _testSiteLatency();
    }
    _pushSubPage(
      '站点与线路',
      (context) => _buildSiteSection(context.read<AppState>()),
      plain: true,
      listenable: _siteRevision,
      actions: (context) {
        final t = AppTokens.of(context);
        return [_siteTesting ? _buildTestLoading(t) : _buildTestButton(t)];
      },
    );
  }

  /// 测速进行中的胶囊（与「测速」按钮同尺寸，避免顶栏跳动）
  Widget _buildTestLoading(AppTokens t) {
    return Container(
      height: 31,
      padding: const EdgeInsets.symmetric(horizontal: 13),
      decoration: BoxDecoration(
        color: t.surface2,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(strokeWidth: 1.8, color: t.accent),
          ),
          const SizedBox(width: 6),
          Text(
            '测速中',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: t.accent,
            ),
          ),
        ],
      ),
    );
  }

  /// 顶栏「测速」胶囊
  Widget _buildTestButton(AppTokens t) {
    return Material(
      color: t.surface2,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        onTap: _testSiteLatency,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.speed_rounded, size: 15, color: t.accent),
              const SizedBox(width: 5),
              Text(
                '测速',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: t.accent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }


  /// 站点与线路（二级页整页内容）
  ///
  /// 布局对齐 _ui_v2.html 第 6 屏：顶部大卡放当前站点 →
  /// 按站点系分组列出全部站点（自定义站跟着它所属的站点系走）→ 底部添加入口。
  /// 延迟仍是相对分档：≤1.5× 最快绿、≤3× 琥珀、其余红，超时直接红。
  Widget _buildSiteSection(AppState appState) {
    final t = AppTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildCurrentSiteCard(appState, t),
        ..._buildSiteGroups(appState, t),
        const SizedBox(height: 2),
        _buildAddSiteButton(appState, t),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            '延迟为直连该域名的 HEAD 往返耗时，超时代表当前网络不可达；'
            '切换到同系的其他域名不会改变站点内容。',
            style: TextStyle(fontSize: 11, height: 1.6, color: t.text3),
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  /// 顶部大卡：当前站点
  Widget _buildCurrentSiteCard(AppState appState, AppTokens t) {
    final host = _siteHost(appState.currentSite ?? '');
    final family = appState.isSiteSelected
        ? (_siteFamilyNames[appState.currentSiteType] ?? '自定义站点')
        : '未选择';
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(AppRadius.xxl),
        border: Border.all(color: t.line),
        boxShadow: t.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '当前站点',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: t.text3,
            ),
          ),
          const SizedBox(height: 9),
          Row(
            children: [
              _buildSiteAvatar(host),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      host.isEmpty ? '请选择站点' : host,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: t.text1,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 5,
                      runSpacing: 5,
                      children: [
                        _buildSiteTag(family, t, color: t.accent),
                        if (_isFastestSite(host))
                          _buildSiteTag('最快', t, color: t.success),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _buildSiteLatency(host, t),
            ],
          ),
        ],
      ),
    );
  }

  /// 底部「添加自定义站点」入口
  Widget _buildAddSiteButton(AppState appState, AppTokens t) {
    return Material(
      color: t.surface,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: () => _showAddCustomSiteDialog(appState),
        child: Container(
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: t.line),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_rounded, size: 18, color: t.accent),
              const SizedBox(width: 7),
              Text(
                '添加自定义站点',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: t.accent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }




  /// 按站点家族分组生成选项列表
  ///
  /// 自定义站点不单独沉底，而是按它**所属的家族**排进对应分组——
  /// 用户手动归类（或按域名推断）到九色系的自定义站点就该出现在九色系里，
  /// 否则「归类」这个动作在界面上看不出来。预设站在前、自定义站跟在后面。
  List<Widget> _buildSiteGroups(AppState appState, AppTokens t) {
    final widgets = <Widget>[];
    for (final family in _siteFamilyOrder) {
      final presets = CrawlerConfig.presetsOfFamily(family);
      final customs = appState.customSites
          .where((s) =>
              !CrawlerConfig.availableSites.contains(s) &&
              appState.siteFamilyOf(s) == family)
          .toList();
      if (presets.isEmpty && customs.isEmpty) continue;
      final rows = <Widget>[];
      for (var i = 0; i < presets.length; i++) {
        if (rows.isNotEmpty) rows.add(_buildSiteDivider(t));
        rows.add(
            _buildSiteOption(appState, presets[i], i == 0 ? '主站' : '备用', t));
      }
      for (final site in customs) {
        if (rows.isNotEmpty) rows.add(_buildSiteDivider(t));
        rows.add(
            _buildSiteOption(appState, site, '自定义', t, customSite: true));
      }
      widgets.add(_buildSiteGroupLabel(_siteFamilyNames[family] ?? family, t));
      widgets.add(
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: BorderRadius.circular(AppRadius.xl),
            border: Border.all(color: t.line),
            boxShadow: t.cardShadow,
          ),
          child: Column(children: rows),
        ),
      );
      widgets.add(const SizedBox(height: 2));
    }
    return widgets;
  }

  Widget _buildSiteDivider(AppTokens t) =>
      Divider(height: 1, thickness: 1, color: t.line);


  Widget _buildSiteGroupLabel(String text, AppTokens t) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 7),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
          color: t.text3,
        ),
      ),
    );
  }


  /// 单个站点选项：状态圆点 + 域名 + 角色/测速状态 + 延迟（+ 自定义站更多操作）
  Widget _buildSiteOption(
      AppState appState, String site, String roleTag, AppTokens t,
      {bool customSite = false}) {
    final selected = appState.currentSite == site;
    final host = _siteHost(site);
    final ms = _siteLatency[host];
    final subtitle = [
      roleTag,
      if (customSite && appState.hasManualSiteType(site)) '手动归类',
      if (_isFastestSite(host)) '最快',
      ms == null ? '未测速' : '已测速',
    ].join(' · ');
    return InkWell(
      onTap: () {
        if (selected) return;
        appState.changeSite(site);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text('已切换到 $host'),
            duration: const Duration(seconds: 2),
          ));
      },
      child: Padding(
        padding: EdgeInsets.fromLTRB(13, 11, customSite ? 4 : 13, 11),
        child: Row(
          children: [
            _buildSiteRowIcon(selected, t),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    host,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight:
                          selected ? FontWeight.w700 : FontWeight.w600,
                      color: selected ? t.accent : t.text1,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: t.text3),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _buildSiteLatency(host, t),
            if (customSite) _buildCustomSiteMenu(appState, site, t),
          ],
        ),
      ),
    );
  }

  /// 选项左侧状态圆点：选中是实心勾，未选中是描边地球
  Widget _buildSiteRowIcon(bool selected, AppTokens t) {
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? t.accent : t.surface2,
        shape: BoxShape.circle,
      ),
      child: Icon(
        selected ? Icons.check_rounded : Icons.language_rounded,
        size: 15,
        color: selected ? Colors.white : t.text2,
      ),
    );
  }


  /// 自定义站点的更多操作：归类到某个系 / 删除
  Widget _buildCustomSiteMenu(AppState appState, String site, AppTokens t) {
    return PopupMenuButton<String>(
      tooltip: '更多操作',
      padding: EdgeInsets.zero,
      icon: Icon(Icons.more_vert_rounded, size: 18, color: t.text3),
      iconSize: 18,
      onSelected: (value) {
        if (value == 'family') {
          _showSiteFamilyDialog(appState, site);
        } else if (value == 'delete') {
          _confirmRemoveCustomSite(appState, site);
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          value: 'family',
          height: 44,
          child: Row(
            children: [
              Icon(Icons.category_outlined, size: 18, color: t.text2),
              const SizedBox(width: 10),
              Text('归类', style: TextStyle(fontSize: 14, color: t.text1)),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'delete',
          height: 44,
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 18, color: t.danger),
              const SizedBox(width: 10),
              Text('删除', style: TextStyle(fontSize: 14, color: t.danger)),
            ],
          ),
        ),
      ],
    );
  }

  /// 自定义站点归类弹窗
  ///
  /// 用 StatefulBuilder 而不是另建 StatefulWidget：这里只需要一个临时选中值，
  /// 弹窗关闭即丢，没必要为它多开一个类。
  Future<void> _showSiteFamilyDialog(AppState appState, String site) async {
    final host = _siteHost(site);
    final automatic = CrawlerConfig.detectSiteType(site);
    // 用 __auto__ 做「自动推断」的哨兵值，而不是 null：
    // Radio 的 value 为 null 在 groupValue 也为 null 时无法区分"没选"，
    // 而且泛型 RadioListTile<String?> 的 null 分支容易踩断言。
    const autoValue = '__auto__';
    // 当前归类：手动指定过就用它，否则是「自动」
    String choice =
        appState.hasManualSiteType(site) ? appState.siteFamilyOf(site) : autoValue;
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        final autoLabel = _siteFamilyNames[automatic] ?? automatic;
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text('归类站点'),
            contentPadding: EdgeInsets.fromLTRB(0, 12, 0, 0),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    host,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade600),
                  ),
                ),
                SizedBox(height: 8),
                RadioListTile<String>(
                  value: autoValue,
                  groupValue: choice,
                  dense: true,
                  title: Text('自动（按域名推断）',
                      style: TextStyle(fontSize: 14)),
                  subtitle: Text('当前判定为 $autoLabel',
                      style: TextStyle(fontSize: 11)),
                  onChanged: (v) {
                    if (v == null) return;
                    setDialogState(() => choice = v);
                  },
                ),
                for (final family in _siteFamilyOrder)
                  RadioListTile<String>(
                    value: family,
                    groupValue: choice,
                    dense: true,
                    title: Text(_siteFamilyNames[family] ?? family,
                        style: TextStyle(fontSize: 14)),
                    subtitle: Text(_siteFamilyHint(family),
                        style: TextStyle(fontSize: 11)),
                    onChanged: (v) {
                      if (v == null) return;
                      setDialogState(() => choice = v);
                    },
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, choice),
                child: Text('确定'),
              ),
            ],
          ),
        );
      },
    );
    if (result == null || !mounted) return;
    await appState
        .setCustomSiteType(site, result == '__auto__' ? null : result);
    if (!mounted) return;
    final label = result == '__auto__'
        ? '自动推断'
        : (_siteFamilyNames[result] ?? result);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('$host 已归类为 $label'),
        duration: Duration(seconds: 2),
      ));
  }

  /// 家族的一句话说明，放进归类弹窗的副标题
  String _siteFamilyHint(String family) {
    switch (family) {
      case 'porn91':
        return '91porn 风格，v.php?next=watch 列表，移动端请求头';
      case 'jiuse':
        return '九色风格，列表与详情解析单独一套';
      case 'hifuli':
        return '嗨碰风格，播放地址写在 window.HIPORN_WATCH 里';
      case 'original':
        return 'ml0987/hsex 风格，list-{page}.htm 列表';
      default:
        return '';
    }
  }

  /// 删除自定义站点（带确认）
  Future<void> _confirmRemoveCustomSite(AppState appState, String site) async {
    final host = _siteHost(site);
    final wasCurrent = appState.currentSite == site;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('删除站点'),
        content: Text(wasCurrent
            ? '确定删除 $host 吗？它正是当前使用的站点，删除后会自动切到同系的预设站点。'
            : '确定删除 $host 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final fallback = await appState.removeCustomSite(site);
    if (!mounted) return;
    final fallbackHost = fallback == null ? '' : _siteHost(fallback);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(fallbackHost.isEmpty
            ? '已删除 $host'
            : '已删除 $host，当前站点切换到 $fallbackHost'),
        duration: Duration(seconds: 2),
      ));
  }

  /// 站点徽标：取域名首段的前两个字符
  ///
  /// IP（含本地 mock 的 172.16.1.2:8899）首段是纯数字，取两位会显示成
  /// 毫无意义的「17」，这类主机统一改用地球图标。
  Widget _buildSiteAvatar(String host) {
    final first = host.isEmpty ? '' : host.split(RegExp(r'[.:]')).first;
    final isIpLike = first.isNotEmpty && int.tryParse(first) != null;
    var label = first.toUpperCase();
    if (label.length > 2) label = label.substring(0, 2);
    return Container(
      width: 42,
      height: 42,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(13),
        gradient: const LinearGradient(
          colors: [Color(0xFF1565C0), Color(0xFF42A5F5)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: isIpLike || label.isEmpty
          ? const Icon(Icons.language_rounded, size: 22, color: Colors.white)
          : Text(
              label,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold),
            ),
    );
  }

  /// 该站点是否为当前实测最快的可达站点
  bool _isFastestSite(String host) {
    final ms = _siteLatency[host];
    if (ms == null || ms < 0) return false;
    return ms == _fastestSiteLatency;
  }


  /// 角色小标签（主站/备用/自定义/最快）
  Widget _buildSiteTag(String text, AppTokens t, {Color? color}) {
    final c = color ?? t.text2;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: c.withOpacity(t.dark ? 0.18 : 0.10),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: c,
        ),
      ),
    );
  }


  /// 当前最快可达站点的延迟（用于相对分档），无数据返回 null
  int? get _fastestSiteLatency {
    final values = _siteLatency.values.where((v) => v >= 0);
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a < b ? a : b);
  }

  /// 延迟分档配色
  ///
  /// 绝对阈值在不同网络下没有可比性（模拟器普遍 2s 以上、真机常见 100~500ms），
  /// 所以按「相对当前最快站点」分档：1.5 倍内绿、3 倍内橙、更慢红，超时直接红。
  Color _siteLatencyColor(int ms, AppTokens t) {
    if (ms < 0) return t.danger;
    final fastest = _fastestSiteLatency;
    if (fastest == null || fastest <= 0) return t.text3;
    if (ms <= fastest * 1.5) return t.success;
    if (ms <= fastest * 3) return t.warning;
    return t.danger;
  }

  /// 延迟展示文本
  String _siteLatencyText(int ms) => ms < 0 ? '超时' : '${ms}ms';

  /// 站点延迟文本（未测速时不占位）
  Widget _buildSiteLatency(String host, AppTokens t) {
    final ms = _siteLatency[host];
    if (ms == null) return const SizedBox.shrink();
    return Text(
      _siteLatencyText(ms),
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        color: _siteLatencyColor(ms, t),
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }

  /// 去掉协议前缀取主机名（用于展示与测速）
  /// 测速用的探测地址：沿用站点自己的协议与端口，只保留 origin
  String _siteProbeUrl(String site) {
    final raw = site.trim();
    if (raw.isEmpty) return '';
    final withScheme =
        raw.startsWith('http://') || raw.startsWith('https://')
            ? raw
            : 'https://$raw';
    final uri = Uri.tryParse(withScheme);
    if (uri == null || uri.host.isEmpty) return '';
    final scheme = uri.scheme.isEmpty ? 'https' : uri.scheme;
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '$scheme://${uri.host}$port$_siteTestPath';
  }

  String _siteHost(String site) {
    if (site.isEmpty) return '';
    final uri = Uri.tryParse(site);
    if (uri != null && uri.host.isNotEmpty) {
      final host = uri.host.replaceAll('www.', '');
      // 非默认端口要带上，否则本地 mock 的 8899 / 8901 会显示成同一个域名
      final port = uri.hasPort ? uri.port : 0;
      return (port == 0 || port == 80 || port == 443) ? host : '$host:$port';
    }
    return site.replaceFirst(RegExp(r'^https?://'), '').replaceAll('/', '');
  }


  /// 并发探测所有站点的可达性与延迟
  ///
  /// 与播放节点测速同一套判定：HEAD 站点根路径，只要拿到响应
  /// （403/404 也算）就认为该域名可达，只有连不上/超时才记 -1。
  Future<void> _testSiteLatency() async {
    if (_siteTesting) return;
    final appState = context.read<AppState>();
    // host -> 探测地址。用站点自己的协议，本地 http 的 mock 站点
    // 才不会因为被强制拼成 https 而一律显示「超时」。
    final targets = <String, String>{};
    for (final site in appState.allSites) {
      final host = _siteHost(site);
      final url = _siteProbeUrl(site);
      if (host.isEmpty || url.isEmpty) continue;
      targets.putIfAbsent(host, () => url);
    }
    setState(() {
      _siteTesting = true;
      _siteLatency.clear();
    });
    _siteRevision.value++;
    final dio = Dio(
      BaseOptions(
        connectTimeout: Duration(milliseconds: 3000),
        receiveTimeout: Duration(milliseconds: 3000),
      ),
    );
    await Future.wait(targets.entries.map((entry) async {
      final host = entry.key;
      final sw = Stopwatch()..start();
      int ms;
      try {
        await dio.head<void>(entry.value);
        ms = sw.elapsedMilliseconds;
      } on DioException catch (e) {
        ms = e.response != null ? sw.elapsedMilliseconds : -1;
      } catch (_) {
        ms = -1;
      }
      sw.stop();
      if (!mounted) return;
      setState(() => _siteLatency[host] = ms);
      // 二级页是独立路由，拿不到这里的 setState，只能靠 notifier 触发重建
      _siteRevision.value++;
    }));
    if (mounted) setState(() => _siteTesting = false);
    _siteRevision.value++;
  }

  /// 手动输入自定义站点网址
  Future<void> _showAddCustomSiteDialog(AppState appState) async {
    final controller = TextEditingController();
    String? input;
    // 添加时就能指定站点系，省掉"先加再归类"两步
    const autoValue = '__auto__';
    String family = autoValue;
    // 注意：controller 不能在这里 dispose。
    //
    // showDialog 的 Future 在弹窗**开始关闭**时就完成了，但退出动画还要再跑
    // 一小段时间，期间 AlertDialog 里的 TextField 仍会重建并读取 controller。
    // 原来的写法在 finally 里立刻 dispose()，于是动画期间访问已释放的
    // controller，抛 'Failed assertion: _dependents.isEmpty is not true' 红屏。
    // 交给 State 的生命周期统一回收（见 _customSiteController 字段）。
    _customSiteController?.dispose();
    _customSiteController = controller;
    try {
      input = await showDialog<String>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
          title: Text('手动输入网址'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('请输入站点网址:', style: TextStyle(fontSize: 12)),
              SizedBox(height: 8),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  hintText: 'https://example.com',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              SizedBox(height: 8),
              Text(
                '支持 http/https，可省略协议前缀',
                style: TextStyle(fontSize: 10, color: Colors.grey),
              ),
              SizedBox(height: 12),
              Text('站点系:', style: TextStyle(fontSize: 12)),
              SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: Text('自动', style: TextStyle(fontSize: 12)),
                    selected: family == autoValue,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) =>
                        setDialogState(() => family = autoValue),
                  ),
                  for (final f in _siteFamilyOrder)
                    ChoiceChip(
                      label: Text(_siteFamilyNames[f] ?? f,
                          style: TextStyle(fontSize: 12)),
                      selected: family == f,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => setDialogState(() => family = f),
                    ),
                ],
              ),
              SizedBox(height: 4),
              Text(
                '自动 = 按域名推断，大多数镜像站需要手动指定',
                style: TextStyle(fontSize: 10, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(
                  dialogContext, '${family == autoValue ? '' : family}|${controller.text}'),
              child: Text('确定'),
            ),
          ],
        ),
        ),
      );
    } finally {
      // 这里只记录“输入已结束”，不再 dispose controller：
      // 弹窗关闭动画期间 TextField 还会重建一次，提前释放会红屏。
    }

    if (input == null || !mounted) return;
    // 约定：'家族|网址'，家族为空串表示自动推断
    final sep = input.indexOf('|');
    final chosenFamily = sep < 0 ? '' : input.substring(0, sep);
    final url = sep < 0 ? input : input.substring(sep + 1);
    if (url.trim().isEmpty) return;

    final normalized = await appState.addCustomSite(
      url,
      siteType: chosenFamily.isEmpty ? null : chosenFamily,
    );
    if (normalized != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已切换到 $normalized')),
      );
    }
  }

  /// 2. 下载目录设置区域
  Widget _buildDownloadDirContent(AppState appState) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.grey.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  appState.downloadDir.isEmpty 
                    ? '正在初始化...' 
                    : appState.downloadDir,
                  style: TextStyle(fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _selectDownloadDirectory(appState),
                icon: Icon(Icons.folder_open, size: 18),
                label: Text('选择目录'),
              ),
            ),
            SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _openDownloadDirectory(appState.downloadDir),
                icon: Icon(Icons.folder_shared, size: 18),
                label: Text('打开目录'),
              ),
            ),
          ],
        ),
        Divider(height: 24),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('防媒体扫描', style: TextStyle(fontSize: 14)),
          subtitle: Text('在下载目录创建 .nomedia，防止视频出现在相册', style: TextStyle(fontSize: 12, color: Colors.grey)),
          value: appState.nomediaEnabled,
          onChanged: (v) async {
            final ok = await appState.toggleNomedia(v);
            if (!mounted) return;
            if (!ok) {
              // 失败时开关不会翻（appState 没改状态），
              // 这里明确告诉用户原因，别让人反复点。
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    appState.downloadDir.isEmpty
                        ? '请先设置下载目录'
                        : '设置失败，请检查下载目录是否可写',
                  ),
                ),
              );
            }
          },
        ),
        Divider(height: 24),
        // 缓存管理：清理临时残留与失效记录
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.cleaning_services_outlined),
          title: Text('缓存管理', style: TextStyle(fontSize: 14)),
          subtitle: Text(
            '清理未合并的临时文件、以及文件已删除却残留的记录',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          trailing: Icon(Icons.chevron_right),
          onTap: () => _openCacheManager(appState),
        ),
      ],
    );
  }
  
  /// 打开缓存管理页面
  Future<void> _openCacheManager(AppState appState) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CacheManagerPage(appState: appState),
      ),
    );
  }

  /// 打开搜索历史管理页
  ///
  /// 这里不直接驱动搜索：设置页与搜索页是两个独立 tab，
  /// 强行跨页触发搜索会带来焦点/滚动位置等副作用。
  /// 用户在历史页点某条记录时，仅把关键词复制过去供其粘贴。
  Future<void> _openSearchHistory(AppState appState) async {
    final picked = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const SearchHistoryPage()),
    );
    if (!mounted || picked == null || picked.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: picked));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制「$picked」，可到搜索页粘贴')),
    );
  }
  
  void _setDownloadDirectory(String path) async {
    final appState = context.read<AppState>();
    try {
      final dir = Directory(path);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      // await：切换目录要落盘、重开数据库、迁移旧目录的 .db，
      // 提前弹提示会让用户以为已完成、随后又被覆盖。
      await appState.setDownloadDir(path);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已设置下载目录: $path')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('设置失败: $e')),
        );
      }
    }
  }
  
  void _selectDownloadDirectory(AppState appState) async {
    // 尝试使用 file_picker 选择目录
    try {
      String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
      
      if (selectedDirectory != null) {
        _setDownloadDirectory(selectedDirectory);
        return;
      }
    } catch (e) {
      // file_picker 不可用时回退到手动输入，这里忽略具体异常
    }

    // await 之后页面可能已被销毁，使用 context 前必须检查
    if (!mounted) return;

    // 如果 file_picker 失败，显示手动输入对话框
    final controller = TextEditingController(text: appState.downloadDir);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('选择下载目录'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('请输入下载目录路径:', style: TextStyle(fontSize: 12)),
            SizedBox(height: 8),
            TextField(
              controller: controller,
              decoration: InputDecoration(
                hintText: '/storage/emulated/0/Download',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            SizedBox(height: 8),
            Text(
              '注意：目录必须存在且有写入权限',
              style: TextStyle(fontSize: 10, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text('确定'),
          ),
        ],
      ),
    );
    
    if (result != null && result.isNotEmpty) {
      _setDownloadDirectory(result);
    }
  }
  
  /// 打开下载目录（用系统文件管理器跳转到该目录）
  ///
  /// 原实现只是弹了个 SnackBar 显示路径，并没有真正打开目录，
  /// 这里改为通过 platform channel 调起系统文件管理器。
  /// 若设备没有可用的文件管理器，则退化为复制路径提示。
  Future<void> _openDownloadDirectory(String path) async {
    if (path.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('下载目录未设置')),
      );
      return;
    }

    try {
      // 确保目录存在，否则文件管理器可能拒绝跳转
      final dir = Directory(path);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final opened = await OpenDirectoryPlugin.openDirectory(path);

      if (!opened && mounted) {
        // 没有可用的文件管理器时，给出可操作的兜底提示
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('无法打开文件管理器\n路径: $path'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开目录失败: $e')),
        );
      }
    }
  }

  /// 2.5 下载并发设置区域
  Widget _buildDownloadConcurrencyContent(AppState appState) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 同时下载任务数
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('同时下载任务数', style: TextStyle(fontSize: 14)),
                  Text('同时下载的视频数量', style: TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ),
            SizedBox(width: 8),
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).colorScheme.primary),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  _buildConcurrentButton(
                    icon: Icons.remove,
                    onTap: appState.maxConcurrentTasks > 1
                        ? () => appState.setMaxConcurrentTasks(appState.maxConcurrentTasks - 1)
                        : null,
                  ),
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text(
                      '${appState.maxConcurrentTasks}',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                  _buildConcurrentButton(
                    icon: Icons.add,
                    onTap: appState.maxConcurrentTasks < 5
                        ? () => appState.setMaxConcurrentTasks(appState.maxConcurrentTasks + 1)
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ),
        SizedBox(height: 12),
        Divider(),
        
        // TS切片并发数
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('切片并发数', style: TextStyle(fontSize: 14)),
                  Text('单个视频TS切片同时下载数', style: TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ),
            SizedBox(width: 8),
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).colorScheme.primary),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  _buildConcurrentButton(
                    icon: Icons.remove,
                    onTap: appState.maxConcurrentSegments > 4
                        ? () => appState.setMaxConcurrentSegments(appState.maxConcurrentSegments - 4)
                        : null,
                  ),
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text(
                      '${appState.maxConcurrentSegments}',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                  _buildConcurrentButton(
                    icon: Icons.add,
                    onTap: appState.maxConcurrentSegments < 64
                        ? () => appState.setMaxConcurrentSegments(appState.maxConcurrentSegments + 4)
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ),
        SizedBox(height: 8),
        Text(
          '建议WiFi下使用32，移动数据下使用8-16',
          style: TextStyle(fontSize: 11, color: Colors.grey),
        ),
        SizedBox(height: 12),
        Divider(),

        // 播放节点（视频 CDN 线路）
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('播放节点', style: TextStyle(fontSize: 14)),
                  Text(
                    '切换视频下载/播放的CDN线路',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ],
        ),
        SizedBox(height: 8),
        _buildCdnNodePicker(appState),
        SizedBox(height: 8),
        Text(
          _cdnHintFor(appState.currentSiteType),
          style: TextStyle(fontSize: 11, color: Colors.grey),
        ),
      ],
    );
  }
  
  /// 构建并发数调节按钮
  Widget _buildConcurrentButton({required IconData icon, VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        child: Icon(icon, size: 18, color: onTap != null ? Theme.of(context).colorScheme.primary : Colors.grey),
      ),
    );
  }

  /// 播放节点说明文案（按站点类型给出该系的线路来源）
  String _cdnHintFor(String siteType) {
    switch (siteType) {
      case 'porn91':
        return '对应 91porn 的「选择速度最快的视频服务器」：'
            '只更换视频服务器域名，视频内容不变。'
            '服务器 H/I 站点标注为 VIP，实测 I 可直连、H 需要签名。';
      case 'jiuse':
        return '九色系站点本身没有节点切换，这里的线路是本 App 补的：'
            '站点把地址发到 cdn2/cdn3.jiuse2.cloud 或 cdn2/cdn3.jiuse3.cloud，'
            '只换域名、路径与 token 原样保留，视频内容不变。'
            '带 /hlsd/ 的地址是站点内置样片，换线路也仍是样片。';
      case 'hifuli':
        return '嗨碰的播放页只提供一条线路（customer-hpnet.hlsdelivery.net），'
            '站点本身没有节点切换，这里固定为「自动（跟随站点）」。';
      default:
        return '对应播放页的「切换播放节点」：只更换CDN域名，'
            '视频内容不变。某条线路慢或下载失败时，换一条再重试即可。';
    }
  }

  /// 播放节点选择器
  ///
  /// 网页版播放页的「切换播放节点」点开后会先对每条线路测速再列出来，
  /// 这里保持一致：点「测速」逐个探测，把延迟显示在选项右侧。
  Widget _buildCdnNodePicker(AppState appState) {
    final nodes = appState.availableCdnNodes;
    final selected =
        CrawlerConfig.nodeByHost(appState.currentSiteType, appState.cdnHost);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                value: selected.host,
                isExpanded: true,
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border:
                      OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
                items: nodes.map((node) {
                  return DropdownMenuItem<String>(
                    value: node.host,
                    child: Row(
                      children: [
                        Expanded(
                          child:
                              Text(node.name, overflow: TextOverflow.ellipsis),
                        ),
                        _buildLatencyBadge(node.host),
                      ],
                    ),
                  );
                }).toList(),
                onChanged: (v) => appState.setCdnHost(v ?? ''),
              ),
            ),
            SizedBox(width: 8),
            SizedBox(
              height: 44,
              child: OutlinedButton(
                onPressed: _cdnTesting ? null : _testCdnLatency,
                child: _cdnTesting
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text('测速'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 线路延迟标签：绿色 <300ms，橙色 <800ms，红色更慢或超时
  Widget _buildLatencyBadge(String host) {
    final ms = _cdnLatency[host];
    if (ms == null) {
      return SizedBox.shrink();
    }
    final bool timeout = ms < 0;
    final Color color = timeout
        ? Colors.red
        : ms < 300
            ? Colors.green
            : ms < 800
                ? Colors.orange
                : Colors.red;
    return Padding(
      padding: EdgeInsets.only(left: 8),
      child: Text(
        timeout ? '超时' : '${ms}ms',
        style: TextStyle(
          fontSize: 12,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// 逐个探测线路延迟
  ///
  /// 两套站点类型的探测目标不同：
  /// - original：和网页版 fastest_cdn.js 的 ping() 一致，HEAD 一个切片路径
  /// - porn91：站点没有固定探测路径，直接 HEAD 服务器根路径，
  ///   能连上（哪怕 403/404）就说明这条线路通
  Future<void> _testCdnLatency() async {
    final appState = context.read<AppState>();
    final nodes = appState.availableCdnNodes;
    final siteType = appState.currentSiteType;
    final testPath = siteType == 'porn91'
        ? '/'
        : siteType == 'jiuse'
            ? _cdnTestPathJiuse
            : _cdnTestPath;

    setState(() {
      _cdnTesting = true;
      _cdnLatency.clear();
    });
    final dio = Dio(
      BaseOptions(
        connectTimeout: Duration(milliseconds: 3000),
        receiveTimeout: Duration(milliseconds: 3000),
      ),
    );
    for (final node in nodes) {
      if (node.host.isEmpty) continue;
      final sw = Stopwatch()..start();
      int ms;
      try {
        await dio.head<void>('https://${node.host}$testPath');
        ms = sw.elapsedMilliseconds;
      } on DioException catch (e) {
        // 有响应说明域名可达（路径 404 也算通），只有连不上才算超时
        ms = e.response != null ? sw.elapsedMilliseconds : -1;
      } catch (_) {
        ms = -1;
      }
      sw.stop();
      if (!mounted) return;
      setState(() => _cdnLatency[node.host] = ms);
    }
    if (mounted) setState(() => _cdnTesting = false);
  }

  /// 3. 浏览设置区域
  Widget _buildBrowseContent(AppState appState) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 视频显示模式切换
        Row(
          children: [
            Text('视频显示模式', style: TextStyle(fontSize: 14)),
            Spacer(),
            ChoiceChip(
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.grid_view, size: 16),
                  SizedBox(width: 4),
                  Text('大图'),
                ],
              ),
              selected: appState.videoDisplayMode == 'grid',
              onSelected: (selected) {
                if (selected) {
                  appState.setVideoDisplayMode('grid');
                }
              },
            ),
            SizedBox(width: 8),
            ChoiceChip(
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.list, size: 16),
                  SizedBox(width: 4),
                  Text('列表'),
                ],
              ),
              selected: appState.videoDisplayMode == 'list',
              onSelected: (selected) {
                if (selected) {
                  appState.setVideoDisplayMode('list');
                }
              },
            ),
          ],
        ),
        Divider(),
        
        // 搜索历史管理
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.history, size: 20),
          title: Text('搜索历史'),
          subtitle: Text(
            appState.searchHistory.isEmpty
                ? '暂无记录'
                : '已保存 ${appState.searchHistory.entries.length} 条',
          ),
          trailing: Icon(Icons.chevron_right, size: 20),
          onTap: () => _openSearchHistory(appState),
        ),
        Divider(),
        
        // 在线播放（实验性功能）
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Row(
            children: [
              Text('在线播放'),
              SizedBox(width: 8),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('实验', style: TextStyle(fontSize: 10, color: Colors.orange)),
              ),
            ],
          ),
          subtitle: Text('列表模式时点击封面直接在线播放'),
          value: appState.streamingMode,
          onChanged: appState.toggleStreamingMode,
        ),
        Divider(),
        
        // 回顶部按钮设置
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('显示回顶部按钮'),
          subtitle: Text('滚动时显示快速回顶部按钮'),
          value: appState.showBackToTop,
          onChanged: (v) {
            appState.setShowBackToTop(v);
          },
        ),
        if (appState.showBackToTop)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('按钮位置'),
            trailing: SegmentedButton<String>(
              segments: [
                ButtonSegment(value: 'left', label: Text('左下')),
                ButtonSegment(value: 'right', label: Text('右下')),
              ],
              selected: {appState.backToTopPosition},
              onSelectionChanged: (s) {
                appState.setBackToTopPosition(s.first);
              },
            ),
          ),
        Divider(),
        
        // 外部播放器设置
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('使用外部播放器'),
          subtitle: Text('点击视频时使用系统播放器打开'),
          value: appState.useExternalPlayer,
          onChanged: (v) {
            appState.setExternalPlayer(v);
          },
        ),
        Divider(),

        // 隐私模式：列表封面加模糊，避免公共场合被看到内容
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('隐私模式'),
          subtitle: Text('列表封面加模糊，长按封面可临时看清'),
          value: appState.privacyMode,
          onChanged: (v) async {
            await appState.togglePrivacyMode();
          },
        ),
        Divider(),

        // 作者更新自动检查开关
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('自动检查作者更新'),
          subtitle: Text('每 6 小时在后台检查一次已关注作者的新视频'),
          value: _followedAutoCheck,
          onChanged: (v) async {
            await appState.followedAuthorsService
                .setAutoCheckEnabled(v);
            if (mounted) setState(() => _followedAutoCheck = v);
          },
        ),
      ],
    );
  }

  /// 4. 主题模式设置区域
  Widget _buildThemeContent(AppState appState) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 跟随系统开关
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('跟随系统'),
          subtitle: Text('自动切换日间/夜间模式'),
          value: appState.themeMode == 2,
          onChanged: (v) {
            if (v) {
              appState.setAutoTheme();
            } else {
              // 关闭跟随系统时，切换到日间模式
              appState.setLightMode();
            }
          },
        ),
        Divider(),
        
        // 主题选择（跟随系统关闭时才可操作）
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('选择主题'),
          subtitle: Text(
            appState.themeMode == 2 
                ? '当前跟随系统' 
                : (appState.themeMode == 0 ? '日间模式' : '夜间模式')
          ),
          trailing: SegmentedButton<int>(
            segments: [
              ButtonSegment(
                value: 0,
                icon: Icon(Icons.light_mode, size: 18),
                label: Text('日'),
              ),
              ButtonSegment(
                value: 1,
                icon: Icon(Icons.dark_mode, size: 18),
                label: Text('夜'),
              ),
              ButtonSegment(
                value: 2,
                icon: Icon(Icons.settings_suggest, size: 18),
                label: Text('自动'),
              ),
            ],
            selected: {appState.themeMode},
            onSelectionChanged: (s) {
              final mode = s.first;
              switch (mode) {
                case 0:
                  appState.setLightMode();
                  break;
                case 1:
                  appState.setDarkMode();
                  break;
                case 2:
                  appState.setAutoTheme();
                  break;
              }
            },
          ),
        ),
        
        // 当前主题预览
        SizedBox(height: 8),
        Container(
          padding: EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceVariant,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                appState.isDarkMode ? Icons.dark_mode : Icons.light_mode,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
              SizedBox(width: 8),
              Text(
                '当前: ${appState.isDarkMode ? "夜间模式" : "日间模式"}',
                style: TextStyle(
                  color: Theme.of(context).textTheme.bodyMedium?.color,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 24),
        _buildGlassStyleBlock(),
      ],
    );
  }

  /// 界面风格：玻璃拟态开关 + 浓度滑块
  ///
  /// 单独提出来是因为它要放在 ExpansionTile 的 Padding 里面——
  /// 之前直接挂在 children 顶层，少了那 16px 左边距，
  /// 导致「毛玻璃效果」比上面几项整体左移，看起来没对齐。
  Widget _buildGlassStyleBlock() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 可在两种观感间即时切换，觉得毛玻璃卡顿或不好看可直接关掉，
        // 无需回滚代码。字号跟随同卡片的「跟随系统」「选择主题」，
        // 不显式指定，否则会比上下两项小两号。
        ValueListenableBuilder<bool>(
          valueListenable: UiStyle.glassEnabled,
          builder: (context, glass, _) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('毛玻璃效果'),
                  subtitle: Text(
                    glass ? '已开启，控件半透明模糊' : '已关闭，控件为实心色',
                  ),
                  value: glass,
                  onChanged: (v) => UiStyle.setGlassEnabled(v),
                ),
                // 浓度滑块：只在毛玻璃开启时出现，
                // 关闭后被 AnimatedSize 收掉，不留空档。
                AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  alignment: Alignment.topCenter,
                  child: glass
                      ? _buildGlassOpacitySlider()
                      : const SizedBox(width: double.infinity),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  /// 玻璃浓度滑块（仅毛玻璃开启时显示）
  ///
  /// 浓度越高，顶栏/底栏的叠加色越实、透出的背景越少。
  /// 上下两侧共用 [UiStyle.glassOpacity]，拖动后立即同步生效。
  Widget _buildGlassOpacitySlider() {
    return ValueListenableBuilder<double>(
      valueListenable: UiStyle.glassOpacity,
      builder: (context, value, _) {
        final percent = (value * 100).round();
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '不透明度',
                    style: TextStyle(fontSize: 13),
                  ),
                  const Spacer(),
                  Text(
                    '$percent%',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              Slider(
                value: value,
                min: 0.2,
                max: 1.0,
                // 5% 一档，避免手指微动就抖动
                divisions: 16,
                label: '$percent%',
                onChanged: (v) {
                  // 只更新内存值让界面实时跟随，
                  // 松手时才写盘（见 onChangeEnd），避免频繁 IO。
                  UiStyle.glassOpacity.value = v;
                },
                onChangeEnd: (v) => UiStyle.setGlassOpacity(v),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 5. 应用锁设置区域
  Widget _buildAppLockContent(AppState appState) {
    return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.lock, size: 20, color: Colors.red),
                SizedBox(width: 8),
                Text('应用锁', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
            SizedBox(height: 8),
            Text(
              appState.appLockEnabled 
                  ? '已启用 - 进入应用时需要身份验证'
                  : '未启用 - 点击开启应用锁保护',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            SizedBox(height: 12),
            
            // 应用锁开关（始终可点击）
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('应用锁'),
              subtitle: Text(_getAppLockSubtitle(appState)),
              value: appState.appLockEnabled,
              onChanged: (v) => _onAppLockToggle(appState, v),
            ),
            
            // 如果已启用，显示PIN码设置入口
            if (appState.appLockEnabled) ...[
              Divider(),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.pin, size: 20),
                title: Text('修改PIN码'),
                trailing: Icon(Icons.chevron_right),
                onTap: () => _showChangePinDialog(),
              ),
            ],
          ],
    );
  }
  
  String _getAppLockSubtitle(AppState appState) {
    if (!appState.appLockEnabled) {
      return '进入应用时需要输入PIN码';
    }
    return '已启用PIN码解锁';
  }
  
  Future<void> _onAppLockToggle(AppState appState, bool enable) async {
    if (enable) {
      // 设置新PIN码
      final pin = await PinInputDialog.showSetPin(context);
      if (pin == null || !mounted) return;
      
      final success = await _pinService.setPin(pin);
      if (!mounted) return;

      if (!success) {
        // 存不进去就不能开启，否则会出现「开了锁但没有PIN可解」的死局
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PIN码保存失败，应用锁未启用')),
        );
        return;
      }

      // 再校验一次确实写进去了，双保险
      final stored = await _pinService.hasPin();
      if (!mounted) return;
      if (!stored) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PIN码写入校验失败，应用锁未启用')),
        );
        return;
      }

      await appState.toggleAppLock(true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已启用应用锁')),
      );
    } else {
      // 关闭应用锁 - 先验证PIN码
      final pin = await PinInputDialog.showVerifyPin(context);
      if (pin == null || !mounted) return;
      
      final success = await _pinService.verifyPin(pin);
      if (!success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PIN码错误')),
        );
        return;
      }
      
      // 删除 PIN 是关闭应用锁的前提。删失败还去关开关，
      // 下次启动就没有 PIN 可校验，等于锁坏了打不开。
      try {
        await _pinService.removePin();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('清除PIN码失败，应用锁未关闭：$e')),
          );
          // 回滚开关显示，避免 UI 与真实状态不一致
          await appState.toggleAppLock(true);
        }
        return;
      }

      await appState.toggleAppLock(false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已关闭应用锁')),
        );
      }
    }
  }
  
  Future<void> _showChangePinDialog() async {
    // 先验证当前PIN
    final currentPin = await PinInputDialog.showVerifyPin(context);
    if (currentPin == null || !mounted) return;
    
    final success = await _pinService.verifyPin(currentPin);
    if (!mounted) return;
    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('当前PIN码错误')),
      );
      return;
    }
    
    // 设置新PIN码
    final newPin = await PinInputDialog.showSetPin(context);
    if (newPin == null || !mounted) return;
    
    final saved = await _pinService.setPin(newPin);
    if (!mounted) return;
    if (saved) {
      // 再确认一次真的写进去了：写失败却提示「已修改」，
      // 用户下次解锁会直接卡在旧 PIN 上，且再也回不来。
      final stored = await _pinService.hasPin();
      if (!mounted) return;
      if (stored && await _pinService.verifyPin(newPin)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PIN码已修改')),
        );
        return;
      }
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('PIN码修改失败，请重试（原PIN码仍然有效）')),
    );
  }

  /// 6. 权限状态展示区域
  Widget _buildPermissionContent(AppState appState) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            appState.permissionGranted ? Icons.check_circle : Icons.error,
            color: appState.permissionGranted ? Colors.green : Colors.red,
          ),
          title: Text('存储权限'),
          subtitle: Text(
            appState.permissionGranted
                ? '已授权'
                : (appState.storagePermissionPermanentlyDenied
                    ? '已被拒绝，请到系统设置中手动开启'
                    : '未授权'),
          ),
          trailing: !appState.permissionGranted
            ? TextButton(
                onPressed: () async {
                  final granted = await appState.requestPermissions();
                  if (!mounted || granted) return;
                  // 永久拒绝时 request() 不会弹窗，
                  // 必须明确引导去系统设置，否则按钮看着像坏了
                  if (appState.storagePermissionPermanentlyDenied) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('权限已被拒绝，请在系统设置中开启'),
                        action: SnackBarAction(
                          label: '去设置',
                          onPressed: () =>
                              appState.openAppSettingsPage(),
                        ),
                      ),
                    );
                  }
                },
                child: Text('授权'),
              )
            : null,
        ),
        // 悬浮窗权限
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            appState.overlayPermissionGranted ? Icons.check_circle : Icons.error,
            color: appState.overlayPermissionGranted ? Colors.green : Colors.orange,
          ),
          title: Text('悬浮窗权限'),
          subtitle: Text(appState.overlayPermissionGranted ? '已授权' : '未授权（悬浮播放需要）'),
          trailing: TextButton.icon(
            onPressed: () async {
              await appState.requestOverlayPermission();
            },
            icon: Icon(Icons.settings_outlined, size: 16),
            label: Text(appState.overlayPermissionGranted ? '设置' : '去授权'),
          ),
        ),
      ],
    );
  }

  /// 7. 调试设置区域（默认折叠）
  Widget _buildDebugContent(AppState appState) {
    final t = AppTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('Debug 日志'),
          subtitle: Text(
            '记录手机上每一步操作、每次网络请求与下载全过程，'
            '重启后保持开启',
            style: TextStyle(fontSize: 12.5, color: t.text3),
          ),
          value: appState.debugMode,
          onChanged: (v) async {
            await appState.toggleDebug(v);
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('保存HTML'),
          subtitle: Text(
            '保存请求的HTML到文件，用于调试解析问题',
            style: TextStyle(fontSize: 12.5, color: t.text3),
          ),
          value: appState.saveDebugHtml,
          onChanged: (v) {
            appState.toggleSaveDebugHtml(v);
          },
        ),
        if (appState.debugMode) ...[
          const SizedBox(height: 4),
          // 新增强调的主入口：一键把日志文件分享出去（微信/QQ 收到的是文件本体，
          // 不再是把整段文本塞进聊天框被截断）
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _shareLogFile,
              icon: const Icon(Icons.ios_share_rounded, size: 18),
              label: const Text('提交日志（分享文件）'),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '遇到问题时点这里，把日志文件发给我即可定位',
            style: TextStyle(fontSize: 11.5, color: t.text3),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _openLogCenter,
                  icon: const Icon(Icons.article_outlined, size: 18),
                  label: const Text('日志中心'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _saveLog(appState.downloadDir),
                  icon: const Icon(Icons.save_alt_rounded, size: 18),
                  label: const Text('保存到下载目录'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _manageLogs,
                  icon: const Icon(Icons.folder_open_rounded, size: 18),
                  label: const Text('管理日志'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _clearLog,
                  icon: const Icon(Icons.delete_sweep_rounded,
                      size: 18, color: Colors.red),
                  label: const Text('清空日志',
                      style: TextStyle(color: Colors.red)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// 一键把日志文件分享出去
  Future<void> _shareLogFile() async {
    final (path, error) = await logger.exportForShare();
    if (!mounted) return;
    if (path == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出日志失败: $error')),
      );
      return;
    }
    logger.mark('提交日志', path);
    await Share.shareXFiles(
      [XFile(path, mimeType: 'text/plain')],
      subject: '91Download 运行日志',
      text: '91Download 运行日志（含设备信息与操作记录）',
    );
  }

  /// 打开日志中心：实时查看最近日志、直接复制关键片段
  Future<void> _openLogCenter() async {
    await _pushSubPage('日志中心', (context) => _LogCenterContent());
  }

  /// 8. 关于页面区域
  Widget _buildAboutContent() {
    return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info, size: 20, color: Colors.cyan),
                SizedBox(width: 8),
                Text('关于', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
            SizedBox(height: 12),
            Text('91Download 移动端', style: TextStyle(fontSize: 14)),
            SizedBox(height: 4),
            Text('版本: ${VersionService.fullVersion}', style: TextStyle(fontSize: 12, color: Colors.grey)),
            SizedBox(height: 8),
            Text('视频下载工具移动端版本', style: TextStyle(fontSize: 12, color: Colors.grey)),
            SizedBox(height: 8),
            Text(
              '支持 91porn、ml0987 等多个站点',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            SizedBox(height: 16),
            // 检查更新按钮
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _checkUpdate(),
                icon: Icon(Icons.system_update, size: 18),
                label: Text('检查更新'),
              ),
            ),
          ],
    );
  }
  
  /// 检查更新
  Future<void> _checkUpdate() async {
    // 显示检查中提示
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('正在检查更新...')),
    );
    
    final remoteVersion = await VersionService.checkUpdate();
    if (!mounted) return;

    if (remoteVersion == null) {
      final reason = VersionService.lastError;
      // 「正在检查中」不是失败，措辞要区别对待，否则用户看到
      // 连点两下就冒出来的「网络错误」，会以为功能坏了。
      final message = (reason == null || reason.isEmpty)
          ? '检查更新失败：请检查网络连接'
          : (reason.contains('正在检查') ? reason : '检查更新失败：$reason');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
      return;
    }
    
    if (!VersionService.hasNewVersion(remoteVersion)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('当前已是最新版本 ${VersionService.fullVersion}')),
      );
      return;
    }
    
    // 有新版本，显示更新对话框
    if (!mounted) return;
    _showUpdateDialog(remoteVersion);
  }
  
  /// 显示更新对话框（信息分层：版本对照 → 更新内容 → 操作）
  void _showUpdateDialog(VersionInfo version) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color cardColor = isDark ? const Color(0xFF242424) : Colors.white;
    final Color subColor =
        isDark ? const Color(0xFFB0B0B0) : const Color(0xFF757575);

    showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: cardColor,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusXl),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── 头部：图标 + 标题 + 版本对照 ──
            Container(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              color: AppTheme.primaryColor.withOpacity(isDark ? 0.14 : 0.07),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryColor.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                        ),
                        child: const Icon(
                          Icons.system_update,
                          color: AppTheme.primaryColor,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Text(
                        '发现新版本',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  // 版本对照：旧 → 新，一眼看出跨度
                  Row(
                    children: [
                      _buildVersionChip(
                        VersionService.fullVersion,
                        subColor,
                        isDark,
                        strikethrough: true,
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(
                          Icons.arrow_forward,
                          size: 14,
                          color: subColor,
                        ),
                      ),
                      _buildVersionChip(
                        version.fullVersion,
                        AppTheme.primaryColor,
                        isDark,
                        bold: true,
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // ── 内容：大小/日期 + 更新列表 ──
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 元信息（安装包大小 / 发布日期）—— 有才显示
                    if ((version.size ?? 0) > 0 || version.publishedAt.isNotEmpty)
                      Wrap(
                        spacing: 16,
                        runSpacing: 4,
                        children: [
                          if ((version.size ?? 0) > 0)
                            _buildMetaRow(
                              Icons.save_alt,
                              '安装包 ${_formatBytes(version.size!)}',
                              subColor,
                            ),
                          if (version.publishedAt.isNotEmpty)
                            _buildMetaRow(
                              Icons.event,
                              version.publishedAt.split('T').first,
                              subColor,
                            ),
                        ],
                      ),

                    if (version.releaseNotes.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        '更新内容',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: subColor,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 10),
                      // 逐条圆点列表，比一整块文本好扫读
                      ...version.releaseNotes.map(
                        (note) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                margin: const EdgeInsets.only(top: 6),
                                width: 5,
                                height: 5,
                                decoration: const BoxDecoration(
                                  color: AppTheme.primaryColor,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  note,
                                  style: const TextStyle(
                                    fontSize: 13.5,
                                    height: 1.45,
                                  ),
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
            ),

            // ── 操作：等宽大按钮 ──
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 46,
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: subColor,
                          side: BorderSide(
                            color: isDark
                                ? const Color(0xFF3A3A3A)
                                : const Color(0xFFDDDDDD),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(AppTheme.radiusMd),
                          ),
                        ),
                        child: const Text('稍后更新'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: SizedBox(
                      height: 46,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          Navigator.pop(dialogContext);
                          _downloadUpdate(version);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryColor,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(AppTheme.radiusMd),
                          ),
                        ),
                        icon: const Icon(Icons.download, size: 18),
                        label: const Text(
                          '立即更新',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
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

  /// 版本胶囊（旧版本加删除线，新版本高亮）
  Widget _buildVersionChip(
    String label,
    Color color,
    bool isDark, {
    bool bold = false,
    bool strikethrough = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bold
            ? color.withOpacity(0.16)
            : (isDark ? const Color(0xFF2E2E2E) : const Color(0xFFF0F0F0)),
        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12.5,
          color: color,
          fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
          decoration: strikethrough ? TextDecoration.lineThrough : null,
          decorationColor: color,
        ),
      ),
    );
  }

  /// 图标 + 文字的次要元信息
  Widget _buildMetaRow(IconData icon, String text, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 4),
        Text(text, style: TextStyle(fontSize: 12, color: color)),
      ],
    );
  }
  
  /// 下载更新
  ///
  /// 进度弹窗展示：百分比大字 + 已下载/总大小 + 实时速度。
  /// 总大小未知（total == 0）时退化为不限量滚动动画，避免卡在 0%。
  Future<void> _downloadUpdate(VersionInfo version) async {
    // 下载状态（由 StatefulBuilder 驱动重绘）
    int received = 0;
    int total = 0;
    double speed = 0; // 字节/秒

    // 速度用滑动平均，避免每 200ms 一次回调造成数字乱跳
    int lastBytes = 0;
    DateTime lastTick = DateTime.now();

    StateSetter? setDialogState;
    final cancelToken = CancelToken();
    var userCancelled = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) {
          setDialogState = setState;
          return AlertDialog(
            title: const Text('正在下载更新'),
            content: _buildDownloadProgressContent(
              received: received,
              total: total,
              speed: speed,
            ),
            actions: [
              TextButton(
                onPressed: () {
                  userCancelled = true;
                  // 真正中断网络传输，而不只是关掉弹窗
                  if (!cancelToken.isCancelled) cancelToken.cancel('user cancelled');
                  Navigator.pop(dialogContext);
                },
                child: const Text('取消下载'),
              ),
            ],
          );
        },
      ),
    );

    final success = await VersionService.downloadAndInstall(
      version,
      (rec, tot) {
        final now = DateTime.now();
        final elapsed = now.difference(lastTick).inMilliseconds;
        // 累积到 500ms 再算一次速度，短间隔采样噪声大
        if (elapsed >= 500) {
          final deltaBytes = rec - lastBytes;
          if (deltaBytes > 0) {
            speed = deltaBytes / (elapsed / 1000.0);
          }
          lastBytes = rec;
          lastTick = now;
        }
        received = rec;
        total = tot;
        setDialogState?.call(() {});
      },
      cancelToken: cancelToken,
    );

    if (!mounted) return;
    Navigator.pop(context); // 关闭进度对话框

    // 用户主动取消：静默处理，不弹「下载更新失败」
    if (userCancelled || VersionService.wasCancelled) return;

    if (!success) {
      // 展示真实失败原因（版本不完整 / 连接超时 / 无法启动安装器等）
      final reason = VersionService.lastError ?? '下载更新失败';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(reason)),
      );
    }
  }

  /// 构建下载进度弹窗内容（方案 A：信息只出现一次）
  Widget _buildDownloadProgressContent({
    required int received,
    required int total,
    required double speed,
  }) {
    final bool unknownTotal = total <= 0;
    final double progress =
        unknownTotal ? 0 : (received / total).clamp(0.0, 1.0);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '请保持网络连接，勿退出应用',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 16),

        // 标题行：百分比大字 + 大小。总大小未知时不显示假的 0%
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (!unknownTotal) ...[
              Text(
                '${(progress * 100).toStringAsFixed(0)}',
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                  height: 1,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const Text(
                '%',
                style: TextStyle(fontSize: 15, color: Colors.grey, height: 1),
              ),
              const SizedBox(width: 10),
            ] else
              const Text(
                '正在获取文件信息…',
                style: TextStyle(fontSize: 14, color: Colors.grey, height: 1),
              ),
            const Spacer(),
            Text(
              unknownTotal
                  ? _formatBytes(received)
                  : '${_formatBytes(received)} / ${_formatBytes(total)}',
              style: const TextStyle(
                fontSize: 12,
                color: Colors.grey,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // 进度条：已知总量用确定值，未知用不限量滚动动画
        ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: unknownTotal
              ? const LinearProgressIndicator(minHeight: 8)
              : TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: progress),
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOut,
                  builder: (context, value, _) => LinearProgressIndicator(
                    value: value,
                    minHeight: 8,
                  ),
                ),
        ),
        const SizedBox(height: 10),

        // 底部：已下载量 + 实时速度
        Row(
          children: [
            Text(
              '已下载 ${_formatBytes(received)}',
              style: const TextStyle(
                fontSize: 11.5,
                color: Colors.grey,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const Spacer(),
            if (speed > 0)
              Text(
                '↓ ${_formatBytes(speed.round())}/s',
                style: const TextStyle(
                  fontSize: 11.5,
                  color: Colors.green,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
          ],
        ),
      ],
    );
  }

  /// 字节数格式化（B / KB / MB / GB）
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
  
  
  Future<void> _saveLog(String downloadDir) async {
    if (downloadDir.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('下载目录未初始化')),
      );
      return;
    }
    
    if (!logger.enabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('请先开启Debug模式')),
      );
      return;
    }
    
    if (logger.logPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('日志文件未初始化，请稍后重试')),
      );
      return;
    }
    
    final (savedPath, error) = await logger.saveToDirectoryWithError(downloadDir);
    if (savedPath != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('日志已保存到: $savedPath')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $error')),
      );
    }
  }
  
  /// 管理日志 - 查看和删除日志文件列表
  Future<void> _manageLogs() async {
    final files = await logger.getAllLogFiles();
    
    if (!mounted) return;
    
    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('暂无日志文件')),
      );
      return;
    }
    
    // 显示日志列表对话框
    final result = await showDialog<String>(
      context: context,
      builder: (context) => _LogManagerDialog(files: files),
    );
    
    if (result == null || !mounted) return;
    
    if (result == 'clear_all') {
      // 清空所有日志
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('确认清空'),
          content: Text('确定要删除所有日志文件吗？'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text('取消')),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('确定', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );
      
      if (confirm == true) {
        final count = await logger.deleteAllSavedLogs();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已删除 $count 个日志文件')),
          );
        }
      }
    } else if (result.startsWith('delete:')) {
      // 删除单个日志
      final filePath = result.substring(7);
      final success = await logger.deleteLogFile(filePath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(success ? '日志已删除' : '删除失败')),
        );
      }
      // 重新显示列表
      _manageLogs();
    }
  }
  
  Future<void> _clearLog() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('确认清空'),
        content: Text('确定要清空所有日志吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('确定', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    
    if (confirm == true) {
      await logger.clearLogs();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('日志已清空')),
      );
    }
  }
}

/// 日志管理对话框
class _LogManagerDialog extends StatefulWidget {
  final List<File> files;
  
  _LogManagerDialog({required this.files});
  
  @override
  State<_LogManagerDialog> createState() => _LogManagerDialogState();
}

class _LogManagerDialogState extends State<_LogManagerDialog> {
  Set<String> _selectedFiles = {};
  
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('日志管理'),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '共 ${widget.files.length} 个日志文件',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: widget.files.length,
                itemBuilder: (context, index) {
                  final file = widget.files[index];
                  final fileName = file.path.split('/').last;
                  final fileSize = file.lengthSync();
                  final modifiedTime = file.lastModifiedSync();
                  final isSelected = _selectedFiles.contains(file.path);
                  
                  return ListTile(
                    dense: true,
                    leading: Checkbox(
                      value: isSelected,
                      onChanged: (value) {
                        setState(() {
                          if (value == true) {
                            _selectedFiles.add(file.path);
                          } else {
                            _selectedFiles.remove(file.path);
                          }
                        });
                      },
                    ),
                    title: Text(
                      fileName,
                      style: TextStyle(fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${_formatFileSize(fileSize)} · ${_formatDateTime(modifiedTime)}',
                      style: TextStyle(fontSize: 11),
                    ),
                    trailing: IconButton(
                      icon: Icon(Icons.delete_outline, color: Colors.red, size: 20),
                      onPressed: () {
                        Navigator.pop(context, 'delete:${file.path}');
                      },
                    ),
                    onTap: () {
                      setState(() {
                        if (isSelected) {
                          _selectedFiles.remove(file.path);
                        } else {
                          _selectedFiles.add(file.path);
                        }
                      });
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('取消'),
        ),
        if (_selectedFiles.isNotEmpty)
          TextButton(
            onPressed: () async {
              final count = _selectedFiles.length;
              // 在 await 之前取好 Navigator / ScaffoldMessenger，
              // 避免 await 之后再通过 context 查找（此时可能已失效）
              final navigator = Navigator.of(context);
              final messenger = ScaffoldMessenger.of(context);

              for (final path in _selectedFiles) {
                await logger.deleteLogFile(path);
              }

              navigator.pop();
              messenger.showSnackBar(
                SnackBar(content: Text('已删除 $count 个日志文件')),
              );
            },
            child: Text('删除选中', style: TextStyle(color: Colors.red)),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context, 'clear_all'),
          child: Text('清空全部', style: TextStyle(color: Colors.red)),
        ),
      ],
    );
  }
  
  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  
  String _formatDateTime(DateTime dt) {
    return '${dt.month}/${dt.day} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
  }
}


/// 设置项的二级页面：统一顶栏（返回 + 标题 + 可选右侧动作）+ 内容区
///
/// [plain] 为 true 时内容自己带卡片（站点与线路按原型排成大卡 + 分组），
/// 外面再套一层白卡会变成「卡中卡」。
class _SettingsSubPage extends StatelessWidget {
  final String title;
  final WidgetBuilder body;
  final List<Widget> Function(BuildContext context)? actions;
  final bool plain;
  final Listenable? listenable;

  const _SettingsSubPage({
    required this.title,
    required this.body,
    this.actions,
    this.plain = false,
    this.listenable,
  });

  @override
  Widget build(BuildContext context) {
    final l = listenable;
    if (l == null) return _build(context);
    // 二级页是 push 出来的独立路由，父 State 的 setState 建不到它；
    // 站点延迟这类异步结果只能靠 ValueNotifier 主动触发重建。
    return AnimatedBuilder(
      animation: l,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final t = AppTokens.of(context);
    final act = actions;
    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(
        backgroundColor: t.surface,
        centerTitle: false,
        toolbarHeight: 58,
        titleSpacing: 0,
        elevation: 0,
        leadingWidth: 52,
        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          // 必须居中：AppBar 的 leading 会被拉满工具条高度，
          // 直接放 34x34 的 AppIconBtn 会被纵向拉长，圆角框变成瘦高条
          child: Center(
            child: AppIconBtn(
              icon: Icons.arrow_back_rounded,
              tooltip: '返回',
              onTap: () => Navigator.pop(context),
            ),
          ),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: t.text1,
          ),
        ),
        actions: act == null
            ? null
            : [
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: act(context),
                  ),
                ),
              ],
        shape: Border(bottom: BorderSide(color: t.line)),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            12, 12, 12, MediaQuery.of(context).padding.bottom + 24),
        children: [
          if (plain)
            body(context)
          else
            Container(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
              decoration: BoxDecoration(
                color: t.surface,
                borderRadius: BorderRadius.circular(AppRadius.xl),
                border: Border.all(color: t.line),
                boxShadow: t.cardShadow,
              ),
              child: body(context),
            ),
        ],
      ),
    );
  }
}
/// 日志中心：实时查看当前会话日志尾部，支持刷新/复制/分享
class _LogCenterContent extends StatefulWidget {
  const _LogCenterContent();

  @override
  State<_LogCenterContent> createState() => _LogCenterContentState();
}

class _LogCenterContentState extends State<_LogCenterContent> {
  String _content = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final tail = await logger.getLogTail(tailLines: 300);
    if (!mounted) return;
    setState(() {
      _content = tail;
      _loading = false;
    });
  }

  Future<void> _copyAll() async {
    if (_content.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _content));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('日志已复制到剪贴板')),
    );
  }

  Future<void> _shareFile() async {
    final (path, error) = await logger.exportForShare();
    if (!mounted) return;
    if (path == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出日志失败: $error')),
      );
      return;
    }
    logger.mark('提交日志', path);
    await Share.shareXFiles(
      [XFile(path, mimeType: 'text/plain')],
      subject: '91Download 运行日志',
      text: '91Download 运行日志（含设备信息与操作记录）',
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final lineCount =
        _content.isEmpty ? 0 : _content.split(String.fromCharCode(10)).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _loading
                    ? '加载中…'
                    : '最近 $lineCount 行 · ${_content.length} 字符',
                style: TextStyle(fontSize: 12.5, color: t.text3),
              ),
            ),
            AppIconBtn(
              icon: Icons.refresh_rounded,
              tooltip: '刷新',
              onTap: _reload,
            ),
            const SizedBox(width: 8),
            AppIconBtn(
              icon: Icons.copy_rounded,
              tooltip: '复制全部',
              onTap: _copyAll,
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          height: 460,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: t.surface2,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: t.line),
          ),
          child: _loading
              ? const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _content.isEmpty
                          ? '暂无日志，请先开启 Debug 日志。'
                          : _content,
                      style: TextStyle(
                        fontSize: 10.5,
                        height: 1.45,
                        color: t.text2,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _shareFile,
            icon: const Icon(Icons.ios_share_rounded, size: 18),
            label: const Text('提交日志（分享文件）'),
          ),
        ),
      ],
    );
  }
}


