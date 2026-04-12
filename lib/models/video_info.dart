/// 视频信息模型

class VideoInfo {
  final String id;          // viewkey
  final String url;         // 视频页面 URL
  final String title;       // 标题
  final String? cover;      // 封面 URL
  final String? author;     // 作者名
  final String? authorId;   // 作者ID（用于跳转作者主页）
  final String? duration;   // 时长
  final String? uploadDate; // 上传日期
  final String? m3u8Url;    // m3u8 地址（解析后）

  VideoInfo({
    required this.id,
    required this.url,
    required this.title,
    this.cover,
    this.author,
    this.authorId,
    this.duration,
    this.uploadDate,
    this.m3u8Url,
  });

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
