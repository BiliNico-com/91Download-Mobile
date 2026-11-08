import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/search_history_service.dart';
import '../components/app_shell.dart';
import '../components/empty_state.dart';
import '../theme/app_tokens.dart';

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
        final t = AppTokens.of(context);
        final service = appState.searchHistory;
        final bottomInset = MediaQuery.of(context).padding.bottom;

        return Scaffold(
          backgroundColor: t.bg,
          appBar: AppBar(
            backgroundColor: t.surface,
            centerTitle: false,
            toolbarHeight: 58,
            titleSpacing: 0,
            leadingWidth: 52,
            leading: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Center(
                child: AppIconBtn(
                  icon: Icons.arrow_back_rounded,
                  tooltip: '返回',
                  onTap: () => Navigator.of(context).maybePop(),
                ),
              ),
            ),
            title: Text(
              '搜索历史',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: t.text1,
              ),
            ),
            actions: [
              if (service.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Center(
                    child: GestureDetector(
                      onTap: () => _confirmClear(context, t, service),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        height: 30,
                        padding: const EdgeInsets.symmetric(horizontal: 13),
                        decoration: BoxDecoration(
                          color: t.dangerSoft,
                          borderRadius:
                              BorderRadius.circular(AppRadius.pill),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '清空',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: t.danger,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
            shape: Border(bottom: BorderSide(color: t.line, width: 1)),
          ),
          body: service.isEmpty
              ? const EmptyState(
                  icon: Icons.history_toggle_off_rounded,
                  title: '还没有搜索记录',
                  subtitle: '在搜索页搜过的关键词会留在这里',
                  iconSize: 56,
                )
              : ListView(
                  padding: EdgeInsets.fromLTRB(12, 12, 12, bottomInset + 24),
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: t.surface,
                        borderRadius: BorderRadius.circular(AppRadius.xl),
                        border: t.cardBorder,
                        boxShadow: t.cardShadow,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          for (var i = 0; i < service.entries.length; i++) ...[
                            _buildRow(context, t, service, service.entries[i]),
                            if (i != service.entries.length - 1)
                              Divider(height: 1, thickness: 1, color: t.line),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      '共 ${service.entries.length} 条记录；点击可回填到搜索框',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, color: t.text3),
                    ),
                  ],
                ),
        );
      },
    );
  }

  Widget _buildRow(BuildContext context, AppTokens t,
      SearchHistoryService service, String keyword) {
    return InkWell(
      onTap: () {
        // 只回填关键词，由用户在搜索页确认后再搜，
        // 避免从设置页直接触发一次数据重载
        Navigator.of(context).pop(keyword);
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 11, 6, 11),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: t.surface2,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.history_rounded, size: 16, color: t.text3),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Text(
                keyword,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: t.text1,
                ),
              ),
            ),
            GestureDetector(
              onTap: () => service.remove(keyword),
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                child: Icon(Icons.close_rounded, size: 17, color: t.text3),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context, AppTokens t,
      SearchHistoryService service) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.xl),
        ),
        title: Text(
          '清空搜索历史',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: t.text1,
          ),
        ),
        content: Text(
          '确定要清空全部搜索历史吗？此操作不可撤销。',
          style: TextStyle(fontSize: 13, height: 1.5, color: t.text2),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: t.text3)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              '清空',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: t.danger,
              ),
            ),
          ),
        ],
      ),
    );
    if (ok == true) {
      await service.clear();
    }
  }
}
