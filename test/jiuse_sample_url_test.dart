import 'package:flutter_test/flutter_test.dart';
import 'package:download_91/crawler/config.dart';

/// 九色系「样片地址」识别 + 下载接口响应解析（纯离线）
void main() {
  group('isJiuseSampleUrl', () {
    test('识别 /hlsd/<名字>/index.m3u8 样片', () {
      expect(
          CrawlerConfig.isJiuseSampleUrl(
              'https://cdn2.jiuse2.cloud/hlsd/js10/index.m3u8'),
          isTrue);
      expect(
          CrawlerConfig.isJiuseSampleUrl(
              '//cdn2.jiuse2.cloud/hlsd/js10/index.m3u8'),
          isTrue);
      expect(
          CrawlerConfig.isJiuseSampleUrl(
              'https://cdn22.jiuse3.cloud/hlsd/abc/index.m3u8?t=1'),
          isTrue);
    });

    test('带 token 的真实地址不算样片', () {
      expect(
          CrawlerConfig.isJiuseSampleUrl(
              'https://cdn22.jiuse3.cloud/2026/11/05/'
              'e7bc985da2f0a3d3a83bfc04396f0fc7/index.m3u8?t=1794031276'),
          isFalse);
      expect(
          CrawlerConfig.isJiuseSampleUrl(
              'https://cdn.hdcdn.store/1699999/tok/hls/1257475/index.m3u8'),
          isFalse);
    });
  });

  group('jiuseDataIdFromHtml', () {
    test('从按钮上取 data-id', () {
      const html = '<div class="likeBtn" data-id="js/6660f5c5aa73924ffa3511a723ac1edb"></div>';
      expect(CrawlerConfig.jiuseDataIdFromHtml(html),
          'js/6660f5c5aa73924ffa3511a723ac1edb');
    });

    test('没有 data-id 时返回 null', () {
      expect(CrawlerConfig.jiuseDataIdFromHtml('<video data-src="x"></video>'),
          isNull);
    });

    test('真实详情页样本里能取到 id', () {
      // 取自 D:\91\jiuse_detail.html 的形态
      const html = '<a class="likeBtn" data-id="js/6660f5c5aa73924ffa3511a723ac1edb">'
          '<a class="dislikeBtn" data-id="js/6660f5c5aa73924ffa3511a723ac1edb">';
      expect(CrawlerConfig.jiuseDataIdFromHtml(html),
          'js/6660f5c5aa73924ffa3511a723ac1edb');
    });
  });

  group('jiuseApiDownloadUrl', () {
    test('拼出接口地址', () {
      expect(
          CrawlerConfig.jiuseApiDownloadUrl(
              'https://jiuse.icu', 'js/6660f5c5aa73924ffa3511a723ac1edb'),
          'https://jiuse.icu/apiDownloadUrl/js/6660f5c5aa73924ffa3511a723ac1edb');
    });
  });

  group('parseJiuseDownloadApiResponse', () {
    test('裸 URL 文本', () {
      expect(
          CrawlerConfig.parseJiuseDownloadApiResponse(
              'https://cdn22.jiuse3.cloud/2026/11/05/abc/index.m3u8?t=1&m=2'),
          'https://cdn22.jiuse3.cloud/2026/11/05/abc/index.m3u8?t=1&m=2');
    });

    test('带引号并转义 & 的文本', () {
      expect(
          CrawlerConfig.parseJiuseDownloadApiResponse(
              '"https://cdn22.jiuse3.cloud/a/index.m3u8?t=1&amp;m=2"\n'),
          'https://cdn22.jiuse3.cloud/a/index.m3u8?t=1&m=2');
    });

    test('JSON 包装', () {
      expect(
          CrawlerConfig.parseJiuseDownloadApiResponse(
              '{"code":0,"url":"https://cdn22.jiuse3.cloud/a/index.m3u8"}'),
          'https://cdn22.jiuse3.cloud/a/index.m3u8');
      expect(
          CrawlerConfig.parseJiuseDownloadApiResponse(
              '{"data":"https://cdn22.jiuse3.cloud/b/index.m3u8"}'),
          'https://cdn22.jiuse3.cloud/b/index.m3u8');
    });

    test('空响应与非 URL 返回 null', () {
      expect(CrawlerConfig.parseJiuseDownloadApiResponse(''), isNull);
      expect(CrawlerConfig.parseJiuseDownloadApiResponse('{"code":403}'), isNull);
      expect(CrawlerConfig.parseJiuseDownloadApiResponse('VIP会员才能下载'),
          isNull);
    });
  });

  group('九色系节点表', () {
    test('节点与白名单一致，且不含 cdn22', () {
      final nodes = CrawlerConfig.nodesFor('jiuse');
      expect(nodes.first.host, isEmpty, reason: '第一项必须是「自动」');
      expect(nodes.length, greaterThan(1));
      for (final n in nodes.where((n) => n.host.isNotEmpty)) {
        expect(CrawlerConfig.hostsFor('jiuse'), contains(n.host));
      }
      expect(CrawlerConfig.hostsFor('jiuse'),
          isNot(contains('cdn22.jiuse2.cloud')));
      expect(CrawlerConfig.hostsFor('jiuse'),
          isNot(contains('cdn22.jiuse3.cloud')));
    });

    test('三个系的节点表互不串味', () {
      expect(CrawlerConfig.nodesFor('porn91'), CrawlerConfig.porn91Nodes);
      expect(CrawlerConfig.nodesFor('jiuse'), CrawlerConfig.jiuseNodes);
      expect(CrawlerConfig.nodesFor('original'), CrawlerConfig.originalNodes);
      expect(CrawlerConfig.hostsFor('jiuse'),
          isNot(equals(CrawlerConfig.originalHosts)));
      expect(CrawlerConfig.hostsFor('jiuse'),
          isNot(equals(CrawlerConfig.porn91Hosts)));
    });

    test('nodeByHost 能按 host 找回，未知值回落自动', () {
      expect(CrawlerConfig.nodeByHost('jiuse', 'cdn2.jiuse3.cloud').host,
          'cdn2.jiuse3.cloud');
      expect(CrawlerConfig.nodeByHost('jiuse', 'cdn.hdcdn.store').host, isEmpty);
    });
  });
}
