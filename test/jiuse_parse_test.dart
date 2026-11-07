import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:download_91/crawler/config.dart';

void main() {
  test('jiuse 站点类型识别', () {
    expect(CrawlerConfig.detectSiteType('https://91porny.com'), 'jiuse');
    expect(CrawlerConfig.detectSiteType('https://jiuse.icu'), 'jiuse');
    expect(CrawlerConfig.detectSiteType('https://www.91porny.com'), 'jiuse');
    // 原有站点不受影响
    expect(CrawlerConfig.detectSiteType('https://91porn.com'), 'porn91');
    expect(CrawlerConfig.detectSiteType('https://hsex.icu'), 'original');
  });


  test('jiuse 分区覆盖网页上的 14 个分类', () {
    // 依据：抓取 jiuse.icu/video 原始 HTML，移动端「选择分类」折叠面板
    // (mobileCateContainer) 与桌面端左侧栏 (cateContainer) 是同一份
    // 14 项 data-href，名称与路径逐字对应。
    const expected = {
      '最近更新': '/video/category/latest',
      '高清视频': '/video/category/hd',
      '最近加精': '/video/category/recent-favorite',
      '当前最热': '/video/category/hot-list',
      '最近得分': '/video/category/recent-rating',
      '非付费': '/video/category/nonpaid',
      '91原创': '/video/category/ori',
      '10分钟以上': '/video/category/long-list',
      '20分钟以上': '/video/category/longer-list',
      '本月讨论': '/video/category/month-discuss',
      '本月收藏': '/video/category/top-favorite',
      '收藏最多': '/video/category/most-favorite',
      '本月最热': '/video/category/top-list',
      '上月最热': '/video/category/top-last',
    };

    final types = CrawlerConfig.getListTypes('jiuse');
    final aliases = CrawlerConfig.getListTypeAliases('jiuse');

    for (final e in expected.entries) {
      final key = aliases[e.key];
      expect(key, isNotNull, reason: '缺少分类「${e.key}」');
      expect('/${types[key]}', e.value, reason: '「${e.key}」路径不对');
    }

    // 中文名不能重复映射到同一个 key
    expect(aliases.length, aliases.values.toSet().length);

    // 顶部导航 3 项 + 分区面板 14 项
    expect(types.length, 17);
    expect(aliases.length, 17);
  });

  test('jiuse 列表类型与搜索 URL', () {
    final types = CrawlerConfig.getListTypes('jiuse');
    expect(types['list'], 'video');
    expect(types['videos'], 'videos');
    expect(types['vod'], 'vod');

    final aliases = CrawlerConfig.getListTypeAliases('jiuse');
    expect(aliases['蝌蚪'], 'videos');

    final su = CrawlerConfig.buildSearchUrl(
        'https://jiuse.icu', 'jiuse', '测试');
    expect(su, contains('/search?keywords='));
    expect(su, isNot(contains('search.htm')));
  });

  test('jiuse 卡片正则能从真实页面抓到站内视频', () {
    final file = File('D:/91/site_jiuse_icu.html');
    if (!file.existsSync()) {
      markTestSkipped('样本页面不存在');
      return;
    }
    final html = file.readAsStringSync(encoding: utf8);

    final cards = CrawlerConfig.jiuseCardPattern.allMatches(html).toList();
    print('卡片数: ${cards.length}');
    expect(cards, isNotEmpty);

    int inSite = 0;
    int ads = 0;
    for (final c in cards) {
      final href =
          CrawlerConfig.jiuseVideoHrefPattern.firstMatch(c.group(1)!);
      if (href != null) {
        inSite++;
        expect(href.group(1)!.startsWith('/'), isTrue,
            reason: '只应匹配站内相对路径');
      } else {
        ads++;
      }
    }
    print('站内视频: $inSite, 广告/非视频: $ads');
    expect(inSite, greaterThan(0));
  });
}
