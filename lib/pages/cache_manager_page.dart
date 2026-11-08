import 'package:flutter/material.dart';
import '../services/app_state.dart';
import '../services/cache_service.dart';
import '../components/app_shell.dart';
import '../theme/app_tokens.dart';

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
    // 用 isEmpty 而不是 totalCount == 0：只剩封面缓存时 totalCount 也是 0，
    // 那样「清理」按钮点了没反应，用户以为功能坏了。
    if (res == null || res.isEmpty || _cleaning) return;

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
    final t = AppTokens.of(context);
    final res = _result;
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
          '缓存管理',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: t.text1,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: AppIconBtn(
                icon: Icons.refresh_rounded,
                tooltip: '重新扫描',
                onTap: _scanning ? null : _scan,
              ),
            ),
          ),
        ],
        shape: Border(bottom: BorderSide(color: t.line, width: 1)),
      ),
      body: _scanning && res == null
          ? Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                    strokeWidth: 2.5, color: t.accent),
              ),
            )
          : ListView(
              padding: EdgeInsets.fromLTRB(12, 12, 12, bottomInset + 24),
              children: [
                _buildSummary(t, res),
                const SizedBox(height: 11),
                _buildCoverCacheSection(t, res),
                // 临时文件与失效记录的多选清理区；封面缓存有独立按钮，
                // 因此这里只看 totalCount（不含封面占用）
                if (res == null || res.totalCount == 0)
                  _buildEmptyState(t)
                else ...[
                  _buildTempSection(t, res),
                  _buildOrphanHistorySection(t, res),
                  _buildOrphanTasksSection(t, res),
                  const SizedBox(height: 6),
                  _buildCleanButton(t),
                ],
                const SizedBox(height: 22),
                _buildNote(t),
              ],
            ),
    );
  }

  /// 统一卡片外壳
  Widget _card(AppTokens t, {required Widget child, EdgeInsets? padding}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 11),
      padding: padding,
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: t.cardBorder,
        boxShadow: t.cardShadow,
      ),
      child: child,
    );
  }

  Widget _buildSummary(AppTokens t, CacheScanResult? res) {
    return _card(
      t,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.folder_outlined, size: 17, color: t.accent),
              const SizedBox(width: 8),
              Text(
                '扫描位置',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: t.text1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            widget.appState.downloadDir.isEmpty
                ? '（未设置下载目录）'
                : widget.appState.downloadDir,
            style: TextStyle(fontSize: 11.5, height: 1.4, color: t.text3),
          ),
          if (res != null && !res.isEmpty) ...[
            const SizedBox(height: 11),
            Divider(height: 1, thickness: 1, color: t.line),
            const SizedBox(height: 11),
            Text(
              '发现 ${res.totalCount} 项残留，可释放约 ${formatBytes(res.totalBytes)}',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: t.accent,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyState(AppTokens t) {
    return _card(
      t,
      padding: const EdgeInsets.symmetric(vertical: 36),
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: t.successSoft,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.check_rounded, size: 26, color: t.success),
          ),
          const SizedBox(height: 12),
          Text(
            '很干净，没有发现残留文件',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: t.text1,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            '临时目录与记录均已正常清理',
            style: TextStyle(fontSize: 11.5, color: t.text3),
          ),
        ],
      ),
    );
  }

  /// 封面图缓存占用与清理入口
  Widget _buildCoverCacheSection(AppTokens t, CacheScanResult? res) {
    final bytes = res?.coverCacheBytes ?? 0;

    return _card(
      t,
      padding: const EdgeInsets.fromLTRB(14, 11, 10, 11),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: t.accentSoft,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.image_outlined, size: 18, color: t.accent),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '封面图缓存',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: t.text1,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  bytes > 0
                      ? '占用 ${formatBytes(bytes)}；清空后浏览时需重新下载'
                      : '暂无封面缓存',
                  maxLines: 2,
                  style: TextStyle(fontSize: 11.5, color: t.text3),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _clearingCoverCache
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : GestureDetector(
                  onTap: bytes > 0 ? _clearCoverCache : null,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    height: 28,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: bytes > 0 ? t.dangerSoft : t.surface2,
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '清空',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: bytes > 0 ? t.danger : t.text3,
                      ),
                    ),
                  ),
                ),
        ],
      ),
    );
  }

  Widget _buildTempSection(AppTokens t, CacheScanResult res) {
    return _buildSection(
      t,
      title: '未合并的临时文件',
      subtitle: '下载中途被关闭或崩溃时留下的切片缓存，可直接删除',
      icon: Icons.folder_delete_outlined,
      color: t.warning,
      value: _cleanTemp,
      onChanged: (v) => setState(() => _cleanTemp = v),
      entries: res.tempDirs,
      showSize: true,
    );
  }

  Widget _buildOrphanHistorySection(AppTokens t, CacheScanResult res) {
    return _buildSection(
      t,
      title: '失效的下载记录',
      subtitle: '文件已被删除，但记录仍在——这就是「删除后又出现」的原因',
      icon: Icons.history_toggle_off_rounded,
      color: t.danger,
      value: _cleanOrphanHistory,
      onChanged: (v) => setState(() => _cleanOrphanHistory = v),
      entries: res.orphanHistory,
      showSize: false,
    );
  }

  Widget _buildOrphanTasksSection(AppTokens t, CacheScanResult res) {
    return _buildSection(
      t,
      title: '失效的任务列表项',
      subtitle: '任务列表中文件已不存在的已完成条目',
      icon: Icons.playlist_remove_rounded,
      color: t.accent,
      value: _cleanOrphanTasks,
      onChanged: (v) => setState(() => _cleanOrphanTasks = v),
      entries: res.orphanTasks,
      showSize: false,
    );
  }

  Widget _buildSection(
    AppTokens t, {
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

    return _card(
      t,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 14, 0),
            child: Row(
              children: [
                Checkbox(
                  value: value,
                  onChanged: (v) => onChanged(v ?? false),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  activeColor: AppTokens.blue,
                ),
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: color.withOpacity(t.dark ? 0.18 : 0.10),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  alignment: Alignment.center,
                  child: Icon(icon, size: 16, color: color),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$title (${entries.length})',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: t.text1,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 2,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.35,
                          color: t.text3,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Divider(height: 1, thickness: 1, color: t.line),
          // 最多展示 50 条，避免超长列表卡顿
          ...entries.take(50).map(
                (e) => Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          e.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: t.text2),
                        ),
                      ),
                      if (showSize && e.sizeBytes > 0)
                        Text(
                          e.sizeText,
                          style: TextStyle(fontSize: 11, color: t.text3),
                        ),
                    ],
                  ),
                ),
              ),
          if (entries.length > 50)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
              child: Text(
                '… 其余 ${entries.length - 50} 项',
                style: TextStyle(fontSize: 11, color: t.text3),
              ),
            ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget _buildCleanButton(AppTokens t) {
    final enabled = !_cleaning &&
        ((_cleanTemp && (_result?.tempDirs.isNotEmpty ?? false)) ||
            (_cleanOrphanHistory &&
                (_result?.orphanHistory.isNotEmpty ?? false)) ||
            (_cleanOrphanTasks && (_result?.orphanTasks.isNotEmpty ?? false)));

    return GestureDetector(
      onTap: enabled ? _clean : null,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color: enabled ? AppTokens.blue : t.surface3,
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_cleaning)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: t.text3),
              )
            else
              Icon(Icons.cleaning_services_rounded,
                  size: 17, color: enabled ? Colors.white : t.text3),
            const SizedBox(width: 7),
            Text(
              _cleaning ? '清理中…' : '清理选中项',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w800,
                color: enabled ? Colors.white : t.text3,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNote(AppTokens t) {
    return Text(
      '说明：清理只移除临时缓存与失效记录，不会删除已下载完成的视频文件。'
      '若某个视频的文件已丢失，其记录会出现在「失效的下载记录」中，清理后可避免它反复出现在已下载列表。',
      style: TextStyle(fontSize: 11, height: 1.6, color: t.text3),
    );
  }
}
