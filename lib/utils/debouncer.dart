import 'dart:async';

/// 防抖工具类，用于延迟执行频繁触发的操作
/// 
/// 典型用法：搜索输入防抖
/// ```dart
/// final _debouncer = Debouncer(milliseconds: 500);
///
/// void onSearchChanged(String value) {
///   _debouncer.run(() => _performSearch(value));
/// }
/// ```
class Debouncer {
  final int milliseconds;
  Timer? _timer;

  Debouncer({required this.milliseconds});

  void run(VoidCallback action) {
    _timer?.cancel();
    _timer = Timer(Duration(milliseconds: milliseconds), action);
  }

  void dispose() {
    _timer?.cancel();
  }
}

typedef VoidCallback = void Function();
