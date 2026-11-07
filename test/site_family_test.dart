import 'package:flutter_test/flutter_test.dart';
import 'package:download_91/crawler/config.dart';

/// 自定义站点「手动归类」相关的纯逻辑测试。
///
/// 这些逻辑决定列表模板、请求头、解密分支走哪一套，
/// 一旦回归，界面上看不出来（站点还是能选），但列表会一条都解析不出来。
void main() {
  group('detectSiteType 按域名推断', () {
    test('已知域名映射到对应家族', () {
      expect(CrawlerConfig.detectSiteType('https://91porn.com'), 'porn91');
      expect(CrawlerConfig.detectSiteType('https://91porny.com'), 'jiuse');
      expect(CrawlerConfig.detectSiteType('https://jiuse.icu'), 'jiuse');
      expect(CrawlerConfig.detectSiteType('https://ml0987.xyz'), 'original');
      expect(CrawlerConfig.detectSiteType('https://hsex.icu'), 'original');
    });

    test('www 前缀会被剥掉', () {
      expect(CrawlerConfig.detectSiteType('https://www.91porn.com'), 'porn91');
    });

    test('未知域名兜底 original', () {
      expect(CrawlerConfig.detectSiteType('https://unknown.example.com'),
          'original',
          reason: '没有映射信息时只能保守地按 original 处理');
    });

    test('非法 URL 不抛异常', () {
      expect(() => CrawlerConfig.detectSiteType('not a url'), returnsNormally);
      expect(CrawlerConfig.detectSiteType('not a url'), 'original');
    });
  });

  group('resolveSiteType 手动归类优先于域名推断', () {
    test('没有覆盖映射时等价于 detectSiteType', () {
      expect(CrawlerConfig.resolveSiteType('https://91porn.com', null),
          'porn91');
      expect(CrawlerConfig.resolveSiteType('https://91porn.com', {}), 'porn91');
    });

    test('覆盖值生效，即使域名本身能推断出别的家族', () {
      final overrides = {'https://91porny.com': 'original'};
      expect(CrawlerConfig.resolveSiteType('https://91porny.com', overrides),
          'original',
          reason: '用户明确指定过，就不能再按域名推断的 jiuse 走');
    });

    test('自定义镜像域名可以归类到九色系', () {
      final overrides = {'https://jiuse-mirror.example.com': 'jiuse'};
      expect(
          CrawlerConfig.resolveSiteType(
              'https://jiuse-mirror.example.com', overrides),
          'jiuse',
          reason: '这正是本功能的用途：未知域名不该被死锁在 original');
      // 没有覆盖时它就是 original
      expect(
          CrawlerConfig.resolveSiteType('https://jiuse-mirror.example.com', {}),
          'original');
    });

    test('覆盖值非法时忽略，回落到域名推断', () {
      final overrides = {'https://91porn.com': 'nonsense'};
      expect(CrawlerConfig.resolveSiteType('https://91porn.com', overrides),
          'porn91',
          reason: '脏数据不能把站点带进未知分支');
    });
  });

  group('normalizeSiteType', () {
    test('合法值原样返回', () {
      for (final family in CrawlerConfig.siteFamilies) {
        expect(CrawlerConfig.normalizeSiteType(family), family);
      }
    });

    test('null 与非法值兜底 original', () {
      expect(CrawlerConfig.normalizeSiteType(null), 'original');
      expect(CrawlerConfig.normalizeSiteType(''), 'original');
      expect(CrawlerConfig.normalizeSiteType('Porn91'), 'original',
          reason: '家族名是大小写敏感的常量，不做模糊匹配');
    });
  });

  group('presetsOfFamily', () {
    test('每个家族都有预设站点可用作删除后的回退', () {
      for (final family in CrawlerConfig.siteFamilies) {
        final presets = CrawlerConfig.presetsOfFamily(family);
        expect(presets, isNotEmpty,
            reason: '删掉当前自定义站点后要回退到同系预设，$family 不能为空');
      }
    });

    test('预设站点全部来自 availableSites 且家族自洽', () {
      for (final family in CrawlerConfig.siteFamilies) {
        for (final site in CrawlerConfig.presetsOfFamily(family)) {
          expect(CrawlerConfig.availableSites, contains(site));
          expect(CrawlerConfig.detectSiteType(site), family);
        }
      }
    });

    test('三个家族的预设并集等于 availableSites 全集', () {
      final all = <String>{};
      for (final family in CrawlerConfig.siteFamilies) {
        all.addAll(CrawlerConfig.presetsOfFamily(family));
      }
      expect(all.length, CrawlerConfig.availableSites.length,
          reason: '每个预设站点都必须属于某个家族，不能漏');
    });
  });
}
