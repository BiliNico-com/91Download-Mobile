import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:share_plus/share_plus.dart';
import 'package:open_filex/open_filex.dart';
import 'package:volume_controller/volume_controller.dart';
import 'dart:async';
import 'dart:io';
import '../services/app_state.dart';
import '../services/download_manager.dart';
import '../services/brightness_service.dart';
import '../services/pip_service.dart';
import '../services/floating_video_service.dart';
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
    bool deleteFile = true;  // ✅ 默认勾选删除文件
    
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
      final shouldDeleteFile = result['deleteFile'] ?? true;
      final idsToDelete = _selectedIds.toList();
      
      for (final id in idsToDelete) {
        final task = appState.downloadManager.getTask(id);
        
        // 删除本地文件
        if (shouldDeleteFile && task?.filePath != null && task!.filePath!.isNotEmpty) {
          try {
            final file = File(task.filePath!);
            if (await file.exists()) {
              await file.delete();
              print('已删除文件: ${task.filePath}');
            }
          } catch (e) {
            print('删除文件失败: $e');
          }
        }
        
        // 删除历史记录
        if (appState.crawler != null) {
          try {
            await appState.crawler!.deleteDownloadHistory(id);
          } catch (e) {
            print('删除历史记录失败: $e');
          }
        }
        
        // 删除任务
        appState.downloadManager.cancelTask(id);
      }
      
      setState(() {
        _selectedIds.clear();
        _isCompletedSelectMode = false;
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

/// 视频播放器页面（支持手势控制、自定义控件、长按快进快退、PiP）
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

class _VideoPlayerPageState extends State<VideoPlayerPage> with WidgetsBindingObserver {
  late VideoPlayerController _videoPlayerController;
  ChewieController? _chewieController;
  bool _isInitialized = false;
  bool _hasError = false;
  String _errorMessage = '';
  
  // ====== 控件显示控制 ======
  bool _showControls = true;
  bool _showPlayPauseIcon = false;
  bool _isPlayingState = false;
  
  // ====== 水平手势（进度控制） ======
  bool _isHorizontalDragging = false;
  double _dragStartX = 0;
  double _dragStartY = 0;
  Duration _dragStartPosition = Duration.zero;
  Duration _seekPosition = Duration.zero;
  bool _showSeekIndicator = false;
  
  // ====== 垂直手势（亮度/音量） ======
  bool _isVerticalDragging = false;
  String _verticalDragType = '';
  double _verticalDragStartY = 0;
  double _verticalDragStartValue = 0.5;
  double _currentBrightness = 0.5;
  double _currentVolume = 0.5;
  bool _showVerticalIndicator = false;
  double _savedBrightness = 0.5;
  
  // ====== 长按倍速播放 ======
  bool _isLongPressing = false;
  String _longPressSide = '';
  bool _showLongPressIndicator = false;
  
  // ====== PiP ======
  bool _isPipAvailable = false;
  bool _isInPipMode = false;
  
  // ====== 悬浮窗 ======
  bool _isFloatingAvailable = false;
  bool _isInFloatingMode = false;
  
  Timer? _hideControlsTimer;
  
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    VolumeController().listener((volume) {
      if (mounted) setState(() => _currentVolume = volume);
    });
    VolumeController().getVolume().then((volume) {
      if (mounted) setState(() => _currentVolume = volume);
    });
    _checkPipAvailability();
    _checkFloatingAvailability();
    _initializePlayer();
  }
  
  Future<void> _checkPipAvailability() async {
    try {
      final available = await PipService.isAvailable();
      if (mounted) setState(() => _isPipAvailable = available);
    } catch (e) {}
  }
  
  Future<void> _checkFloatingAvailability() async {
    try {
      final available = await FloatingVideoService.isPermissionGranted();
      if (mounted) setState(() => _isFloatingAvailable = available);
    } catch (e) {
      if (mounted) setState(() => _isFloatingAvailable = false);
    }
  }
  
  Future<void> _enterFloatingMode() async {
    if (!_isFloatingAvailable) {
      // 请求权限
      final granted = await FloatingVideoService.requestPermission();
      if (!granted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('需要悬浮窗权限才能使用此功能'),
              action: SnackBarAction(
                label: '去设置',
                onPressed: () => FloatingVideoService.openSettings(),
              ),
            ),
          );
        }
        return;
      }
      if (mounted) setState(() => _isFloatingAvailable = true);
    }
    
    // 启动悬浮窗
    final success = await FloatingVideoService.startFloating(
      videoPath: widget.filePath,
      title: widget.title,
    );
    
    if (mounted) {
      setState(() => _isInFloatingMode = success);
      if (success) {
        // 返回上一页，但保持悬浮窗播放
        Navigator.pop(context);
      }
    }
  }
  
  Future<void> _exitFloatingMode() async {
    await FloatingVideoService.stopFloating();
    if (mounted) setState(() => _isInFloatingMode = false);
  }
  
  Future<void> _initializePlayer() async {
    try {
      _videoPlayerController = VideoPlayerController.file(File(widget.filePath));
      await _videoPlayerController.initialize();
      
      try {
        _savedBrightness = await BrightnessService.getBrightness();
        _currentBrightness = _savedBrightness;
        await BrightnessService.saveBrightness();
      } catch (_) {}
      
      _chewieController = ChewieController(
        videoPlayerController: _videoPlayerController,
        autoPlay: true,
        looping: false,
        aspectRatio: _videoPlayerController.value.aspectRatio,
        showControls: false,
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
          child: Center(child: CircularProgressIndicator(color: Colors.white)),
        ),
      );
      
      if (mounted) {
        setState(() => _isInitialized = true);
        _startHideControlsTimer();
      }
    } catch (e) {
      if (mounted) setState(() { _hasError = true; _errorMessage = e.toString(); });
    }
  }
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // 不在悬浮窗模式下才处理 PiP
    if (!_isInFloatingMode && state == AppLifecycleState.paused && _isPipAvailable && !_isInPipMode && _isInitialized) {
      _enterPipMode();
    }
  }
  
  Future<void> _enterPipMode() async {
    if (!_isPipAvailable) return;
    final aspectRatio = _videoPlayerController.value.aspectRatio ?? 16/9;
    final success = await PipService.enterPipMode(aspectRatio: aspectRatio);
    if (mounted) setState(() => _isInPipMode = success);
  }
  
  void _startHideControlsTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(Duration(seconds: 3), () {
      if (mounted && !_isHorizontalDragging && !_isVerticalDragging && !_isLongPressing) {
        setState(() => _showControls = false);
      }
    });
  }
  
  void _showControlsTemporarily() {
    setState(() => _showControls = true);
    _startHideControlsTimer();
  }
  
  void _togglePlayPause() {
    if (_videoPlayerController.value.isPlaying) {
      _videoPlayerController.pause();
      _isPlayingState = false;
    } else {
      _videoPlayerController.play();
      _isPlayingState = true;
    }
    setState(() => _showPlayPauseIcon = true);
    Future.delayed(Duration(milliseconds: 800), () {
      if (mounted) setState(() => _showPlayPauseIcon = false);
    });
    _showControlsTemporarily();
  }
  
  void _seekTo(Duration position) {
    final duration = _videoPlayerController.value.duration;
    _videoPlayerController.seekTo(Duration(
      milliseconds: position.inMilliseconds.clamp(0, duration.inMilliseconds),
    ));
  }
  
  void _onHorizontalSeekStart(double globalX) {
    if (!_videoPlayerController.value.isInitialized) return;
    setState(() {
      _isHorizontalDragging = true;
      _dragStartX = globalX;
      _dragStartPosition = _videoPlayerController.value.position;
      _seekPosition = _dragStartPosition;
      _showSeekIndicator = true;
      _showControls = true;
    });
    _hideControlsTimer?.cancel();
    if (_videoPlayerController.value.isPlaying) _videoPlayerController.pause();
  }
  
  void _onHorizontalSeekUpdate(double globalX) {
    if (!_isHorizontalDragging) return;
    final screenWidth = MediaQuery.of(context).size.width;
    final dx = globalX - _dragStartX;
    final totalDuration = _videoPlayerController.value.duration;
    final seekRatio = dx / (screenWidth / 2);
    final seekSeconds = (seekRatio * 10).round();
    final newPosition = _dragStartPosition + Duration(seconds: seekSeconds);
    _seekPosition = Duration(
      milliseconds: newPosition.inMilliseconds.clamp(0, totalDuration.inMilliseconds),
    );
    setState(() {});
  }
  
  void _onHorizontalSeekEnd() {
    if (!_isHorizontalDragging) return;
    _seekTo(_seekPosition);
    setState(() { _isHorizontalDragging = false; _showSeekIndicator = false; });
    _videoPlayerController.play();
    _startHideControlsTimer();
  }
  
  void _onVerticalDragStart(double globalX, double globalY) {
    if (!_videoPlayerController.value.isInitialized) return;
    final screenWidth = MediaQuery.of(context).size.width;
    final isLeftSide = globalX < screenWidth / 2;
    setState(() {
      _isVerticalDragging = true;
      _verticalDragStartY = globalY;
      _verticalDragType = isLeftSide ? 'brightness' : 'volume';
      _verticalDragStartValue = isLeftSide ? _currentBrightness : _currentVolume;
      _showVerticalIndicator = true;
      _showControls = true;
    });
    _hideControlsTimer?.cancel();
  }
  
  void _onVerticalDragUpdate(double globalY) {
    if (!_isVerticalDragging) return;
    final screenHeight = MediaQuery.of(context).size.height;
    final dy = globalY - _verticalDragStartY;
    final change = -dy / screenHeight;
    var newValue = (_verticalDragStartValue + change).clamp(0.0, 1.0);
    setState(() {
      if (_verticalDragType == 'brightness') {
        _currentBrightness = newValue;
        try { BrightnessService.setBrightness(newValue); } catch (_) {}
      } else {
        _currentVolume = newValue;
        VolumeController().setVolume(newValue, showSystemUI: false);
      }
    });
  }
  
  void _onVerticalDragEnd() {
    if (!_isVerticalDragging) return;
    setState(() { _isVerticalDragging = false; _showVerticalIndicator = false; });
    _startHideControlsTimer();
  }
  
  void _onLongPressStart(double globalX) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isLeftSide = globalX < screenWidth / 2;
    setState(() {
      _isLongPressing = true;
      _longPressSide = isLeftSide ? 'left' : 'right';
      _showLongPressIndicator = true;
      _showControls = false;
    });
    // 设置倍速播放
    _videoPlayerController.setPlaybackSpeed(isLeftSide ? 0.5 : 2.0);
    if (!_videoPlayerController.value.isPlaying) {
      _videoPlayerController.play();
    }
  }
  
  void _onLongPressEnd() {
    if (_isLongPressing) {
      // 恢复正常速度
      _videoPlayerController.setPlaybackSpeed(1.0);
      setState(() { 
        _isLongPressing = false; 
        _showLongPressIndicator = false; 
      });
      _showControlsTemporarily();
    }
  }
  
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideControlsTimer?.cancel();
    try { BrightnessService.restoreBrightness(); } catch (_) {}
    _videoPlayerController.dispose();
    _chewieController?.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: _buildVideoBody()),
            if (_showControls && !_isInPipMode && !_isInFloatingMode) _buildControlsOverlay(),
            if (_showPlayPauseIcon) _buildPlayPauseIndicator(),
          ],
        ),
      ),
    );
  }
  
  Widget _buildVideoBody() {
    if (_hasError) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, color: Colors.red, size: 64),
            SizedBox(height: 16),
            Text('视频加载失败', style: TextStyle(color: Colors.white, fontSize: 18)),
            SizedBox(height: 8),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text(_errorMessage, style: TextStyle(color: Colors.grey, fontSize: 12), textAlign: TextAlign.center),
            ),
            SizedBox(height: 24),
            ElevatedButton(
              onPressed: () {
                setState(() { _hasError = false; _errorMessage = ''; });
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
            Text('加载中...', style: TextStyle(color: Colors.white)),
          ],
        ),
      );
    }
    
    return GestureDetector(
      onTap: _togglePlayPause,
      onLongPressStart: (details) => _onLongPressStart(details.globalPosition.dx),
      onLongPressEnd: (_) => _onLongPressEnd(),
      child: Listener(
        onPointerDown: (event) {
          _dragStartX = event.position.dx;
          _dragStartY = event.position.dy;
        },
        onPointerMove: (event) {
          final dx = (event.position.dx - _dragStartX).abs();
          final dy = (event.position.dy - _dragStartY).abs();
          
          if (!_isVerticalDragging && !_isLongPressing && !_isHorizontalDragging) {
            if (dx > 10 && dx > dy) {
              _onHorizontalSeekStart(_dragStartX);
            } else if (dy > 10 && dy > dx) {
              _onVerticalDragStart(_dragStartX, _dragStartY);
            }
          } else if (_isHorizontalDragging) {
            _onHorizontalSeekUpdate(event.position.dx);
          } else if (_isVerticalDragging) {
            _onVerticalDragUpdate(event.position.dy);
          }
        },
        onPointerUp: (_) {
          if (_isHorizontalDragging) _onHorizontalSeekEnd();
          else if (_isVerticalDragging) _onVerticalDragEnd();
        },
        onPointerCancel: (_) {
          if (_isHorizontalDragging) _onHorizontalSeekEnd();
          else if (_isVerticalDragging) _onVerticalDragEnd();
        },
        child: Stack(
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: _videoPlayerController.value.aspectRatio ?? 16/9,
                child: VideoPlayer(_videoPlayerController),
              ),
            ),
            if (_showSeekIndicator) _buildSeekIndicator(),
            if (_showVerticalIndicator) _buildVerticalIndicator(),
            if (_showLongPressIndicator) _buildLongPressIndicator(),
          ],
        ),
      ),
    );
  }
  
  Widget _buildControlsOverlay() {
    return Column(
      children: [
        // 顶部工具栏
        Container(
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black54, Colors.transparent],
            ),
          ),
          child: Row(
            children: [
              IconButton(icon: Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.pop(context)),
              Expanded(
                child: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.white, fontSize: 16)),
              ),
              if (_isPipAvailable)
                IconButton(icon: Icon(Icons.picture_in_picture_alt, color: Colors.white),
                    onPressed: _enterPipMode, tooltip: '小窗播放'),
              IconButton(icon: Icon(Icons.picture_in_picture, color: Colors.white),
                  onPressed: _enterFloatingMode, tooltip: '悬浮窗播放'),
            ],
          ),
        ),
        Spacer(),
        // 底部进度条和控件
        Container(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Colors.black54, Colors.transparent],
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildProgressBar(),
              SizedBox(height: 8),
              Row(
                children: [
                  IconButton(icon: Icon(_videoPlayerController.value.isPlaying ? Icons.pause : Icons.play_arrow,
                      color: Colors.white, size: 32), onPressed: _togglePlayPause),
                  IconButton(icon: Icon(Icons.replay_5, color: Colors.white, size: 28), onPressed: () {
                    final pos = _videoPlayerController.value.position;
                    _seekTo(Duration(milliseconds: pos.inMilliseconds - 5000));
                  }),
                  IconButton(icon: Icon(Icons.forward_5, color: Colors.white, size: 28), onPressed: () {
                    final pos = _videoPlayerController.value.position;
                    _seekTo(Duration(milliseconds: pos.inMilliseconds + 5000));
                  }),
                  Spacer(),
                  ValueListenableBuilder<VideoPlayerValue>(
                    valueListenable: _videoPlayerController,
                    builder: (context, value, child) {
                      return Text(
                        '${_formatDuration(value.position)} / ${_formatDuration(value.duration)}',
                        style: TextStyle(color: Colors.white70, fontSize: 12),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
  
  Widget _buildProgressBar() {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: _videoPlayerController,
      builder: (context, value, child) {
        final progress = value.duration.inMilliseconds > 0
            ? value.position.inMilliseconds / value.duration.inMilliseconds : 0.0;
        return LayoutBuilder(
          builder: (context, constraints) {
            final barWidth = constraints.maxWidth;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) {
                final tapX = details.localPosition.dx;
                final newProgress = (tapX / barWidth).clamp(0.0, 1.0);
                _seekTo(Duration(milliseconds: (newProgress * value.duration.inMilliseconds).round()));
              },
              onHorizontalDragUpdate: (details) {
                final dragX = details.localPosition.dx;
                final newProgress = (dragX / barWidth).clamp(0.0, 1.0);
                _seekTo(Duration(milliseconds: (newProgress * value.duration.inMilliseconds).round()));
              },
              child: Container(
                height: 24,
                alignment: Alignment.center,
                child: Stack(
                  children: [
                    Container(height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
                    FractionallySizedBox(
                      widthFactor: progress.clamp(0.0, 1.0),
                      child: Container(height: 4, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(2))),
                    ),
                    Positioned(
                      left: barWidth * progress.clamp(0.0, 1.0) - 6,
                      child: Container(width: 12, height: 12, decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle)),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
  
  Widget _buildPlayPauseIndicator() {
    return Center(
      child: Container(
        padding: EdgeInsets.all(24),
        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(16)),
        child: Icon(_isPlayingState ? Icons.play_arrow : Icons.pause, color: Colors.white, size: 64),
      ),
    );
  }
  
  Widget _buildSeekIndicator() {
    final isFastForward = _seekPosition > _dragStartPosition;
    return Center(
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(isFastForward ? Icons.fast_forward : Icons.fast_rewind, color: Colors.white),
            SizedBox(width: 12),
            Text(_formatDuration(_seekPosition), style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            Text(' / ${_formatDuration(_videoPlayerController.value.duration)}', style: TextStyle(color: Colors.white70, fontSize: 14)),
          ],
        ),
      ),
    );
  }
  
  Widget _buildVerticalIndicator() {
    final value = _verticalDragType == 'brightness' ? _currentBrightness : _currentVolume;
    final icon = _verticalDragType == 'brightness'
        ? (_currentBrightness > 0.5 ? Icons.brightness_high : Icons.brightness_low)
        : (_currentVolume > 0.5 ? Icons.volume_up : Icons.volume_down);
    return Positioned(
      top: 100,
      left: _verticalDragType == 'brightness' ? 24 : null,
      right: _verticalDragType == 'volume' ? 24 : null,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 32),
            SizedBox(height: 16),
            SizedBox(
              width: 4,
              height: 80,
              child: Container(
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                child: FractionallySizedBox(
                  alignment: Alignment.bottomCenter,
                  heightFactor: value,
                  child: Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(2))),
                ),
              ),
            ),
            SizedBox(height: 12),
            Text('${(value * 100).round()}%', style: TextStyle(color: Colors.white, fontSize: 14)),
          ],
        ),
      ),
    );
  }
  
  Widget _buildLongPressIndicator() {
    final isSlowMotion = _longPressSide == 'left';
    return Center(
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 32, vertical: 20),
        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(isSlowMotion ? Icons.slow_motion_video : Icons.fast_forward, color: Colors.white, size: 48),
            SizedBox(height: 8),
            Text(
              isSlowMotion ? '0.5x 慢速' : '2.0x 快速',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }
  
  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

