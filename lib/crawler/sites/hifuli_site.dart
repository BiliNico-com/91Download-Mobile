/// 嗨碰系站点（hifuli.com / hiporn.net）的解析实现
///
/// 只做 HTML 解析与 URL 拼装，不发任何 HTTP 请求。
/// 播放地址写在前端配置对象 window.HIPORN_WATCH 里（JSON-LD 的 contentUrl
/// 是同一份地址的兜底），sign/t 是带时效的签名，所以每次播放/下载都必须
/// 重新抓详情页，不能缓存地址。

import '../config.dart';
import '../../models/video_info.dart';
import '../../utils/logger.dart';
import 'site_handler.dart';

class HifuliSite extends SiteHandler {
  const HifuliSite();

  @override
  String get siteType => 'hifuli';

  /// 第 1 页不带页码（/hot），第 2 页起走路径式（/hot/page/2）
  @override
  String buildListUrl(String baseUrl, String urlPattern, int page) =>
      CrawlerConfig.buildHifuliListUrl(baseUrl, urlPattern, page);

  @override
  String buildAuthorUrl(String baseUrl, String authorId, int page) {
    final id = CrawlerConfig.normalizeHifuliAuthorId(authorId);
    return page <= 1
        ? baseUrl + '/u/' + id
        : baseUrl + '/u/' + id + '/page/' + page.toString();
  }

  @override
  String buildAuthorSearchUrl(String baseUrl, String keyword) =>
      CrawlerConfig.buildSearchUrl(baseUrl, 'hifuli', keyword);

  /// 解析嗨碰（hifuli.com / hiporn.net）的视频列表
  ///
  /// 首页与列表页是两套 DOM（首页卡片直接挂在 grid 下，列表页外面多一层
  /// article.hiporn-list-card 和 meta 行），但卡片本身的 class 一致，
  /// 所以统一按卡片切片取字段：
  ///   a.hiporn-video-card[href=/video/{数字id}-{slug}]
  ///     ├ div.hiporn-video-card-thumb > img[data-original=封面] + span.…duration
  ///     └ h3.hiporn-video-card-title 标题
  ///
  /// 注意：封面只在 data-original，src 恒为占位图 /dist/notfound.jpg。
  @override
  List<VideoInfo> parseVideoList(String html, String baseUrl) {
    final videos = <VideoInfo>[];
    final seenIds = <String>{};
    Logger().logSync('Parse', '解析 hifuli HTML, 长度: ${html.length}');

    for (final m in CrawlerConfig.hifuliCardPattern.allMatches(html)) {
      final card = m.group(0)!;

      final hrefMatch = CrawlerConfig.hifuliHrefPattern.firstMatch(card);
      if (hrefMatch == null) continue;
      final href = hrefMatch.group(1)!;
      final id = hrefMatch.group(2)!;
      if (seenIds.contains(id)) continue;
      seenIds.add(id);

      // 标题：卡片标题节点优先，取不到退回图片 alt
      String? title;
      final titleMatch = CrawlerConfig.hifuliTitlePattern.firstMatch(card);
      if (titleMatch != null) title = titleMatch.group(1);
      if (title == null || title.trim().isEmpty) {
        final alt = RegExp(r'alt="([^"]*)"', caseSensitive: false)
            .firstMatch(card)
            ?.group(1);
        if (alt != null && alt.trim().isNotEmpty) title = alt;
      }
      if (title == null || title.trim().isEmpty) continue;
      title = CrawlerConfig.stripInvisible(
              CrawlerConfig.unescapeHtml(title))
          .trim();

      // 封面：只认 data-original，src 是占位图
      String? cover;
      final coverMatch =
          CrawlerConfig.hifuliCoverPattern.firstMatch(card);
      if (coverMatch != null) {
        cover = CrawlerConfig.resolveAbsoluteUrl(
            baseUrl, coverMatch.group(1)!.trim());
      }

      // 时长：span.hiporn-video-card-duration（形如 41:11）
      String? duration;
      final durMatch =
          CrawlerConfig.hifuliDurationPattern.firstMatch(card);
      if (durMatch != null) {
        final d = durMatch.group(1)!.trim();
        if (d.isNotEmpty && d != '--:--') duration = d;
      }

      // 作者与上传时间都在卡片下方的 meta 行里（列表/搜索/推荐/热榜页专有）：
      //   div.hiporn-list-card-meta
      //     ├ a.hiporn-list-card-author[href=/u/{urlencode 名字}] > span 名字
      //     └ time.hiporn-list-card-time 「3天前」
      //
      // 作者 id 优先取站点给的 href：把显示名重新编码在「显示名 ≠ URL 名」
      // 时（含空格、emoji、大小写变体）会拼出打不开的主页地址。
      // meta 行只有 a/img/span/time，不含嵌套 div，所以切块不会截断。
      String? author;
      String? authorId;
      String? uploadDate;
      final metaMatch = CrawlerConfig.hifuliCardMetaPattern.firstMatch(card);
      if (metaMatch != null) {
        final meta = metaMatch.group(1)!;

        final hrefMatch =
            CrawlerConfig.hifuliCardAuthorHrefPattern.firstMatch(meta);
        final idFromHref = hrefMatch == null
            ? ''
            : CrawlerConfig.normalizeHifuliAuthorId(hrefMatch.group(1)!);

        final authorMatch =
            CrawlerConfig.hifuliCardAuthorPattern.firstMatch(meta);
        if (authorMatch != null) {
          final name = CrawlerConfig.stripInvisible(
                  CrawlerConfig.unescapeHtml(authorMatch.group(1)!))
              .trim();
          if (name.isNotEmpty) {
            author = name;
            // 「匿名」是站点给未登录/匿名投稿占的位，点进去只有一页无关视频，
            // 不提供跳转（保持原有行为）；有真实 href 时其余作者一律可跳。
            if (name != '匿名') {
              authorId = idFromHref.isNotEmpty
                  ? idFromHref
                  : Uri.encodeComponent(name);
            }
          }
        }

        final timeMatch =
            CrawlerConfig.hifuliCardTimePattern.firstMatch(meta);
        if (timeMatch != null) {
          final t = CrawlerConfig.stripInvisible(
                  CrawlerConfig.unescapeHtml(timeMatch.group(1)!))
              .trim();
          if (t.isNotEmpty) uploadDate = t;
        }
      }

      videos.add(VideoInfo(
        id: id,
        url: '$baseUrl$href',
        title: title,
        cover: cover,
        author: author,
        authorId: authorId,
        duration: duration,
        // 相对时间（3天前 / 4小时前），与详情页的绝对日期是同一件事
        uploadDate: uploadDate,
      ));
    }

    Logger().logSync('Parse', 'hifuli 解析完成: ${videos.length} 个视频');
    return videos;
  }

  /// 详情页：播放地址在 HIPORN_WATCH.player.url，元信息在 JSON-LD
  @override
  Future<SiteDetail> extractDetail(
      String html, VideoInfo video, String baseUrl) async {
    String? videoUrl;
    String? extractionMethod;
    String? hipornTitle;
    String? hipornAuthor;
    String? hipornAuthorId;
    String? hipornDuration;
    String? hipornDate;
    String? hipornViews;

    final playerMatch =
        CrawlerConfig.hifuliPlayerUrlPattern.firstMatch(html);
    if (playerMatch != null) {
      videoUrl = CrawlerConfig.resolveAbsoluteUrl(
          baseUrl, playerMatch.group(1)!.replaceAll('&amp;', '&'));
      extractionMethod = 'hifuli-HIPORN_WATCH';
    }
    if (videoUrl == null) {
      final contentMatch =
          CrawlerConfig.hifuliContentUrlPattern.firstMatch(html);
      if (contentMatch != null) {
        videoUrl = CrawlerConfig.resolveAbsoluteUrl(
            baseUrl, contentMatch.group(1)!.replaceAll('&amp;', '&'));
        extractionMethod = 'hifuli-jsonld';
      }
    }
    if (videoUrl != null) {
      await logger.log('Debug',
          'hifuli 播放地址($extractionMethod): ${videoUrl.length > 120 ? videoUrl.substring(0, 120) + "..." : videoUrl}');
    } else {
      await logger.log('Warning', 'hifuli 详情页未找到 player.url / contentUrl');
    }

    final titleMatch =
        CrawlerConfig.hifuliDetailTitlePattern.firstMatch(html);
    if (titleMatch != null) {
      final t = CrawlerConfig.stripInvisible(
              CrawlerConfig.unescapeHtml(titleMatch.group(1)!))
          .trim();
      if (t.isNotEmpty) hipornTitle = t;
    }
    final authorMatch =
        CrawlerConfig.hifuliDetailAuthorPattern.firstMatch(html);
    if (authorMatch != null) {
      final a = CrawlerConfig.stripInvisible(
              CrawlerConfig.unescapeHtml(authorMatch.group(1)!))
          .trim();
      if (a.isNotEmpty) {
        hipornAuthor = a;
        // 详情页作者块没有 /u/ 链接（全文 0 命中），只能按站点路径规则
        // 把名字编码成 /u/{urlencode 名字}。列表页带来的 authorId 优先，
        // 这里是「直接从详情页打开、没有列表上下文」时的兜底。
        if (a != '匿名') hipornAuthorId = Uri.encodeComponent(a);
      }
    }
    final durMatch =
        CrawlerConfig.hifuliIsoDurationPattern.firstMatch(html);
    if (durMatch != null) {
      hipornDuration =
          CrawlerConfig.formatIsoDuration(durMatch.group(0));
    }
    final dateMatch =
        CrawlerConfig.hifuliUploadDatePattern.firstMatch(html);
    if (dateMatch != null) {
      // 站点给的是 ISO 串（2018-08-11T00:00:00+08:00），
      // 原样上屏会带着时分秒和时区，播放页的胶囊放不下。
      hipornDate =
          CrawlerConfig.formatHifuliDate(dateMatch.group(1)!.trim());
    }
    final viewsMatch =
        CrawlerConfig.hifuliViewsPattern.firstMatch(html);
    if (viewsMatch != null) hipornViews = viewsMatch.group(1)!.trim();

    return SiteDetail(
      videoUrl: videoUrl,
      method: extractionMethod,
      title: hipornTitle,
      author: hipornAuthor,
      authorId: hipornAuthorId,
      duration: hipornDuration,
      uploadDate: hipornDate,
      views: hipornViews,
    );
  }

  /// 从嗨碰的视频列表/搜索页里提炼作者（去重后按命中条数排序）
  ///
  /// 站点没有独立的「搜索到用户」区块，作者信息只存在于每张卡片的 meta 行，
  /// 所以搜索作者只能复用它。这里刻意和 [_parseVideoListHifuli] 用同一套
  /// 正则与 id 规范，保证「列表里能点的作者」与「搜索出来的作者」是同一批、
  /// 同一个 authorId，否则点进主页会 404。
  @override
  List<AuthorInfo>? parseAuthors(String html, String baseUrl) {
    final counts = <String, int>{};
    final names = <String, String>{};

    // 显示名与 href 不一致时以 href 为准，所以用 href 派生的 id 做去重键。
    for (final card in CrawlerConfig.hifuliCardPattern.allMatches(html)) {
      final metaMatch =
          CrawlerConfig.hifuliCardMetaPattern.firstMatch(card.group(0)!);
      if (metaMatch == null) continue;
      final meta = metaMatch.group(1)!;

      final nameMatch = CrawlerConfig.hifuliCardAuthorPattern.firstMatch(meta);
      if (nameMatch == null) continue;
      final name = CrawlerConfig.stripInvisible(
              CrawlerConfig.unescapeHtml(nameMatch.group(1)!))
          .trim();
      // 「匿名」是站点给匿名投稿占的位，主页里没有作者维度内容，不收录。
      if (name.isEmpty || name == '匿名') continue;

      final hrefMatch =
          CrawlerConfig.hifuliCardAuthorHrefPattern.firstMatch(meta);
      final id = hrefMatch == null
          ? Uri.encodeComponent(name)
          : CrawlerConfig.normalizeHifuliAuthorId(hrefMatch.group(1)!);
      if (id.isEmpty) continue;

      names[id] = name;
      counts[id] = (counts[id] ?? 0) + 1;
    }

    final authors = names.entries
        .map((e) => AuthorInfo(
              id: e.key,
              name: e.value,
              // 站点不给作者总投稿数，这里用「本次结果里命中的视频条数」代替：
              // 它是一个真实数字，比硬编码 0 有信息量，也能用来排序。
              videoCount: counts[e.key] ?? 0,
              profileUrl: '$baseUrl/u/${e.key}',
            ))
        .toList();

    // 命中数多的排前面：搜索时作者的相关性和这个基本成正比。
    authors.sort((a, b) => b.videoCount.compareTo(a.videoCount));
    return authors;
  }

  /// 嗨碰只有 /hot、/recommend、/s 带分页控件，data-last-page 数字不可信，
  /// 唯一可靠判据是 data-next-url 是否为空。首页没有分页控件且每次请求都重排，
  /// 直接当单页信息流。
  @override
  SitePagination? decidePagination({
    required String html,
    required int page,
    required int itemCount,
    required String signature,
    required String lastSignature,
  }) {
    final hasMore = CrawlerConfig.hifuliHasNextPage(html);
    if (hasMore == null) {
      return const SitePagination(
        hasMore: false,
        parsed: true,
        log: 'hifuli 页面无分页控件，按单页信息流处理',
      );
    }
    return SitePagination(
      hasMore: hasMore,
      parsed: true,
      log: hasMore
          ? 'hifuli 分页控件命中：data-next-url 不为空，还有下一页'
          : 'hifuli 分页控件命中：data-next-url 为空，已是最后一页',
    );
  }
}
