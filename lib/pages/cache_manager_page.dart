import 'package:flutter/material.dart';
import '../services/app_state.dart';
import '../services/cache_service.dart';

/// 缓存管理页
///
/// 展示下载目录中的残留内容，并允许分项清理：
///   1. 未合并的临时切片目录（*_temp）
///   2. 文件已删除、但历史记录仍残留的条目
///   3. 文件已删除、但任务记录仍残留的条目
class CacheManagerPage extends StatefulWidget {
  final AppState appState;

  const CacheManagerPage({super.key, required this.appState});

  @override
  State<CacheManagerPage> createState() => _CacheManagerPageState();
}

class _CacheManagerPageState extends State<CacheManagerPage> {
  CacheScanResult? _result;
  bool _scanning = false;
  bool _cleaning = false;

  // 分项勾选
  bool _cleanTemp = true;
  bool _cleanOrphanHistory = true;
  bool _cleanOrphanTasks = true;

  /// 清空封面缓存（独立按钮，立即执行）
  bool _clearingCoverCache = false;

  Future<void> _clearCoverCache() async {
    if (_clearingCoverCache) return;
    setState(() => _clearingCoverCache = true);

    final before = _result?.coverCacheBytes ?? 0;
    final ok = await CacheService.clearCoverCache();

    if (!mounted) return;
    setState(() => _clearingCoverCache = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok
            ? '已清空封面缓存，释放 ${formatBytes(before)}'
            : '清空封面缓存失败'),
      ),
    );
    await _scan();
  }

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    if (_scanning) return;
    setState(() => _scanning = true);

    final res = await CacheService.scan(
      downloadDir: widget.appState.downloadDir,
      downloadManager: widget.appState.downloadManager,
      crawler: widget.appState.crawler,
    );

    if (!mounted) return;
    setState(() {
      _result = res;
      _scanning = false;
    });
  }

  Future<void> _clean() async {
    final res = _result;
    if (res == null || res.totalCount == 0 || _cleaning) return;

    setState(() => _cleaning = true);

    final report = await CacheService.clean(
      scanResult: res,
      downloadManager: widget.appState.downloadManager,
      crawler: widget.appState.crawler,
      deleteTemp: _cleanTemp,
      deleteOrphanHistory: _cleanOrphanHistory,
      deleteOrphanTasks: _cleanOrphanTasks,
    );

    if (!mounted) return;
    setState(() => _cleaning = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          report.totalRemoved == 0
              ? '没有可清理的内容'
              : '已清理 ${report.totalRemoved} 项，释放 ${report.freedText}',
        ),
      ),
    );

    // 重新扫描以刷新列表
    await _scan();
  }

  @override
  Widget build(BuildContext context) {
    final res = _result;

    return Scaffold(
      appBar: AppBar(
        title: const Text('缓存管理'),
        actions: [
          IconButton(
            tooltip: '重新扫描',
            icon: _scanning
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            onPressed: _scanning ? null : _scan,
          ),
        ],
      ),
      body: _scanning && res == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _buildSummary(res),
                const SizedBox(height: 12),
                _buildCoverCacheSection(res),
                // 临时文件与失效记录的多选清理区；封面缓存有独立按钮，
                // 因此这里只看 totalCount（不含封面占用）
                if (res == null || res.totalCount == 0)
                  _buildEmptyState()
                else ...[
                  _buildTempSection(res),
                  _buildOrphanHistorySection(res),
                  _buildOrphanTasksSection(res),
                  const SizedBox(height: 16),
                  _buildCleanButton(),
                ],
                const SizedBox(height: 24),
                _buildNote(),
              ],
            ),
    );
  }

  Widget _buildSummary(CacheScanResult? res) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.folder_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('扫描位置', style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              widget.appState.downloadDir.isEmpty ? '（未设置下载目录）' : widget.appState.downloadDir,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            if (res != null && !res.isEmpty) ...[
              const Divider(height: 24),
              Text(
                '发现 ${res.totalCount} 项残留，可释放约 ${formatBytes(res.totalBytes)}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Column(
          children: [
            Icon(Icons.check_circle_outline, size: 56, color: Colors.green),
            const SizedBox(height: 12),
            const Text('很干净，没有发现残留文件'),
            const SizedBox(height: 4),
            Text(
              '临时目录与记录均已正常清理',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  /// 封面图缓存占用与清理入口
  ///
  /// 封面走磁盘缓存（cached_network_image），浏览过的图片会留在本地，
  /// 二次打开无需重新下载；这里只做占用展示与手动清空。
  Widget _buildCoverCacheSection(CacheScanResult? res) {
    final bytes = res?.coverCacheBytes ?? 0;
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(Icons.image_outlined, color: theme.colorScheme.primary),
        title: const Text('封面图缓存', style: TextStyle(fontSize: 14)),
        subtitle: Text(
          bytes > 0
              ? '已缓存缩略图，占用 ${formatBytes(bytes)}；清空后浏览时需重新下载'
              : '暂无封面缓存',
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
        trailing: _clearingCoverCache
            ? const SizedBox(
                width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : TextButton(
                onPressed: bytes > 0 ? _clearCoverCache : null,
                child: const Text('清空'),
              ),
      ),
    );
  }

  Widget _buildTempSection(CacheScanResult res) {
    return _buildSection(
      title: '未合并的临时文件',
      subtitle: '下载中途被关闭或崩溃时留下的切片缓存，可直接删除',
      icon: Icons.folder_delete_outlined,
      color: Colors.orange,
      value: _cleanTemp,
      onChanged: (v) => setState(() => _cleanTemp = v),
      entries: res.tempDirs,
      showSize: true,
    );
  }

  Widget _buildOrphanHistorySection(CacheScanResult res) {
    return _buildSection(
      title: '失效的下载记录',
      subtitle: '文件已被删除，但记录仍在——这就是「删除后又出现」的原因',
      icon: Icons.history_toggle_off,
      color: Colors.red,
      value: _cleanOrphanHistory,
      onChanged: (v) => setState(() => _cleanOrphanHistory = v),
      entries: res.orphanHistory,
      showSize: false,
    );
  }

  Widget _buildOrphanTasksSection(CacheScanResult res) {
    return _buildSection(
      title: '失效的任务列表项',
      subtitle: '任务列表中文件已不存在的已完成条目',
      icon: Icons.playlist_remove,
      color: Colors.purple,
      value: _cleanOrphanTasks,
      onChanged: (v) => setState(() => _cleanOrphanTasks = v),
      entries: res.orphanTasks,
      showSize: false,
    );
  }

  Widget _buildSection({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required bool value,
    required ValueChanged<bool> onChanged,
    required List<CacheEntry> entries,
    required bool showSize,
  }) {
    if (entries.isEmpty) return const SizedBox.shrink();

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CheckboxListTile(
            value: value,
            onChanged: (v) => onChanged(v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            secondary: Icon(icon, color: color),
            title: Text('$title (${entries.length})',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            subtitle: Text(subtitle, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ),
          const Divider(height: 1),
          // 最多展示 50 条，避免超长列表卡顿
          ...entries.take(50).map((e) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        e.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    if (showSize && e.sizeBytes > 0)
                      Text(e.sizeText,
                          style: const TextStyle(fontSize: 11, color: Colors.grey)),
                  ],
                ),
              )),
          if (entries.length > 50)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Text(
                '… 其余 ${entries.length - 50} 项',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildCleanButton() {
    final enabled = !_cleaning &&
        ((_cleanTemp && (_result?.tempDirs.isNotEmpty ?? false)) ||
            (_cleanOrphanHistory && (_result?.orphanHistory.isNotEmpty ?? false)) ||
            (_cleanOrphanTasks && (_result?.orphanTasks.isNotEmpty ?? false)));

    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: enabled ? _clean : null,
        icon: _cleaning
            ? const SizedBox(
                width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.cleaning_services),
        label: Text(_cleaning ? '清理中…' : '清理选中项'),
      ),
    );
  }

  Widget _buildNote() {
    return Text(
      '说明：清理只移除临时缓存与失效记录，不会删除已下载完成的视频文件。'
      '若某个视频的文件已丢失，其记录会出现在「失效的下载记录」中，清理后可避免它反复出现在已下载列表。',
      style: TextStyle(fontSize: 11, color: Colors.grey, height: 1.5),
    );
  }
}
