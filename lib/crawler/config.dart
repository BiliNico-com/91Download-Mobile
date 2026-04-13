/// 爬虫核心配置
/// 严格参照 Python 版本 _src/lib/__init__.py

class CrawlerConfig {
  // ==================== 站点类型配置 ====================
  
  /// 站点类型映射（域名 -> CMS类型）
  /// "original": ml0987/hsex 风格 CMS（list-{page}.htm 格式）
  /// "porn91": 91porn 风格 CMS（v.php?next=watch 格式）
  static const Map<String, String> siteTypes = {
    "91porn.com": "porn91",
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
  
  /// 获取列表类型映射（根据站点类型）
  static Map<String, String> getListTypes(String siteType) {
    return siteType == "porn91" ? listTypesV2 : listTypesOriginal;
  }
  
  /// 获取中文名映射（根据站点类型）
  static Map<String, String> getListTypeAliases(String siteType) {
    return siteType == "porn91" ? listTypeAliasesV2 : listTypeAliasesOriginal;
  }
  
  /// 构建搜索URL
  static String buildSearchUrl(String baseUrl, String siteType, String keyword, {int page = 1, String sort = "new"}) {
    if (siteType == "porn91") {
      // porn91 风格搜索 URL（支持分页）
      // URL格式: search_result.php?search_id=xxx&search_type=search_videos&min_duration=&page=N
      return "$baseUrl/search_result.php?search_id=${Uri.encodeComponent(keyword)}&search_type=search_videos&min_duration=&page=$page";
    } else {
      // original 风格搜索 URL（支持分页）
      // ✅ 修复：实际URL格式是 search-{page}.htm?search=xxx，不是 search.htm?search=xxx&page=N
      return "$baseUrl/search-$page.htm?search=${Uri.encodeComponent(keyword)}";
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
    // porn91 使用桌面端请求头（移动端请求会返回不同的视频ID，导致封面与视频不匹配）
    return defaultHeaders;
  }

  // ==================== 站点配置 ====================
  
  static const List<String> availableSites = [
    "https://91porn.com",
    "https://ml0987.xyz",
    "https://hsex.icu",
    "https://hsex.men",
  ];

  /// 图片 CDN 域名（仅 porn91 使用）
  static const String imgCdnUrl = "https://1729130453.rsc.cdn77.org";

  // ==================== 正则表达式 ====================
  
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
  static final RegExp authorPattern = RegExp(
    r'作者[：:]\s*</span>\s*([^<\n]+)',
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
