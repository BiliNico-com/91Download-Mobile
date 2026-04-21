import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:share_plus/share_plus.dart';
import 'package:open_filex/open_filex.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';
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
  bool _isCompletedSelectMode = false;  // 已下载tab的选择模式
  bool _isSelectMode = false;     // 选择模式（已下载tab）
  
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
    bool deleteFile = false;  // ✅ 移到外部，避免每次重建时重置
    
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
                            _isCompletedSelectMode = false;
                          } else {
                            _selectedIds = tasks.map((t) => t.id).toSet();
                            _isCompletedSelectMode = true;
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
                        onPressed: () {
                          _deleteSelectedWithConfirm(appState);
                          setState(() {
                            _isCompletedSelectMode = false;
                            _selectedIds.clear();
                          });
                        },
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
    bool deleteFile = true;  // ✅ 移到外部，默认勾选删除文件
    
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
              Navigator.pop(context, {'deleteFile': deleteFile});
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
      onLongPress: () {
        // 长按进入选择模式
        setState(() {
          _isCompletedSelectMode = true;
          _selectedIds.add(task.id);
        });
      },
      onTap: () {
        if (_isCompletedSelectMode) {
          // 选择模式：切换选中
          setState(() {
            if (selected) {
              _selectedIds.remove(task.id);
              if (_selectedIds.isEmpty) {
                _isCompletedSelectMode = false;
              }
            } else {
              _selectedIds.add(task.id);
            }
          });
        } else {
          // 非选择模式：播放视频
          _playVideo(task, appState);
        }
      },
      child: Card(
        margin: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        color: selected ? Colors.blue.withOpacity(0.1) : null,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              // 预览图（放大 + 右下角时长 + 选中标记）
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: task.video.cover != null
                      ? Image.network(task.video.cover!, width: 96, height: 64, fit: BoxFit.cover)
                      : Container(width: 96, height: 64, color: Colors.grey[300], child: Icon(Icons.video_file, size: 24)),
                  ),
                  // 时长标签（右下角）
                  if (task.video.duration != null && task.video.duration!.isNotEmpty)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Container(
                        padding: EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          task.video.duration!,
                          style: TextStyle(color: Colors.white, fontSize: 10),
                        ),
                      ),
                    ),
                  // 选择模式下显示勾选框
                  if (_isCompletedSelectMode)
                    Positioned(
                      top: 2,
                      left: 2,
                      child: Container(
                        padding: EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: selected ? Colors.blue : Colors.white,
                          shape: BoxShape.circle,
                          border: Border.all(color: selected ? Colors.blue : Colors.grey, width: 2),
                        ),
                        child: Icon(selected ? Icons.check : null, size: 12, color: Colors.white),
                      ),
                    ),
                ],
              ),
              SizedBox(width: 12),
              // 信息区域
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _formatTitle(task.video),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13),
                    ),
                    SizedBox(height: 4),
                    Text(
                      '下载于 ${_formatTime(task.endTime)}',
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
              ),
              // 分享按钮（移除播放按钮，只保留分享）
              if (!_isCompletedSelectMode)
                IconButton(
                  icon: Icon(Icons.share, color: Colors.blue, size: 22),
                  onPressed: () => _shareVideo(task),
                  tooltip: '分享',
                  padding: EdgeInsets.only(left: 4),
                  constraints: BoxConstraints(minWidth: 36, minHeight: 36),
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

/// 视频播放器页面（支持亮度/音量手势控制）
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
  
  // 垂直手势：亮度/音量
  bool _isVerticalDragging = false;
  String _verticalDragType = ''; // 'brightness' 或 'volume'
  double _verticalDragStartY = 0;
  double _verticalDragStartValue = 0.5;
  double _currentBrightness = 0.5;
  double _currentVolume = 0.5;
  bool _showVerticalIndicator = false;
  double _savedBrightness = 0.5; // 用于恢复原始亮度
  
  @override
  void initState() {
    super.initState();
    // 初始化音量监听
    VolumeController().listener((volume) {
      if (mounted) {
        setState(() => _currentVolume = volume);
      }
    });
    _currentVolume = VolumeController().value;
    _initializePlayer();
  }
  
  Future<void> _initializePlayer() async {
    try {
      // 使用文件路径初始化 VideoPlayerController
      _videoPlayerController = VideoPlayerController.file(File(widget.filePath));
      
      await _videoPlayerController.initialize();
      
      // 保存并初始化当前屏幕亮度
      try {
        _savedBrightness = await ScreenBrightness().current;
        _currentBrightness = _savedBrightness;
      } catch (_) {}
      
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
    // 恢复屏幕亮度
    try {
      ScreenBrightness().resetScreenBrightness();
    } catch (_) {}
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
      // ─── 水平拖拽：快进/快退 ───
      onHorizontalDragStart: (details) {
        if (!_videoPlayerController.value.isInitialized) return;
        setState(() {
          _isDragging = true;
          _dragStartX = details.globalPosition.dx;
          _dragStartPosition = _videoPlayerController.value.position;
          _seekPosition = _dragStartPosition;
          _showSeekIndicator = true;
        });
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
        _seekPosition = Duration(
          milliseconds: newPosition.inMilliseconds.clamp(0, totalDuration.inMilliseconds),
        );
        
        setState(() {});
      },
      onHorizontalDragEnd: (details) {
        if (!_isDragging) return;
        
        _videoPlayerController.seekTo(_seekPosition);
        
        setState(() {
          _isDragging = false;
          _showSeekIndicator = false;
        });
        
        _videoPlayerController.play();
      },
      // ─── 垂直拖拽：左侧调亮度，右侧调音量 ───
      onVerticalDragStart: (details) {
        if (!_videoPlayerController.value.isInitialized) return;
        final screenWidth = MediaQuery.of(context).size.width;
        final isLeftSide = details.globalPosition.dx < screenWidth / 2;
        
        setState(() {
          _isVerticalDragging = true;
          _verticalDragStartY = details.globalPosition.dy;
          _verticalDragType = isLeftSide ? 'brightness' : 'volume';
          _verticalDragStartValue = isLeftSide ? _currentBrightness : _currentVolume;
          _showVerticalIndicator = true;
        });
      },
      onVerticalDragUpdate: (details) {
        if (!_isVerticalDragging) return;
        
        final screenHeight = MediaQuery.of(context).size.height;
        final dy = details.globalPosition.dy - _verticalDragStartY;
        
        // 向下滑动 dy 为正 → 减小值（变暗/变小声）
        // 向上滑动 dy 为负 → 增大值（变亮/变大声）
        final change = -dy / screenHeight; // 归一化到 0~1
        var newValue = (_verticalDragStartValue + change).clamp(0.0, 1.0);
        
        setState(() {
          if (_verticalDragType == 'brightness') {
            _currentBrightness = newValue;
            try {
              ScreenBrightness().setScreenBrightness(newValue);
            } catch (_) {}
          } else {
            _currentVolume = newValue;
            VolumeController().setVolume(newValue, showSystemUI: false);
          }
        });
      },
      onVerticalDragEnd: (details) {
        if (!_isVerticalDragging) return;
        setState(() {
          _isVerticalDragging = false;
          _showVerticalIndicator = false;
        });
      },
      child: Stack(
        children: [
          Center(
            child: Chewie(controller: _chewieController!),
          ),
          // 水平进度指示器
          if (_showSeekIndicator)
            Center(
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _seekPosition < _dragStartPosition 
                        ? Icons.replay_10 
                        : Icons.forward_10,
                      color: Colors.white,
                    ),
                    SizedBox(width: 8),
                    Text(
                      '${_formatDuration(_seekPosition)} / ${_formatDuration(_videoPlayerController.value.duration)}',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // 亮度/音量指示器（左侧或右侧垂直显示）
          if (_showVerticalIndicator)
            Positioned(
              top: 80,
              left: _verticalDragType == 'brightness' ? 24 : null,
              right: _verticalDragType == 'volume' ? 24 : null,
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _verticalDragType == 'brightness'
                        ? (_currentBrightness > 0.5 ? Icons.brightness_high : Icons.brightness_low)
                        : (_currentVolume > 0.5 ? Icons.volume_up : Icons.volume_down),
                      color: Colors.white,
                      size: 28,
                    ),
                    SizedBox(height: 12),
                    SizedBox(
                      width: 120,
                      height: 4,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: _verticalDragType == 'brightness' ? _currentBrightness : _currentVolume,
                          backgroundColor: Colors.white24,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      '${(_verticalDragType == 'brightness' ? _currentBrightness : _currentVolume * 100).round()}%',
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ],
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
