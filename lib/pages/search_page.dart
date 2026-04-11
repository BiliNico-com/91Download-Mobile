import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_state.dart';
import '../models/video_info.dart';
import '../utils/logger.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> with AutomaticKeepAliveClientMixin {
  final _keywordController = TextEditingController();
  List<VideoInfo> _results = [];
  List<AuthorInfo> _authorResults = [];  // 作者搜索结果
  Set<String> _selectedIds = {};
  bool _isLoading = false;
  bool _isAuthorMode = false;
  
  @override
  bool get wantKeepAlive => true;  // 保持页面状态

  @override
  Widget build(BuildContext context) {
    super.build(context);  // 必须调用
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
                : _isAuthorMode
                    ? _buildAuthorResults()
                    : _buildVideoResults(),
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
    
    await logger.i('Search', 'UI操作: 点击搜索按钮, 关键词: ${_keywordController.text}, 作者模式: $_isAuthorMode');
    
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) {
      await logger.w('Search', '爬虫为空, 请先选择站点');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('请先在设置页选择站点')),
      );
      return;
    }
    
    setState(() {
      _isLoading = true;
      _results.clear();
      _authorResults.clear();
      _selectedIds.clear();
    });
    
    if (_isAuthorMode) {
      // 搜索作者
      await logger.d('Search', '开始搜索作者...');
      final authors = await crawler.searchAuthors(_keywordController.text);
      await logger.i('Search', '作者搜索完成, 结果数: ${authors.length}');
      
      setState(() {
        _authorResults = authors;
        _isLoading = false;
      });
    } else {
      // 搜索视频
      await logger.d('Search', '开始搜索视频...');
      final results = await crawler.searchVideos(_keywordController.text);
      await logger.i('Search', '视频搜索完成, 结果数: ${results.length}');
      
      setState(() {
        _results = results;
        _selectedIds = results.map((v) => v.id).toSet();
        _isLoading = false;
      });
    }
  }
  
  /// 构建视频搜索结果
  Widget _buildVideoResults() {
    if (_results.isEmpty) {
      return Center(child: Text('输入关键词搜索', style: TextStyle(color: Colors.grey)));
    }
    
    return GridView.builder(
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
    );
  }
  
  /// 构建作者搜索结果
  Widget _buildAuthorResults() {
    if (_authorResults.isEmpty) {
      return Center(child: Text('输入关键词搜索作者', style: TextStyle(color: Colors.grey)));
    }
    
    return ListView.builder(
      padding: EdgeInsets.all(16),
      itemCount: _authorResults.length,
      itemBuilder: (context, index) {
        final author = _authorResults[index];
        return Card(
          child: ListTile(
            leading: CircleAvatar(
              child: Icon(Icons.person),
            ),
            title: Text(author.name),
            subtitle: Text('视频数: ${author.videoCount}'),
            trailing: Icon(Icons.arrow_forward_ios, size: 16),
            onTap: () => _showAuthorVideos(author),
          ),
        );
      },
    );
  }
  
  /// 显示作者的所有视频
  void _showAuthorVideos(AuthorInfo author) async {
    await logger.i('Search', '点击作者: ${author.name}');
    
    // TODO: 跳转到作者视频列表页或弹窗显示
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('作者功能开发中: ${author.name} (${author.videoCount}个视频)')),
      );
    }
  }

  void _download() async {
    await logger.i('Search', 'UI操作: 点击下载按钮, 选中 ${_selectedIds.length} 个视频');
    
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('请先在设置页选择站点')),
      );
      return;
    }
    
    // 获取选中的视频
    final selectedVideos = _results.where((v) => _selectedIds.contains(v.id)).toList();
    
    await logger.i('Search', '添加 ${selectedVideos.length} 个视频到下载队列');
    
    // 添加到下载管理器
    for (final video in selectedVideos) {
      appState.downloadManager.addTask(video);
    }
    
    // 显示提示
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已添加 ${selectedVideos.length} 个视频到下载队列'),
          action: SnackBarAction(
            label: '查看',
            onPressed: () {
              // 切换到下载页面
              DefaultTabController.of(context).animateTo(3);
            },
          ),
        ),
      );
    }
    
    // 清空选择
    setState(() {
      _selectedIds.clear();
    });
  }
}
