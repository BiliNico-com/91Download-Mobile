import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import '../services/app_state.dart';
import '../crawler/config.dart';
import '../utils/logger.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> with AutomaticKeepAliveClientMixin {
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
              // 站点选择 - 必须先选择
              _buildSiteSection(appState),
              
              // 下载目录
              _buildDownloadDirSection(appState),
              
              // 播放器设置
              _buildPlayerSection(appState),
              
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
                  print('[Settings] 选择站点: $site');
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

  Widget _buildPlayerSection(AppState appState) {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.view_module, size: 20, color: Colors.blue),
                SizedBox(width: 8),
                Text('浏览设置', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
            SizedBox(height: 12),
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
                appState.showBackToTop = v;
                appState.notifyListeners();
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
                  },
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
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Debug模式'),
              subtitle: Text('开启后将记录运行日志'),
              value: appState.debugMode,
              onChanged: (v) async {
                await appState.toggleDebug(v);
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
            Text('版本: v1.0.5', style: TextStyle(fontSize: 12, color: Colors.grey)),
            SizedBox(height: 8),
            Text('视频下载工具移动端版本', style: TextStyle(fontSize: 12, color: Colors.grey)),
            SizedBox(height: 8),
            Text(
              '支持 91porn、ml0987 等多个站点',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
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
    
    final savedPath = await logger.saveToDirectory(downloadDir);
    if (savedPath != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('日志已保存到: $savedPath')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存日志失败，请检查存储权限')),
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
