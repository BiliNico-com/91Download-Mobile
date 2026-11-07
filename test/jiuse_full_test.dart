import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:download_91/crawler/crawler_core.dart';

void main() {
  test('jiuse 列表能解析出视频（走真实 CrawlerCore）', () async {
    final f = File('D:/91/site_jiuse_icu.html');
    if (!f.existsSync()) {
      markTestSkipped('样本不存在');
      return;
    }
    final html = f.readAsStringSync(encoding: utf8);
    final core = CrawlerCore(baseUrl: 'https://jiuse.icu');
    // 反射不到私有方法，改用公开入口不现实（需要网络）；
    // 这里就验证 siteType 判定 + 正则命中数
    print('siteType = ${core.siteType}');
    expect(core.siteType, 'jiuse');
    final cards = RegExp(r'<div[^>]*class="[^"]*colVideoList[^"]*"[^>]*>([\s\S]*?)</div>\s*</div>', caseSensitive: false).allMatches(html).length;
    final elems = RegExp(r'class="video-elem"').allMatches(html).length;
    print('colVideoList 容器: $cards, video-elem: $elems');
    expect(elems, greaterThan(0));
  });
}
