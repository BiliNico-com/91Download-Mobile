import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:download_91/crawler/crawler_core.dart';

/// 端到端回归：对着本地 mock 站点跑完整抓取链路。
///
/// mock 站点用 D:\91\_mock_server.py 起，回放 D:\91 下真实保存的 jiuse 页面：
///   python _mock_server.py 8899
/// 服务器没起时整组跳过，不影响 CI。
void main() {
  const base = 'http://127.0.0.1:8899';
  late bool online;

  setUpAll(() async {
    try {
      final s = await Socket.connect('127.0.0.1', 8899,
          timeout: const Duration(milliseconds: 300));
      s.destroy();
      online = true;
    } catch (_) {
      online = false;
    }
  });

  CrawlerCore makeCore() => CrawlerCore(
        baseUrl: base,
        siteType: 'jiuse',
        dio: Dio(BaseOptions(connectTimeout: const Duration(seconds: 5))),
      );

  test('越界页回放同一份内容时分页必须停', () async {
    if (!online) return markTestSkipped('mock 站点未启动');
    final core = makeCore();
    final page1 = await core.getVideoList('list', 1);
    expect(page1.length, greaterThanOrEqualTo(30));
    expect(core.lastRequestHasMore, isTrue, reason: '满页应继续');
    final page2 = await core.getVideoList('list', 2);
    expect(page2.length, page1.length);
    expect(core.lastRequestHasMore, isFalse, reason: '内容相同必须停');
  });

  test('作者搜索能拿到用户区块的作者', () async {
    if (!online) return markTestSkipped('mock 站点未启动');
    final authors = await makeCore().searchAuthors('test');
    expect(authors.length, 8);
    expect(authors.map((a) => a.name), contains('Testgogogo'));
  });

  test('作者主页走 /author/ 分支并能解析出视频', () async {
    if (!online) return markTestSkipped('mock 站点未启动');
    final core = makeCore();
    final authors = await core.searchAuthors('test');
    final videos = await core.getAuthorVideos(authors.first.id);
    expect(videos, isNotEmpty);
  });

  test('详情页能从 data-src 取到 m3u8', () async {
    if (!online) return markTestSkipped('mock 站点未启动');
    final core = makeCore();
    final list = await core.getVideoList('list', 1);
    final detail = await core.getVideoDetail(list.first);
    expect(detail?.m3u8Url ?? '', contains('.m3u8'));
  });
}
