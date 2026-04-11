import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_state.dart';
import '../models/video_info.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _keywordController = TextEditingController();
  List<VideoInfo> _results = [];
  Set<String> _selectedIds = {};
  bool _isLoading = false;
  bool _isAuthorMode = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('搜索'),
            Text('通过关键词搜索并下载视频',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
      body: Column(
        children: [
          // 搜索框
          Padding(
            padding: EdgeInsets.all(16),
            child: Row(
              children: [
                // 模式切换
                DropdownButton<bool>(
                  value: _isAuthorMode,
                  items: [
                    DropdownMenuItem(value: false, child: Text('搜视频')),
                    DropdownMenuItem(value: true, child: Text('搜作者')),
                  ],
                  onChanged: (v) => setState(() => _isAuthorMode = v!),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _keywordController,
                    decoration: InputDecoration(
                      hintText: '输入关键词...',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12),
                    ),
                  ),
                ),
                SizedBox(width: 8),
                FilledButton(
                  onPressed: _search,
                  child: Text('搜索'),
                ),
              ],
            ),
          ),
          
          // 结果列表
          Expanded(
            child: _isLoading
                ? Center(child: CircularProgressIndicator())
                : _results.isEmpty
                    ? Center(child: Text('输入关键词搜索', style: TextStyle(color: Colors.grey)))
                    : GridView.builder(
                        padding: EdgeInsets.all(8),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          childAspectRatio: 0.75,
                        ),
                        itemCount: _results.length,
                        itemBuilder: (context, index) {
                          final video = _results[index];
                          final selected = _selectedIds.contains(video.id);
                          
                          return GestureDetector(
                            onTap: () => _toggleSelection(video.id),
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
                      ),
          ),
          
          // 底部操作栏
          if (_results.isNotEmpty)
            Container(
              padding: EdgeInsets.all(16),
              child: Row(
                children: [
                  TextButton(
                    onPressed: _toggleAll,
                    child: Text(_selectedIds.length == _results.length ? '取消全选' : '全选'),
                  ),
                  Spacer(),
                  FilledButton(
                    onPressed: _selectedIds.isEmpty ? null : _download,
                    child: Text('下载 (${_selectedIds.length})'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _toggleAll() {
    setState(() {
      if (_selectedIds.length == _results.length) {
        _selectedIds.clear();
      } else {
        _selectedIds = _results.map((v) => v.id).toSet();
      }
    });
  }

  Future<void> _search() async {
    if (_keywordController.text.isEmpty) return;
    
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('请先在设置页选择站点')),
      );
      return;
    }
    
    setState(() {
      _isLoading = true;
      _results.clear();
    });
    
    final results = await crawler.searchVideos(_keywordController.text);
    
    setState(() {
      _results = results;
      _selectedIds = results.map((v) => v.id).toSet();
      _isLoading = false;
    });
  }

  void _download() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('开始下载 ${_selectedIds.length} 个视频')),
    );
  }
}
