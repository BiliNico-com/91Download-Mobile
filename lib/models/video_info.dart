/// 视频信息模型

/// 站点在标题/作者里插入的隐形字符。
///
/// 91porn 一类站点会把文字逐字拆开，在字与字之间插入 U+FE00~U+FE0F
/// 这些「变体选择符」做反爬混淆。它们没有字形但占一个位置，
/// 界面上看就是名字中间凭空多出空格：
///   「北︀︁︃︃︀︂︀︃︀︁︃︂京」 → 实际应为「北京」
///   「w︀︁︃︃︀︂︀︃︀︁︂︃xx198710」 → 实际应为「wxx198710」
///
/// 这里在模型层统一剔除：解析有多个分支（列表页/详情页/搜索/作者主页），
/// 逐个改容易漏，放在构造函数里任何来源都会被净化。
final RegExp _invisibleChars = RegExp(
  r'[\uFE00-\uFE0F\u200B-\u200F\u202A-\u202E\u2060-\u206F\u00AD\uFEFF]',
);

/// 去掉隐形字符（不碰正常的空格与全角空格）
String _purify(String input) => input.replaceAll(_invisibleChars, '');

/// 同上，但允许 null
String? _purifyNullable(String? input) =>
    input == null ? null : input.replaceAll(_invisibleChars, '');

class VideoInfo {
  final String id;          // viewkey
  final String url;         // 视频页面 URL
  final String title;       // 标题
  final String? cover;      // 封面 URL
  final String? author;     // 作者名
  final String? authorId;   // 作者ID（用于跳转作者主页）
  final String? duration;   // 时长
  final String? uploadDate; // 上传日期
  final String? views;      // 观看数
  final String? m3u8Url;    // m3u8 地址（解析后）

  VideoInfo({
    required this.id,
    required this.url,
    required String title,
    this.cover,
    String? author,
    this.authorId,
    String? duration,
    String? uploadDate,
    String? views,
    this.m3u8Url,
  })  : title = _purify(title),
        // 标题和作者是站点加料的重灾区，构造时就洗干净，
        // 后面无论列表页、详情页还是搜索解析都拿不到脏数据。
        author = _purifyNullable(author),
        duration = _purifyNullable(duration),
        uploadDate = _purifyNullable(uploadDate),
        views = _purifyNullable(views);

  factory VideoInfo.fromJson(Map<String, dynamic> json) {
    return VideoInfo(
      id: json['id'] ?? '',
      url: json['url'] ?? '',
      title: json['title'] ?? '',
      cover: json['cover'],
      author: json['author'],
      authorId: json['authorId'],
      duration: json['duration'],
      uploadDate: json['uploadDate'],
      views: json['views'],
      m3u8Url: json['m3u8Url'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'url': url,
      'title': title,
      'cover': cover,
      'author': author,
      'authorId': authorId,
      'duration': duration,
      'uploadDate': uploadDate,
      'views': views,
      'm3u8Url': m3u8Url,
    };
  }

  /// 构造封面 URL
  static String buildCoverUrl(String coverId) {
    return "https://1729130453.rsc.cdn77.org/thumb/$coverId.jpg";
  }
}

/// 作者信息模型
class AuthorInfo {
  final String id;      // 作者ID（URL参数）
  final String name;    // 作者名称
  final String? avatar; // 头像URL
  final int videoCount; // 视频数量
  final String profileUrl; // 作者主页URL

  AuthorInfo({
    required this.id,
    required this.name,
    this.avatar,
    this.videoCount = 0,
    required this.profileUrl,
  });

  factory AuthorInfo.fromJson(Map<String, dynamic> json) {
    return AuthorInfo(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      avatar: json['avatar'],
      videoCount: json['videoCount'] ?? 0,
      profileUrl: json['profileUrl'] ?? '',
    );
  }
}
