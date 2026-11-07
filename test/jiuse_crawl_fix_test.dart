import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:download_91/crawler/config.dart';
import 'package:download_91/crawler/crawler_core.dart';

/// jiuse 系（91porny / jiuse.icu）爬取回归测试
///
/// 全部基于 D:/91 下的真实页面样本，不依赖网络。
/// 覆盖 5 项已修缺陷：
///   A 蝌蚪卡片 /videos/view/{id}/{hash}/ 被整批丢弃
///   B 封面协议相对地址（//cdn/x.jpg）拼错
///   C 页面无分页控件导致无限翻页
///   D 作者主页 URL / 解析器走错分支
///   E 作者搜索 URL / 解析器走错分支
void main() {
  final home = File('D:/91/site_jiuse_icu.html');
  final search = File('D:/91/jiuse_search.html');

  String? read(File f) =>
      f.existsSync() ? f.readAsStringSync(encoding: utf8) : null;

  group('缺陷A：三种详情路径都要认得', () {
    test('蝌蚪两段路径不再被当成广告丢弃', () {
      const hrefs = [
        '/vod/view/SxeO',
        '/video/view/8fa43eb9a5b88b2f0e5f',
        '/videos/view/127663/410ed2e1f969cb2d31254a32fec95c0a/',
      ];
      for (final h in hrefs) {
        final m = CrawlerConfig.jiuseVideoHrefPattern
            .firstMatch('<a href="$h">');
        expect(m, isNotNull, reason: '应匹配 $h');
        expect(m!.group(1), h);
      }
    });

    test('站外广告仍然排除', () {
      const ads = [
        '<a href="https://8743.n87436130.vip/?cid=1">',
        '<a href="/author/babybaby1">',
        '<a href="/search?keywords=x">',
      ];
      for (final a in ads) {
        expect(CrawlerConfig.jiuseVideoHrefPattern.firstMatch(a), isNull,
            reason: '不应匹配 $a');
      }
    });

    test('id 取 /view/ 后第一段', () {
      expect(CrawlerConfig.jiuseVideoId('/vod/view/SxeO'), 'SxeO');
      expect(CrawlerConfig.jiuseVideoId('/video/view/8fa43eb9a5b88b2f0e5f'),
          '8fa43eb9a5b88b2f0e5f');
      expect(
          CrawlerConfig.jiuseVideoId(
              '/videos/view/127663/410ed2e1f969cb2d31254a32fec95c0a/'),
          '127663');
    });

    test('真实首页样本：解析条数从 21 提升到 33', () {
      final html = read(home);
      if (html == null) return markTestSkipped('样本不存在');
      final core = CrawlerCore(baseUrl: 'https://jiuse.icu');
      final videos = core.parseJiuseListForTest(html);
      // 旧实现只认单段 id：21 条；修复后应包含 12 张蝌蚪卡
      expect(videos.length, greaterThanOrEqualTo(30));
      expect(videos.any((v) => v.id == '127663'), isTrue,
          reason: '蝌蚪视频 127663 必须出现在结果里');
      expect(videos.every((v) => v.url.startsWith('https://jiuse.icu/')), isTrue);
      // 站外广告一条都不能进来
      expect(videos.any((v) => v.url.contains('n87436130')), isFalse);
    });
  });

  group('缺陷B：封面地址补全', () {
    test('协议相对地址补 https', () {
      expect(
        CrawlerConfig.resolveJiuseAssetUrl(
            'https://jiuse.icu', '//int.ucloud165.xyz/thumb/1.jpg'),
        'https://int.ucloud165.xyz/thumb/1.jpg',
      );
    });

    test('站内相对地址补 baseUrl', () {
      expect(
        CrawlerConfig.resolveJiuseAssetUrl('https://jiuse.icu', '/static/a.jpg'),
        'https://jiuse.icu/static/a.jpg',
      );
    });

    test('绝对地址原样返回', () {
      const u = 'https://cdn.a.com/1.jpg';
      expect(CrawlerConfig.resolveJiuseAssetUrl('https://jiuse.icu', u), u);
    });

    test('真实样本里不再出现双斜杠拼错', () {
      final html = read(home);
      if (html == null) return markTestSkipped('样本不存在');
      final core = CrawlerCore(baseUrl: 'https://jiuse.icu');
      final videos = core.parseJiuseListForTest(html);
      final covers = videos.map((v) => v.cover).whereType<String>().toList();
      expect(covers, isNotEmpty);
      for (final c in covers) {
        expect(c.contains('jiuse.icu//'), isFalse, reason: '拼错的封面: $c');
        expect(c.startsWith('http'), isTrue, reason: '封面必须是绝对地址: $c');
      }
    });
  });

  group('缺陷C：无分页控件时的翻页判据', () {
    test('空页即结束', () {
      expect(
          CrawlerConfig.jiusePageHasMore(
              itemCount: 0, page: 1, signature: '', lastSignature: ''),
          isFalse);
    });

    test('与上一页完全相同即结束', () {
      expect(
          CrawlerConfig.jiusePageHasMore(
            itemCount: 20,
            page: 3,
            signature: 'a,b,c',
            lastSignature: 'a,b,c',
          ),
          isFalse);
    });

    test('条数不足一页即结束', () {
      expect(
          CrawlerConfig.jiusePageHasMore(
              itemCount: 5, page: 2, signature: 'x', lastSignature: 'y'),
          isFalse);
    });

    test('满页且内容不同则继续', () {
      expect(
          CrawlerConfig.jiusePageHasMore(
              itemCount: 20, page: 2, signature: 'x', lastSignature: 'y'),
          isTrue);
    });

    test('走真实入口：第二页同内容判定结束', () {
      final html = read(home);
      if (html == null) return markTestSkipped('样本不存在');
      final core = CrawlerCore(baseUrl: 'https://jiuse.icu');
      final page1 = core.parseJiuseListForTest(html);
      core.applyPaginationForTest(html, 1, page1);
      expect(core.lastRequestHasMore, isTrue, reason: '首页满页应继续');
      // 越界页回放同一份内容 → 必须停
      core.applyPaginationForTest(html, 2, page1);
      expect(core.lastRequestHasMore, isFalse);
    });
  });

  group('缺陷D：作者主页', () {
    test('dashen 前缀必须保留', () {
      expect(CrawlerConfig.jiuseAuthorId('author', 'babybaby1'), 'babybaby1');
      expect(CrawlerConfig.jiuseAuthorId('dashen', 'Charles599'),
          'dashen/Charles599');
    });

    test('真实样本：站内卡片的作者与 authorId 都不为空', () {
      final html = read(home);
      if (html == null) return markTestSkipped('样本不存在');
      final core = CrawlerCore(baseUrl: 'https://jiuse.icu');
      final videos = core.parseJiuseListForTest(html);
      final withAuthor = videos.where((v) => (v.author ?? '').isNotEmpty).toList();
      expect(withAuthor.length, greaterThanOrEqualTo(15));
      // dashen 系作者在样本里是 Charles599 / 369242358
      final dashen = videos.where((v) => (v.authorId ?? '').startsWith('dashen/'));
      expect(dashen, isNotEmpty, reason: 'dashen 前缀丢失会导致作者主页 404');
    });
  });

  group('缺陷E：作者搜索', () {
    test('能从搜索结果页的用户区块拿到作者', () {
      final html = read(search);
      if (html == null) return markTestSkipped('样本不存在');
      final authors = <String>[];
      for (final m
          in CrawlerConfig.jiuseAuthorBadgePattern.allMatches(html)) {
        authors.add('${m.group(2)!.trim()}|${m.group(3)!.trim()}');
      }
      expect(authors.length, 8);
      expect(authors, contains('Testgogogo|Testgogogo'));
      expect(authors, contains('test7557737|test7557737'));
      // 视频卡片里的作者（如 sistit）不属于用户区块，不应混进来
      expect(authors.any((a) => a.startsWith('sistit|')), isFalse);
    });
  });
}
