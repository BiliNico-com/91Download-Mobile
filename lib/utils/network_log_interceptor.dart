import 'package:dio/dio.dart';

import 'logger.dart';

/// 网络请求日志拦截器
///
/// 挂到 CrawlerCore 的 Dio 上，把每一次请求记成一行：
/// 方法、精简后的 URL、状态码、耗时、响应字节数。
/// 排查「抓不到列表 / 详情解析失败 / 下载 403」时，
/// 光看业务日志判断不出是站点拒绝还是解析写错，有了这层就能直接对照。
class NetworkLogInterceptor extends Interceptor {
  NetworkLogInterceptor({this.name = 'Crawler'});

  final String name;

  /// 记请求开始时刻
  static const String _startKey = 'netLogStart';

  /// 切片下载会产生成百上千条请求，只采样记录，避免日志被刷满
  int _segmentCount = 0;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (logger.enabled) {
      options.extra[_startKey] = DateTime.now().millisecondsSinceEpoch;
    }
    handler.next(options);
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    _record(response.requestOptions, response.statusCode, null, response);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _record(err.requestOptions, err.response?.statusCode, err, err.response);
    handler.next(err);
  }

  void _record(
    RequestOptions options,
    int? statusCode,
    DioException? error,
    Response<dynamic>? response,
  ) {
    if (!logger.enabled) return;
    try {
      final uri = options.uri;
      final path = uri.path.isEmpty ? '/' : uri.path;
      final isSegment = path.endsWith('.ts') ||
          path.endsWith('.m4s') ||
          path.endsWith('.m4a') ||
          path.endsWith('.aac');
      if (isSegment) {
        _segmentCount++;
        // 前 3 个切片各记一条，之后每 50 个采样一条
        if (_segmentCount > 3 && _segmentCount % 50 != 0) return;
      }

      final start = options.extra[_startKey];
      final ms = start is int ? DateTime.now().millisecondsSinceEpoch - start : -1;
      final query = uri.query.isEmpty ? '' : '?' + _shortQuery(uri.query);
      final target = options.method + ' ' + uri.host + path + query;
      final elapsed = ms >= 0 ? '${ms}ms' : '-';

      if (error != null) {
        final type = error.type.name;
        final message = error.message ?? '';
        final tail = message.isEmpty ? '' : ' ' + message;
        logger.network('${target} -> 失败(${type}, ${elapsed})${tail}', level: LogLevel.warn);
        return;
      }

      final length = _bodyLength(response);
      final suffix = length == null ? '' : ' ${length} B';
      final level = (statusCode ?? 0) >= 400 ? LogLevel.warn : LogLevel.info;
      logger.network('${target} -> ${statusCode} ${elapsed}${suffix}', level: level);
    } catch (_) {
      // 日志本身绝不能影响请求
    }
  }

  /// 查询串里可能带签名，只保留前若干字符，够区分接口就行
  String _shortQuery(String query) {
    if (query.isEmpty) return query;
    return query.length <= 60 ? query : query.substring(0, 60) + '...';
  }

  String? _bodyLength(Response<dynamic>? response) {
    if (response == null) return null;
    final header = response.headers.value(Headers.contentLengthHeader);
    if (header != null && header.isNotEmpty) return header;
    final data = response.data;
    if (data is List<int>) return '${data.length}';
    if (data is String) return '${data.length}';
    return null;
  }
}
