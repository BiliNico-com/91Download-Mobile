import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:download_91/crawler/config.dart';
import 'package:download_91/crawler/crawler_core.dart';
import 'package:download_91/models/video_info.dart';

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

  test('分区分页走路径式 URL，第 2 页页脚没有更靠后的页码时停', () async {
    if (!online) return markTestSkipped('mock 站点未启动');
    final core = makeCore();
    // mock 端：/video/category/hd 回放带完整分页控件的真实样本，
    // /video/category/hd/2 回放同一份但删掉了 <ul class="pagination">
    final page1 = await core.getVideoList('hd', 1);
    expect(page1.length, greaterThanOrEqualTo(20));
    expect(core.lastRequestHasMore, isTrue, reason: '页脚有 2..17152 的链接');

    final page2 = await core.getVideoList('hd', 2);
    expect(page2, isNotEmpty, reason: '第 2 页仍应有内容');
    expect(core.lastRequestHasMore, isFalse, reason: '没有更靠后的页码必须停');
  });

  test('详情页能从 data-src 取到 m3u8', () async {
    if (!online) return markTestSkipped('mock 站点未启动');
    final core = makeCore();
    final list = await core.getVideoList('list', 1);
    final detail = await core.getVideoDetail(list.first);
    expect(detail?.m3u8Url ?? '', contains('.m3u8'));
  });

  test('data-src 是样片时改走 /apiDownloadUrl 取真实地址', () async {
    if (!online) return markTestSkipped('mock 站点未启动');
    final core = makeCore();
    // mock 端 /vod/view/SAMPLESRC 回放的详情页里 data-src 被换成
    // //cdn2.jiuse2.cloud/hlsd/js10/index.m3u8（站点内置 12 秒样片）
    final sample = VideoInfo(
      id: 'SAMPLESRC',
      url: 'http://127.0.0.1:8899/vod/view/SAMPLESRC',
      title: '样片测试',
    );
    final detail = await core.getVideoDetail(sample);
    expect(detail, isNotNull);
    final url = detail!.m3u8Url ?? '';
    expect(CrawlerConfig.isJiuseSampleUrl(url), isFalse,
        reason: '样片地址必须被替换成真实地址');
    expect(url, contains('e7bc985da2f0a3d3a83bfc04396f0fc7'));
    expect(url, contains('.m3u8'));
  });

  test('接口不可用时保留原样片地址，不让整条链路失败', () async {
    if (!online) return markTestSkipped('mock 站点未启动');
    final core = makeCore();
    // mock 端 /vod/view/NOAPI 的详情页是样片，且 /apiDownloadUrl/js/noapi
    // 回一段「VIP会员才能下载」的非 URL 文本，模拟接口拒绝。
    final sample = VideoInfo(
      id: 'NOAPI',
      url: 'http://127.0.0.1:8899/vod/view/NOAPI',
      title: '样片测试',
    );
    final detail = await core.getVideoDetail(sample);
    expect(detail, isNotNull, reason: '接口失败不应让详情解析整条失败');
    final url = detail!.m3u8Url ?? '';
    expect(CrawlerConfig.isJiuseSampleUrl(url), isTrue,
        reason: '取不到真实地址时保留原样片地址');
  });
}
