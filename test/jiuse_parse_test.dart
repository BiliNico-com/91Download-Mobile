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
