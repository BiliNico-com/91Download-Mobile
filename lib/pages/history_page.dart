import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_state.dart';
import '../utils/logger.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _history = [];
  bool _isLoading = true;
  
  @override
  bool get wantKeepAlive => true;  // 保持页面状态

  @override
  void initState() {
    super.initState();
    Future.microtask(() => _loadHistory());
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);  // 必须调用
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('下载历史'),
            Text('查看和管理已下载的记录',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.delete_outline),
            onPressed: _clearHistory,
            tooltip: '清空历史',
          ),
        ],
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator())
          : _history.isEmpty
              ? Center(child: Text('暂无记录', style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  itemCount: _history.length,
                  itemBuilder: (context, index) {
                    final item = _history[index];
                    return ListTile(
                      leading: Icon(Icons.video_file),
                      title: Text(item['title'] ?? ''),
                      subtitle: Text(
                        item['download_time'] ?? '',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      trailing: Icon(Icons.check_circle, color: Colors.green),
                      onTap: () => _openVideo(item['file_path']),
                    );
                  },
                ),
    );
  }

  Future<void> _loadHistory() async {
    
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    
    if (crawler == null) {
      await logger.w('History', '爬虫为空, 无法加载历史');
      setState(() {
        _history = [];
        _isLoading = false;
      });
      return;
    }
    
    final history = await crawler.getDownloadHistory();
    await logger.i('History', '加载历史记录: ${history.length} 条');
    
    setState(() {
      _history = history;
      _isLoading = false;
    });
  }

  void _openVideo(String? path) async {
    if (path == null) return;
    // TODO: 打开视频播放器
  }

  Future<void> _clearHistory() async {
    
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('确认清空'),
        content: Text('确定要清空所有下载历史吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text('确定')),
        ],
      ),
    );
    
    if (confirm == true) {
      await logger.i('History', '确认清空历史记录');
      // TODO: 清空数据库
      _loadHistory();
    }
  }
}
