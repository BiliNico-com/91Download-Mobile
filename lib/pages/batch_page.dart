import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/video_info.dart';
import '../services/app_state.dart';
import '../utils/logger.dart';

class BatchPage extends StatefulWidget {
  const BatchPage({super.key});

  @override
  State<BatchPage> createState() => _BatchPageState();
}

class _BatchPageState extends State<BatchPage> {
  String _selectedType = 'list';
  int _pageStart = 1;
  int _pageEnd = 3;
  List<VideoInfo> _videos = [];
  Set<String> _selectedIds = {};
  bool _isLoading = false;
  String _status = '就绪';
  double _progress = 0.0;
  String _progressText = '';
  
  final _typeNames = {
    'list': '视频',
    'hot': '当前最热',
    'topm': '本月最热',
    'ori': '91原创',
  };
  
  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, _) {
        // 记录批量页面状态
        Future.microtask(() {
          logger.d('Batch', 'build: isSiteSelected=${appState.isSiteSelected}, currentSite=${appState.currentSite}');
        });
        
        // 检查是否已选择站点
        if (!appState.isSiteSelected) {
          return _buildNoSiteSelected();
        }
        
        return _buildMainContent();
      },
    );
  }
  
  Widget _buildNoSiteSelected() {
    // 记录用户看到了"请先选择站点"提示
    Future.microtask(() {
      logger.w('Batch', '当前未选择站点, 显示提示界面');
    });
    
    return Scaffold(
      appBar: AppBar(
        title: Text('批量爬取'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.language, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('请先选择站点', style: TextStyle(fontSize: 18, color: Colors.grey)),
            SizedBox(height: 8),
            Text('在设置页面选择要使用的站点', style: TextStyle(fontSize: 14, color: Colors.grey)),
            SizedBox(height: 24),
            Text('← 左滑到设置页面选择站点', 
              style: TextStyle(fontSize: 14, color: Colors.blue)),
          ],
        ),
      ),
    );
  }
  
  Widget _buildMainContent() {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('批量爬取'),
            Text('按页面范围批量下载视频资源', 
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
        actions: [
          Container(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.2),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(_status, style: TextStyle(color: Colors.green)),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSettings(),
          if (_progress > 0) _buildProgress(),
          Expanded(child: _buildVideoGrid()),
          _buildBottomBar(),
        ],
      ),
    );
  }

  Widget _buildSettings() {
    return Card(
      margin: EdgeInsets.all(16),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Text('列表: '),
                Expanded(
                  child: DropdownButtonFormField(
                    value: _selectedType,
                    items: _typeNames.entries.map((e) {
                      return DropdownMenuItem(value: e.key, child: Text(e.value));
                    }).toList(),
                    onChanged: (v) async {
                      if (v != null) {
                        await logger.i('Batch', 'UI操作: 选择列表类型 -> ${_typeNames[v]}');
                        setState(() => _selectedType = v);
                      }
                    },
                  ),
                ),
              ],
            ),
            SizedBox(height: 16),
            Row(
              children: [
                Text('页码: '),
                SizedBox(width: 50, child: TextFormField(
                  initialValue: '1',
                  onChanged: (v) {
                    _pageStart = int.tryParse(v) ?? 1;
                  },
                )),
                Text(' ~ '),
                SizedBox(width: 50, child: TextFormField(
                  initialValue: '3',
                  onChanged: (v) {
                    _pageEnd = int.tryParse(v) ?? 3;
                  },
                )),
                Spacer(),
                FilledButton(
                  onPressed: _isLoading ? null : () async {
                    print('[Batch] 加载按钮被点击');
                    await _loadVideos();
                  },
                  child: _isLoading 
                    ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text('加载'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgress() {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          LinearProgressIndicator(value: _progress),
          SizedBox(height: 4),
          Text(_progressText, style: TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _buildVideoGrid() {
    if (_isLoading && _videos.isEmpty) {
      return Center(child: CircularProgressIndicator());
    }
    
    if (_videos.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.video_library_outlined, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('点击加载获取视频列表', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }
    
    return GridView.builder(
      padding: EdgeInsets.all(8),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.75,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: _videos.length,
      itemBuilder: (context, index) {
        final video = _videos[index];
        final isSelected = _selectedIds.contains(video.id);
        
        return GestureDetector(
          onTap: () async {
            final action = isSelected ? '取消选择' : '选择';
            await logger.d('Batch', 'UI操作: $action视频 [${video.title}]');
            setState(() {
              if (isSelected) {
                _selectedIds.remove(video.id);
              } else {
                _selectedIds.add(video.id);
              }
            });
          },
          child: Card(
            color: isSelected ? Colors.blue.withOpacity(0.2) : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.grey[800],
                      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
                    ),
                    child: Center(
                      child: Icon(Icons.play_circle, size: 48, color: Colors.white54),
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.all(8),
                  child: Text(
                    video.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 8)],
      ),
      child: Row(
        children: [
          TextButton(
            onPressed: _videos.isEmpty ? null : () async {
              final isAllSelected = _selectedIds.length == _videos.length;
              await logger.i('Batch', 'UI操作: ${isAllSelected ? "取消全选" : "全选"}');
              setState(() {
                if (isAllSelected) {
                  _selectedIds.clear();
                } else {
                  _selectedIds = _videos.map((v) => v.id).toSet();
                }
              });
            },
            child: Text(_selectedIds.length == _videos.length ? '取消全选' : '全选'),
          ),
          Spacer(),
          FilledButton(
            onPressed: _selectedIds.isEmpty ? null : _startDownload,
            child: Text('下载 (${_selectedIds.length})'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadVideos() async {
    print('[Batch] _loadVideos 开始执行');
    print('[Batch] _isLoading=$_isLoading, _selectedType=$_selectedType');
    
    await logger.i('Batch', 'UI操作: 点击加载按钮, 类型=$_selectedType, 页码=$_pageStart-$_pageEnd');
    
    setState(() {
      _isLoading = true;
      _status = '加载中...';
      _videos.clear();
    });
    print('[Batch] 状态已更新: _isLoading=$_isLoading, _status=$_status');
    
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    print('[Batch] crawler=${crawler != null ? "存在" : "null"}, currentSite=${appState.currentSite}');
    
    if (crawler == null) {
      await logger.e('Batch', '爬虫为空, 请先选择站点');
      setState(() {
        _isLoading = false;
        _status = '请先选择站点';
      });
      return;
    }
    
    final videos = <VideoInfo>[];
    for (var p = _pageStart; p <= _pageEnd; p++) {
      print('[Batch] 开始加载第 $p 页');
      await logger.i('Batch', '网络请求: 加载第 $p 页');
      final list = await crawler.getVideoList(_selectedType, p);
      print('[Batch] 第 $p 页返回 ${list.length} 个视频');
      videos.addAll(list);
    }
    
    await logger.i('Batch', '加载完成, 共 ${videos.length} 个视频');
    
    setState(() {
      _videos = videos;
      _selectedIds = videos.map((v) => v.id).toSet();
      _isLoading = false;
      _status = '就绪';
    });
    print('[Batch] 加载完成, _videos.length=${_videos.length}');
  }

  Future<void> _startDownload() async {
    await logger.i('Batch', 'UI操作: 点击下载按钮, 选中 ${_selectedIds.length} 个视频');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('开始下载 ${_selectedIds.length} 个视频')),
    );
  }
}
