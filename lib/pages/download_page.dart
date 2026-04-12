import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:share_plus/share_plus.dart';
import 'package:open_filex/open_filex.dart';
import 'dart:io';
import '../services/app_state.dart';
import '../services/download_manager.dart';
import '../models/video_info.dart' show VideoInfo;
import '../utils/logger.dart';

class DownloadPage extends StatefulWidget {
  const DownloadPage({super.key});

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  late TabController _tabController;
  Set<String> _selectedIds = {};  // 已选择的任务ID
  
  @override
  bool get wantKeepAlive => true;
  
  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }
  
  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('下载管理'),
            Consumer<AppState>(
              builder: (context, appState, _) {
                final dm = appState.downloadManager;
                return Text(
                  '下载中: ${dm.downloadingCount} | 已完成: ${dm.completedCount}',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                );
              },
            ),
          ],
        ),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: '下载中'),
            Tab(text: '已下载'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildDownloadingTab(),
          _buildCompletedTab(),
        ],
      ),
    );
  }
  
  /// 下拉刷新回调
  Future<void> _onRefresh() async {
    // 触发重新构建
    setState(() {
      // 强制刷新 UI
    });
    // 等待一小段时间以确保状态更新
    await Future.delayed(Duration(milliseconds: 300));
  }
  
  Widget _buildDownloadingTab() {
    return Consumer<AppState>(
      builder: (context, appState, _) {
        final tasks = appState.downloadManager.downloadingTasks;
        
        if (tasks.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.download_outlined, size: 64, color: Colors.grey),
                SizedBox(height: 16),
                Text('暂无下载任务', style: TextStyle(color: Colors.grey)),
                SizedBox(height: 8),
                Text('在搜索页面选择视频后点击下载', style: TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          );
        }
        
        return Column(
          children: [
            // 全选操作栏
            Container(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () {
                      setState(() {
                        // 只选择下载中的任务ID
                        final downloadingIds = tasks
                            .where((t) => t.status == DownloadStatus.downloading || 
                                          t.status == DownloadStatus.paused ||
                                          t.status == DownloadStatus.pending ||
                                          t.status == DownloadStatus.failed)
                            .map((t) => t.id)
                            .toSet();
                        if (_selectedIds.length == downloadingIds.length) {
                          _selectedIds.clear();
                        } else {
                          _selectedIds = downloadingIds;
                        }
                      });
                    },
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _selectedIds.length == tasks.length 
                            ? Icons.check_box 
                            : Icons.check_box_outline_blank,
                          size: 18,
                        ),
                        SizedBox(width: 4),
                        Text(_selectedIds.length == tasks.length ? '取消全选' : '全选'),
                      ],
                    ),
                  ),
                  Spacer(),
                  if (_selectedIds.isNotEmpty)
                    Text(
                      '已选择 ${_selectedIds.length} 个',
                      style: TextStyle(color: Colors.blue),
                    ),
                ],
              ),
            ),
            // 任务列表
            Expanded(
              child: RefreshIndicator(
                onRefresh: _onRefresh,
                child: ListView.builder(
                  itemCount: tasks.length,
                  itemBuilder: (context, index) {
                    final task = tasks[index];
                    final selected = _selectedIds.contains(task.id);
                    return _buildDownloadTaskItem(task, selected, appState);
                  },
                ),
              ),
            ),
            // 底部批量操作栏（与搜索页一致）
            if (_selectedIds.isNotEmpty)
              Container(
                padding: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black12,
                      blurRadius: 4,
                      offset: Offset(0, -2),
                    ),
                  ],
                ),
                child: SafeArea(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildActionButton(
                        icon: Icons.play_arrow,
                        label: '开始',
                        color: Colors.green,
                        onPressed: () => _batchStart(appState),
                      ),
                      _buildActionButton(
                        icon: Icons.pause,
                        label: '暂停',
                        color: Colors.orange,
                        onPressed: () => _batchPause(appState),
                      ),
                      _buildActionButton(
                        icon: Icons.stop,
                        label: '停止',
                        color: Colors.red,
                        onPressed: () => _batchStop(appState),
                      ),
                      _buildActionButton(
                        icon: Icons.delete,
                        label: '删除',
                        color: Colors.red,
                        onPressed: () => _batchDeleteWithConfirm(appState),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
  
  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: color,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color),
          SizedBox(height: 4),
          Text(label, style: TextStyle(color: color, fontSize: 12)),
        ],
      ),
    );
  }
  
  void _batchStart(AppState appState) async {
    for (final id in _selectedIds.toList()) {
      final task = appState.downloadManager.downloadingTasks.firstWhere(
        (t) => t.id == id,
        orElse: () => throw Exception('Task not found'),
      );
      if (task.status == DownloadStatus.paused) {
        appState.downloadManager.resumeTask(id);
      } else if (task.status == DownloadStatus.pending || task.status == DownloadStatus.failed) {
        appState.downloadManager.startTask(id);
      }
    }
    setState(() {
      _selectedIds.clear();
    });
  }
  
  void _batchPause(AppState appState) async {
    for (final id in _selectedIds.toList()) {
      appState.downloadManager.pauseTask(id);
    }
    setState(() {
      _selectedIds.clear();
    });
  }
  
  void _batchStop(AppState appState) async {
    for (final id in _selectedIds.toList()) {
      appState.downloadManager.cancelTask(id);
    }
    setState(() {
      _selectedIds.clear();
    });
  }
  
  /// 批量删除（带确认对话框，询问是否删除本地文件）
  void _batchDeleteWithConfirm(AppState appState) async {
    final count = _selectedIds.length;
    
    final result = await showDialog<Map<String, bool>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('确认删除'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('确定要删除选中的 $count 个任务吗？'),
            SizedBox(height: 16),
            StatefulBuilder(
              builder: (context, setDialogState) {
                bool deleteFile = false;
                return Row(
                  children: [
                    Checkbox(
                      value: deleteFile,
                      onChanged: (v) {
                        setDialogState(() {
                          deleteFile = v ?? false;
                        });
                      },
                    ),
                    Expanded(
                      child: Text('同时删除本地文件', style: TextStyle(fontSize: 14)),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('取消'),
          ),
          TextButton(
            onPressed: () {
              // 获取复选框状态
              final checkbox = context.findAncestorStateOfType<State>();
              final deleteFile = checkbox != null;
              Navigator.pop(context, {'deleteFile': deleteFile});
            },
            child: Text('确定', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    
    if (result != null) {
      final deleteFile = result['deleteFile'] ?? false;
      
      for (final id in _selectedIds.toList()) {
        if (deleteFile) {
          // 删除任务和本地文件
          final task = appState.downloadManager.getTask(id);
          if (task?.filePath != null) {
            try {
              final file = File(task!.filePath!);
              if (await file.exists()) {
                await file.delete();
              }
            } catch (e) {
            }
          }
        }
        appState.downloadManager.cancelTask(id);
      }
      setState(() {
        _selectedIds.clear();
      });
    }
  }
  
  Widget _buildCompletedTab() {
    return Consumer<AppState>(
      builder: (context, appState, _) {
        final tasks = appState.downloadManager.completedTasks;
        
        if (tasks.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.folder_outlined, size: 64, color: Colors.grey),
                SizedBox(height: 16),
                Text('暂无下载记录', style: TextStyle(color: Colors.grey)),
              ],
            ),
          );
        }
        
        return RefreshIndicator(
          onRefresh: _onRefresh,
          child: Column(
            children: [
              // 全选/删除操作栏
              Container(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: () {
                        setState(() {
                          if (_selectedIds.length == tasks.length) {
                            _selectedIds.clear();
                          } else {
                            _selectedIds = tasks.map((t) => t.id).toSet();
                          }
                        });
                      },
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _selectedIds.length == tasks.length 
                              ? Icons.check_box 
                              : Icons.check_box_outline_blank,
                            size: 18,
                          ),
                          SizedBox(width: 4),
                          Text(_selectedIds.length == tasks.length ? '取消全选' : '全选'),
                        ],
                      ),
                    ),
                    Spacer(),
                    if (_selectedIds.isNotEmpty)
                      TextButton(
                        onPressed: () => _deleteSelectedWithConfirm(appState),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.delete, size: 18, color: Colors.red),
                            SizedBox(width: 4),
                            Text('删除 (${_selectedIds.length})', style: TextStyle(color: Colors.red)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: tasks.length,
                  itemBuilder: (context, index) {
                    final task = tasks[index];
                    final selected = _selectedIds.contains(task.id);
                    return _buildCompletedTaskItem(task, selected, appState);
                  },
                ),
              ),
              // 底部操作栏
              Padding(
                padding: EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          appState.downloadManager.clearCompleted();
                          setState(() {
                            _selectedIds.clear();
                          });
                        },
                        icon: Icon(Icons.delete_sweep, color: Colors.orange),
                        label: Text('清空记录', style: TextStyle(color: Colors.orange)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
  
  /// 删除选中任务（带确认对话框，询问是否删除本地文件）
  void _deleteSelectedWithConfirm(AppState appState) async {
    final count = _selectedIds.length;
    
    final result = await showDialog<Map<String, bool>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('确认删除'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('确定要删除选中的 $count 个下载记录吗？'),
            SizedBox(height: 16),
            StatefulBuilder(
              builder: (context, setDialogState) {
                bool deleteFile = true;  // 默认勾选删除文件
                return Row(
                  children: [
                    Checkbox(
                      value: deleteFile,
                      onChanged: (v) {
                        setDialogState(() {
                          deleteFile = v ?? true;
                        });
                      },
                    ),
                    Expanded(
                      child: Text('同时删除本地文件', style: TextStyle(fontSize: 14)),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('取消'),
          ),
          TextButton(
            onPressed: () {
              // 获取复选框状态（通过查找Checkbox的状态）
              Navigator.pop(context, {'deleteFile': true});
            },
            child: Text('确定', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    
    if (result != null) {
      final deleteFile = result['deleteFile'] ?? true;
      
      for (final id in _selectedIds.toList()) {
        if (deleteFile) {
          // 删除本地文件
          final task = appState.downloadManager.getTask(id);
          if (task?.filePath != null) {
            try {
              final file = File(task!.filePath!);
              if (await file.exists()) {
                await file.delete();
              }
            } catch (e) {
            }
          }
        }
        appState.downloadManager.cancelTask(id);
      }
      setState(() {
        _selectedIds.clear();
      });
    }
  }
  
  Widget _buildDownloadTaskItem(DownloadTask task, bool selected, AppState appState) {
    return GestureDetector(
      onTap: () {
        setState(() {
          if (_selectedIds.contains(task.id)) {
            _selectedIds.remove(task.id);
          } else {
            _selectedIds.add(task.id);
          }
        });
      },
      child: Card(
        margin: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        color: selected ? Colors.blue.withOpacity(0.1) : null,
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // 封面 + 选中标记
                  Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: task.video.cover != null
                          ? Image.network(task.video.cover!, width: 80, height: 60, fit: BoxFit.cover)
                          : Container(width: 80, height: 60, color: Colors.grey[300], child: Icon(Icons.video_file)),
                      ),
                      // 选中标记（左上角）
                      if (selected)
                        Positioned(
                          top: 2,
                          left: 2,
                          child: Container(
                            padding: EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: Colors.blue,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(Icons.check, size: 12, color: Colors.white),
                          ),
                        ),
                    ],
                  ),
                  SizedBox(width: 12),
                  // 信息
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _formatTitle(task.video),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        SizedBox(height: 4),
                        Text(
                          task.statusText,
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                  // 控制按钮
                  _buildTaskControls(task, appState),
                ],
              ),
            
            // 进度条
            if (task.status == DownloadStatus.downloading) ...[
              SizedBox(height: 8),
              LinearProgressIndicator(value: task.progress),
              SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // 显示已下载/总大小
                  Text(
                    task.progressText.isNotEmpty 
                        ? task.progressText 
                        : '${(task.progress * 100).toStringAsFixed(1)}%',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  // 显示下载速度
                  if (task.speedText.isNotEmpty)
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.green.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.speed, size: 12, color: Colors.green),
                          SizedBox(width: 4),
                          Text(
                            task.speedText,
                            style: TextStyle(fontSize: 11, color: Colors.green),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
            
            // 错误信息
            if (task.status == DownloadStatus.failed && task.error != null) ...[
              SizedBox(height: 4),
              Text(
                '错误: ${task.error}',
                style: TextStyle(fontSize: 11, color: Colors.red),
              ),
            ],
          ],
        ),
      ),
    ),
  );
  }
  
  Widget _buildTaskControls(DownloadTask task, AppState appState) {
    switch (task.status) {
      case DownloadStatus.pending:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(Icons.play_arrow, color: Colors.green),
              onPressed: () => appState.downloadManager.startTask(task.id),
              tooltip: '开始',
            ),
            IconButton(
              icon: Icon(Icons.delete, color: Colors.red),
              onPressed: () => _deleteTaskWithConfirm(task, appState),
              tooltip: '删除',
            ),
          ],
        );
      case DownloadStatus.downloading:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(Icons.pause, color: Colors.orange),
              onPressed: () => appState.downloadManager.pauseTask(task.id),
              tooltip: '暂停',
            ),
            IconButton(
              icon: Icon(Icons.stop, color: Colors.red),
              onPressed: () => appState.downloadManager.cancelTask(task.id),
              tooltip: '停止',
            ),
          ],
        );
      case DownloadStatus.paused:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(Icons.play_arrow, color: Colors.green),
              onPressed: () => appState.downloadManager.resumeTask(task.id),
              tooltip: '继续',
            ),
            IconButton(
              icon: Icon(Icons.delete, color: Colors.red),
              onPressed: () => _deleteTaskWithConfirm(task, appState),
              tooltip: '删除',
            ),
          ],
        );
      case DownloadStatus.failed:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(Icons.refresh, color: Colors.blue),
              onPressed: () => appState.downloadManager.retryTask(task.id),
              tooltip: '重试',
            ),
            IconButton(
              icon: Icon(Icons.delete, color: Colors.red),
              onPressed: () => _deleteTaskWithConfirm(task, appState),
              tooltip: '删除',
            ),
          ],
        );
      default:
        return SizedBox.shrink();
    }
  }
  
  /// 单个任务删除（带确认对话框）
  void _deleteTaskWithConfirm(DownloadTask task, AppState appState) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('确认删除'),
        content: Text('确定要删除任务"${_formatTitle(task.video)}"吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('确定', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    
    if (result == true) {
      appState.downloadManager.cancelTask(task.id);
    }
  }
  
  Widget _buildCompletedTaskItem(DownloadTask task, bool selected, AppState appState) {
    return GestureDetector(
      onTap: () {
        // 短按播放视频
        _playVideo(task, appState);
      },
      onLongPress: () {
        // 长按选择视频
        setState(() {
          if (_selectedIds.contains(task.id)) {
            _selectedIds.remove(task.id);
          } else {
            _selectedIds.add(task.id);
          }
        });
      },
      child: Card(
        margin: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        color: selected ? Colors.blue.withOpacity(0.1) : null,
        child: ListTile(
          leading: Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: task.video.cover != null
                  ? Image.network(task.video.cover!, width: 60, height: 45, fit: BoxFit.cover)
                  : Container(width: 60, height: 45, color: Colors.grey[300], child: Icon(Icons.video_file, size: 20)),
              ),
              // 选中标记（左上角）
              if (selected)
                Positioned(
                  top: 0,
                  left: 0,
                  child: Container(
                    padding: EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: Colors.blue,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.check, size: 12, color: Colors.white),
                  ),
                ),
            ],
          ),
          title: Text(
            _formatTitle(task.video),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '下载于 ${_formatTime(task.endTime)}',
            style: TextStyle(fontSize: 12),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 播放按钮
              IconButton(
                icon: Icon(Icons.play_circle, color: Colors.green),
                onPressed: () => _playVideo(task, appState),
                tooltip: '播放',
              ),
              // 分享按钮
              IconButton(
                icon: Icon(Icons.share, color: Colors.blue),
                onPressed: () => _shareVideo(task),
                tooltip: '分享',
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  /// 播放视频
  void _playVideo(DownloadTask task, AppState appState) async {
    
    if (task.filePath == null || task.filePath!.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('文件路径不存在')),
        );
      }
      return;
    }
    
    final file = File(task.filePath!);
    if (!await file.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('文件不存在: ${task.filePath}')),
        );
      }
      return;
    }
    
    // 根据设置决定使用内置还是外部播放器
    if (appState.useExternalPlayer) {
      await _playWithExternalPlayer(task);
    } else {
      await _playWithInternalPlayer(task);
    }
  }
  
  /// 使用内置播放器播放
  Future<void> _playWithInternalPlayer(DownloadTask task) async {
    
    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => VideoPlayerPage(
            filePath: task.filePath!,
            title: task.video.title,
          ),
        ),
      );
    }
  }
  
  /// 使用外部播放器播放
  Future<void> _playWithExternalPlayer(DownloadTask task) async {
    
    try {
      final file = File(task.filePath!);
      if (!await file.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('文件不存在')),
          );
        }
        return;
      }
      
      // 使用 open_filex 打开外部播放器（自动处理 FileProvider）
      final result = await OpenFilex.open(
        task.filePath!,
        type: 'video/*',
      );
      
      if (result.type != ResultType.done) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('没有可用的外部播放器，使用内置播放器')),
          );
        }
        await _playWithInternalPlayer(task);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开外部播放器失败: $e')),
        );
      }
      // 回退到内置播放器
      await _playWithInternalPlayer(task);
    }
  }
  
  /// 分享视频
  void _shareVideo(DownloadTask task) async {
    if (task.filePath == null) return;
    
    try {
      await Share.shareXFiles([XFile(task.filePath!)], text: task.video.title);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('分享失败: $e')),
        );
      }
    }
  }
  
  String _formatTitle(VideoInfo video) {
    String title = video.title;
    // 添加作者信息
    if (video.author != null && video.author!.isNotEmpty) {
      title = '$title - ${video.author}';
    }
    // 截断过长的标题
    if (title.length > 40) {
      return '${title.substring(0, 40)}...';
    }
    return title;
  }
  
  String _formatTime(DateTime? time) {
    if (time == null) return '未知';
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
  }
}

/// 视频播放器页面
class VideoPlayerPage extends StatefulWidget {
  final String filePath;
  final String title;
  
  const VideoPlayerPage({
    super.key,
    required this.filePath,
    required this.title,
  });
  
  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  late VideoPlayerController _videoPlayerController;
  ChewieController? _chewieController;
  bool _isInitialized = false;
  bool _hasError = false;
  String _errorMessage = '';
  
  // 手势控制进度相关
  bool _isDragging = false;
  double _dragStartX = 0;
  Duration _dragStartPosition = Duration.zero;
  Duration _seekPosition = Duration.zero;
  bool _showSeekIndicator = false;
  
  @override
  void initState() {
    super.initState();
    _initializePlayer();
  }
  
  Future<void> _initializePlayer() async {
    try {
      
      // 使用文件路径初始化 VideoPlayerController
      _videoPlayerController = VideoPlayerController.file(File(widget.filePath));
      
      await _videoPlayerController.initialize();
      
      _chewieController = ChewieController(
        videoPlayerController: _videoPlayerController,
        autoPlay: true,
        looping: false,
        aspectRatio: _videoPlayerController.value.aspectRatio,
        errorBuilder: (context, errorMessage) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error, color: Colors.red, size: 48),
                SizedBox(height: 16),
                Text('播放错误: $errorMessage', style: TextStyle(color: Colors.red)),
              ],
            ),
          );
        },
        placeholder: Container(
          color: Colors.black,
          child: Center(
            child: CircularProgressIndicator(color: Colors.white),
          ),
        ),
      );
      
      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _hasError = true;
          _errorMessage = e.toString();
        });
      }
    }
  }
  
  @override
  void dispose() {
    _videoPlayerController.dispose();
    _chewieController?.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      backgroundColor: Colors.black,
      body: _buildBody(),
    );
  }
  
  Widget _buildBody() {
    if (_hasError) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, color: Colors.red, size: 64),
            SizedBox(height: 16),
            Text(
              '视频加载失败',
              style: TextStyle(color: Colors.white, fontSize: 18),
            ),
            SizedBox(height: 8),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _errorMessage,
                style: TextStyle(color: Colors.grey, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
            SizedBox(height: 24),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _hasError = false;
                  _errorMessage = '';
                });
                _initializePlayer();
              },
              child: Text('重试'),
            ),
          ],
        ),
      );
    }
    
    if (!_isInitialized || _chewieController == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 16),
            Text(
              '加载中...',
              style: TextStyle(color: Colors.white),
            ),
          ],
        ),
      );
    }
    
    return GestureDetector(
      onHorizontalDragStart: (details) {
        if (!_videoPlayerController.value.isInitialized) return;
        setState(() {
          _isDragging = true;
          _dragStartX = details.globalPosition.dx;
          _dragStartPosition = _videoPlayerController.value.position;
          _seekPosition = _dragStartPosition;
          _showSeekIndicator = true;
        });
        // 暂停播放以便拖动
        if (_videoPlayerController.value.isPlaying) {
          _videoPlayerController.pause();
        }
      },
      onHorizontalDragUpdate: (details) {
        if (!_isDragging) return;
        
        final screenWidth = MediaQuery.of(context).size.width;
        final dx = details.globalPosition.dx - _dragStartX;
        
        // 每滑动屏幕宽度的 1/2，快进/快退 10 秒
        final totalDuration = _videoPlayerController.value.duration;
        final seekRatio = dx / (screenWidth / 2);
        final seekSeconds = (seekRatio * 10).round();
        
        final newPosition = _dragStartPosition + Duration(seconds: seekSeconds);
        // 限制在有效范围内
        _seekPosition = Duration(
          milliseconds: newPosition.inMilliseconds.clamp(0, totalDuration.inMilliseconds),
        );
        
        setState(() {});
      },
      onHorizontalDragEnd: (details) {
        if (!_isDragging) return;
        
        // 跳转到目标位置
        _videoPlayerController.seekTo(_seekPosition);
        
        setState(() {
          _isDragging = false;
          _showSeekIndicator = false;
        });
        
        // 恢复播放
        _videoPlayerController.play();
      },
      child: Stack(
        children: [
          Center(
            child: Chewie(controller: _chewieController!),
          ),
          // 进度指示器
          if (_showSeekIndicator)
            Center(
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${_formatDuration(_seekPosition)} / ${_formatDuration(_videoPlayerController.value.duration)}',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
  
  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes}:${seconds.toString().padLeft(2, '0')}';
  }
}
