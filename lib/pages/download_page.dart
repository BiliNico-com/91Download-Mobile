import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:share_plus/share_plus.dart';
import 'package:open_filex/open_filex.dart';
import 'package:volume_controller/volume_controller.dart';
import 'dart:async';
import 'dart:io';
import '../services/app_state.dart';
import '../services/download_manager.dart';
import '../services/brightness_service.dart';
import '../components/empty_state.dart';
import '../components/cover_image.dart';
import '../components/player_glass.dart';
import '../services/pip_service.dart';
import '../services/floating_video_service.dart';
import '../models/video_info.dart' show VideoInfo;
import '../utils/logger.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

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
    await Future.delayed(const Duration(milliseconds: 300));
  }
  
  Widget _buildDownloadingTab() {
    return Consumer<AppState>(
      builder: (context, appState, _) {
        final tasks = appState.downloadManager.downloadingTasks;
        
        if (tasks.isEmpty) {
          return EmptyState(
            icon: Icons.download_outlined,
            title: '暂无下载任务',
            subtitle: '在搜索页面选择视频后点击下载',
          );
        }
        
        return Column(
          children: [
            // 全选操作栏
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () {
                      setState(() {
                        // 本标签页中的任务全部可选（含失败待重试的）
                        final ids = tasks.map((t) => t.id).toSet();
                        if (_selectedIds.length == ids.length) {
                          _selectedIds.clear();
                        } else {
                          _selectedIds = ids;
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
            // 任务列表（进行中在前，失败项单独分组沉底）
            Expanded(
              child: RefreshIndicator(
                onRefresh: _onRefresh,
                child: Builder(
                  builder: (context) {
                    // 拆成两段，便于在失败组前插入分组标题
                    final active =
                        tasks.where((t) => t.status != DownloadStatus.failed).toList();
                    final failed =
                        tasks.where((t) => t.status == DownloadStatus.failed).toList();

                    // 行数 = 进行中 + (失败组标题 + 失败项)
                    final rowCount =
                        active.length + (failed.isEmpty ? 0 : failed.length + 1);

                    return ListView.builder(
                      itemCount: rowCount,
                      itemBuilder: (context, index) {
                        if (index < active.length) {
                          final task = active[index];
                          return _buildSlidableDownloadItem(
                              task, _selectedIds.contains(task.id), appState);
                        }

                        // 失败组
                        final fi = index - active.length;
                        if (fi == 0) {
                          return _buildFailedGroupHeader(failed.length);
                        }
                        final task = failed[fi - 1];
                        return _buildSlidableDownloadItem(
                            task, _selectedIds.contains(task.id), appState);
                      },
                    );
                  },
                ),
              ),
            ),
            // 底部批量操作栏（与搜索页一致）
            if (_selectedIds.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(16),
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
        // 只展示真正下载完成的任务；失败项归"下载中"标签页（可重试）
        final tasks = appState.downloadManager.completedTasks;
        
        if (tasks.isEmpty) {
          return EmptyState(
            icon: Icons.folder_outlined,
            title: '暂无下载记录',
            subtitle: '已完成的下载会显示在这里',
          );
        }
        
        return RefreshIndicator(
          onRefresh: _onRefresh,
          child: Column(
            children: [
              // 全选/删除操作栏
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                        onPressed: () async {
                          await _deleteSelectedWithConfirm(appState);
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
                padding: const EdgeInsets.all(16),
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
  Future<void> _deleteSelectedWithConfirm(AppState appState) async {
    final count = _selectedIds.length;
    bool deleteFile = true;  // 默认勾选删除文件
    
    final result = await showDialog<Map<String, bool>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
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
            onPressed: () => Navigator.pop(dialogContext),
            child: Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext, {'deleteFile': deleteFile});
            },
            child: Text('确定', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    
    if (result != null && result['deleteFile'] != null) {
      final shouldDeleteFile = result['deleteFile']!;
      final idsToDelete = _selectedIds.toList();
      int deletedCount = 0;
      
      print('准备删除 ${idsToDelete.length} 个任务');
      print('待删除的 ID 列表: $idsToDelete');
      
      for (final id in idsToDelete) {
        print('正在处理任务 ID: $id');
        final task = appState.downloadManager.getTask(id);
        print('getTask 返回: ${task != null ? "存在" : "不存在"}');
        
        // 删除本地文件
        if (shouldDeleteFile) {
          // 优先从任务获取 filePath，否则从历史数据库获取
          String? filePath = task?.filePath;
          if (filePath == null && appState.crawler != null) {
            try {
              final history = await appState.crawler!.getDownloadHistory(limit: 1000);
              final record = history.firstWhere((h) => h['video_id'] == id, orElse: () => <String, dynamic>{});
              filePath = record['file_path'] as String?;
              print('从历史记录获取文件路径: $filePath');
            } catch (e) {
              print('获取历史记录失败: $e');
            }
          }
          
          if (filePath != null && filePath.isNotEmpty) {
            try {
              final file = File(filePath);
              if (await file.exists()) {
                await file.delete();
                print('已删除文件: $filePath');
              }
            } catch (e) {
              print('删除文件失败: $e');
            }
          }
        }
        
        // 从 download_history.db 删除历史记录
        if (appState.crawler != null) {
          try {
            await appState.crawler!.deleteDownloadHistory(id);
            print('已从 download_history.db 删除: $id');
          } catch (e) {
            print('删除历史记录失败: $e');
          }
        }
        
        // 从 download_tasks.db 删除任务，并一并清理临时目录
        // 注意：文件已在上面按需删除，这里补删可能残留的 *_temp 目录
        await appState.downloadManager.cancelTask(id);
        print('cancelTask 已完成');
        deletedCount++;
      }
      
      // 清空选择状态并刷新 UI
      setState(() {
        _selectedIds.clear();
        _isCompletedSelectMode = false;
      });
      
      // 显示删除成功提示
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已删除 $deletedCount 个记录')),
        );
      }
    }
  }
  
  void _retryDownload(DownloadTask task, AppState appState) async {
    try {
      // 重置任务状态为 pending 并重新添加到队列
      await appState.downloadManager.retryTask(task.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已开始重试下载')),
      );
    } catch (e) {
      // 异常路径同样可能发生在页面销毁之后
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('重试失败: $e')),
      );
    }
  }

  Widget _buildDownloadTaskItem(DownloadTask task, bool selected, AppState appState) {
    final isFailed = task.status == DownloadStatus.failed;

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
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        // 失败项给一层淡红底 + 左侧红条，滑动列表时也能一眼认出
        color: selected
            ? Colors.blue.withOpacity(0.1)
            : (isFailed ? Colors.red.withOpacity(0.06) : null),
        shape: isFailed && !selected
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: Colors.red, width: 1),
              )
            : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // 封面 + 选中标记
                  Stack(
                    children: [
                      // 封面走磁盘缓存，避免每次进入下载页重新下载
                      CoverImage(
                        url: task.video.cover,
                        width: 80,
                        height: 60,
                        borderRadius: BorderRadius.circular(4),
                        fallbackIconSize: 20,
                      ),
                      // 选中标记（左上角）
                      if (selected)
                        Positioned(
                          top: 2,
                          left: 2,
                          child: Container(
                            padding: const EdgeInsets.all(2),
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
                  // 仅显示切片进度（如「下载中 13/120」）
                  Text(
                    task.progressText.isNotEmpty
                        ? task.progressText
                        : '${(task.progress * 100).toStringAsFixed(0)}%',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  // 速度只在此处展示一次，避免与上方文本重复
                  if (task.speedText.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
  
  /// 失败任务分组标题
  ///
  /// 失败项与进行中的任务同处"下载中"标签页，用一条带颜色的小标题区分，
  /// 避免混在一起看不清哪些需要重试。
  Widget _buildFailedGroupHeader(int count) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.red.withOpacity(0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 16, color: Colors.red),
          const SizedBox(width: 6),
          Text(
            '下载失败 ($count)',
            style: const TextStyle(
              fontSize: 12,
              color: Colors.red,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          const Text(
            '可重试或删除',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
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
    if (!_isCompletedSelectMode) {
      return Dismissible(
        key: ValueKey('completed_${task.id}'),
        direction: DismissDirection.endToStart,
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          color: Colors.red,
          child: const Icon(Icons.delete, color: Colors.white),
        ),
        confirmDismiss: (_) async {
          return await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('确认删除'),
              content: Text(task.status == DownloadStatus.failed
                  ? '确定要删除这个失败的下载任务吗？'
                  : '确定要删除已下载的视频吗？'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除', style: TextStyle(color: Colors.red))),
              ],
            ),
          );
        },
        onDismissed: (_) => _deleteTaskWithConfirm(task, appState),
        child: GestureDetector(
          onLongPress: () {
            setState(() {
              _isCompletedSelectMode = true;
              _selectedIds.add(task.id);
            });
          },
          onTap: task.status == DownloadStatus.failed
            ? () {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('下载失败：${task.error ?? '未知错误'}'),
                    duration: const Duration(seconds: 3),
                    action: SnackBarAction(
                      label: '重试',
                      onPressed: () => _retryDownload(task, appState),
                    ),
                  ),
                );
              }
            : () => _playVideo(task, appState),
          child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        color: selected ? Colors.blue.withOpacity(0.1) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
                  // 预览图（磁盘缓存 + 右下角时长 + 选中标记）
                  Stack(
                    children: [
                      CoverImage(
                        url: task.video.cover,
                        width: 96,
                        height: 64,
                        borderRadius: BorderRadius.circular(6),
                        fallbackIconSize: 24,
                      ),
                  // 时长标签（右下角）
                  if (task.video.duration != null && task.video.duration!.isNotEmpty)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
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
                        padding: const EdgeInsets.all(2),
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
                      '下载于 ${_formatTime(task.endTime ?? task.startTime)}',
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
                  padding: const EdgeInsets.only(left: 4),
                  constraints: BoxConstraints(minWidth: 36, minHeight: 36),
                ),
            ],
          ),
        ),
      ),
    ),
  );
    }
    // 选择模式：返回普通卡片（不允许滑动删除）
    return GestureDetector(
      onLongPress: () {
        setState(() {
          _isCompletedSelectMode = true;
          _selectedIds.add(task.id);
        });
      },
      onTap: () {
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
      },
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        color: selected ? Colors.blue.withOpacity(0.1) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Stack(
                children: [
                  CoverImage(
                    url: task.video.cover,
                    width: 96,
                    height: 64,
                    borderRadius: BorderRadius.circular(6),
                    fallbackIconSize: 24,
                  ),
                  if (task.video.duration != null && task.video.duration!.isNotEmpty)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
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
                  if (_isCompletedSelectMode)
                    Positioned(
                      top: 2,
                      left: 2,
                      child: Container(
                        padding: const EdgeInsets.all(2),
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
                      '下载于 ${_formatTime(task.endTime ?? task.startTime)}',
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  /// 构建下载中列表项（使用 Dismissible 滑动删除）
  Widget _buildSlidableDownloadItem(DownloadTask task, bool selected, AppState appState) {
    return Dismissible(
      key: Key('download_${task.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: Colors.red,
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (direction) async {
        return await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('确认删除'),
            content: Text('确定要删除下载任务"${task.video.title}"吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('删除', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        );
      },
      onDismissed: (_) => appState.downloadManager.cancelTask(task.id),
      child: _buildDownloadTaskItem(task, selected, appState),
    );
  }
  
  /// 播放视频
  void _playVideo(DownloadTask task, AppState appState) async {
    
    // 无条件关闭悬浮窗，避免状态不同步导致灰屏
    try {
      FloatingVideoService.stopFloating();  // 不等待异步结果
      await Future.delayed(const Duration(milliseconds: 150));  // 减少等待时间
    } catch (e) {
      debugPrint('[DownloadPage] 关闭悬浮窗时出错: $e');
    }
    
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
  
  /// 显示完整的年月日时分
  ///
  /// 旧实现只输出「时:分:秒」，看不出是哪天下的，
  /// 隔天再看得靠猜。这里给出完整日期时间，并对今天/昨天做友好化。
  String _formatTime(DateTime? time) {
    if (time == null) return '未知';

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(time.year, time.month, time.day);
    final hm = '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';

    final diffDays = today.difference(that).inDays;
    if (diffDays == 0) return '今天 $hm';
    if (diffDays == 1) return '昨天 $hm';

    final md = '${time.month.toString().padLeft(2, '0')}-'
        '${time.day.toString().padLeft(2, '0')}';
    // 跨年时补上年份，避免"同月同日不同年"无法分辨
    if (time.year != now.year) {
      return '${time.year}-$md $hm';
    }
    return '$md $hm';
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
  
  // ====== 长按倍速播放 ======
  bool _isLongPressing = false;
  String _longPressSide = '';
  bool _showLongPressIndicator = false;

  /// 用户选择的常驻播放倍速
  ///
  /// 长按临时变速后要恢复到它，而不是硬编码回到 1.0x
  /// （否则用户选过 1.5x，长按一次就被打回原速）。
  double _playbackSpeed = 1.0;
  
  // ====== PiP ======
  bool _isPipAvailable = false;
  bool _isInPipMode = false;
  
  // ====== 悬浮窗 ======
  bool _isFloatingAvailable = false;
  bool _isInFloatingMode = false;
  
  // ====== 控件锁定 ======
  bool _controlsLocked = false;
  
  Timer? _hideControlsTimer;
  Timer? _floatingCheckTimer;  // 悬浮窗状态检查定时器
  StreamSubscription? _overlaySubscription;
  
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
    _listenToOverlayMessages();
    _initializePlayer();
  }
  
  void _listenToOverlayMessages() {
    // 原生悬浮窗方案：不再需要 overlayListener
    // 悬浮窗关闭由原生 Service 内部处理，通过 isFloating 状态判断即可
    // 如果未来需要接收原生广播消息，可以使用 MethodChannel 的 EventChannel
  }
  
  Future<void> _checkPipAvailability() async {
    try {
      final available = await PipService.isAvailable();
      if (mounted) setState(() => _isPipAvailable = available);
    } catch (e) {}
  }
  
  Future<void> _checkFloatingAvailability() async {
    try {
      print('[FloatingMode] 检查悬浮窗权限...');
      logger.logSync('FloatingMode', '检查悬浮窗权限...');
      final available = await FloatingVideoService.isPermissionGranted();
      print('[FloatingMode] 悬浮窗权限状态: $available');
      logger.logSync('FloatingMode', '悬浮窗权限状态: $available');
      if (mounted) setState(() => _isFloatingAvailable = available);
    } catch (e) {
      print('[FloatingMode] 检查权限失败: $e');
      logger.logSync('FloatingMode', '检查权限失败: $e');
      if (mounted) setState(() => _isFloatingAvailable = false);
    }
  }
  
  Future<void> _enterFloatingMode() async {
    print('[FloatingMode] 开始进入悬浮模式');
    logger.logSync('FloatingMode', '开始进入悬浮模式');
    if (!_isFloatingAvailable) {
      print('[FloatingMode] 悬浮窗权限未授予，请求中...');
      logger.logSync('FloatingMode', '悬浮窗权限未授予，请求中...');
      // 请求权限
      final granted = await FloatingVideoService.requestPermission();
      print('[FloatingMode] 权限请求结果: $granted');
      logger.logSync('FloatingMode', '权限请求结果: $granted');
      if (!granted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('需要悬浮窗权限才能使用此功能，请在系统设置中授权'),
            ),
          );
        }
        return;
      }
      if (mounted) setState(() => _isFloatingAvailable = true);
    }
    
    print('[FloatingMode] 启动悬浮窗，文件: ${widget.filePath}');
    logger.logSync('FloatingMode', '启动悬浮窗，文件: ${widget.filePath}');
    // 记录当前进度并传给悬浮窗，让它接着播（否则会从头开始）
    final currentPosMs =
        _videoPlayerController?.value.position.inMilliseconds ?? 0;
    // 启动悬浮窗
    final success = await FloatingVideoService.startFloating(
      videoPath: widget.filePath,
      title: widget.title,
      initialPositionMs: currentPosMs,
    );
    
    print('[FloatingMode] 悬浮窗启动结果: $success');
    logger.logSync('FloatingMode', '悬浮窗启动结果: $success');
    
    if (mounted) {
      setState(() => _isInFloatingMode = success);
      if (success) {
        // 暂停当前播放，悬浮窗会继续播放
        _videoPlayerController?.pause();
        // 隐藏控件，显示悬浮窗播放中的提示
        _showControls = false;
        // 启动定时器检查悬浮窗状态
        _startFloatingCheckTimer();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('悬浮窗启动失败，请检查权限设置')),
        );
      }
    }
  }
  
  /// 启动悬浮窗状态检查定时器
  ///
  /// 必须查询**原生真实状态**（isActuallyRunning）。
  /// 早先这里判断的是 FloatingVideoService.isFloating —— 那是 Dart 本地标记，
  /// 只有 Dart 主动调用 stopFloating() 才会变 false；
  /// 用户在悬浮窗上双击/点 × 关闭时原生自行停止，本地标记永远是 true，
  /// 导致遮罩永不消失、进度也永远恢复不回来（这正是此前的故障原因）。
  void _startFloatingCheckTimer() {
    _floatingCheckTimer?.cancel();
    _floatingCheckTimer = Timer.periodic(const Duration(milliseconds: 250), (timer) async {
      // 防重入：上一次探测还没返回就跳过本次
      if (_checkingFloatingState) return;
      _checkingFloatingState = true;
      try {
        final running = await FloatingVideoService.isActuallyRunning();
        if (!running) {
          timer.cancel();
          if (mounted && _isInFloatingMode) {
            // 立即摘掉遮罩，再恢复进度/播放状态
            setState(() => _isInFloatingMode = false);
            debugPrint('[FloatingMode] 检测到原生悬浮窗已关闭，退出悬浮模式');
            await _resumeFromFloating();
          }
        }
      } finally {
        _checkingFloatingState = false;
      }
    });
  }

  /// 悬浮窗状态探测是否进行中（避免异步探测重叠）
  bool _checkingFloatingState = false;
  
  Future<void> _exitFloatingMode() async {
    _floatingCheckTimer?.cancel();
    await FloatingVideoService.stopFloating();
    if (mounted) setState(() => _isInFloatingMode = false);
    // 收起悬浮窗后接着原进度继续播放，避免"进度丢失 + 还要手点播放"
    await _resumeFromFloating();
  }
  
  /// 悬浮窗收起后，把内置播放器恢复到悬浮窗停下的位置
  ///
  /// 播放状态**跟随悬浮窗**：
  ///   - 悬浮窗关闭时在播放 → 内置播放器继续播
  ///   - 悬浮窗关闭时已暂停 → 只恢复进度，保持暂停
  ///
  /// 进度由原生侧在关闭悬浮窗时记录（见 FloatingWindowService.capturePlaybackPosition）。
  /// Flutter 侧有多条路径可能触发恢复（关闭按钮 / 定时器 / 生命周期回调），
  /// 这里用进行中标记避免并发重复 seek 造成跳动。
  bool _resumingFromFloating = false;

  Future<void> _resumeFromFloating() async {
    if (_resumingFromFloating) return;
    _resumingFromFloating = true;
    try {
      final controller = _videoPlayerController;
      if (controller == null || !controller.value.isInitialized) return;

      final posMs = await FloatingVideoService.getFloatingLastPosition();
      final wasPlaying = await FloatingVideoService.wasFloatingPlaying();
      debugPrint('[FloatingMode] 悬浮窗进度=${posMs}ms, 当时在播放=$wasPlaying');

      if (posMs > 0) {
        final duration = controller.value.duration;
        var target = Duration(milliseconds: posMs);
        // 越界保护：避免 seek 到视频末尾或超出时长
        if (target >= duration) {
          target = duration - const Duration(seconds: 1);
        }
        if (target < Duration.zero) target = Duration.zero;
        await controller.seekTo(target);
        debugPrint('[FloatingMode] 已恢复到 ${target.inSeconds}s');
      }

      // 跟随悬浮窗的播放状态，而不是无条件自动播放
      if (wasPlaying) {
        await controller.play();
        debugPrint('[FloatingMode] 悬浮窗当时在播放 → 继续播放');
      } else {
        await controller.pause();
        debugPrint('[FloatingMode] 悬浮窗当时已暂停 → 保持暂停');
      }

      if (mounted) {
        setState(() {
          _showControls = false;
        });
        _startHideControlsTimer();
      }
    } catch (e) {
      debugPrint('[FloatingMode] 恢复播放失败: $e');
    } finally {
      _resumingFromFloating = false;
    }
  }
  
  Future<void> _initializePlayer() async {
    try {
      _videoPlayerController = VideoPlayerController.file(File(widget.filePath));
      await _videoPlayerController.initialize();
      
      try {
        _currentBrightness = await BrightnessService.getBrightness();
        await BrightnessService.saveBrightness();
      } catch (_) {}
      
      // 说明：此处曾创建 ChewieController，但控件为自绘（showControls 恒为 false），
      // 且画面由 VideoPlayer 直接渲染，该控制器不承担任何职责，已移除。
      _videoPlayerController.setLooping(false);
      
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
    
    // 从PiP模式恢复时重置状态并显示控件
    if (state == AppLifecycleState.resumed && _isInPipMode && !_isInFloatingMode) {
      setState(() {
        _isInPipMode = false;
        _showControls = true;
      });
      _startHideControlsTimer();
    }
    
    // 从悬浮窗模式恢复（优先处理悬浮窗，因为悬浮窗和 PiP 可能冲突）
    if (state == AppLifecycleState.resumed && _isInFloatingMode) {
      // 检查悬浮窗是否已关闭（必须问原生，本地标记不可靠）
      Future.delayed(const Duration(milliseconds: 200), () async {
        final running = await FloatingVideoService.isActuallyRunning();
        if (!running && mounted && _isInFloatingMode) {
          // 悬浮窗已关闭，恢复播放（含进度）
          setState(() {
            _isInFloatingMode = false;
            _isInPipMode = false;  // 同时清除 PiP 状态
            _showControls = false;
          });
          await _resumeFromFloating();
          _startHideControlsTimer();
        }
      });
    }
    
    // 仅在非悬浮窗模式下处理 PiP 进入（修复：避免同时触发两者导致冲突）
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
    // 控件锁定时不自动隐藏
    if (_controlsLocked) return;
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && !_isHorizontalDragging && !_isVerticalDragging && !_isLongPressing) {
        setState(() => _showControls = false);
      }
    });
  }
  
  void _toggleControlsLock() {
    setState(() {
      _controlsLocked = !_controlsLocked;
      if (_controlsLocked) {
        // 锁定时取消隐藏计时器，保持控件显示
        _hideControlsTimer?.cancel();
      } else {
        // 解锁时重新开始计时
        _startHideControlsTimer();
      }
    });
  }
  
  void _showControlsTemporarily() {
    setState(() => _showControls = true);
    _startHideControlsTimer();
  }

  /// 单击画面：显示 / 隐藏控件
  ///
  /// 控件锁定时不响应，避免误触把控件藏起来后无法操作。
  void _toggleControlsVisibility() {
    if (_controlsLocked) return;

    if (_showControls) {
      _hideControlsTimer?.cancel();
      setState(() => _showControls = false);
    } else {
      _showControlsTemporarily();
    }
  }

  /// 双击画面：播放 / 暂停
  void _togglePlayPause() {
    if (_videoPlayerController.value.isPlaying) {
      _videoPlayerController.pause();
      _isPlayingState = false;
    } else {
      _videoPlayerController.play();
      _isPlayingState = true;
    }
    // 双击后给出图标反馈（中央图标短暂显示）
    setState(() => _showPlayPauseIcon = true);
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _showPlayPauseIcon = false);
    });
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

    // 灵敏度自适应：整屏宽度对应「整个视频时长」，
    // 一次滑动即可覆盖全片；过短视频/超长视频用上下限兜住手感。
    //   旧实现固定「半屏 = 10 秒」，看长视频要滑很多次。
    final spanMs = totalDuration.inMilliseconds.clamp(20000, 3600000);
    final offsetMs = (dx / screenWidth * spanMs).round();

    final newPosition = _dragStartPosition + Duration(milliseconds: offsetMs);
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
        // 失败时由 BrightnessService 内部打印日志，不再静默吞掉
        BrightnessService.setBrightness(newValue);
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
    // 长按临时变速（松手后恢复用户选择的常驻倍速）
    _videoPlayerController.setPlaybackSpeed(isLeftSide ? 0.5 : 2.0);
    if (!_videoPlayerController.value.isPlaying) {
      _videoPlayerController.play();
    }
  }
  
  void _onLongPressEnd() {
    if (_isLongPressing) {
      // 恢复到用户选择的常驻倍速，而不是固定 1.0x
      _videoPlayerController.setPlaybackSpeed(_playbackSpeed);
      setState(() { 
        _isLongPressing = false; 
        _showLongPressIndicator = false; 
      });
      _showControlsTemporarily();
    }
  }

  /// 设置常驻播放倍速
  void _setPlaybackSpeed(double speed) {
    setState(() => _playbackSpeed = speed);
    // 长按进行中时不要立刻覆盖临时倍速
    if (!_isLongPressing) {
      _videoPlayerController.setPlaybackSpeed(speed);
    }
  }

  /// 弹出倍速选择面板
  void _showSpeedPicker() {
    _hideControlsTimer?.cancel();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text(
                  '播放速度',
                  style: TextStyle(color: Colors.white, fontSize: 15),
                ),
              ),
              const Divider(height: 1, color: Colors.white24),
              ...kPlayerSpeedOptions.map((speed) {
                final selected = (speed - _playbackSpeed).abs() < 0.001;
                return ListTile(
                  dense: true,
                  title: Text(
                    speed == 1.0 ? '正常 (1.0x)' : '${speed}x',
                    style: TextStyle(
                      color: selected ? Theme.of(context).colorScheme.primary : Colors.white,
                      fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  trailing: selected
                      ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary, size: 20)
                      : null,
                  onTap: () {
                    _setPlaybackSpeed(speed);
                    Navigator.of(sheetContext).pop();
                    _showControlsTemporarily();
                  },
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    ).then((_) {
      // 面板关闭后重新计时隐藏控件
      if (mounted) _startHideControlsTimer();
    });
  }
  
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideControlsTimer?.cancel();
    _floatingCheckTimer?.cancel();
    _overlaySubscription?.cancel();
    // volume_controller 是单例且只保留一个订阅：这里不解除，
    // 每次进出播放页都会泄漏一个 EventChannel 订阅 + 原生监听器
    VolumeController().removeListener();
    BrightnessService.restoreBrightness();
    _videoPlayerController.dispose();
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
            // 悬浮窗播放中提示
            if (_isInFloatingMode) _buildFloatingModeOverlay(),
          ],
        ),
      ),
    );
  }
  
  /// 悬浮窗播放中的提示层
  ///
  /// 早期用 Colors.black87 全屏盖住，视觉上像"多了一层遮罩"，
  /// 切换回来时那层黑幕延迟消失会很割裂。
  /// 现改为半透明 + 轻量提示，既能说明状态，又不至于糊住整个页面。
  Widget _buildFloatingModeOverlay() {
    return Container(
      color: Colors.black.withOpacity(0.55),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.picture_in_picture_alt,
                color: Colors.white70, size: 48),
            const SizedBox(height: 12),
            const Text(
              '正在悬浮窗中播放',
              style: TextStyle(color: Colors.white, fontSize: 15),
            ),
            const SizedBox(height: 6),
            const Text(
              '双击悬浮窗可返回',
              style: TextStyle(color: Colors.white60, fontSize: 12),
            ),
            const SizedBox(height: 16),
            // 保留一个显式的关闭入口，避免只能靠双击悬浮窗
            TextButton.icon(
              onPressed: _exitFloatingMode,
              icon: const Icon(Icons.close_fullscreen, size: 18),
              label: const Text('收回并继续播放'),
              style: TextButton.styleFrom(foregroundColor: Colors.white70),
            ),
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
              padding: const EdgeInsets.symmetric(horizontal: 32),
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
    
    if (!_isInitialized) {
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
      // 交互约定（对齐主流播放器）：
      //   单击 → 显示/隐藏控件
      //   双击 → 播放/暂停
      // 注意 onTap 与 onDoubleTap 同存时，Flutter 会自动延迟 onTap
      // 以等待双击判定，这是标准行为。
      onTap: _toggleControlsVisibility,
      onDoubleTap: _togglePlayPause,
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
        // 顶部工具栏（长方形玻璃底栏，与底部控件风格统一）
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: GlassSurface(
            borderRadius: const BorderRadius.all(Radius.circular(10)),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              children: [
                GlassIconButton(
                  icon: Icons.arrow_back,
                  onPressed: () => Navigator.pop(context),
                  size: 40,
                  tooltip: '返回',
                ),
                Expanded(
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 15),
                  ),
                ),
                if (_isPipAvailable)
                  GlassIconButton(
                    icon: Icons.picture_in_picture_alt,
                    onPressed: _enterPipMode,
                    size: 40,
                    tooltip: '画中画',
                  ),
                GlassIconButton(
                  icon: Icons.picture_in_picture,
                  onPressed: _enterFloatingMode,
                  size: 40,
                  tooltip: '悬浮窗播放',
                ),
              ],
            ),
          ),
        ),
        const Spacer(),
        // 底部进度条和控件（长方形玻璃底栏）
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: GlassSurface(
            borderRadius: const BorderRadius.all(Radius.circular(10)),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildProgressBar(),
                const SizedBox(height: 4),
                Row(
                  children: [
                    // 播放/暂停：主操作，用相对大的图标突出
                    IconButton(
                      icon: Icon(
                        _videoPlayerController.value.isPlaying
                            ? Icons.pause
                            : Icons.play_arrow,
                        color: Colors.white,
                        size: 30,
                      ),
                      onPressed: _togglePlayPause,
                      tooltip: _videoPlayerController.value.isPlaying ? '暂停' : '播放',
                    ),
                    IconButton(
                      icon: const Icon(Icons.replay_5, color: Colors.white, size: 24),
                      onPressed: () {
                        final pos = _videoPlayerController.value.position;
                        _seekTo(Duration(milliseconds: pos.inMilliseconds - 5000));
                      },
                      tooltip: '后退 5 秒',
                    ),
                    IconButton(
                      icon: const Icon(Icons.forward_5, color: Colors.white, size: 24),
                      onPressed: () {
                        final pos = _videoPlayerController.value.position;
                        _seekTo(Duration(milliseconds: pos.inMilliseconds + 5000));
                      },
                      tooltip: '前进 5 秒',
                    ),
                    // 锁定控件按钮
                    IconButton(
                      icon: Icon(_controlsLocked ? Icons.lock : Icons.lock_open,
                          color: _controlsLocked ? Colors.lightBlueAccent : Colors.white, size: 20),
                      onPressed: _toggleControlsLock,
                      tooltip: _controlsLocked ? '解锁控件' : '锁定控件',
                    ),
                    const Spacer(),
                    // 倍速：非常驻 1.0x 时高亮，便于一眼看出当前速度
                    TextButton(
                      onPressed: _showSpeedPicker,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 32),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        foregroundColor: _playbackSpeed == 1.0
                            ? Colors.white70
                            : Colors.lightBlueAccent,
                      ),
                      child: Text(
                        '${_playbackSpeed}x',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                    ValueListenableBuilder<VideoPlayerValue>(
                      valueListenable: _videoPlayerController,
                      builder: (context, value, child) {
                        return Text(
                          '${formatPlayerDuration(value.position)} / ${formatPlayerDuration(value.duration)}',
                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
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
                    // 轨道：半透明白，配合玻璃底座仍可辨识
                    Container(
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.28),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    // 已播放部分
                    FractionallySizedBox(
                      widthFactor: progress.clamp(0.0, 1.0),
                      child: Container(
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    // 拖拽圆点：带细描边，避免在亮画面上糊掉
                    Positioned(
                      left: barWidth * progress.clamp(0.0, 1.0) - 6,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.black26, width: 0.5),
                        ),
                      ),
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
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(16)),
        child: Icon(_isPlayingState ? Icons.play_arrow : Icons.pause, color: Colors.white, size: 64),
      ),
    );
  }
  
  Widget _buildSeekIndicator() {
    final isFastForward = _seekPosition > _dragStartPosition;
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
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
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
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

