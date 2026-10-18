import 'dart:io';
import 'dart:ui' show FontFeature;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import '../services/app_state.dart';
import '../services/version_service.dart';

import '../services/pin_service.dart';
import '../utils/logger.dart';
import '../utils/open_directory.dart';
import '../theme/ui_style.dart';
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
  Widget build(BuildContext context) {
    super.build(context);  // 必须调用，启用AutomaticKeepAliveClientMixin
    return Consumer<AppState>(
      builder: (context, appState, _) {
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('设置'),
                Text('站点、下载目录',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          ),
          body: ListView(
            children: [
              // 1. 当前站点选择（折叠）
              _buildSiteSection(appState),
              
              // 2. 下载目录设置（折叠）
              _buildDownloadDirSection(appState),
              
              // 3. 下载并发设置（折叠）
              _buildDownloadConcurrencySection(appState),
              
              // 4. 浏览设置（折叠）
              _buildBrowseSection(appState),
              
              // 5. 主题模式设置（折叠）
              _buildThemeSection(appState),
              
              // 6. 应用锁设置（不折叠）
              _buildAppLockSection(appState),
              
              // 7. 权限状态展示（折叠）
              _buildPermissionSection(appState),
              
              // 8. 调试设置（折叠）
              _buildDebugSection(appState),
              
              // 9. 关于页面 + 检查更新（不折叠）
              _buildAboutSection(),
              
              // 底部间距
              const SizedBox(height: 32),
            ],
          ),
        );
      },
    );
  }

  /// 1. 当前站点选择区域（折叠）
  Widget _buildSiteSection(AppState appState) {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: true,  // 站点选择默认展开
          leading: Icon(Icons.language, size: 20, color: Colors.blue),
          title: Row(
            children: [
              Text('当前站点', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              if (!appState.isSiteSelected) ...[
                SizedBox(width: 8),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text('请选择', style: TextStyle(color: Colors.orange, fontSize: 12)),
                ),
              ],
            ],
          ),
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButtonFormField<String>(
                    value: appState.currentSite,
                    hint: Text('请选择站点', style: TextStyle(color: Colors.grey)),
                    decoration: InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    items: appState.allSites.map((site) {
                      return DropdownMenuItem(
                        value: site,
                        child: Text(site),
                      );
                    }).toList(),
                    onChanged: (site) async {
                      if (site != null) {
                        print('[Settings] 选择站点: $site');
                        appState.changeSite(site);
                        print('[Settings] 站点已切换, currentSite=${appState.currentSite}');
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('已切换到 $site')),
                        );
                      }
                    },
                  ),
                  SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => _showAddCustomSiteDialog(appState),
                    icon: Icon(Icons.add_link, size: 18),
                    label: Text('手动输入网址'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 手动输入自定义站点网址
  Future<void> _showAddCustomSiteDialog(AppState appState) async {
    final controller = TextEditingController();
    String? input;
    try {
      input = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
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
    } finally {
      controller.dispose();
    }

    if (input == null || input.trim().isEmpty || !mounted) return;

    final normalized = await appState.addCustomSite(input);
    if (normalized != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已切换到 $normalized')),
      );
    }
  }

  /// 2. 下载目录设置区域
  Widget _buildDownloadDirSection(AppState appState) {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: false,  // 默认折叠
          leading: Icon(Icons.folder, size: 20, color: Colors.amber),
          title: Text('下载目录', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
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
              ),
            ),
          ],
        ),
      ),
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
  Widget _buildDownloadConcurrencySection(AppState appState) {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: false,  // 默认折叠
          leading: Icon(Icons.download, size: 20, color: Colors.teal),
          title: Text('下载设置', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
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
                ],
              ),
            ),
          ],
        ),
      ),
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

  /// 3. 浏览设置区域
  Widget _buildBrowseSection(AppState appState) {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: false,  // 默认折叠
          leading: Icon(Icons.view_module, size: 20, color: Colors.blue),
          title: Text('浏览设置', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
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
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 4. 主题模式设置区域
  Widget _buildThemeSection(AppState appState) {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: false,  // 默认折叠
          leading: Icon(Icons.palette, size: 20, color: Colors.purple),
          title: Text('主题模式', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
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
                ],
              ),
            ),
            const Divider(height: 24),
            // ── 界面风格：玻璃拟态开关 ──
            // 可在两种观感间即时切换，觉得毛玻璃卡顿或不好看可直接关掉，
            // 无需回滚代码。
            //
            // 文案与字号要和上方「跟随系统」保持一致：实测该行可用宽度约
            // 220dp，原副标题「已开启：控件半透明模糊，观感更现代（低端机
            // 可能略耗性能）」会折成两行、行高比相邻开关高出一截，看起来
            // 就像没对齐。改成单行短句后两者视觉节奏一致。
            ValueListenableBuilder<bool>(
              valueListenable: UiStyle.glassEnabled,
              builder: (context, glass, _) {
                return SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '毛玻璃效果',
                    style: TextStyle(fontSize: 14),
                  ),
                  subtitle: Text(
                    glass ? '已开启，控件半透明模糊' : '已关闭，控件为实心色',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  value: glass,
                  onChanged: (v) => UiStyle.setGlassEnabled(v),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 5. 应用锁设置区域
  Widget _buildAppLockSection(AppState appState) {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
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
        ),
      ),
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
  Widget _buildPermissionSection(AppState appState) {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: false,  // 默认折叠
          leading: Icon(Icons.security, size: 20, color: Colors.green),
          title: Text('权限状态', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
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
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 7. 调试设置区域（默认折叠）
  Widget _buildDebugSection(AppState appState) {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: false,  // 默认折叠
          leading: Icon(Icons.bug_report, size: 20, color: Colors.purple),
          title: Text('调试设置', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Debug模式'),
                    subtitle: Text('开启后将记录运行日志'),
                    value: appState.debugMode,
                    onChanged: (v) async {
                      await appState.toggleDebug(v);
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('保存HTML'),
                    subtitle: Text('保存请求的HTML到文件，用于调试'),
                    value: appState.saveDebugHtml,
                    onChanged: (v) {
                      appState.toggleSaveDebugHtml(v);
                    },
                  ),
                  if (appState.debugMode) ...[
                    SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _exportLog,
                            icon: Icon(Icons.share, size: 18),
                            label: Text('分享日志'),
                          ),
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _saveLog(appState.downloadDir),
                            icon: Icon(Icons.save, size: 18),
                            label: Text('保存日志'),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _manageLogs,
                            icon: Icon(Icons.folder_open, size: 18),
                            label: Text('管理日志'),
                          ),
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _clearLog,
                            icon: Icon(Icons.delete_sweep, size: 18, color: Colors.red),
                            label: Text('清空日志', style: TextStyle(color: Colors.red)),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.red,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 8. 关于页面区域
  Widget _buildAboutSection() {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
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
        ),
      ),
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
  
  Future<void> _exportLog() async {
    final content = await logger.getLogContent();
    if (!mounted) return;

    if (content.isEmpty || content == '暂无日志') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('暂无日志可导出')),
      );
      return;
    }
    
    await Share.share(content, subject: '91Download Network Log');
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
