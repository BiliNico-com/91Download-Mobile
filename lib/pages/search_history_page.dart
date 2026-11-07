import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/search_history_service.dart';
import '../theme/app_theme.dart';

/// 搜索历史管理页
///
/// 此前历史只在搜索框下方以下拉形式展示最多 8 条，达到 20 条上限后
/// 无法查看完整列表，也不能单条删除或整体清空。
class SearchHistoryPage extends StatelessWidget {
  const SearchHistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, _) {
        final service = appState.searchHistory;
        return Scaffold(
          appBar: AppBar(
            title: const Text('搜索历史'),
            actions: [
              if (service.isNotEmpty)
                TextButton(
                  onPressed: () => _confirmClear(context, service),
                  child: const Text('清空'),
                ),
            ],
          ),
          body: service.isEmpty
              ? _buildEmpty(context)
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: AppTheme.spacingSm),
                  itemCount: service.entries.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, indent: 56),
                  itemBuilder: (context, index) {
                    final keyword = service.entries[index];
                    return ListTile(
                      leading: const Icon(Icons.history, size: 20),
                      title: Text(keyword),
                      trailing: IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: '删除',
                        onPressed: () => service.remove(keyword),
                      ),
                      onTap: () {
                        // 只回填关键词，由用户在搜索页确认后再搜，
                        // 避免从设置页直接触发一次数据重载
                        Navigator.of(context).pop(keyword);
                      },
                    );
                  },
                ),
        );
      },
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.history_toggle_off,
            size: 56,
            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.3),
          ),
          const SizedBox(height: AppTheme.spacingMd),
          Text(
            '还没有搜索记录',
            style: TextStyle(
              fontSize: 15,
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClear(
      BuildContext context, SearchHistoryService service) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空搜索历史'),
        content: const Text('确定要清空全部搜索历史吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await service.clear();
    }
  }
}
