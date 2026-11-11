/// 站点差异的唯一入口
///
/// 四个站点家族各写一份 [SiteHandler]：怎么拼列表 URL、怎么从 HTML 里
/// 抠出视频卡片、详情页的播放地址藏在哪、分页怎么判断。CrawlerCore 只负责
/// 网络、分页状态与下载，遇到站点差异就转给当前 handler。
///
/// 约定：**站点类不发 HTTP 请求**。凡是要联网才能拿到的地址
/// （jiuse 的真实播放地址、porn91 的 cookie 会话）都留在 CrawlerCore，
/// 这样每个站点文件都能脱离网络单独读、单独改、单独测。

import '../../models/video_info.dart';

/// 详情页提取结果
class SiteDetail {
  const SiteDetail({
    this.videoUrl,
    this.method,
    this.needsRealUrl = false,
    this.title,
    this.author,
    this.authorId,
    this.duration,
    this.uploadDate,
    this.views,
  });

  /// 从详情页 HTML 里抽到的播放地址；null 表示交给通用兜底
  final String? videoUrl;

  /// 命中哪条策略，仅用于排查
  final String? method;

  /// 抽到的地址是站点样片（所有视频共用），要 CrawlerCore 联网换真实地址
  final bool needsRealUrl;

  /// 详情页自带的元信息（嗨碰系用，其余站点为 null）
  final String? title;
  final String? author;
  final String? authorId;
  final String? duration;
  final String? uploadDate;
  final String? views;
}

/// 分页判断结果
class SitePagination {
  const SitePagination({
    required this.hasMore,
    required this.parsed,
    required this.log,
    this.rememberSignature = false,
  });

  final bool hasMore;

  /// 是否解析到了站点分页控件（false 表示走了条数兜底）
  final bool parsed;

  /// 写进日志的判断依据
  final String log;

  /// 是否记下本页的 id 序列（jiuse 靠「与上一页完全相同」判断到底）
  final bool rememberSignature;
}

/// 一个站点家族的全部差异点
abstract class SiteHandler {
  const SiteHandler();

  String get siteType;

  /// 列表/详情/作者页 URL 是否要额外加 _t 时间戳防缓存（只有 porn91 需要）
  bool get addCacheBuster => false;

  /// 列表页 URL。默认按配置里的路径占位符拼，jiuse / hifuli 各有分页规则。
  String buildListUrl(String baseUrl, String urlPattern, int page) =>
      '${baseUrl}/${urlPattern.replaceAll('{page}', page.toString())}';

  String buildAuthorUrl(String baseUrl, String authorId, int page);

  String buildAuthorSearchUrl(String baseUrl, String keyword);

  List<VideoInfo> parseVideoList(String html, String baseUrl);

  Future<SiteDetail> extractDetail(
      String html, VideoInfo video, String baseUrl);

  /// 作者搜索页的站点专用解析；返回 null 表示用通用的 btn/badge 正则
  List<AuthorInfo>? parseAuthors(String html, String baseUrl) => null;

  /// 分页判断；返回 null 表示用通用的「分页控件 + 条数兜底」
  SitePagination? decidePagination({
    required String html,
    required int page,
    required int itemCount,
    required String signature,
    required String lastSignature,
  }) =>
      null;
}
