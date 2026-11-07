/// 爬虫核心配置
/// 严格参照 Python 版本 _src/lib/__init__.py

import 'dart:convert';
import 'dart:typed_data';

/// porn91 播放页解密出来的真实信息
class Porn91Secret {
  final String? title;
  final String? author;
  final String? duration;
  const Porn91Secret({this.title, this.author, this.duration});

  bool get isEmpty =>
      (title == null || title!.isEmpty) &&
      (author == null || author!.isEmpty);
}

/// 一条视频 CDN 播放线路。
///
/// [host] 为空表示「自动」——不改写站点下发的地址。
class CdnNode {
  final String name;
  final String host;
  const CdnNode({required this.name, required this.host});

  /// 下拉框用：只有 host 非空时标识才是唯一的
  String get value => host;

  @override
  String toString() => host.isEmpty ? name : '$name ($host)';
}

class CrawlerConfig {
  // ==================== 站点类型配置 ====================
  
  /// 站点类型映射（域名 -> CMS类型）
  /// "original": ml0987/hsex 风格 CMS（list-{page}.htm 格式）
  /// "porn91": 91porn 风格 CMS（v.php?next=watch 格式）
  static const Map<String, String> siteTypes = {
    "91porn.com": "porn91",
    "91porny.com": "jiuse",
    "jiuse.icu": "jiuse",
    "ml0987.xyz": "original",
    "hsex.icu": "original",
    "hsex.men": "original",
  };
  
  /// 站点家族（界面分组顺序也按这个顺序）
  static const List<String> siteFamilies = ['porn91', 'jiuse', 'original'];

  /// 检测站点类型
  static String detectSiteType(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return "original";
    final domain = uri.host.replaceAll('www.', '');
    return siteTypes[domain] ?? "original";
  }

  /// 校验/兜底一个站点类型取值
  static String normalizeSiteType(String? type) =>
      siteFamilies.contains(type) ? type! : "original";

  /// 解析某个站点最终应使用的类型
  ///
  /// 用户手动添加的自定义站点，域名不在 [siteTypes] 里，靠 [detectSiteType]
  /// 只能兜底成 original —— 但用户可能就是拿九色系的镜像域名来用，
  /// 走 original 的解析模板会一条都解析不出来。所以允许为自定义站点
  /// 手动指定家族（[overrides]：站点 URL -> 家族），优先于域名推断。
  static String resolveSiteType(String url, Map<String, String>? overrides) {
    final manual = overrides?[url];
    if (manual != null && siteFamilies.contains(manual)) return manual;
    return detectSiteType(url);
  }

  /// 取某个家族下的预设站点（用于删除自定义站点后的回退）
  static List<String> presetsOfFamily(String family) =>
      availableSites.where((s) => detectSiteType(s) == family).toList();
  
  // ==================== 列表类型配置 ====================
  
  /// original CMS URL 模板（ml0987/hsex 风格）
  static const Map<String, String> listTypesOriginal = {
    "list": "list-{page}.htm",
    "top7": "top7_list-{page}.htm",
    "top": "top_list-{page}.htm",
    "5min": "5min_list-{page}.htm",
    "long": "long_list-{page}.htm",
  };
  
  /// original CMS 中文名映射
  static const Map<String, String> listTypeAliasesOriginal = {
    "视频": "list",
    "周榜": "top7",
    "月榜": "top",
    "5分钟+": "5min",
    "10分钟+": "long",
  };
  
  /// porn91 系列 URL 模板（91porn 风格）
  static const Map<String, String> listTypesV2 = {
    "list": "v.php?next=watch&page={page}",
    "ori": "v.php?category=ori&viewtype=basic&page={page}",
    "hot": "v.php?category=hot&viewtype=basic&page={page}",
    "top": "v.php?category=top&viewtype=basic&page={page}",
    "topm": "v.php?category=top&m=-1&viewtype=basic&page={page}",
    "long": "v.php?category=long&viewtype=basic&page={page}",
    "longer": "v.php?category=longer&viewtype=basic&page={page}",
    "rf": "v.php?category=rf&viewtype=basic&page={page}",
    "tf": "v.php?category=tf&viewtype=basic&page={page}",
    "hd": "v.php?category=hd&viewtype=basic&page={page}",
    "mf": "v.php?category=mf&viewtype=basic&page={page}",
    "md": "v.php?category=md&viewtype=basic&page={page}",
  };

  /// porn91 中文名映射
  static const Map<String, String> listTypeAliasesV2 = {
    "视频": "list",
    "91原创": "ori",
    "当前最热": "hot",
    "本月最热": "top",
    "每月最热": "topm",
    "10分钟以上": "long",
    "20分钟以上": "longer",
    "本月收藏": "tf",
    "最近加精": "rf",
    "高清": "hd",
    "本月讨论": "md",
    "收藏最多": "mf",
  };
  
  /// jiuse 站点（91porny / jiuse.icu）的列表路径
  ///
  /// 这套站用的是 9scdn/static 前端，分区有两处入口，必须都覆盖：
  ///
  /// ① 顶部导航（只有 3 个内容入口）
  ///      /video 视频，/videos 蝌蚪，/vod 精品
  /// ② 视频列表页里的分区面板 —— 移动端「选择分类」折叠面板
  ///    （class mobileCateContainer）与桌面端左侧栏（class cateContainer）
  ///    同源，都是 14 个 data-href，只是渲染容器不同：
  ///      /video/category/{slug}
  ///
  /// 只做 ① 会让 App 里只剩 3 个分类，与网页上看到的十几个分类对不上。
  static const Map<String, String> listTypesJiuse = {
    // ① 顶部导航
    "list": "video",
    "videos": "videos",
    "vod": "vod",
    // ② 分类面板（顺序与网页一致）
    "latest": "video/category/latest",
    "hd": "video/category/hd",
    "rf": "video/category/recent-favorite",
    "hot": "video/category/hot-list",
    "rating": "video/category/recent-rating",
    "nonpaid": "video/category/nonpaid",
    "ori": "video/category/ori",
    "long": "video/category/long-list",
    "longer": "video/category/longer-list",
    "discuss": "video/category/month-discuss",
    "tf": "video/category/top-favorite",
    "mf": "video/category/most-favorite",
    "top": "video/category/top-list",
    "last": "video/category/top-last",
  };

  /// jiuse 中文名映射（顺序即分类标签的展示顺序）
  static const Map<String, String> listTypeAliasesJiuse = {
    // 顶部导航
    "视频": "list",
    "蝌蚪": "videos",
    "精品": "vod",
    // 分类面板
    "最近更新": "latest",
    "高清视频": "hd",
    "最近加精": "rf",
    "当前最热": "hot",
    "最近得分": "rating",
    "非付费": "nonpaid",
    "91原创": "ori",
    "10分钟以上": "long",
    "20分钟以上": "longer",
    "本月讨论": "discuss",
    "本月收藏": "tf",
    "收藏最多": "mf",
    "本月最热": "top",
    "上月最热": "last",
  };

  /// jiuse 分类路径是否走「路径式分页」
  ///
  /// 实测（抓取 jiuse.icu/video 原始 HTML）：分类页第 2 页是
  ///   /video/category/hd/2
  /// 页码在路径里，不是 ?page=2。页脚分页链接与 id=goPage 的跳转表单
  /// （value="/video/category/hd/"）都是这么拼的。
  static bool jiuseUsesPathPaging(String path) {
    final p = path.startsWith("/") ? path.substring(1) : path;
    return p.startsWith("video/category/");
  }

  /// 构建 jiuse 列表页 URL
  ///
  /// 分类面板走 /path/{page}；顶部导航的 /video、/videos、/vod 未实测出
  /// 分页格式，沿用 ?page=N（N>1 时才带）。
  static String buildJiuseListUrl(String baseUrl, String path, int page) {
    final p = path.startsWith("/") ? path.substring(1) : path;
    if (page <= 1) return "$baseUrl/$p";
    if (jiuseUsesPathPaging(p)) return "$baseUrl/$p/$page";
    return "$baseUrl/$p?page=$page";
  }

  /// 获取列表类型映射（根据站点类型）
  static Map<String, String> getListTypes(String siteType) {
    if (siteType == "jiuse") return listTypesJiuse;
    return siteType == "porn91" ? listTypesV2 : listTypesOriginal;
  }
  
  /// 获取中文名映射（根据站点类型）
  static Map<String, String> getListTypeAliases(String siteType) {
    if (siteType == "jiuse") return listTypeAliasesJiuse;
    return siteType == "porn91" ? listTypeAliasesV2 : listTypeAliasesOriginal;
  }
  
  /// 构建搜索URL
  static String buildSearchUrl(String baseUrl, String siteType, String keyword, {int page = 1, String sort = "default"}) {
    if (siteType == "jiuse") {
      // jiuse 是 GET 表单：/search?keywords=xxx（分页用 &page=N）
      final kw = Uri.encodeComponent(keyword);
      return page <= 1
          ? "$baseUrl/search?keywords=$kw"
          : "$baseUrl/search?keywords=$kw&page=$page";
    }
    if (siteType == "porn91") {
      // porn91 风格搜索 URL（支持分页）
      // URL格式: search_result.php?search_id=xxx&search_type=search_videos&min_duration=&page=N
      return "$baseUrl/search_result.php?search_id=${Uri.encodeComponent(keyword)}&search_type=search_videos&min_duration=&page=$page";
    } else {
      // original 风格搜索 URL：第 1 页 search.htm（不带页码），第 2 页起 search-{page}.htm
      // 真实格式（用户实测）：
      //   第1页: search.htm?search=xxx[&sort=new/hot]
      //   第2页: search-2.htm?search=xxx[&sort=new/hot]
      final pagePath = page <= 1 ? "search.htm" : "search-$page.htm";
      String url = "$baseUrl/$pagePath?search=${Uri.encodeComponent(keyword)}";
      // 添加排序参数（default 时不添加）
      if (sort != "default") {
        url += "&sort=$sort";
      }
      return url;
    }
  }

  // ==================== 请求头 ====================
  
  /// 完整的浏览器请求头伪装（模拟Chrome浏览器 - 桌面版）
  static const Map<String, String> defaultHeaders = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
    "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
    // 注意：不设置Accept-Encoding，让Dio自动处理gzip解压
    "Connection": "keep-alive",
    "Upgrade-Insecure-Requests": "1",
    "Sec-Fetch-Dest": "document",
    "Sec-Fetch-Mode": "navigate",
    "Sec-Fetch-Site": "none",
    "Sec-Fetch-User": "?1",
    "Sec-CH-UA": '"Chromium";v="131", "Not_A Brand";v="24"',
    "Sec-CH-UA-Mobile": "?0",
    "Sec-CH-UA-Platform": '"Windows"',
    "Cache-Control": "no-cache",
    "Pragma": "no-cache",
  };
  
  /// 移动端请求头（模拟Android Chrome）
  /// 用于porn91站点，避免分类请求返回错误内容
  static const Map<String, String> mobileHeaders = {
    "User-Agent": "Mozilla/5.0 (Linux; Android 14; Pixel 7 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
    "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
    // 注意：不设置Accept-Encoding，让Dio自动处理gzip解压
    "Connection": "keep-alive",
    "Upgrade-Insecure-Requests": "1",
    "Sec-Fetch-Dest": "document",
    "Sec-Fetch-Mode": "navigate",
    "Sec-Fetch-Site": "none",
    "Sec-Fetch-User": "?1",
    "Sec-CH-UA": '"Chromium";v="131", "Not_A Brand";v="24"',
    "Sec-CH-UA-Mobile": "?1",
    "Sec-CH-UA-Platform": '"Android"',
    "Cache-Control": "no-cache",
    "Pragma": "no-cache",
  };
  
  /// 获取请求头（根据站点类型）
  static Map<String, String> getHeaders(String siteType) {
    // porn91 使用移动端请求头
    return siteType == "porn91" ? mobileHeaders : defaultHeaders;
  }

  // ==================== 站点配置 ====================
  
  static const List<String> availableSites = [
    "https://91porn.com",
    "https://91porny.com",
    "https://jiuse.icu",
    "https://ml0987.xyz",
    "https://hsex.icu",
    "https://hsex.men",
  ];

  /// 图片 CDN 域名（仅 porn91 使用）
  static const String imgCdnUrl = "https://1729130453.rsc.cdn77.org";

  /// 已知的广告片 ID。
  ///
  /// 91porn 播放页的 <source> 常常直接就是这条广告，
  /// 真实地址藏在 strencode2 里，必须避开。
  static const List<String> knownAdVideoIds = ['358999'];

  // ==================== 播放节点（视频 CDN 线路）====================

  // ---- 两套节点必须分开：porn91 和 original 用的是完全不同的 CDN ----
  //
  // porn91（91porn.com）：la.btc620.com / *.rsc.cdn77.org / cns.killcovid2021.com
  //   来自站点 /speed.php「选择速度最快的视频服务器」页。
  // original（hdcdn 系站点）：cdn/shark/fdc/shark-v6 .hdcdn.store
  //   来自站点播放页「切换播放节点」（/static/js/fastest_cdn.js）。
  //
  // 两者域名互不相通，混用会 100% 下不动，所以各存各的配置项、
  // 各用各的 host 白名单。

  /// porn91 的视频服务器（对应站点 /speed.php 的服务器 A / H / I）
  ///
  /// 站点切换方式是 POST speed.php 提交 video_server=A|H|I，由服务端会话记住。
  /// 其中 H、I 标注为「VIP 用户使用」，非会员只能在页面上看到但不能选；
  /// 不过实测把域名直接换成 I 仍可正常拉流（H 需要 secure 签名，会 403），
  /// 所以这里把三条都列出来，由用户自己按测速结果选择。
  static const List<CdnNode> porn91Nodes = [
    CdnNode(name: '自动（跟随站点）', host: ''),
    CdnNode(name: '服务器 A（默认）', host: 'la.btc620.com'),
    CdnNode(name: '服务器 H（VIP）', host: '1470423830.rsc.cdn77.org'),
    CdnNode(name: '服务器 I（VIP）', host: 'cns.killcovid2021.com'),
  ];

  /// porn91 站点自带服务器域名集合（用于判断该不该改写）
  static const Set<String> porn91Hosts = {
    'la.btc620.com',
    '1470423830.rsc.cdn77.org',
    'cns.killcovid2021.com',
  };

  /// original 站点的 CDN 线路（播放页「切换播放节点」）
  ///
  /// 站点实现只做 url.hostname = host，路径 / token / 查询参数全部原样保留。
  static const List<CdnNode> originalNodes = [
    CdnNode(name: '自动（跟随站点）', host: ''),
    CdnNode(name: '线路 1（默认）', host: 'cdn.hdcdn.store'),
    CdnNode(name: '线路 2（Shark）', host: 'shark.hdcdn.store'),
    CdnNode(name: '线路 3（FDC）', host: 'fdc.hdcdn.store'),
    CdnNode(name: '线路 4（IPv6-SK）', host: 'shark-v6.hdcdn.store'),
  ];

  /// original 站点自带 CDN 域名集合
  static const Set<String> originalHosts = {
    'cdn.hdcdn.store',
    'shark.hdcdn.store',
    'fdc.hdcdn.store',
    'shark-v6.hdcdn.store',
  };

  /// 按站点类型取节点列表
  static List<CdnNode> nodesFor(String siteType) =>
      siteType == 'porn91' ? porn91Nodes : originalNodes;

  /// 按站点类型取「可改写域名」白名单
  static Set<String> hostsFor(String siteType) =>
      siteType == 'porn91' ? porn91Hosts : originalHosts;

  /// 按站点类型 + host 找线路，找不到返回「自动」
  static CdnNode nodeByHost(String siteType, String? host) {
    for (final n in nodesFor(siteType)) {
      if (n.host == (host ?? '')) return n;
    }
    return nodesFor(siteType).first;
  }

  // ==================== porn91 标题/作者解密 ====================

  /// 解密站点藏在 `<i id="xd..." data-XXX="...">` 里的真实标题/作者。
  ///
  /// 91porn 的播放页会把真实标题、作者、时长加密后塞在一个隐藏的 <i> 标签里，
  /// 页面上可见的文本只是掺了大量变体选择符的占位符；真实值要等 JS 在
  /// 「随机 2~6 秒后」或「用户第一次滚动/点击/按键」时才替换进 DOM。
  /// 纯 HTTP 抓取永远等不到那一刻，所以必须自己解密，否则拿到的标题和作者
  /// 都是带隐形字符的假值。
  ///
  /// 算法（对应页面内联脚本的 dec 函数）：
  ///   base64 解码 → 与密钥逐字节异或 → UTF-8 解码
  /// 密钥（k）和值代码（m）都写在同一个 <script> 里。
  static Porn91Secret? decodePorn91Secret(String html) {
    try {
      // 隐藏节点：<i id="xdXXXX" data-PREFIX="..." data-PREFIXu="..." data-PREFIXd="...">
      final node = RegExp(
        r'<i[^>]*id="xd[0-9a-z]+"([^>]*)>',
        caseSensitive: false,
      ).firstMatch(html);
      if (node == null) return null;

      final attrs = <String, String>{};
      for (final m in RegExp(r'(data-[0-9a-z]+)="([^"]*)"')
          .allMatches(node.group(1)!)) {
        attrs[m.group(1)!] = m.group(2)!;
      }

      // 密钥与模式取自同页脚本：var m=0,...,k="5071dad6";
      final keyMatch = RegExp(r'k="([0-9a-fA-F]+)"').firstMatch(html);
      final modeMatch = RegExp(r'var\s+m=(\d+)').firstMatch(html);
      if (keyMatch == null) return null;
      final key = keyMatch.group(1)!;
      final mode = int.tryParse(modeMatch?.group(1) ?? '0') ?? 0;

      // data-PREFIX 是标题，后缀 u 是作者，后缀 d 是时长（秒）
      String? title;
      String? author;
      String? duration;
      for (final entry in attrs.entries) {
        final k = entry.key;
        if (!k.startsWith('data-')) continue;
        if (k.endsWith('u')) {
          author ??= _decryptPorn91(entry.value, key, mode);
        } else if (k.endsWith('d')) {
          final secs = int.tryParse(
              _decryptPorn91(entry.value, key, mode) ?? '');
          if (secs != null && secs > 0) {
            duration = '${(secs ~/ 3600).toString().padLeft(2, '0')}:'
                '${((secs ~/ 60) % 60).toString().padLeft(2, '0')}:'
                '${(secs % 60).toString().padLeft(2, '0')}';
          }
        } else {
          title ??= _decryptPorn91(entry.value, key, mode);
        }
      }

      if (title == null && author == null) return null;
      return Porn91Secret(title: title, author: author, duration: duration);
    } catch (_) {
      return null;
    }
  }

  /// 单个字段的解密：base64 → 异或 → UTF-8
  static String? _decryptPorn91(String value, String key, int mode) {
    if (value.isEmpty) return null;
    var s = value;
    // 与页面脚本保持一致：reverse 模式先把串倒过来再 base64 解码
    if (mode == 2) s = s.split('').reversed.join();
    final bytes = base64Decode(s);
    final keyBytes = key.codeUnits;
    final out = Uint8List(bytes.length);
    for (var i = 0; i < bytes.length; i++) {
      out[i] = bytes[i] ^ keyBytes[i % keyBytes.length];
    }
    var text = utf8.decode(out, allowMalformed: true);
    if (mode == 4) text = text.split('').reversed.join();
    return stripInvisible(text).trim();
  }

  // ==================== 文本净化 ====================

  /// 页面里夹在汉字中间的隐形字符（变体选择符 / 零宽字符）。
  ///
  /// 91porn 一类站点会把标题和作者逐字拆开、在字与字之间插入
  /// U+FE00~U+FE0F 这类「变体选择符」做反爬/指纹混淆。这些字符没有字形，
  /// 但会占一个位置，界面上看就是标题、作者名里凭空多出空格或缝隙，
  /// 例如「北︀︁︃︃︀︂︀︃︀︁︃︂京」实际应显示为「北京」。
  /// 渲染前统一剔除，标题和作者都要过一遍。
  static final RegExp invisibleCharsPattern = RegExp(
    r'[\uFE00-\uFE0F\u200B-\u200F\u202A-\u202E\u2060-\u206F\u00AD\uFEFF]',
  );

  /// 剔除隐形字符并压缩连续空白
  ///
  /// 只处理「看得见但没内容」的字符，不会动正常的全角/半角空格和换行，
  /// 所以原本就带空格的英文标题不会被改写坏。
  static String stripInvisible(String input) {
    if (input.isEmpty) return input;
    return input.replaceAll(invisibleCharsPattern, '');
  }

  // ==================== 正则表达式 ====================
  
  // ---- jiuse 站点（91porny / jiuse.icu）----
  //
  // 卡片结构（9scdn 前端）：
  //   <div class="colVideoList"><div class="video-elem">
  //     <a class="display" href="/vod/view/SxeO">
  //       <div class="img" style="background-image: url('...')"></div>
  //       <small class="layer">00:22:08</small>
  //     </a>
  //     <a class="title ..." href="/vod/view/SxeO">标题</a>
  //     <small>... 作者: <a href="/author/xxx">名字</a> ... 日期 | N次播放 ...</small>
  //   </div></div>
  //
  // 注意卡片区里还混着整段是外链的广告（href 指向站外），必须按 URL 过滤。

  /// jiuse 视频卡片容器
  static final RegExp jiuseCardPattern = RegExp(
    r'<div[^>]*class="[^"]*colVideoList[^"]*"[^>]*>([\s\S]*?)</div>\s*</div>',
    caseSensitive: false,
  );

  /// jiuse 视频详情路径（站内才算，排除广告外链）
  ///
  /// 真实站点同时存在四种路径形态，早期只认得前两种（单段 id），
  /// 导致首页里 12 张「蝌蚪」卡片被整批判为广告丢弃：
  ///   /vod/view/SxeO                                精品，短 id
  ///   /video/view/8fa43eb9a5b88b2f0e5f              普通，十六进制 id
  ///   /videos/view/127663/410ed2e1f969cb2d31254a/  蝌蚪，数字 id + hash + 结尾斜杠
  ///   /video/viewhd/ef5152fe75b733995347            高清分区专用，viewhd 段
  ///
  /// 最后一种是从 /video/category/* 分区页抓到的：该页 48 个详情链接全是
  /// viewhd 形态、一个 /view/ 都没有。漏掉它会让新增的分类点开就是空列表。
  /// 因此这里不再限制 id 字符集与段数，只要求是站内相对路径。
  static final RegExp jiuseVideoHrefPattern = RegExp(
    r'href="(/(?:vod|video|videos|v)/view(?:hd)?/[^"#?\s]+)"',
    caseSensitive: false,
  );

  /// 从 jiuse 详情路径里取视频 id
  ///
  /// 一律取 /view/（或 /viewhd/）之后的第一段：蝌蚪的多段路径（id + hash）
  /// 用 id 作唯一键，同一视频换 hash 时仍能去重。
  static final RegExp jiuseVideoIdPattern = RegExp(r'/view(?:hd)?/([^/?#]+)');

  static String? jiuseVideoId(String href) =>
      jiuseVideoIdPattern.firstMatch(href)?.group(1);

  /// 把 jiuse 页面里出现的资源地址补全成绝对 URL
  ///
  /// 封面有两种相对写法，直接拼 baseUrl 会拼错：
  ///   //int.ucloud165.xyz/thumb/1.jpg   协议相对，应补 https:
  ///   /static/xxx.jpg                  站内相对，应补 baseUrl
  static String resolveJiuseAssetUrl(String baseUrl, String raw) {
    final u = raw.trim();
    if (u.isEmpty) return u;
    if (u.startsWith('//')) return 'https:$u';
    if (u.startsWith('http://') || u.startsWith('https://')) return u;
    if (u.startsWith('/')) return '$baseUrl$u';
    return '$baseUrl/$u';
  }

  /// jiuse 卡片里的作者链接
  ///
  /// 站点有两套作者主页：/author/xxx 与 /dashen/xxx。前缀要一起捕获，
  /// 取作者视频时才能拼对路径（dashen 系拼成 /author/ 会 404）。
  /// 语法：作者: <a class="text-dark" href="/author/babybaby1">babybaby1</a>
  static final RegExp jiuseAuthorLinkPattern = RegExp(
    r'作者[:：]\s*<a[^>]*href="[^"]*/(author|dashen)/([^"?]+)"[^>]*>([^<]+)</a>',
    caseSensitive: false,
  );

  /// 把作者链接的两段信息拼成可再次请求的 authorId
  ///
  /// /author/foo -> foo（默认走 /author/）
  /// /dashen/foo -> dashen/foo（必须保留前缀）
  static String jiuseAuthorId(String prefix, String raw) {
    final p = prefix.toLowerCase();
    final id = raw.trim();
    return p == 'dashen' ? 'dashen/$id' : id;
  }

  /// jiuse 搜索页里「搜索到用户」区块的作者链接
  ///
  /// 结构（同一个 /search 结果页里，用户区块在视频区块之前）：
  ///   <a class="badge badge-light border text-dark ..." href="/author/Testgogogo">
  ///     Testgogogo <span class="badge badge-danger ml-1">8</span></a>
  /// 视频卡片里的作者链接只有 class="text-dark"，没有 badge，
  /// 因此限制 badge 就能只拿到用户区块。
  static final RegExp jiuseAuthorBadgePattern = RegExp(
    r'<a[^>]*class="[^"]*\bbadge\b[^"]*"[^>]*href="(/author/([^"]+))"[^>]*>'
    r'\s*([^<]+?)\s*<span[^>]*>\s*(\d+)\s*</span>',
    caseSensitive: false,
  );

  /// jiuse 分区页的路径式分页链接（第 2 页起：/video/category/hd/2 … /17152）
  static final RegExp jiuseCategoryPageLinkPattern = RegExp(
    r'/video/category/[a-z0-9-]+/(\d+)',
    caseSensitive: false,
  );

  /// jiuse 列表是否还有下一页（优先看真实分页链接）
  ///
  /// 实测分区页（/video/category/*）页脚是有完整分页控件的：
  ///   <ul class="pagination">…<a href="/video/category/hd/2">2</a>…<a href="/video/category/hd/17152">17152</a>
  /// 存在比当前页更大的页码链接就说明还有下一页；到底时只剩比当前页小的链接，
  /// 前后翻页符号也被置灰。
  ///
  /// 返回 null 表示页面上没有任何路径式分页链接（例如首页），
  /// 交给 [jiusePageHasMore] 的条数/内容比对判据。
  static bool? jiusePaginationHasMore(String html, int currentPage) {
    final links = jiuseCategoryPageLinkPattern.allMatches(html);
    var found = false;
    for (final m in links) {
      found = true;
      final n = int.tryParse(m.group(1) ?? '');
      if (n != null && n > currentPage) return true;
    }
    return found ? false : null;
  }

  /// jiuse 列表是否还有下一页
  ///
  /// 该站页面不渲染任何分页控件（实测：分页块 0 个、page= 链接 0 个），
  /// 只能靠「本页条数 + 是否与上一页内容重复」判断，历史实现按
  /// fallbackPageSize 兜底会让首页 20+ 条一路判为有下一页，滚到底也不停。
  ///
  /// 判定：
  ///   - 0 条 → 没有下一页（越界页通常返回空列表）
  ///   - 与上一页内容完全相同 → 没有下一页（部分 CMS 越界时回放最后一页）
  ///   - 其余按条数兜底
  static bool jiusePageHasMore({
    required int itemCount,
    required int page,
    required String signature,
    required String lastSignature,
  }) {
    if (itemCount <= 0) return false;
    if (page > 1 && signature.isNotEmpty && signature == lastSignature) {
      return false;
    }
    return itemCount >= fallbackPageSize;
  }

  /// 视频容器匹配（col-lg-3 内的 well-sm）- porn91 专用
  static final RegExp containerPattern = RegExp(
    r'<div[^>]*class="[^"]*col-lg-3[^"]*"[^>]*>\s*<div[^>]*class="[^"]*well[^"]*well-sm[^"]*"',
    caseSensitive: false,
  );
  
  /// original CMS 视频列表项
  static final RegExp originalVideoItemPattern = RegExp(
    r'<div[^>]*class="video-item[^"]*"[^>]*>[\s\S]*?<a[^>]*href="([^"]+)"[^>]*>[\s\S]*?<img[^>]*src="([^"]+)"[^>]*>[\s\S]*?<span[^>]*class="video-title[^"]*"[^>]*>([^<]+)</span>',
    caseSensitive: false,
  );

  /// viewkey 提取（支持十六进制和纯数字）- porn91 专用
  static final RegExp viewkeyPattern = RegExp(
    r'<a[^>]*href="([^"]*viewkey=([a-zA-Z0-9]+)[^"]*)"[^>]*>',
    caseSensitive: false,
  );

  /// 封面 ID 提取（playvthumb_XXXXXX）- porn91 专用
  static final RegExp playvthumbPattern = RegExp(
    r'playvthumb_(\d+)',
  );

  /// 标题提取（只匹配到第一个 <）
  static final RegExp titlePattern = RegExp(
    r'class="video-title[^"]*"[^>]*>([^<]+)',
  );

  /// 作者提取 - porn91 风格
  /// 匹配多种格式：
  /// - 作者：</span>xxx
  /// - 作者:xxx
  /// - 作者：xxx
  /// - <span>作者</span>：xxx
  /// ✅ 修复：跳过作者冒号后的HTML标签（如</span>），正确捕获作者名
  static final RegExp authorPattern = RegExp(
    r'(?:作者|From)[：:]\s*(?:</?[^>]+>\s*)*([^<\n\r]+)',
    caseSensitive: false,
  );
  
  /// 作者提取 - original 风格
  static final RegExp authorPatternOriginal = RegExp(
    r'作者[：:]\s*(?:<a[^>]*>)?([^<\n]+?)(?:</a>)?',
  );
  
  /// 时长提取 - original 风格
  static final RegExp durationPatternOriginal = RegExp(
    r'(?:时长|时间|时长：|时间：)\s*([0-9:]+)',
  );
  
  /// original CMS 标题提取
  static final RegExp originalTitlePattern = RegExp(
    r'<span[^>]*class="video-title[^"]*"[^>]*>([^<]+)</span>',
    caseSensitive: false,
  );
  
  /// original CMS 视频链接提取
  static final RegExp originalVideoLinkPattern = RegExp(
    r'<a[^>]*href="(video-\d+\.htm)"[^>]*>',
    caseSensitive: false,
  );
  
  /// original CMS 封面提取
  static final RegExp originalCoverPattern = RegExp(
    r'<img[^>]*src="([^"]+)"[^>]*class="[^"]*thumb[^"]*"',
    caseSensitive: false,
  );

  /// m3u8 URL 提取
  static final RegExp m3u8Pattern = RegExp(
    r'(https?://[^\s"\x27>]+\.m3u8[^\s"\x27>]*)',
    caseSensitive: false,
  );

  /// TS 切片提取
  static final RegExp tsPattern = RegExp(
    r'^(https?://[^\s"\x27>]+\.ts[^\s"\x27>]*)$',
    multiLine: true,
  );

  /// AES-128 KEY 提取
  static final RegExp aesKeyPattern = RegExp(
    r'#EXT-X-KEY:METHOD=AES-128,URI="([^"]+)"',
  );

  /// 视频时长提取
  static final RegExp durationPattern = RegExp(
    r'<span class="duration">([^<]+)</span>',
  );

  /// 上传日期提取
  static final RegExp uploadDatePattern = RegExp(
    r'添加时间[：:]\s*</span>\s*([^<\n]+)',
  );

  // ==================== 分页控件正则 ====================

  /// 分页区域容器（pagination / pager / page-nav 等常见 CMS 类名）
  /// 只在分页区域内查找"下一页"，避免误命中正文里的普通链接
  static final RegExp paginationBlockPattern = RegExp(
    r'<(?:ul|div|nav)[^>]*class="[^"]*(?:pagination|pager|page-nav|pagenavi|pages)[^"]*"[^>]*>[\s\S]{0,3000}?</(?:ul|div|nav)>',
    caseSensitive: false,
  );

  /// 指向更大页码的链接（如 page=2、page-2.htm、search-2.htm）
  /// 用于判断"是否还有下一页"：当前页为 N 时，存在 N+1 的链接即说明有下一页
  static final RegExp paginationPageLinkPattern = RegExp(
    r'''(?:page[=/_-]|page=|/)(\d+)(?:\.htm|\.html|["'?#]|$)''',
    caseSensitive: false,
  );

  /// 文本形式的"下一页"（中文 / 英文 / 符号）
  /// 注意：要排除 disabled 态（当前已在最后一页时，站点常把"下一页"置灰）
  static final RegExp nextPageTextPattern = RegExp(
    r'>\s*(?:下一页|下页|次页|next|Next|NEXT|›|»|&gt;|&raquo;)\s*<',
  );

  /// disabled / 置灰标记：命中说明该分页元素不可点击（通常出现在最后一页）
  static final RegExp paginationDisabledPattern = RegExp(
    r'class="[^"]*(?:disabled|is-disabled)[^"]*"',
    caseSensitive: false,
  );

  // ==================== 文本清理正则（避免循环中重复编译）====================

  /// HTML 标签剥离
  static final RegExp htmlTagPattern = RegExp(r'<[^>]*>');

  /// HTML 实体字符（如 &nbsp;）
  static final RegExp htmlEntityPattern = RegExp(r'&[a-z]+;');

  /// 空白字符规范化（含全角空格）
  static final RegExp whitespacePattern = RegExp(r'[\s　]+');

  // ==================== 分页配置 ====================

  /// 条数兜底阈值
  ///
  /// 仅当站点分页控件解析失败时使用：返回条数 >= 此值即认为可能还有下一页。
  /// 之所以取 12（而非原来硬编码的 20）：站点每页条数并不固定，
  /// 用 20 会在实际返回 15~19 条时被误判为"没有更多"，导致无限滚动提前停止。
  /// 取一个偏小的值只会多请求一次（代价可控），而误判为 false 会直接中断列表。
  static const int fallbackPageSize = 12;

  // ==================== 下载配置 ====================
  
  /// 并发线程数
  static const int maxConcurrentDownloads = 32;

  /// 重试次数
  static const int maxRetries = 3;

  /// 连接超时（秒）
  static const int connectTimeout = 15;

  /// 读取超时（秒）
  static const int readTimeout = 30;
}
