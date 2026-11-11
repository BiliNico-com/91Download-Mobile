/// 九色系站点（91porny.com / jiuse.icu）的解析实现
///
/// 只做 HTML 解析与 URL 拼装，不发任何 HTTP 请求：
/// 抓页面、换真实播放地址（/apiDownloadUrl、/video/embed）都由
/// [CrawlerCore] 负责，这样这个文件可以单独改、单独测。

import '../config.dart';
import '../../models/video_info.dart';
import '../../utils/logger.dart';
import 'site_handler.dart';

class JiuseSite extends SiteHandler {
  const JiuseSite();

  @override
  String get siteType => 'jiuse';

  @override
  String buildListUrl(String baseUrl, String urlPattern, int page) =>
      CrawlerConfig.buildJiuseListUrl(baseUrl, urlPattern, page);

  @override
  String buildAuthorSearchUrl(String baseUrl, String keyword) =>
      CrawlerConfig.buildSearchUrl(baseUrl, 'jiuse', keyword);

  @override
  String buildAuthorUrl(String baseUrl, String authorId, int page) {
    final id = authorId.trim();
    final path =
        id.startsWith('author/') || id.startsWith('dashen/') ? id : 'author/$id';
    return page <= 1 ? '$baseUrl/$path' : '$baseUrl/$path?page=$page';
  }

  /// 解析 jiuse 站点（91porny / jiuse.icu）的视频列表
  ///
  /// 卡片结构见 [CrawlerConfig.jiuseCardPattern] 的注释。
  /// 三个要点：
  /// 1. 卡片区混着整段是站外跳转的广告，必须只认站内 /xxx/view/yyy 链接；
  /// 2. 作者写在「作者:」文本里，且可能是纯文本也可能是 <a>；
  /// 3. 封面在 style="background-image: url('...')" 里，不是 img[src]。
  @override
  List<VideoInfo> parseVideoList(String html, String baseUrl) {
    final videos = <VideoInfo>[];
    final seenIds = <String>{};
    var hdSkipped = 0;
    Logger().logSync('Parse', '解析 jiuse HTML, 长度: ${html.length}');

    for (final m in CrawlerConfig.jiuseCardPattern.allMatches(html)) {
      final card = m.group(1)!;

      // 必须是站内视频详情链接，站外广告直接跳过
      final hrefMatch =
          CrawlerConfig.jiuseVideoHrefPattern.firstMatch(card);
      if (hrefMatch == null) continue;
      final href = hrefMatch.group(1)!;

      // 高清（/video/viewhd/）整条跳过：未登录时该路径恒返回 12 秒样片，
      // 所有视频共用同一段画面，下载下来必是同一个文件；同一 id 改走
      // /video/view/ 又只给 6 秒 VIP 占位。所以高清不进列表。
      if (CrawlerConfig.jiuseIsHdPath(href)) {
        hdSkipped++;
        continue;
      }

      // 取详情 id 作为唯一键：
      //   /vod/view/SxeO                              -> SxeO
      //   /videos/view/127663/410ed2e1f969cb2d3125/   -> 127663（取第一段）
      final id = CrawlerConfig.jiuseVideoId(href);
      if (id == null || id.isEmpty) continue;
      if (seenIds.contains(id)) continue;
      seenIds.add(id);

      // 标题：优先取 title 链接的文本，取不到再退回任意 title= 属性
      String? title;
      final titleLink = RegExp(
        r'<a[^>]*class="[^"]*\btitle\b[^"]*"[^>]*>([^<]+)</a>',
        caseSensitive: false,
      ).firstMatch(card);
      if (titleLink != null) {
        title = CrawlerConfig.stripInvisible(titleLink.group(1)!).trim();
      }
      title ??=
          RegExp(r'title="([^"]+)"').firstMatch(card)?.group(1)?.trim();
      if (title == null || title.isEmpty) continue;

      // 封面
      String? cover;
      final coverMatch = RegExp(
        r"""background-image:\s*url\(\s*['"]?([^)'"]+)""",
      ).firstMatch(card);
      if (coverMatch != null) {
        // 封面有两种相对写法：//cdn.../1.jpg（协议相对）与 /static/1.jpg（站内相对），
        // 早期统一 '$baseUrl$u' 会把协议相对地址拼成 https://host//cdn...
        cover = CrawlerConfig.resolveJiuseAssetUrl(baseUrl, coverMatch.group(1)!);
      }

      // 时长：
      // <small class="layer">00:22:08</small>
      String? duration;
      final durMatch = RegExp(
        r'<small[^>]*class="[^"]*\blayer\b[^"]*"[^>]*>\s*([0-9:]+)\s*</small>',
        caseSensitive: false,
      ).firstMatch(card);
      if (durMatch != null) duration = durMatch.group(1);

      // 作者：作者: <a ...>名字</a> 或 作者: 名字
      String? author;
      String? authorId;
      final authorLink =
          CrawlerConfig.jiuseAuthorLinkPattern.firstMatch(card);
      if (authorLink != null) {
        // 站点有两套作者主页：/author/xxx 与 /dashen/xxx。
        // 记住前缀，取作者视频时才能拼对路径（dashen 系拼成 /author/ 会 404）。
        authorId = CrawlerConfig.jiuseAuthorId(
            authorLink.group(1)!, authorLink.group(2)!);
        author = CrawlerConfig.stripInvisible(authorLink.group(3)!).trim();
      } else {
        final plain = RegExp(r'作者[:：]\s*([^<\n\r]+)', caseSensitive: false)
            .firstMatch(card);
        if (plain != null) {
          author = CrawlerConfig.stripInvisible(plain.group(1)!).trim();
        }
      }

      // 日期 + 播放数：2026-11-05&nbsp;|&nbsp;1351次播放
      String? uploadDate;
      String? views;
      final dateMatch =
          RegExp(r'(\d{4}-\d{2}-\d{2})').firstMatch(card);
      if (dateMatch != null) uploadDate = dateMatch.group(1);
      final viewMatch =
          RegExp(r'([\d.]+\s*[万wW]?)\s*次播放').firstMatch(card);
      if (viewMatch != null) views = viewMatch.group(1)!.trim();

      Logger().logSync('Parse',
          'jiuse 视频: ID=$id, 作者=$author, 时长=$duration, 标题=${title.length > 20 ? title.substring(0, 20) + "..." : title}');

      videos.add(VideoInfo(
        id: id,
        url: '$baseUrl$href',
        title: title,
        cover: cover,
        author: author,
        authorId: authorId,
        duration: duration,
        uploadDate: uploadDate,
        views: views,
      ));
    }

    Logger().logSync('Parse',
        'jiuse 解析完成: ${videos.length} 个视频（跳过高清 $hdSkipped 条）');
    return videos;
  }

  @override
  Future<SiteDetail> extractDetail(
      String html, VideoInfo video, String baseUrl) async {
    String? videoUrl;
    String? extractionMethod;
    final dataSrc = RegExp(
      r'<video[^>]*\bdata-src="([^"]+)"',
      caseSensitive: false,
    ).firstMatch(html);
    if (dataSrc != null) {
      // 站点常给协议相对地址（//cdn2.jiuse2.cloud/...）。
      // 原样交给 Dio 会抛 Unsupported scheme ''，任务 0% 直接失败。
      videoUrl = CrawlerConfig.resolveAbsoluteUrl(
          baseUrl, dataSrc.group(1)!.replaceAll('&amp;', '&'));
      extractionMethod = 'jiuse-data-src';
      await logger.log('Debug', 'jiuse data-src: ${videoUrl.length > 120 ? videoUrl.substring(0, 120) + "..." : videoUrl}');
    }
    // 兜底：有些页面把地址写在 video 的 source 子节点里
    if (videoUrl == null) {
      final srcMatch = RegExp(
        r'<video[^>]*>[\s\S]{0,400}?src="([^"]+\.m3u8[^"]*)"',
        caseSensitive: false,
      ).firstMatch(html);
      if (srcMatch != null) {
        videoUrl = CrawlerConfig.resolveAbsoluteUrl(
            baseUrl, srcMatch.group(1)!.replaceAll('&amp;', '&'));
        extractionMethod = 'jiuse-video-src';
      }
    }
    // data-src 有时指向站点内置的 12 秒样片（/hlsd/<名字>/index.m3u8），
    // 直接下载/播放就只有 11 秒，而且**所有视频都是同一段画面**。
    // 真实地址要靠联网接口换，交给 CrawlerCore 处理。
    return SiteDetail(
      videoUrl: videoUrl,
      method: extractionMethod,
      needsRealUrl:
          videoUrl == null || CrawlerConfig.isJiuseSampleUrl(videoUrl),
    );
  }

  /// 作者搜索结果列表（作者徽章里带投稿数）
  @override
  List<AuthorInfo>? parseAuthors(String html, String baseUrl) {
    final authors = <AuthorInfo>[];
    final seenNames = <String>{};

    for (final m in CrawlerConfig.jiuseAuthorBadgePattern.allMatches(html)) {
      final path = m.group(1)!;
      final authorParam = m.group(2)!.trim();
      final namePart = (m.group(3) ?? '').trim();
      final count = int.tryParse(m.group(4) ?? '0') ?? 0;
      if (authorParam.isEmpty || seenNames.contains(authorParam)) continue;
      seenNames.add(authorParam);
      authors.add(AuthorInfo(
        id: authorParam,
        name: namePart.isNotEmpty ? namePart : authorParam,
        videoCount: count,
        profileUrl: '$baseUrl$path',
      ));
    }
    logger.logSync('Parse', 'jiuse 作者搜索结果: ${authors.length} 个');
    return authors;
  }

  /// 分区页脚有路径式分页链接，拿不到再退回「条数 + 与上一页比对」
  @override
  SitePagination? decidePagination({
    required String html,
    required int page,
    required int itemCount,
    required String signature,
    required String lastSignature,
  }) {
    final fromLinks = CrawlerConfig.jiusePaginationHasMore(html, page);
    if (fromLinks != null) {
      return SitePagination(
        hasMore: fromLinks,
        parsed: true,
        rememberSignature: true,
        log: fromLinks
            ? 'jiuse 分页控件命中：存在大于第 $page 页的链接'
            : 'jiuse 分页控件命中：没有更靠后的页码链接，判定为最后一页',
      );
    }
    final hasMore = CrawlerConfig.jiusePageHasMore(
      itemCount: itemCount,
      page: page,
      signature: signature,
      lastSignature: lastSignature,
    );
    return SitePagination(
      hasMore: hasMore,
      parsed: true,
      rememberSignature: true,
      log: 'jiuse 无分页控件，按条数与重复内容判断：$itemCount 条',
    );
  }
}
