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
    // 嗨碰（HiPorn）：bootstrap5 前端，播放地址写在 window.HIPORN_WATCH 里，
    // 与上面三家的 DOM 结构都不兼容，单独一套模板。
    "hifuli.com": "hifuli",
    "hiporn.net": "hifuli",
  };
  
  /// 站点家族（界面分组顺序也按这个顺序）
  static const List<String> siteFamilies = [
    'porn91',
    'jiuse',
    'original',
    'hifuli',
  ];

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
  /// ① 顶部导航
  ///      /videos 蝌蚪，/vod 精品；（/video 见下，已剔除）
  /// ② 视频列表页里的分区面板 —— 移动端「选择分类」折叠面板
  ///    （class mobileCateContainer）与桌面端左侧栏（class cateContainer）
  ///    同源，都是 14 个 data-href，只是渲染容器不同：
  ///      /video/category/{slug}
  ///
  /// 只做 ① 会让 App 里只剩 3 个分类，与网页上看到的十几个分类对不上。
  ///
  /// 高清（/video 与 /video/category/hd）整条入口被移除：
  /// 这两个入口的卡片 100% 是 /video/viewhd/ 链接，未登录时详情页只给同一条
  /// 12 秒样片（所有视频一模一样），走 /video/view/ 又是 6 秒 VIP 占位，
  /// 下载必然失败。列表解析层也会按 [jiuseIsHdPath] 兜底过滤，
  /// 首页因此余下 33 条非高清卡片（"list" 改指首页 /）。
  static const Map<String, String> listTypesJiuse = {
    // ① 顶部导航
    "list": "",
    "videos": "videos",
    "vod": "vod",
    // ② 分类面板（顺序与网页一致）
    "latest": "video/category/latest",
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
    "首页": "list",
    "蝌蚪": "videos",
    "精品": "vod",
    // 分类面板
    "最近更新": "latest",
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

  // ---- 嗨碰（hifuli.com / hiporn.net）----
  //
  // 站点列表分区只有 4 个入口，且分页行为各不相同（全部实测）：
  //   /            首页信息流  —— 每次请求内容随机重排、HTML 里没有任何分页控件
  //   /video       最新视频    —— 同上，且 /video/page/N 直接 500
  //   /recommend   推荐        —— 有真分页控件，/recommend/page/N
  //   /hot         热榜        —— 有真分页控件，/hot/{日期}/page/N（省略日期也认）
  //
  // 所以「是否存在下一页」不能靠条数兜底（上面的随机重排会让它永远为真），
  // 只能读分页控件上的 data-next-url；首页与 /video 直接当单页信息流。
  static const Map<String, String> listTypesHifuli = {
    "list": "",
    "video": "video",
    "recommend": "recommend",
    "hot": "hot",
  };

  static const Map<String, String> listTypeAliasesHifuli = {
    "首页": "list",
    "最新视频": "video",
    "推荐": "recommend",
    "热榜": "hot",
  };

  /// 嗨碰的哪些列表页是「单页信息流」（不翻页）
  static bool hifuliIsSinglePage(String path) {
    final p = path.startsWith("/") ? path.substring(1) : path;
    return p.isEmpty || p == "video";
  }

  /// 构建嗨碰列表页 URL
  ///
  /// 第 1 页不带页码（/hot）；第 2 页起走路径式（/hot/page/2）。
  /// 单页信息流无论第几页都只返回首页（站点也不认页码参数）。
  static String buildHifuliListUrl(String baseUrl, String path, int page) {
    final p = path.startsWith("/") ? path.substring(1) : path;
    if (p.isEmpty) return "$baseUrl/";
    final clean = p.endsWith("/") ? p.substring(0, p.length - 1) : p;
    if (page <= 1 || hifuliIsSinglePage(clean)) return "$baseUrl/$clean";
    return "$baseUrl/$clean/page/$page";
  }

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
    if (siteType == "hifuli") return listTypesHifuli;
    return siteType == "porn91" ? listTypesV2 : listTypesOriginal;
  }
  
  /// 获取中文名映射（根据站点类型）
  static Map<String, String> getListTypeAliases(String siteType) {
    if (siteType == "jiuse") return listTypeAliasesJiuse;
    if (siteType == "hifuli") return listTypeAliasesHifuli;
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
    if (siteType == "hifuli") {
      // 嗨碰是 GET 表单，真实入口 http://host/s/{关键词}，
      // 第 2 页起 http://host/s/{关键词}/page/{page}
      final kw = Uri.encodeComponent(keyword);
      return page <= 1
          ? "$baseUrl/s/$kw"
          : "$baseUrl/s/$kw/page/$page";
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
    "https://hifuli.com",
  ];

  /// 图片 CDN 域名（仅 porn91 使用）
  static const String imgCdnUrl = "https://1729130453.rsc.cdn77.org";

  /// 已知的广告片 ID。
  ///
  /// 91porn 播放页的 <source> 常常直接就是这条广告，
  /// 真实地址藏在 strencode2 里，必须避开。
  static const List<String> knownAdVideoIds = ['358999'];

  /// 直链里是否带站点签发的时效签名。
  ///
  /// porn91 的真实地址形如
  /// `https://la.btc620.com//mp43/1258149.mp4?st=xxx&e=1794035227&k=xxx&f=xxx`，
  /// `st` 是按「主机 + 路径 + 过期时间」签出来的，改主机（换线路）
  /// 签名立即失效，服务器一律回 403。这类地址不能做 CDN 改写。
  static bool isSignedMediaUrl(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return false;
    final q = u.queryParameters;
    return q.containsKey('st') && q.containsKey('e');
  }

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

  /// 九色系（91porny / jiuse.icu）的 CDN 线路
  ///
  /// 这套站点本身**没有**播放节点切换功能（app.js 里 cdn/线路/节点
  /// 全部 0 命中），这里的选项是本 App 自己补的：站点把播放/下载地址
  /// 发到 cdnN.jiuse2.cloud 或 cdnN.jiuse3.cloud，路径、token、查询参数
  /// 全部原样保留，只换域名——和 original 系「切线路」的做法一致。
  ///
  /// 实测（HEAD，移动端 UA）：
  ///   cdn2/cdn3.jiuse2.cloud、cdn2/cdn3.jiuse3.cloud → /hlsd/js10/index.m3u8 200
  ///   cdn22.jiuse2.cloud、cdn22.jiuse3.cloud          → 同一路径 403
  /// 两组分工不同：cdn(2|3) 服务公开路径，cdn22 只服务带 token 的
  /// /yyyy/mm/dd/<hash>/ 路径。所以 cdn22 不能进改写白名单——
  /// 把带 token 的地址改到 cdn2 上只会 403/404。
  static const List<CdnNode> jiuseNodes = [
    CdnNode(name: '自动（跟随站点）', host: ''),
    CdnNode(name: '线路 1（cdn2.jiuse2）', host: 'cdn2.jiuse2.cloud'),
    CdnNode(name: '线路 2（cdn3.jiuse2）', host: 'cdn3.jiuse2.cloud'),
    CdnNode(name: '线路 3（cdn2.jiuse3）', host: 'cdn2.jiuse3.cloud'),
    CdnNode(name: '线路 4（cdn3.jiuse3）', host: 'cdn3.jiuse3.cloud'),
  ];

  /// 九色系站点自带 CDN 域名集合（用于判断该不该改写）
  ///
  /// 刻意不含 cdn22.*：那是带 token 的专属主机，换域名必挂。
  static const Set<String> jiuseHosts = {
    'cdn2.jiuse2.cloud',
    'cdn3.jiuse2.cloud',
    'cdn2.jiuse3.cloud',
    'cdn3.jiuse3.cloud',
  };

  /// 嗨碰（hifuli.com）的 CDN 线路
  ///
  /// 该站播放页的 routeOptions 只有一条：
  ///   {key: 'core', domain: 'customer-hpnet.hlsdelivery.net', probe_url: '.../ping.txt'}
  /// 站点本身不提供多线路，App 也就没有可替换的域名——留「自动」一项，
  /// 保持设置页结构一致即可。
  static const List<CdnNode> hifuliNodes = [
    CdnNode(name: '自动（跟随站点）', host: ''),
  ];

  /// 嗨碰视频流域名集合（用于判断该不该改写）
  static const Set<String> hifuliHosts = {
    'customer-hpnet.hlsdelivery.net',
  };

  /// 按站点类型取节点列表
  static List<CdnNode> nodesFor(String siteType) {
    switch (siteType) {
      case 'porn91':
        return porn91Nodes;
      case 'jiuse':
        return jiuseNodes;
      case 'hifuli':
        return hifuliNodes;
      default:
        return originalNodes;
    }
  }

  /// 按站点类型取「可改写域名」白名单
  static Set<String> hostsFor(String siteType) {
    switch (siteType) {
      case 'porn91':
        return porn91Hosts;
      case 'jiuse':
        return jiuseHosts;
      case 'hifuli':
        return hifuliHosts;
      default:
        return originalHosts;
    }
  }

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

  /// 常见 HTML 实体反转义（标题里 &amp; / &quot; / &#39; 之类）
  ///
  /// 只处理标题高频道出现的几个，够用且不会误伤正文里的 &xxx; 片段。
  static String unescapeHtml(String input) {
    if (!input.contains('&')) return input;
    return input
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#0*39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&ldquo;', '“')
        .replaceAll('&rdquo;', '”')
        .replaceAll('&hellip;', '…')
        // 站点在作者名/标题里会夹带排版实体，少见但确实会出现
        // （例如「姐放君3&mdash;8」），不解码就原样上屏。
        .replaceAll('&mdash;', '—')
        .replaceAll('&ndash;', '–')
        .replaceAll('&middot;', '·')
        .replaceAll('&lsquo;', '‘')
        .replaceAll('&rsquo;', '’')
        .replaceAll('&laquo;', '«')
        .replaceAll('&raquo;', '»')
        .replaceAll('&times;', '×')
        .replaceAll('&copy;', '©')
        .replaceAll('&reg;', '®')
        // 数字实体 &#8212; / &#x2014; 走通用解码，命名实体覆盖不到的靠它
        .replaceAllMapped(
          RegExp(r'&#([xX]?)([0-9a-fA-F]+);'),
          (m) {
            final raw = m.group(2)!;
            final code = int.tryParse(
              raw,
              radix: m.group(1)!.isEmpty ? 10 : 16,
            );
            if (code == null || code <= 0 || code > 0x10FFFF) return m.group(0)!;
            return String.fromCharCode(code);
          },
        );
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
  /// 最后一种（viewhd）仍要认得，否则卡片整段被判为广告丢弃、连标题都对不上；
  /// 但列表解析时会被 [jiuseIsHdPath] 过滤掉（高清未登录下不了）。
  /// 这里不限制 id 字符集与段数，只要求是站内相对路径。
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

  /// 判断一条 jiuse 详情链接是不是「高清」路径（/video/viewhd/）
  ///
  /// 高清分区未登录时下载不了，列表层要整条过滤掉：
  ///   /video/viewhd/{id}  未登录恒返回 12 秒样片（所有视频同一段）
  ///   /video/view/{id}    同一 id 改走这里变 6 秒 VIP 占位
  /// 所以高清卡片留着也只会下出一个假文件，直接在解析时跳过。
  ///
  /// 注意：不能用卡片上的 vip-layer「高清」徽标判断——线上首页实测有
  /// 10 张带徽标却是 /video/view/ 的普通卡片，/vod/view/ 精品也带徽标。
  static bool jiuseIsHdPath(String href) =>
      href.toLowerCase().contains('/viewhd/');

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

  // ==================== 九色系「样片」识别与真实地址换取 ====================
  //
  // 九色系详情页 <video data-src> 有时给的不是真视频，而是站点内置的
  // 12 秒样片：//cdn2.jiuse2.cloud/hlsd/js10/index.m3u8。
  // 这个路径对任何视频都一样（hlsd/js1、js11、js99 全部 404），
  // 无论带不带 Referer 返回的都是同一份 12.00s 播放列表。
  // 拿它下载就得到「只有 11 秒的假视频」，在线播放也一样。
  //
  // 真实地址要从站点的下载接口取：GET {baseUrl}/apiDownloadUrl/{data-id}
  // 接口是纯 GET、无签名（前端 requestGet 就是裸 $.ajax），
  // 返回体直接就是可下载的 URL 文本，前端拿到后 window.open。

  /// 样片播放列表的特征路径：/hlsd/<名字>/index.m3u8
  static final RegExp jiuseSamplePlaylistPattern =
      RegExp(r'/hlsd/[^/]+/index\.m3u8', caseSensitive: false);

  /// 判断一条播放地址是不是站点内置样片
  static bool isJiuseSampleUrl(String url) =>
      jiuseSamplePlaylistPattern.hasMatch(url);

  /// 播放列表内容是不是站点内置样片
  ///
  /// 样片地址被换过域名也还是同一份内容，所以不能只看 URL，
  /// 下载前要看一眼播放列表本身：
  ///   #EXTINF 合计约 12 秒、切片名一律 index0.ts~index11.ts、
  ///   且 12 段总字节恒为 15,847,272（与具体视频无关）。
  /// 命中说明「这条地址对任何视频都一样」，下下来必然是同一段 12 秒画面。
  static bool jiusePlaylistIsSample(String content) {
    if (content.isEmpty) return false;
    if (!content.contains('#EXTM3U')) return false;
    // 切片名特征：index0.ts / index1.ts ... 而不是真实路径里的 seg-xxx 或数字长名字
    final names = RegExp(r'\n(index\d+\.ts?)\s*$', multiLine: true)
        .allMatches(content)
        .map((m) => m.group(1))
        .toSet();
    if (names.isEmpty) return false;
    final totalSeconds = RegExp(r'#EXTINF:\s*([0-9.]+)')
        .allMatches(content)
        .fold<double>(0, (s, m) => s + (double.tryParse(m.group(1)!) ?? 0));
    // 站点样片是固定的一份：12 段 index0.ts~index11.ts、合计 11.995533 秒。
    // 真实片源实测 27~60 段、单集 5~8 分钟，段数对不上。
    // 用「段数正好 12 且总长落在 11~13 秒」双条件，避免把真实的
    // 十几秒短视频误判成样片而拒绝下载。
    return names.length == 12 && totalSeconds >= 11 && totalSeconds <= 13;
  }

  /// 播放列表内容是不是「未登录占位切片」
  ///
  /// 九色系对 VIP 专属视频会发一条只有单片段的播放列表，
  /// 切片地址带 __vnotice 标记、时长 6 秒，所有视频返回同一份占位。
  static bool jiusePlaylistIsPlaceholder(String content) {
    if (content.isEmpty) return false;
    if (content.contains('__vnotice')) return true;
    final segments = RegExp(r'^[^#\s].*\.ts(?:\?.*)?$', multiLine: true)
        .allMatches(content)
        .length;
    final totalSeconds = RegExp(r'#EXTINF:\s*([0-9.]+)')
        .allMatches(content)
        .fold<double>(0, (s, m) => s + (double.tryParse(m.group(1)!) ?? 0));
    return segments <= 1 && totalSeconds <= 8;
  }

  // ==================== 时长解析与「降级片源」识别 ====================

  /// 播放列表里所有切片的时长合计（秒），取自 #EXTINF
  static double playlistDurationSeconds(String content) {
    if (content.isEmpty) return 0;
    return RegExp(r'#EXTINF:\s*([0-9.]+)')
        .allMatches(content)
        .fold<double>(0, (s, m) => s + (double.tryParse(m.group(1)!) ?? 0));
  }

  /// 把站点自报的视频时长字符串解析成秒
  ///
  /// 各站点格式不统一，这里统一吃掉常见的几种：
  ///   hh:mm:ss  porn91 播放页解密出来的值（config.dart 里补零成三位）
  ///   mm:ss     original CMS / 九色系卡片角标（41:11）
  ///   12分34秒   中文站点
  ///   754       纯秒数
  /// 解析不出来返回 null。调用方必须把 null 当成「无法校验」，
  /// 绝不能当成「时长对不上」去拒绝下载。
  static int? parseDurationSeconds(String? raw) {
    if (raw == null) return null;
    var text = raw.trim();
    if (text.isEmpty) return null;
    // 去掉「时长：」「Duration: 」之类的前缀，只留数字、冒号和分秒
    text = text.replaceFirst(RegExp(r'^[^0-9]+'), '');

    final colon = RegExp(r'^(\d+):(\d{1,2})(?::(\d{1,2}))?').firstMatch(text);
    if (colon != null) {
      final a = int.tryParse(colon.group(1)!) ?? 0;
      final b = int.tryParse(colon.group(2)!) ?? 0;
      final c = colon.group(3);
      if (c == null) return a * 60 + b; // mm:ss
      final cc = int.tryParse(c) ?? 0;
      return a * 3600 + b * 60 + cc; // hh:mm:ss
    }

    final cn = RegExp(r'^(\d+)\s*分\s*(\d+)\s*秒').firstMatch(text);
    if (cn != null) {
      return (int.tryParse(cn.group(1)!) ?? 0) * 60 +
          (int.tryParse(cn.group(2)!) ?? 0);
    }
    final cnSec = RegExp(r'^(\d+)\s*秒').firstMatch(text);
    if (cnSec != null) return int.tryParse(cnSec.group(1)!) ?? 0;

    final pure = RegExp(r'^(\d+)').firstMatch(text);
    if (pure != null) return int.tryParse(pure.group(1)!);
    return null;
  }

  /// 播放列表时长与站点自报时长是否明显对不上
  ///
  /// 九色系对未登录用户存在第三种「假片源」：详情页给的地址既不是
  /// /hlsd/ 样片形态（[isJiuseSampleUrl] 认不出），内容也不是
  /// 12 段 12 秒样片 / 6 秒占位（[jiusePlaylistIsSample] 与
  /// [jiusePlaylistIsPlaceholder] 都拦不住），而是一条带 token 的
  /// 真实播放列表——但**多条不同视频拿到的是同一份**。
  ///
  /// 实测：某视频列表页标注 07:56，播放列表 #EXTINF 合计只有 49 秒；
  /// 另外三条分别标注 05:36 / 04:25，落盘文件与 49 秒那条逐字节相同。
  ///
  /// 返回 true = 明显不符；null = 无法判定（缺时长 / 解析失败 / 短视频）。
  static bool? jiusePlaylistDurationMismatch(
      String content, String? declaredDuration) {
    final expected = parseDurationSeconds(declaredDuration);
    // 一分钟以内的视频不校验：真实短视频与「降级片源」的时长本就接近，
    // 判错会把正常视频挡在门外。
    if (expected == null || expected < 60) return null;
    final actual = playlistDurationSeconds(content);
    if (actual <= 0) return null;
    // 播放列表按切片边界分段，与实际时长有秒级出入；
    // 站点标注也常是取整值。留 30% 余量，只拦「差出好几倍」的降级片源。
    return actual < expected * 0.7;
  }

  /// 九色系免登录取真实地址的备用入口
  ///
  /// 详情页给的是 12 秒样片、而 /apiDownloadUrl 未登录直接 422 时，
  /// /video/embed/{id} 仍会返回一条带 token 的真实播放地址（HTML 内联）。
  static String jiuseEmbedUrl(String baseUrl, String videoId) =>
      '$baseUrl/video/embed/$videoId';

  /// 带 token 的路径（/s/<token>/...）只能在同代 CDN 之间换域名
  ///
  /// 实测：/s/token 路径在 cdn2/cdn3.jiuse3.cloud 上 200，
  /// 在 cdn2/cdn3.jiuse2.cloud 上一律 403；而公开样片路径四台都通。
  /// 用户选到 jiuse2 线路时若无脑改写，就会把能放的地址改成 403。
  static bool jiuseTokenPath(String url) {
    final path = Uri.tryParse(url)?.path ?? '';
    return path.startsWith('/s/');
  }

  /// 判断把 [fromHost] 换成 [toHost] 会不会必然 403
  static bool jiuseHostSwapBlocked(String fromHost, String toHost) {
    if (fromHost == toHost) return false;
    final from3 = fromHost.endsWith('.jiuse3.cloud');
    final to3 = toHost.endsWith('.jiuse3.cloud');
    // 3 代主机之间互换没有问题；跨代（3 → 2）必挂
    return from3 && !to3;
  }

  /// 详情页里点赞/收藏/下载共用的资源 id
  ///
  /// 形态如 js/6660f5c5aa73924ffa3511a723ac1edb，
  /// 在 likeBtn / dislikeBtn / favoriteBtn 上各出现一次，取第一个即可。
  static final RegExp jiuseDataIdPattern = RegExp(
    r'data-id="([^"]{8,})"',
    caseSensitive: false,
  );

  static String? jiuseDataIdFromHtml(String html) =>
      jiuseDataIdPattern.firstMatch(html)?.group(1);

  /// 拼下载接口地址
  static String jiuseApiDownloadUrl(String baseUrl, String dataId) =>
      '$baseUrl/apiDownloadUrl/$dataId';

  /// 解析下载接口的返回体
  ///
  /// 正常是裸 URL 文本；不同版本也可能包成 JSON（url/data/downloadUrl）
  /// 或带引号的字符串，这里都兜住。取不到 http(s) 地址时返回 null。
  static String? parseJiuseDownloadApiResponse(String body) {
    final raw = body.trim();
    if (raw.isEmpty) return null;

    String? candidate;
    if (raw.startsWith('{')) {
      try {
        final obj = jsonDecode(raw);
        if (obj is Map) {
          for (final key in const ['url', 'data', 'downloadUrl', 'download']) {
            final v = obj[key];
            if (v is String && v.trim().isNotEmpty) {
              candidate = v.trim();
              break;
            }
          }
        }
      } catch (_) {
        // 不是合法 JSON，落到下面按裸文本处理
      }
    }
    candidate ??= raw;

    // 去掉成对引号与页面里可能带出的 HTML 转义
    candidate = candidate.replaceAll('&amp;', '&').trim();
    if (candidate.length >= 2 &&
        ((candidate.startsWith('"') && candidate.endsWith('"')) ||
            (candidate.startsWith("'") && candidate.endsWith("'")))) {
      candidate = candidate.substring(1, candidate.length - 1).trim();
    }
    if (!candidate.startsWith('http://') &&
        !candidate.startsWith('https://')) {
      return null;
    }
    return candidate;
  }

  /// 把页面里抓到的视频/切片地址补成绝对 URL
  ///
  /// 站点经常用协议相对写法（`//cdn2.jiuse2.cloud/hlsd/js10/index.m3u8`），
  /// 这种地址交给 Dio / Uri.parse 会直接抛
  /// `Invalid argument(s): Unsupported scheme '' in URI ...`，
  /// 表现为「下载任务 0% 立刻失败」。凡是拿到手的地址都先过一遍这里。
  static String resolveAbsoluteUrl(String baseUrl, String raw) {
    final u = raw.trim();
    if (u.isEmpty) return u;
    if (u.startsWith('//')) return 'https:$u';
    if (u.startsWith('http://') || u.startsWith('https://')) return u;
    // 无 scheme 但形如 host/path（带点的主机名）
    if (!u.startsWith('/') && RegExp(r'^[\w.-]+\.[a-z]{2,}/').hasMatch(u)) {
      return 'https://$u';
    }
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

  // ---- 站点：嗨碰 hifuli.com（细节见文件上方 listTypesHifuli）----

  /// 列表卡片：首页与列表页两套 DOM 但共用同一组 class
  ///
  /// 列表页的作者行在卡片链接闭合之后（article 里的兄弟节点
  /// div.hiporn-list-card-meta），不属于卡片本身，所以把紧随其后的
  /// meta 块一并切进来（间隔最多 200 字符），否则作者永远解析不到。
  /// 该分组可选：首页卡片没有 meta 行，匹配时为空即可。
  static final RegExp hifuliCardPattern = RegExp(
    r'<a\b[^>]*class="[^"]*hiporn-video-card[^"]*"[^>]*>[\s\S]*?</a>'
    r'(?:[\s\S]{0,200}?<div class="hiporn-list-card-meta">[\s\S]{0,3000}?</div>)?',
    caseSensitive: false,
  );

  /// 卡片链接：/video/{数字 id}-{slug}
  static final RegExp hifuliHrefPattern = RegExp(
    r'href="(/video/(\d+)-[^"]*)"',
    caseSensitive: false,
  );

  /// 封面：lazyload 图片的真实地址
  static final RegExp hifuliCoverPattern = RegExp(
    r'data-original="([^"]+)"',
    caseSensitive: false,
  );

  static final RegExp hifuliDurationPattern = RegExp(
    r'hiporn-video-card-duration">\s*([^<]+?)\s*<',
    caseSensitive: false,
  );

  static final RegExp hifuliTitlePattern = RegExp(
    r'hiporn-video-card-title">\s*([^<]+?)\s*<',
    caseSensitive: false,
  );

  /// 卡片作者（列表页专有；首页卡片没有作者行）
  /// 注意窗口要留够：作者头像是一段内联 base64 PNG（约 600~1200 字符），
  /// 窗口太窄会跨不过 img 拿不到后面的 <span>。
  static final RegExp hifuliCardAuthorPattern = RegExp(
    r'hiporn-list-card-author[^>]*>[\s\S]{0,4000}?<span>\s*([^<]+?)\s*</span>',
    caseSensitive: false,
  );

  /// 分页控件容器
  static final RegExp hifuliPagerPattern = RegExp(
    r'<div[^>]*class="[^"]*hiporn-pager[^"]*"[^>]*>',
    caseSensitive: false,
  );

  /// 分页控件上的「下一页地址」（空串 = 已经是最后一页）
  static final RegExp hifuliNextUrlPattern = RegExp(
    r'data-next-url="([^"]*)"',
    caseSensitive: false,
  );

  /// 列表页是否还有下一页
  ///
  /// 返回 null 表示页面上根本没有分页控件（首页 / /video），
  /// 这两个页面每次请求内容都会随机重排，条数判据也失效，
  /// 调用方应当直接按「单页信息流」处理。
  static bool? hifuliHasNextPage(String html) {
    final pager = hifuliPagerPattern.firstMatch(html);
    if (pager == null) return null;
    final next = hifuliNextUrlPattern.firstMatch(pager.group(0)!);
    if (next == null) return null;
    return next.group(1)!.trim().isNotEmpty;
  }

  /// 详情页播放地址
  ///
  /// 站点把地址写在 window.HIPORN_WATCH.player.url 里（页面无 <video>），
  /// 同一份 JSON-LD 的 contentUrl 是等价的兜底来源。
  static final RegExp hifuliPlayerUrlPattern = RegExp(
    r"player\s*:\s*\{[\s\S]{0,400}?url\s*:\s*'([^']+)'",
    caseSensitive: false,
  );

  static final RegExp hifuliContentUrlPattern = RegExp(
    r'"contentUrl"\s*:\s*"([^"]+)"',
    caseSensitive: false,
  );

  /// 详情页标题：<h1 class="hiporn-page-title hiporn-watch-title">
  static final RegExp hifuliDetailTitlePattern = RegExp(
    r'hiporn-watch-title[^>]*>\s*([\s\S]{0,300}?)\s*</h1>',
    caseSensitive: false,
  );

  /// 详情页作者
  static final RegExp hifuliDetailAuthorPattern = RegExp(
    r'hiporn-watch-author-name[^>]*>\s*([^<]+?)\s*<',
    caseSensitive: false,
  );

  /// 详情页封面
  static final RegExp hifuliDetailCoverPattern = RegExp(
    r"player\s*:\s*\{[\s\S]{0,400}?pic\s*:\s*'([^']+)'",
    caseSensitive: false,
  );

  /// JSON-LD 里的时长（ISO 8601，如 PT5M / PT1H2M3S）
  ///
  /// 这个正则在整页 HTML 上定位 "duration":"PT5M" 片段，
  /// 纯解析交给 [formatIsoDuration]（它也接受裸的 PT5M）。
  static final RegExp hifuliIsoDurationPattern = RegExp(
    r'"duration"\s*:\s*"(PT(?:[0-9]+H)?(?:[0-9]+M)?(?:[0-9]+S)?)"',
    caseSensitive: false,
  );

  /// 裸 ISO 8601 时长（不带 JSON 外壳）
  static final RegExp isoDurationBodyPattern = RegExp(
    r'^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$',
    caseSensitive: false,
  );

  /// 详情页播放数
  static final RegExp hifuliViewsPattern = RegExp(
    r'"userInteractionCount"\s*:\s*(\d+)',
    caseSensitive: false,
  );

  /// 详情页上传日期
  static final RegExp hifuliUploadDatePattern = RegExp(
    r'"uploadDate"\s*:\s*"([^"]+)"',
    caseSensitive: false,
  );

  // ---- 嗨碰：列表卡片的作者行（meta）----
  //
  // 列表/搜索/推荐/热榜页的卡片下方多一行 meta，作者与时间都在里面：
  //   <div class="hiporn-list-card-meta">
  //     <a href="/u/{urlencode 名字}" class="hiporn-list-card-author" …>
  //       <img src="data:image/png;base64,…（约 600~1200 字符）" …><span>名字</span>
  //     </a>
  //     <time class="hiporn-list-card-time">3天前</time>
  //   </div>
  // 首页与 /video 的卡片没有这一行（作者/时间都拿不到）。

  /// 卡片里的 meta 块（含作者行与时间）
  static final RegExp hifuliCardMetaPattern = RegExp(
    r'<div class="hiporn-list-card-meta">([\s\S]{0,3000}?)</div>',
    caseSensitive: false,
  );

  /// meta 块里的作者主页地址：/u/{urlencode 名字}
  ///
  /// 这是站点给的真实路径，比「把显示名重新编码」可靠：显示名可能带
  /// 空格/emoji，与 URL 里那段编码并不总是等价。
  static final RegExp hifuliCardAuthorHrefPattern = RegExp(
    r'href="(/u/[^"]+)"',
    caseSensitive: false,
  );

  /// meta 块里的上传时间
  ///
  /// 站点给的是相对时间（3天前 / 4小时前 / 5分钟前），没有绝对日期，
  /// 原样展示即可——它和详情页 JSON-LD 的 uploadDate 是同一件事的两种精度。
  static final RegExp hifuliCardTimePattern = RegExp(
    r'hiporn-list-card-time"[^>]*>\s*([^<]+?)\s*<',
    caseSensitive: false,
  );

  /// 把作者主页地址规范成可直接拼进 /u/ 的 id
  ///
  /// 入参可能是 /u/jds、u/jds、jds 或已编码的 %E5%8C%BF%E5%90%8D，
  /// 统一去掉 u/ 前缀；已编码的百分号形式原样保留，不能再编码一次。
  static String normalizeHifuliAuthorId(String raw) {
    var id = raw.trim();
    if (id.startsWith('/')) id = id.substring(1);
    if (id.startsWith('u/')) id = id.substring(2);
    if (id.startsWith('/')) id = id.substring(1);
    return id;
  }

  /// 把详情页 JSON-LD 的 ISO 日期格式化成 yyyy-MM-dd
  ///
  /// 站点给的是 "2018-08-11T00:00:00+08:00"，直接上屏会带着时分秒与时区，
  /// 播放页的胶囊放不下。拿不到 ISO 形态时原样返回（列表带来的「3天前」
  /// 这类相对时间就属于这种），空串一律返回 null。
  static String? formatHifuliDate(String? raw) {
    if (raw == null) return null;
    final v = raw.trim();
    if (v.isEmpty) return null;
    final m = RegExp(r'^(\d{4}-\d{2}-\d{2})').firstMatch(v);
    if (m != null) return m.group(1);
    return v;
  }

  /// 把 ISO 8601 时长转成 mm:ss / hh:mm:ss，解析不出来返回 null
  static String? formatIsoDuration(String? iso) {
    if (iso == null) return null;
    var v = iso.trim();
    // 允许直接传整页 HTML 片段，也允许传裸的 PT5M
    final wrapped = hifuliIsoDurationPattern.firstMatch(v);
    if (wrapped != null) v = wrapped.group(1)!;
    final m = isoDurationBodyPattern.firstMatch(v);
    if (m == null) return null;
    final h = int.tryParse(m.group(1) ?? '') ?? 0;
    final mi = int.tryParse(m.group(2) ?? '') ?? 0;
    final s = int.tryParse(m.group(3) ?? '') ?? 0;
    if (h == 0 && mi == 0 && s == 0) return null;
    final two = (int v) => v.toString().padLeft(2, '0');
    return h > 0
        ? '$h:${two(mi)}:${two(s)}'
        : '${two(mi)}:${two(s)}';
  }

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
