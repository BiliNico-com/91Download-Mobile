/// 爬虫核心配置
/// 严格参照 Python 版本 _src/lib/__init__.py

class CrawlerConfig {
  // ==================== 列表类型配置 ====================
  
  /// porn91 系列 URL 模板
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

  /// 中文名 -> 内部 key 映射
  static const Map<String, String> listTypeAliases = {
    "视频": "list",
    "91原创": "ori",
    "当前最热": "hot",
    "本月最热": "topm",
    "每月最热": "top",
    "10分钟以上": "longer",
    "20分钟以上": "long",
    "本月收藏": "rf",
    "最近加精": "tf",
    "高清": "hd",
    "本月讨论": "mf",
    "收藏最多": "md",
  };

  // ==================== 请求头 ====================
  
  static const Map<String, String> defaultHeaders = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
    "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
  };

  // ==================== 站点配置 ====================
  
  static const List<String> availableSites = [
    "https://91porn.com",
    "https://ml0987.xyz",
    "https://hsex.icu",
    "https://hsex.men",
  ];

  /// 图片 CDN 域名
  static const String imgCdnUrl = "https://1729130453.rsc.cdn77.org";

  // ==================== 正则表达式 ====================
  
  /// 视频容器匹配（col-lg-3 内的 well-sm）
  static final RegExp containerPattern = RegExp(
    r'<div[^>]*class="[^"]*col-lg-3[^"]*"[^>]*>\s*<div[^>]*class="[^"]*well[^"]*well-sm[^"]*"',
    caseSensitive: false,
  );

  /// viewkey 提取（支持十六进制和纯数字）
  static final RegExp viewkeyPattern = RegExp(
    r'<a[^>]*href="([^"]*viewkey=([a-zA-Z0-9]+)[^"]*)"[^>]*>',
    caseSensitive: false,
  );

  /// 封面 ID 提取（playvthumb_XXXXXX）
  static final RegExp playvthumbPattern = RegExp(
    r'playvthumb_(\d+)',
  );

  /// 标题提取（只匹配到第一个 <）
  static final RegExp titlePattern = RegExp(
    r'class="video-title[^"]*"[^>]*>([^<]+)',
  );

  /// 作者提取
  static final RegExp authorPattern = RegExp(
    r'作者[：:]\s*</span>\s*([^<\n]+)',
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
