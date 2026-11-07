import 'package:flutter_test/flutter_test.dart';
import 'package:download_91/crawler/config.dart';

void main() {
  test('porn91 与 original 节点表必须完全隔离', () {
    final p91 = CrawlerConfig.nodesFor('porn91');
    final ori = CrawlerConfig.nodesFor('original');

    final p91Hosts = p91.map((n) => n.host).where((h) => h.isNotEmpty).toSet();
    final oriHosts = ori.map((n) => n.host).where((h) => h.isNotEmpty).toSet();

    print('porn91 节点: $p91Hosts');
    print('original 节点: $oriHosts');

    expect(p91Hosts.intersection(oriHosts), isEmpty,
        reason: '两套节点不能有交集');
    expect(p91Hosts, containsAll(CrawlerConfig.porn91Hosts));
    expect(oriHosts, containsAll(CrawlerConfig.originalHosts));
  });

  test('按类型查找节点不会串台', () {
    // porn91 的节点在 original 里找不到，应回落到「自动」
    final cross = CrawlerConfig.nodeByHost('original', 'la.btc620.com');
    expect(cross.host, '', reason: 'original 不认识 porn91 的服务器');

    final cross2 = CrawlerConfig.nodeByHost('porn91', 'cdn.hdcdn.store');
    expect(cross2.host, '', reason: 'porn91 不认识 original 的线路');

    // 各自的能找到
    expect(CrawlerConfig.nodeByHost('porn91', 'la.btc620.com').host,
        'la.btc620.com');
    expect(CrawlerConfig.nodeByHost('original', 'shark.hdcdn.store').host,
        'shark.hdcdn.store');
  });

  test('host 白名单按类型隔离', () {
    expect(CrawlerConfig.hostsFor('porn91').contains('cdn.hdcdn.store'), isFalse);
    expect(CrawlerConfig.hostsFor('original').contains('la.btc620.com'),
        isFalse);
    expect(CrawlerConfig.hostsFor('porn91').contains('la.btc620.com'), isTrue);
    expect(CrawlerConfig.hostsFor('original').contains('cdn.hdcdn.store'),
        isTrue);
  });
}
