import 'package:flutter_test/flutter_test.dart';
import 'package:download_91/crawler/config.dart';

void main() {
  test('jiuse 列表 URL 拼装：分类面板走路径式分页', () {
    const base = 'https://jiuse.icu';
    // 第 1 页不带页码
    expect(CrawlerConfig.buildJiuseListUrl(base, 'video/category/hd', 1),
        'https://jiuse.icu/video/category/hd');
    // 第 2 页页码在路径里，不是 ?page=2
    expect(CrawlerConfig.buildJiuseListUrl(base, 'video/category/hd', 2),
        'https://jiuse.icu/video/category/hd/2');
    expect(CrawlerConfig.buildJiuseListUrl(base, '/video/category/top-list', 7),
        'https://jiuse.icu/video/category/top-list/7');
  });

  test('jiuse 列表 URL 拼装：顶部导航沿用查询参数分页', () {
    const base = 'https://jiuse.icu';
    expect(CrawlerConfig.buildJiuseListUrl(base, 'video', 1),
        'https://jiuse.icu/video');
    expect(CrawlerConfig.buildJiuseListUrl(base, 'video', 3),
        'https://jiuse.icu/video?page=3');
    expect(CrawlerConfig.buildJiuseListUrl(base, 'videos', 2),
        'https://jiuse.icu/videos?page=2');
    expect(CrawlerConfig.buildJiuseListUrl(base, 'vod', 2),
        'https://jiuse.icu/vod?page=2');
  });

  test('jiuse 全部分类的 URL 都不残留占位符', () {
    final types = CrawlerConfig.getListTypes('jiuse');
    for (final e in types.entries) {
      final url = CrawlerConfig.buildJiuseListUrl('https://jiuse.icu', e.value, 2);
      expect(url, isNot(contains('{page}')), reason: '${e.key} -> $url');
      expect(url.startsWith('https://jiuse.icu/'), isTrue, reason: url);
    }
  });

  test('jiuse 搜索 URL', () {
    final u = CrawlerConfig.buildSearchUrl('https://jiuse.icu', 'jiuse', '测试');
    print('search: $u');
    expect(u, 'https://jiuse.icu/search?keywords=%E6%B5%8B%E8%AF%95');
  });
}
