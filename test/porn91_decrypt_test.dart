import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:download_91/crawler/config.dart';

void main() {
  test('porn91 标题/作者解密（真实页面样本）', () {
    final file = File('D:/91/p91_detail.html');
    if (!file.existsSync()) {
      markTestSkipped('样本页面不存在');
      return;
    }
    final html = file.readAsStringSync(encoding: utf8);

    final secret = CrawlerConfig.decodePorn91Secret(html);
    expect(secret, isNotNull, reason: '应能从隐藏节点解出信息');

    print('标题 = ${secret!.title}');
    print('作者 = ${secret.author}');
    print('时长 = ${secret.duration}');

    // 解密结果里不允许再残留变体选择符
    if (secret.title != null) {
      expect(secret.title!.contains(RegExp(r'[\uFE00-\uFE0F]')), isFalse,
          reason: '标题不应残留隐形字符');
      expect(secret.title!.trim(), isNotEmpty);
    }
    if (secret.author != null) {
      expect(secret.author!.contains(RegExp(r'[\uFE00-\uFE0F]')), isFalse,
          reason: '作者不应残留隐形字符');
    }
  });

  test('净化函数剥离变体选择符', () {
    const dirty = '北\uFE00\uFE01\uFE03\uFE03\uFE00\uFE02京50岁阿姨';
    expect(CrawlerConfig.stripInvisible(dirty), '北京50岁阿姨');

    const dirtyAuthor = 'w\uFE00\uFE01\uFE03\uFE03\uFE00\uFE02\uFE03\uFE00\uFE01\uFE02\uFE03xx198710';
    expect(CrawlerConfig.stripInvisible(dirtyAuthor), 'wxx198710');

    // 正常空格必须保留
    expect(CrawlerConfig.stripInvisible('The female dog on the sink'),
        'The female dog on the sink');
  });
}
