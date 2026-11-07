import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:download_91/crawler/config.dart';
import 'package:download_91/crawler/crawler_core.dart';

/// jiuse 分区（/video/category/*）相关回归测试
///
/// 样本 D:/91/_jv.html 是从 https://jiuse.icu/video 抓下来的原始页面，
/// 里面的「选择分类」折叠面板（mobileCateContainer）与左侧栏
/// （cateContainer）都完整保留了 14 个 data-href。
void main() {
  final categoryPage = File('D:/91/_jv.html');

  String? read(File f) =>
      f.existsSync() ? f.readAsStringSync(encoding: utf8) : null;

  group('分区清单', () {
    test('14 个分区都能从中文名映射到路径', () {
      final types = CrawlerConfig.getListTypes('jiuse');
      final aliases = CrawlerConfig.getListTypeAliases('jiuse');
      for (final entry in aliases.entries) {
        final path = types[entry.value];
        expect(path, isNotNull, reason: '分类「${entry.key}」缺少路径');
      }
      final categoryPaths =
          types.values.where((p) => p.startsWith('video/category/')).toList();
      expect(categoryPaths.length, 14);
      expect(categoryPaths.toSet().length, 14, reason: '路径不能重复');
    });

    test('分类路径分页是路径式，顶部导航是查询式', () {
      const base = 'https://jiuse.icu';
      expect(CrawlerConfig.buildJiuseListUrl(base, 'video/category/hd', 2),
          'https://jiuse.icu/video/category/hd/2');
      expect(CrawlerConfig.buildJiuseListUrl(base, 'video/category/hd', 1),
          'https://jiuse.icu/video/category/hd');
      expect(CrawlerConfig.buildJiuseListUrl(base, 'video', 2),
          'https://jiuse.icu/video?page=2');
    });
  });

  group('分区页详情链接', () {
    test('viewhd 形态的详情链接也要认得', () {
      const href = '/video/viewhd/ef5152fe75b733995347';
      final m = CrawlerConfig.jiuseVideoHrefPattern
          .firstMatch('<a href="$href">');
      expect(m, isNotNull);
      expect(m!.group(1), href);
      expect(CrawlerConfig.jiuseVideoId(href), 'ef5152fe75b733995347');
    });

    test('viewhd 与 view 的 id 提取互不影响', () {
      expect(CrawlerConfig.jiuseVideoId('/video/viewhd/abc123def456'), 'abc123def456');
      expect(CrawlerConfig.jiuseVideoId('/video/view/8fa43eb9a5b88b2f0e5f'),
          '8fa43eb9a5b88b2f0e5f');
    });
  });

  group('分区页解析（真实样本）', () {
    test('高清分区页能解析出视频卡片', () {
      final html = read(categoryPage);
      if (html == null) {
        markTestSkipped('分区页样本 _jv.html 不存在');
        return;
      }
      final core = CrawlerCore(baseUrl: 'https://jiuse.icu');
      final videos = core.parseJiuseListForTest(html);
      // 实测该页 24 张卡片，全部是站内 viewhd 链接
      expect(videos.length, 24);
      expect(videos.every((v) => v.url.contains('/video/viewhd/')), isTrue);
      expect(videos.first.title, isNotEmpty);
      expect(videos.first.cover, isNotNull);
      expect(videos.map((v) => v.id).toSet().length, videos.length);
    });
  });

  group('分区页分页判断', () {
    test('第 1 页有 2..17152 的链接，判定为有下一页', () {
      final html = read(categoryPage);
      if (html == null) {
        markTestSkipped('分区页样本 _jv.html 不存在');
        return;
      }
      expect(CrawlerConfig.jiusePaginationHasMore(html, 1), isTrue);
      expect(CrawlerConfig.jiusePaginationHasMore(html, 2), isTrue);
    });

    test('只剩较小的页码链接时判定为最后一页', () {
      const html = '<ul class="pagination">'
          '<li><a class="page-link" href="/video/category/hd/1">1</a></li>'
          '<li class="active"><span class="page-link">2</span></li>'
          '</ul>';
      expect(CrawlerConfig.jiusePaginationHasMore(html, 2), isFalse);
    });

    test('没有路径式分页链接时返回 null，交回条数判据', () {
      const html = '<div>没有任何分页</div>';
      expect(CrawlerConfig.jiusePaginationHasMore(html, 1), isNull);
      expect(CrawlerConfig.jiusePaginationHasMore(html, 5), isNull);
    });
  });
}
