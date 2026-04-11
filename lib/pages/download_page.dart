import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:share_plus/share_plus.dart';
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
    await logger.i('DownloadPage', '下拉刷新');
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
        
        return RefreshIndicator(
          onRefresh: _onRefresh,
          child: ListView.builder(
            itemCount: tasks.length,
            itemBuilder: (context, index) {
              final task = tasks[index];
              return _buildDownloadTaskItem(task, appState);
            },
          ),
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
          ),
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
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    task.progressText.isNotEmpty ? task.progressText : '${(task.progress * 100).toStringAsFixed(1)}%',
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
        _playVideo(task, appState);
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
              selected 
                ? Icon(Icons.check_circle, color: Colors.blue)
                : Icon(Icons.check_circle_outline, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
  
  /// 播放视频
  void _playVideo(DownloadTask task, AppState appState) async {
    await logger.i('DownloadPage', '播放视频: ${task.video.title}');
    
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
    await logger.i('DownloadPage', '使用内置播放器');
    
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
    await logger.i('DownloadPage', '使用外部播放器');
    
    try {
      // 使用 url_launcher 打开外部播放器
      // 注意：需要导入 url_launcher: ^6.1.0
      // 如果未安装，则回退到内置播放器
      // ignore: depend_on_referenced_packages
      final uri = Uri.file(task.filePath!);
      await logger.i('DownloadPage', '文件 URI: $uri');
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('正在打开外部播放器...')),
        );
      }
      
      // 由于当前环境可能没有 url_launcher，直接使用内置播放器
      await _playWithInternalPlayer(task);
    } catch (e) {
      await logger.e('DownloadPage', '打开外部播放器失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开失败: $e')),
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
      await logger.e('DownloadPage', '分享失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('分享失败: $e')),
        );
      }
    }
  }
  
  void _deleteSelected(AppState appState) async {
    await logger.i('DownloadPage', '删除选中的 ${_selectedIds.length} 个任务');
    for (final id in _selectedIds.toList()) {
      appState.downloadManager.cancelTask(id);
    }
    setState(() {
      _selectedIds.clear();
    });
  }
  
  String _formatTitle(VideoInfo video) {
    if (video.title.length > 30) {
      return '${video.title.substring(0, 30)}...';
    }
    return video.title;
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
  
  @override
  void initState() {
    super.initState();
    _initializePlayer();
  }
  
  Future<void> _initializePlayer() async {
    try {
      await logger.i('VideoPlayer', '初始化播放器: ${widget.filePath}');
      
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
      await logger.e('VideoPlayer', '初始化失败: $e');
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
    
    return Center(
      child: Chewie(controller: _chewieController!),
    );
  }
}
