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
  
  /// 检测站点类型
  static String detectSiteType(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return "original";
    final domain = uri.host.replaceAll('www.', '');
    return siteTypes[domain] ?? "original";
  }
  
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
  /// 这套站用的是 9scdn/static 前端，路径是干净的 REST 风格：
  ///   /video  普通视频列表，分页参数是 ?page=N
  ///   /videos 蝌蚪，/vod 精品（同一套卡片结构）
  static const Map<String, String> listTypesJiuse = {
    "list": "video",
    "videos": "videos",
    "vod": "vod",
  };

  /// jiuse 中文名映射
  static const Map<String, String> listTypeAliasesJiuse = {
    "视频": "list",
    "蝌蚪": "videos",
    "精品": "vod",
  };

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
  static final RegExp jiuseVideoHrefPattern = RegExp(
    r'href="(/(?:vod|video|v)/view/[A-Za-z0-9]+)"',
    caseSensitive: false,
  );

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
