import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/video_info.dart';
import '../services/app_state.dart';

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
  
  @override
  Widget build(BuildContext context) {
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
                    items: [
                    DropdownMenuItem(value: 'list', child: Text('视频')),
                    DropdownMenuItem(value: 'hot', child: Text('当前最热')),
                    DropdownMenuItem(value: 'topm', child: Text('本月最热')),
                    DropdownMenuItem(value: 'ori', child: Text('91原创')),
                  ],
                    onChanged: (v) => setState(() => _selectedType = v!),
                  ),
                ),
              ],
            ),
            SizedBox(height: 16),
            Row(
              children: [
                Text('页码: '),
                SizedBox(width: 50, child: TextFormField(initialValue: '1', onChanged: (v) => _pageStart = int.tryParse(v) ?? 1)),
                Text(' ~ '),
                SizedBox(width: 50, child: TextFormField(initialValue: '3', onChanged: (v) => _pageEnd = int.tryParse(v) ?? 3)),
                Spacer(),
                FilledButton(
                  onPressed: _loadVideos,
                  child: Text('加载'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgress() {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16),
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
    if (_videos.isEmpty) {
      return Center(child: Text('等待爬取...', style: TextStyle(color: Colors.grey)));
    }
    
    return GridView.builder(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.8,
      ),
      itemCount: _videos.length,
      itemBuilder: (context, index) {
        final video = _videos[index];
        final selected = _selectedIds.contains(video.id);
        
        return GestureDetector(
          onTap: () {
            setState(() {
                if (selected) {
                  _selectedIds.remove(video.id);
                } else {
                  _selectedIds.add(video.id);
                }
              });
          },
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                video.cover != null
                    ? Image.network(video.cover!, fit: BoxFit.cover)
                    : Icon(Icons.video_file, size: 50, color: Colors.grey),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.black.withOpacity(0.8), Colors.transparent],
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                      ),
                    ),
                    child: Text(
                      video.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: Colors.white),
                    ),
                  ),
                ),
                if (selected)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Icon(Icons.check_circle, color: Colors.blue),
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
      child: Row(
        children: [
          TextButton(
            onPressed: () {
              setState(() {
                if (_selectedIds.length == _videos.length) {
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
    setState(() {
      _isLoading = true;
      _status = '加载中...';
      _videos.clear();
    });
    
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    
    final videos = <VideoInfo>[];
    for (var p = _pageStart; p <= _pageEnd; p++) {
      final list = await crawler.getVideoList(_selectedType, p);
      videos.addAll(list);
    }
    
    setState(() {
      _videos = videos;
      _selectedIds = videos.map((v) => v.id).toSet();
      _isLoading = false;
      _status = '就绪';
    });
  }

  void _startDownload() {
    // TODO: 实现下载逻辑
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('开始下载 ${_selectedIds.length} 个视频')),
    );
  }
}
