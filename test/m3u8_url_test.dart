import 'package:flutter_test/flutter_test.dart';
import 'package:download_91/crawler/config.dart';
import 'package:download_91/crawler/crawler_core.dart';

void main() {
  const site = 'https://jiuse.icu';

  group('resolveAbsoluteUrl 补全协议', () {
    test('协议相对地址补 https:', () {
      expect(
        CrawlerConfig.resolveAbsoluteUrl(
            site, '//cdn2.jiuse2.cloud/hlsd/js10/index.m3u8'),
        'https://cdn2.jiuse2.cloud/hlsd/js10/index.m3u8',
      );
    });

    test('已有 scheme 原样返回', () {
      const u = 'https://cdn2.jiuse2.cloud/a/index.m3u8?t=1';
      expect(CrawlerConfig.resolveAbsoluteUrl(site, u), u);
      const h = 'http://cdn2.jiuse2.cloud/a/index.m3u8';
      expect(CrawlerConfig.resolveAbsoluteUrl(site, h), h);
    });

    test('站内绝对路径补站点域名', () {
      expect(CrawlerConfig.resolveAbsoluteUrl(site, '/static/a.jpg'),
          'https://jiuse.icu/static/a.jpg');
      expect(CrawlerConfig.resolveAbsoluteUrl(site, 'static/a.jpg'),
          'https://jiuse.icu/static/a.jpg');
    });

    test('缺 scheme 但形如 host/path 时补 https', () {
      expect(
        CrawlerConfig.resolveAbsoluteUrl(
            site, 'cdn2.jiuse2.cloud/hlsd/js10/index.m3u8'),
        'https://cdn2.jiuse2.cloud/hlsd/js10/index.m3u8',
      );
    });

    test('空串与空白原样返回', () {
      expect(CrawlerConfig.resolveAbsoluteUrl(site, ''), '');
      expect(CrawlerConfig.resolveAbsoluteUrl(site, '   '), '');
    });

    test('结果必须能被 Uri.parse 接受且带 scheme', () {
      final raw = CrawlerConfig.resolveAbsoluteUrl(
          site, '//cdn2.jiuse2.cloud/hlsd/js10/index.m3u8');
      final uri = Uri.parse(raw);
      expect(uri.hasScheme, isTrue);
      expect(uri.host, 'cdn2.jiuse2.cloud');
    });
  });

  group('_parseM3u8 切片地址', () {
    final core = CrawlerCore(baseUrl: site);
    const playlist = 'https://cdn2.jiuse2.cloud/hlsd/js10/index.m3u8';

    test('协议相对的切片行补 https，不拼成站内路径', () {
      const m3u8 = '#EXTM3U\n'
          '#EXT-X-VERSION:3\n'
          '#EXT-X-TARGETDURATION:2\n'
          '#EXTINF:2.0,\n'
          '//cdn2.jiuse2.cloud/hlsd/js10/index0.ts\n'
          '#EXTINF:2.0,\n'
          '//cdn2.jiuse2.cloud/hlsd/js10/index1.ts\n'
          '#EXT-X-ENDLIST';
      expect(core.parseM3u8ForTest(m3u8, playlist), [
        'https://cdn2.jiuse2.cloud/hlsd/js10/index0.ts',
        'https://cdn2.jiuse2.cloud/hlsd/js10/index1.ts',
      ]);
    });

    test('纯相对切片沿用 m3u8 所在目录', () {
      const m3u8 = '#EXTM3U\nindex0.ts\nindex1.ts';
      expect(core.parseM3u8ForTest(m3u8, playlist), [
        'https://cdn2.jiuse2.cloud/hlsd/js10/index0.ts',
        'https://cdn2.jiuse2.cloud/hlsd/js10/index1.ts',
      ]);
    });

    test('站根相对的切片保留 host', () {
      const m3u8 = '#EXTM3U\n/hlsd/js10/index0.ts';
      expect(core.parseM3u8ForTest(m3u8, playlist), [
        'https://cdn2.jiuse2.cloud/hlsd/js10/index0.ts',
      ]);
    });

    test('绝对切片地址原样保留', () {
      const m3u8 = '#EXTM3U\nhttps://cdn2.jiuse2.cloud/x/a.ts';
      expect(core.parseM3u8ForTest(m3u8, playlist), [
        'https://cdn2.jiuse2.cloud/x/a.ts',
      ]);
    });

    test('所有切片都是带 scheme 的绝对地址，且无重复斜杠', () {
      const m3u8 = '#EXTM3U\n'
          '//cdn2.jiuse2.cloud/hlsd/js10/index0.ts\n'
          '/hlsd/js10/index1.ts\n'
          'index2.ts\n'
          'https://cdn2.jiuse2.cloud/x/a.ts';
      final segs = core.parseM3u8ForTest(m3u8, playlist);
      expect(segs.length, 4);
      for (final s in segs) {
        expect(s.startsWith('https://'), isTrue, reason: s);
        expect(s.contains('////'), isFalse, reason: s);
        final rest = s.substring('https://'.length);
        expect(rest.startsWith('/'), isFalse, reason: s);
      }
    });
  });
}
