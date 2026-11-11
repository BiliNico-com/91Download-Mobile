import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

/// 网络环境快照
///
/// 目的只有一个：出问题时用户发来日志，能直接看出
/// 「当时是 WiFi 还是流量、有没有开代理软件、出口公网 IP 落在哪」，
/// 不用再反复追问。判定逻辑见 [verdict]。
class NetworkSnapshot {
  // ── 系统侧（原生通道采集）──
  final bool wifi;
  final bool cellular;
  final bool ethernet;

  /// 是否有 VPN 类型网络在跑。代理软件（Clash / v2rayNG 等）常以 VPN 模式接管全部流量，
  /// 这种模式下本 App 的 Dio 请求也会被接管，是最确定的「走了代理」信号。
  final bool vpn;

  /// 系统是否认为这条网络真的能上网
  final bool validated;

  /// 是否计费网络（流量）
  final bool? metered;

  /// 系统代理（WiFi 高级设置里的代理 / 全局代理）
  final String? systemProxy;

  /// 本机在该网络下的内网 IPv4
  final String? localIpv4;

  // ── 出口侧（公网 IP 探测）──
  final String? publicIp;
  final String? country;
  final String? region;
  final String? city;
  final String? isp;
  final String? org;
  final String? asn;

  /// ip-api 的代理 / 机房 / 移动网络标记
  final bool? flaggedProxy;
  final bool? flaggedHosting;
  final bool? flaggedMobile;

  /// 探测来源（哪个接口回的）
  final String? source;

  /// 探测失败原因（成功时为 null）
  final String? error;

  const NetworkSnapshot({
    this.wifi = false,
    this.cellular = false,
    this.ethernet = false,
    this.vpn = false,
    this.validated = false,
    this.metered,
    this.systemProxy,
    this.localIpv4,
    this.publicIp,
    this.country,
    this.region,
    this.city,
    this.isp,
    this.org,
    this.asn,
    this.flaggedProxy,
    this.flaggedHosting,
    this.flaggedMobile,
    this.source,
    this.error,
  });

  /// 接入方式的中文描述
  String get transportText {
    final parts = <String>[];
    if (wifi) parts.add('WiFi');
    if (cellular) parts.add('移动网络');
    if (ethernet) parts.add('有线');
    if (vpn) parts.add('VPN');
    if (parts.isEmpty) return '未知';
    return parts.join('+');
  }

  bool get _probed => publicIp != null && publicIp!.isNotEmpty;

  /// 出口归属：国家 省 市
  String get locationText {
    final parts = <String>[];
    for (final v in [country, region, city]) {
      if (v != null && v.isNotEmpty && !parts.contains(v)) parts.add(v);
    }
    return parts.isEmpty ? '未知' : parts.join(' ');
  }

  /// 运营商描述，取第一个非空的
  String get carrierText {
    for (final v in [isp, org, asn]) {
      if (v != null && v.isNotEmpty) return v;
    }
    return '未知';
  }

  /// 本机内网地址是否落在代理软件常用的 TUN 网段
  ///
  /// Clash 的 TUN 默认给设备下发 198.18.0.0/15 的地址；
  /// 看到这个网段基本可以断定有代理在接管流量。
  bool get _inTunRange {
    final ip = localIpv4;
    if (ip == null) return false;
    return ip.startsWith('198.18.') || ip.startsWith('198.19.');
  }

  /// 命中的「走代理」证据，按可信度排序
  List<String> get proxySignals {
    final list = <String>[];
    if (vpn) list.add('有 VPN 网络在运行，代理软件会接管本 App 全部流量');
    if (_inTunRange) list.add('内网地址 $localIpv4 落在 198.18/15（代理软件 TUN 常用网段）');
    if (flaggedProxy == true) list.add('出口 IP 被公开库标记为代理/VPN');
    if (flaggedHosting == true) list.add('出口 IP 属于机房（IDC），常见于代理节点');
    return list;
  }

  /// 系统代理只记一条说明，不计入「走代理」判定
  ///
  /// 本 App 的网络请求走 Dart 的 HttpClient，默认不读 Android 的系统代理设置，
  /// 所以即使 WiFi 里填了代理，对本 App 也通常不生效 —— 不能据此说走了代理。
  String? get systemProxyNote {
    final p = systemProxy;
    if (p == null || p.isEmpty) return null;
    return '系统代理 $p（Dart HttpClient 默认不读系统代理，对本 App 一般不生效）';
  }

  /// 最终判定
  String get verdict {
    if (proxySignals.isNotEmpty) return '疑似走代理';
    if (!_probed) {
      return error == null ? '未知（未探测出口 IP）' : '未知（出口 IP 探测失败）';
    }
    return '疑似直连';
  }

  /// 一句话摘要，给界面显示用
  String get oneLine {
    final ip = _probed ? publicIp! : '出口 IP 获取失败';
    final loc = _probed ? locationText : '-';
    return '$transportText · $ip · $loc · $verdict';
  }

  /// 写进日志的多行文本
  List<String> describeLines() {
    final lines = <String>[];
    final online = validated ? '已联网' : '未验证联网';
    final billing = metered == null
        ? '计费未知'
        : (metered! ? '计费网络(流量)' : '非计费网络');
    lines.add('网络接入: $transportText | $online | $billing');
    final ip = localIpv4 ?? '未知';
    final proxy = systemProxy ?? '无';
    lines.add('本机内网 IP: $ip | 系统代理: $proxy');
    if (_probed) {
      lines.add('出口公网 IP: $publicIp（来源 $source）');
      lines.add('出口归属: $locationText | 运营商: $carrierText');
      if (flaggedProxy != null || flaggedHosting != null || flaggedMobile != null) {
        final p = _tri(flaggedProxy);
        final h = _tri(flaggedHosting);
        final m = _tri(flaggedMobile);
        lines.add('出口标记: proxy=$p hosting=$h mobile=$m');
      }
    } else {
      final why = error ?? '无可用接口返回';
      lines.add('出口公网 IP: 获取失败（$why）');
    }
    final signals = proxySignals;
    if (signals.isNotEmpty) {
      lines.add('网络判定: $verdict —— ' + signals.join('；'));
    } else {
      lines.add('网络判定: $verdict —— 未发现代理痕迹');
    }
    final note = systemProxyNote;
    if (note != null) lines.add('补充: $note');
    return lines;
  }

  static String _tri(bool? v) => v == null ? '未知' : (v ? '是' : '否');
}

/// 网络环境采集
///
/// 原生侧拿「接入方式 / 系统代理 / 本机内网 IP」，
/// 公网侧拿「出口 IP 与其归属」，两者合起来才能判断直连还是代理。
class NetworkInfoService {
  static const MethodChannel _channel =
      MethodChannel('com.bilinico.download_91/network_info');

  /// 最近一次采集结果，供「下载失败」这类地方零成本引用
  static NetworkSnapshot? last;

  /// 采集缓存：短时间内重复调用不重复发请求
  static const Duration _cacheTtl = Duration(seconds: 60);
  static DateTime? _lastAt;

  /// 出口 IP 探测接口，按顺序尝试，第一个成功的就用
  ///
  /// ip-api 免费版只允许 http（https 直接返回 {"status":"fail"}），
  /// 它的字段最全（含 proxy / hosting 标记），所以排第一。
  static const List<String> _probes = [
    'http://ip-api.com/json/?lang=zh-CN&fields=status,country,regionName,city,isp,org,as,query,proxy,hosting,mobile',
    'https://myip.ipip.net',
    'https://ipwho.is/',
    'https://ipinfo.io/json',
  ];

  /// 采集一次网络环境
  ///
  /// [force] 为 true 时忽略 60 秒缓存。任何异常都不会抛出，
  /// 失败信息放进 [NetworkSnapshot.error]。
  static Future<NetworkSnapshot> collect({bool force = false}) async {
    final cached = last;
    if (!force && cached != null && _lastAt != null) {
      if (DateTime.now().difference(_lastAt!) < _cacheTtl) return cached;
    }

    // 1. 系统侧
    Map<String, dynamic> native = const {};
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('getNetworkInfo');
      if (raw != null) native = raw;
    } catch (_) {
      // 桌面端 / 通道未注册：只有出口 IP 部分可用，不影响主流程
    }

    // 2. 出口侧
    final probe = await _probePublicIp();

    final snap = NetworkSnapshot(
      wifi: native['wifi'] == true,
      cellular: native['cellular'] == true,
      ethernet: native['ethernet'] == true,
      vpn: native['vpn'] == true,
      validated: native['validated'] == true,
      metered: native['metered'] is bool ? native['metered'] as bool : null,
      systemProxy: _str(native['httpProxy']),
      localIpv4: _str(native['localIpv4']),
      publicIp: probe.ip,
      country: probe.country,
      region: probe.region,
      city: probe.city,
      isp: probe.isp,
      org: probe.org,
      asn: probe.asn,
      flaggedProxy: probe.proxy,
      flaggedHosting: probe.hosting,
      flaggedMobile: probe.mobile,
      source: probe.source,
      error: probe.error,
    );
    last = snap;
    _lastAt = DateTime.now();
    return snap;
  }

  static String? _str(Object? v) {
    final s = v?.toString().trim();
    if (s == null || s.isEmpty) return null;
    return s;
  }

  /// 依次尝试各接口，第一个解析出 IP 的就返回
  static Future<_ProbeResult> _probePublicIp() async {
    String? lastError;
    for (final url in _probes) {
      try {
        final dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 4),
          receiveTimeout: const Duration(seconds: 4),
          sendTimeout: const Duration(seconds: 4),
          followRedirects: true,
          responseType: ResponseType.plain,
          // 接口回 4xx 时也算「有响应」，交给解析判断
          validateStatus: (code) => code != null && code < 500,
        ));
        final res = await dio.get<String>(url);
        final parsed = _parse(url, res.data ?? '');
        if (parsed != null) return parsed;
        lastError = '接口返回无法解析';
      } catch (e) {
        lastError = _shortError(e);
      }
    }
    return _ProbeResult(error: lastError ?? '全部接口均失败');
  }

  static String _shortError(Object e) {
    if (e is DioException) {
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
          return '连接超时';
        case DioExceptionType.receiveTimeout:
          return '读取超时';
        case DioExceptionType.connectionError:
          return '连接失败';
        default:
          return e.message ?? e.type.name;
      }
    }
    return e.toString();
  }

  static _ProbeResult? _parse(String url, String body) {
    if (body.isEmpty) return null;
    final host = Uri.tryParse(url)?.host ?? url;

    // ip-api.com：字段最全，含 proxy/hosting 标记
    if (host.contains('ip-api.com')) {
      final data = _asMap(body);
      if (data == null || data['status'] != 'success') return null;
      return _ProbeResult(
        source: 'ip-api.com',
        ip: _str(data['query']),
        country: _str(data['country']),
        region: _str(data['regionName']),
        city: _str(data['city']),
        isp: _str(data['isp']),
        org: _str(data['org']),
        asn: _str(data['as']),
        proxy: data['proxy'] is bool ? data['proxy'] as bool : null,
        hosting: data['hosting'] is bool ? data['hosting'] as bool : null,
        mobile: data['mobile'] is bool ? data['mobile'] as bool : null,
      );
    }

    // ipip.net：纯文本「当前 IP：x.x.x.x  来自于：中国 湖北 武汉  联通」
    if (host.contains('ipip.net')) {
      final m = RegExp(r'(\d+\.\d+\.\d+\.\d+)').firstMatch(body);
      if (m == null) return null;
      final tail = body.split('来自于：').length > 1 ? body.split('来自于：')[1] : '';
      final segs = tail
          .trim()
          .split(RegExp(r'\s+'))
          .where((s) => s.isNotEmpty)
          .toList();
      return _ProbeResult(
        source: 'myip.ipip.net',
        ip: m.group(1),
        country: segs.isNotEmpty ? segs[0] : null,
        region: segs.length > 1 ? segs[1] : null,
        city: segs.length > 2 ? segs[2] : null,
        isp: segs.length > 3 ? segs.sublist(3).join(' ') : null,
      );
    }

    // ipwho.is：JSON，运营商在 connection 里
    if (host.contains('ipwho.is')) {
      final data = _asMap(body);
      if (data == null || data['success'] == false) return null;
      final conn = data['connection'];
      final connMap = conn is Map ? Map<String, dynamic>.from(conn) : const <String, dynamic>{};
      return _ProbeResult(
        source: 'ipwho.is',
        ip: _str(data['ip']),
        country: _str(data['country']),
        region: _str(data['region']),
        city: _str(data['city']),
        isp: _str(connMap['isp']),
        org: _str(connMap['org']),
        asn: connMap['asn'] == null ? null : 'AS' + connMap['asn'].toString(),
      );
    }

    // ipinfo.io：JSON，只有 org
    if (host.contains('ipinfo.io')) {
      final data = _asMap(body);
      if (data == null) return null;
      return _ProbeResult(
        source: 'ipinfo.io',
        ip: _str(data['ip']),
        country: _str(data['country']),
        region: _str(data['region']),
        city: _str(data['city']),
        org: _str(data['org']),
      );
    }
    return null;
  }

  static Map<String, dynamic>? _asMap(String body) {
    try {
      final raw = jsonDecode(body);
      if (raw is Map) return Map<String, dynamic>.from(raw);
    } catch (_) {}
    return null;
  }
}

class _ProbeResult {
  final String? source;
  final String? ip;
  final String? country;
  final String? region;
  final String? city;
  final String? isp;
  final String? org;
  final String? asn;
  final bool? proxy;
  final bool? hosting;
  final bool? mobile;
  final String? error;

  const _ProbeResult({
    this.source,
    this.ip,
    this.country,
    this.region,
    this.city,
    this.isp,
    this.org,
    this.asn,
    this.proxy,
    this.hosting,
    this.mobile,
    this.error,
  });
}
