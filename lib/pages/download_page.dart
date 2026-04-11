import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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
        
        return ListView.builder(
          itemCount: tasks.length,
          itemBuilder: (context, index) {
            final task = tasks[index];
            return _buildDownloadTaskItem(task, appState);
          },
        );
      },
    );
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
        
        return Column(
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
                    child: Text(_selectedIds.length == tasks.length ? '取消全选' : '全选'),
                  ),
                  Spacer(),
                  if (_selectedIds.isNotEmpty)
                    TextButton(
                      onPressed: () => _deleteSelected(appState),
                      child: Text('删除 (${_selectedIds.length})', style: TextStyle(color: Colors.red)),
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
                    child: OutlinedButton(
                      onPressed: () {
                        appState.downloadManager.clearCompleted();
                        setState(() {
                          _selectedIds.clear();
                        });
                      },
                      child: Text('清空记录'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
  
  Widget _buildDownloadTaskItem(DownloadTask task, AppState appState) {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Padding(
        padding: EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // 封面
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: task.video.cover != null
                    ? Image.network(task.video.cover!, width: 80, height: 60, fit: BoxFit.cover)
                    : Container(width: 80, height: 60, color: Colors.grey[300], child: Icon(Icons.video_file)),
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
              Text(
                task.progressText.isNotEmpty ? task.progressText : '${(task.progress * 100).toStringAsFixed(1)}%',
                style: TextStyle(fontSize: 11, color: Colors.grey),
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
    );
  }
  
  Widget _buildTaskControls(DownloadTask task, AppState appState) {
    switch (task.status) {
      case DownloadStatus.pending:
        return IconButton(
          icon: Icon(Icons.play_arrow, color: Colors.green),
          onPressed: () => appState.downloadManager.startTask(task.id),
          tooltip: '开始',
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
        return IconButton(
          icon: Icon(Icons.play_arrow, color: Colors.green),
          onPressed: () => appState.downloadManager.resumeTask(task.id),
          tooltip: '继续',
        );
      case DownloadStatus.failed:
        return IconButton(
          icon: Icon(Icons.refresh, color: Colors.blue),
          onPressed: () => appState.downloadManager.retryTask(task.id),
          tooltip: '重试',
        );
      default:
        return SizedBox.shrink();
    }
  }
  
  Widget _buildCompletedTaskItem(DownloadTask task, bool selected, AppState appState) {
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
      onLongPress: () {
        // 长按播放视频
        _playVideo(task);
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
              if (selected)
                Positioned(
                  right: 0,
                  bottom: 0,
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
            '下载于 ${_formatTime(task.endTime)}\n长按播放',
            style: TextStyle(fontSize: 12),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 播放按钮
              IconButton(
                icon: Icon(Icons.play_circle, color: Colors.green),
                onPressed: () => _playVideo(task),
                tooltip: '播放',
              ),
              selected 
                ? Icon(Icons.check_circle, color: Colors.blue)
                : Icon(Icons.check_circle_outline, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
  
  void _playVideo(DownloadTask task) async {
    await logger.i('Download', '播放视频: ${task.video.title}');
    
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
    
    // TODO: 使用视频播放器打开文件
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('播放功能开发中: ${task.filePath}')),
      );
    }
  }
  
  void _deleteSelected(AppState appState) async {
    await logger.i('Download', '删除选中的 ${_selectedIds.length} 个任务');
    for (final id in _selectedIds.toList()) {
      appState.downloadManager.cancelTask(id);
    }
    setState(() {
      _selectedIds.clear();
    });
  }
  
  String _formatTitle(VideoInfo video) {
    if (video.author != null && video.author!.isNotEmpty) {
      return '${video.title} - ${video.author}';
    }
    return video.title;
  }
  
  String _formatTime(DateTime? time) {
    if (time == null) return '';
    return '${time.month}/${time.day} ${time.hour}:${time.minute.toString().padLeft(2, '0')}';
  }
}
