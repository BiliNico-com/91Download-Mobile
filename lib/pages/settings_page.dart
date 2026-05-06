import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import '../services/app_state.dart';
import '../services/version_service.dart';

import '../services/pin_service.dart';
import '../crawler/config.dart';
import '../utils/logger.dart';
import 'pin_input_dialog.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> with AutomaticKeepAliveClientMixin {
  final PinService _pinService = PinService();
  
  @override
  bool get wantKeepAlive => true;  // 保持状态
  
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      context.read<AppState>().init();
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
              child: DropdownButtonFormField<String>(
                value: appState.currentSite,
                hint: Text('请选择站点', style: TextStyle(color: Colors.grey)),
                decoration: InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                items: CrawlerConfig.availableSites.map((site) {
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
            ),
          ],
        ),
      ),
    );
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
                    onChanged: (v) => appState.toggleNomedia(v),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  void _setDownloadDirectory(String path) async {
    final appState = context.read<AppState>();
    try {
      final dir = Directory(path);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      appState.setDownloadDir(path);
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
    }
    
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
  
  void _openDownloadDirectory(String path) async {
    if (path.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('下载目录未设置')),
      );
      return;
    }
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('目录路径: $path')),
    );
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
      if (success && mounted) {
        await appState.toggleAppLock(true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已启用应用锁')),
        );
      }
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
      
      await _pinService.removePin();
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
    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('当前PIN码错误')),
      );
      return;
    }
    
    // 设置新PIN码
    final newPin = await PinInputDialog.showSetPin(context);
    if (newPin == null || !mounted) return;
    
    final saved = await _pinService.setPin(newPin);
    if (saved && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('PIN码已修改')),
      );
    }
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
                    subtitle: Text(appState.permissionGranted ? '已授权' : '未授权'),
                    trailing: !appState.permissionGranted
                      ? TextButton(
                          onPressed: () async {
                            await appState.requestPermissions();
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
    
    if (remoteVersion == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('检查更新失败，请检查网络连接')),
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
  
  /// 显示更新对话框
  void _showUpdateDialog(VersionInfo version) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.system_update, color: Colors.green),
            SizedBox(width: 8),
            Text('发现新版本'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('最新版本: ${version.fullVersion}'),
            SizedBox(height: 4),
            Text('当前版本: ${VersionService.fullVersion}'),
            if (version.releaseDate.isNotEmpty) ...[
              SizedBox(height: 4),
              Text('发布日期: ${version.releaseDate}', style: TextStyle(color: Colors.grey)),
            ],
            if (version.releaseNotes.isNotEmpty) ...[
              SizedBox(height: 12),
              Text('更新内容:', style: TextStyle(fontWeight: FontWeight.bold)),
              SizedBox(height: 4),
              Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(version.releaseNotes.join('\n'), style: TextStyle(fontSize: 13)),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text('稍后更新'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(dialogContext);
              _downloadUpdate(version);
            },
            icon: Icon(Icons.download, size: 18),
            label: Text('立即更新'),
          ),
        ],
      ),
    );
  }
  
  /// 下载更新
  Future<void> _downloadUpdate(VersionInfo version) async {
    double progress = 0;
    StateSetter? setDialogState;
    
    // 显示下载进度对话框
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) {
          setDialogState = setState;
          return AlertDialog(
            title: Text('正在下载更新'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: progress),
                SizedBox(height: 8),
                Text('${(progress * 100).toStringAsFixed(0)}%'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text('取消'),
              ),
            ],
          );
        },
      ),
    );
    
    final success = await VersionService.downloadAndInstall(version, (p) {
      progress = p;
      // 刷新对话框UI
      if (setDialogState != null) {
        setDialogState!(() {});
      }
    });
    
    if (mounted) {
      Navigator.pop(context); // 关闭进度对话框
      
      if (!success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下载更新失败')),
        );
      }
    }
  }
  
  Future<void> _exportLog() async {
    final content = await logger.getLogContent();
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
              for (final path in _selectedFiles) {
                await logger.deleteLogFile(path);
              }
              if (mounted) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('已删除 ${_selectedFiles.length} 个日志文件')),
                );
              }
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
