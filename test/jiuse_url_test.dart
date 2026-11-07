import 'package:flutter_test/flutter_test.dart';
import 'package:download_91/crawler/config.dart';

void main() {
  test('jiuse 列表 URL 拼装', () {
    final types = CrawlerConfig.getListTypes('jiuse');
    for (final e in types.entries) {
      print('${e.key} -> ${e.value}');
    }
    // 模拟 getVideoList 的拼接逻辑
    const baseUrl = 'https://jiuse.icu';
    for (final entry in types.entries) {
      final path = entry.value.replaceAll('{page}', '2');
      final url = '$baseUrl/$path?page=2';
      print('page2 url: $url');
      expect(url, isNot(contains('{page}')));
    }
  });

  test('jiuse 搜索 URL', () {
    final u = CrawlerConfig.buildSearchUrl('https://jiuse.icu', 'jiuse', '测试');
    print('search: $u');
    expect(u, 'https://jiuse.icu/search?keywords=%E6%B5%8B%E8%AF%95');
  });
}
