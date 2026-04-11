import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../services/app_state.dart';
import '../crawler/config.dart';
import '../utils/logger.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> with AutomaticKeepAliveClientMixin {
  Timer? _logRefreshTimer;
  static String _logContent = '';  // 改为static，跨页面保持
  static bool _autoRefresh = false;  // 改为static，跨页面保持
  
  @override
  bool get wantKeepAlive => true;  // 保持状态
  
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      context.read<AppState>().init();
      // 如果之前开启了自动刷新，恢复定时器
      if (_autoRefresh) {
        _startAutoRefresh();
      } else {
        // 自动加载一次日志
        _refreshLog();
      }
    });
  }
  
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 每次回到设置页时，都刷新一次日志（从文件读取）
    _refreshLog();
  }
  
  @override
  void dispose() {
    _logRefreshTimer?.cancel();
    super.dispose();
  }
  
  // 启动自动刷新日志
  void _startAutoRefresh() {
    _autoRefresh = true;
    _logRefreshTimer?.cancel();
    _logRefreshTimer = Timer.periodic(Duration(milliseconds: 500), (_) {
      _refreshLog();
    });
    // 立即刷新一次
    _refreshLog();
  }
  
  // 停止自动刷新
  void _stopAutoRefresh() {
    _autoRefresh = false;
    _logRefreshTimer?.cancel();
    _logRefreshTimer = null;
  }
  
  // 刷新日志内容
  Future<void> _refreshLog() async {
    final content = await logger.getLogContent();
    if (mounted) {
      setState(() {
        _logContent = content;
      });
    }
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
              // 站点选择 - 必须先选择
              _buildSiteSection(appState),
              
              // 下载目录
              _buildDownloadDirSection(appState),
              
              // 权限状态
              _buildPermissionSection(appState),
              
              // Debug设置
              _buildDebugSection(appState),
              
              // 关于
              _buildAboutSection(),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSiteSection(AppState appState) {
    return Card(
      margin: EdgeInsets.all(16),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.language, size: 20, color: Colors.blue),
                SizedBox(width: 8),
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
            SizedBox(height: 16),
            DropdownButtonFormField<String>(
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
                  // 先记录日志，再执行操作
                  print('[Settings] 选择站点: $site');
                  await logger.i('Settings', 'UI操作: 切换站点 -> $site');
                  appState.changeSite(site);
                  print('[Settings] 站点已切换, currentSite=${appState.currentSite}');
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('已切换到 $site')),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadDirSection(AppState appState) {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.folder, size: 20, color: Colors.amber),
                SizedBox(width: 8),
                Text('下载目录', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
            SizedBox(height: 12),
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
          ],
        ),
      ),
    );
  }

  Widget _buildPermissionSection(AppState appState) {
    return Card(
      margin: EdgeInsets.all(16),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.security, size: 20, color: Colors.green),
                SizedBox(width: 8),
                Text('权限状态', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
            SizedBox(height: 12),
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
                      await logger.i('Settings', 'UI操作: 点击授权按钮');
                      await appState.requestPermissions();
                    },
                    child: Text('授权'),
                  )
                : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDebugSection(AppState appState) {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bug_report, size: 20, color: Colors.purple),
                SizedBox(width: 8),
                Text('调试设置', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
            SizedBox(height: 12),
            // 回顶部按钮设置
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('显示回顶部按钮'),
              subtitle: Text('滚动时显示快速回顶部按钮'),
              value: appState.showBackToTop,
              onChanged: (v) {
                appState.showBackToTop = v;
                appState.notifyListeners();
                logger.i('Settings', 'UI操作: 切换回顶部按钮 -> $v');
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
                    appState.backToTopPosition = s.first;
                    appState.notifyListeners();
                    logger.i('Settings', 'UI操作: 回顶部按钮位置 -> ${s.first}');
                  },
                ),
              ),
            Divider(),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Debug模式'),
              subtitle: Text('开启后将记录运行日志'),
              value: appState.debugMode,
              onChanged: (v) async {
                await logger.i('Settings', 'UI操作: 切换Debug模式 -> $v');
                await appState.toggleDebug(v);
              },
            ),
            if (appState.debugMode) ...[
              SizedBox(height: 8),
              // 实时日志开关
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('实时日志'),
                subtitle: Text(_autoRefresh ? '每0.5秒自动刷新' : '点击下方按钮刷新'),
                value: _autoRefresh,
                onChanged: (v) {
                  if (v) {
                    _startAutoRefresh();
                    logger.i('Settings', 'UI操作: 开启实时日志');
                  } else {
                    _stopAutoRefresh();
                    logger.i('Settings', 'UI操作: 关闭实时日志');
                  }
                },
              ),
              SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        await _refreshLog();
                        await logger.i('Settings', 'UI操作: 手动刷新日志');
                      },
                      icon: Icon(Icons.refresh, size: 18),
                      label: Text('刷新日志'),
                    ),
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _exportLog,
                      icon: Icon(Icons.share, size: 18),
                      label: Text('分享日志'),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _saveLog(appState.downloadDir),
                      icon: Icon(Icons.save, size: 18),
                      label: Text('保存日志'),
                    ),
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _clearLog,
                      icon: Icon(Icons.delete, size: 18, color: Colors.red),
                      label: Text('清空日志', style: TextStyle(color: Colors.red)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                      ),
                    ),
                  ),
                ],
              ),
              // 日志显示区域
              SizedBox(height: 12),
              Container(
                constraints: BoxConstraints(minHeight: 100, maxHeight: 300),
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  reverse: true, // 最新日志在底部
                  child: Text(
                    _logContent.isEmpty ? '暂无日志，开启实时日志或点击刷新' : _logContent,
                    style: TextStyle(fontSize: 10, color: Colors.green, fontFamily: 'monospace'),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

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
            Text('版本: v1.0.3', style: TextStyle(fontSize: 12, color: Colors.grey)),
            SizedBox(height: 8),
            Text('视频下载工具移动端版本', style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
  
  Future<void> _exportLog() async {
    await logger.i('Settings', 'UI操作: 点击分享日志');
    final content = await logger.getLogContent();
    if (content.isEmpty || content == '暂无日志') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('暂无日志可导出')),
      );
      return;
    }
    
    await Share.share(content, subject: '91Download Debug Log');
  }
  
  Future<void> _saveLog(String downloadDir) async {
    await logger.i('Settings', 'UI操作: 点击保存日志');
    if (downloadDir.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('下载目录未初始化')),
      );
      return;
    }
    
    final savedPath = await logger.saveToDirectory(downloadDir);
    if (savedPath != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('日志已保存到: $savedPath')),
      );
      await logger.i('Settings', '日志已保存: $savedPath');
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存日志失败')),
      );
    }
  }
  
  Future<void> _clearLog() async {
    await logger.i('Settings', 'UI操作: 点击清空日志');
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
      setState(() {
        _logContent = '';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('日志已清空')),
      );
    }
  }
}
