import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 搜索历史服务
///
/// 用 shared_preferences 存储（零新增依赖，且已在本项目中使用）。
/// 采用「最近使用优先」的列表：重复搜索会把它提到最前面。
class SearchHistoryService extends ChangeNotifier {
  static const String _prefKey = 'search_history';
  static const String _prefHintKey = 'search_history_hint_dismissed';

  /// 最多保留的条数。超出后丢弃最旧的。
  static const int maxEntries = 20;

  List<String> _entries = [];
  List<String> get entries => List.unmodifiable(_entries);

  bool get isEmpty => _entries.isEmpty;
  bool get isNotEmpty => _entries.isNotEmpty;

  /// 用户是否已选择"不再提示历史"（保留接口，便于日后扩展）
  bool _hintDismissed = false;
  bool get hintDismissed => _hintDismissed;

  /// 启动时加载
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _entries = prefs.getStringList(_prefKey) ?? [];
      _hintDismissed = prefs.getBool(_prefHintKey) ?? false;
      notifyListeners();
    } catch (e) {
      debugPrint('[SearchHistory] 加载失败: $e');
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefKey, _entries);
    } catch (e) {
      debugPrint('[SearchHistory] 保存失败: $e');
    }
  }

  /// 记录一次搜索
  ///
  /// 去重（大小写不敏感、忽略首尾空格），并把该关键词提到最前。
  /// 空白关键词直接忽略，避免污染列表。
  Future<void> add(String keyword) async {
    final k = keyword.trim();
    if (k.isEmpty) return;

    _entries.removeWhere((e) => e.toLowerCase() == k.toLowerCase());
    _entries.insert(0, k);

    if (_entries.length > maxEntries) {
      _entries = _entries.sublist(0, maxEntries);
    }

    notifyListeners();
    await _persist();
  }

  /// 删除单条
  Future<void> remove(String keyword) async {
    final before = _entries.length;
    _entries.removeWhere((e) => e == keyword);
    if (_entries.length != before) {
      notifyListeners();
      await _persist();
    }
  }

  /// 清空全部
  Future<void> clear() async {
    if (_entries.isEmpty) return;
    _entries = [];
    notifyListeners();
    await _persist();
  }
}
