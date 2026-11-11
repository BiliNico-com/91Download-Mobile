/// 原创系站点（ml0987 / hsex 这类通用 CMS）的解析实现
///
/// 只做 HTML 解析与 URL 拼装，不发任何 HTTP 请求。
/// 这类站点没有专属的播放地址字段，详情页交给 CrawlerCore 的通用兜底
/// （<source> / m3u8 正则 / JS 变量），这里只提供列表与作者页规则。

import '../config.dart';
import '../../models/video_info.dart';
import '../../utils/logger.dart';
import 'site_handler.dart';

class OriginalSite extends SiteHandler {
  const OriginalSite();

  @override
  String get siteType => 'original';

  @override
  String buildAuthorUrl(String baseUrl, String authorId, int page) =>
      baseUrl + '/user-' + page.toString() + '.htm?author=' + authorId;

  @override
  String buildAuthorSearchUrl(String baseUrl, String keyword) =>
      baseUrl + '/search.htm?search=' + Uri.encodeComponent(keyword);

  /// 解析视频列表 HTML - original CMS（ml0987/hsex 风格）
  /// 严格参照 Python 版本 _extract_search_results
  @override
  List<VideoInfo> parseVideoList(String html, String baseUrl) {
    final videos = <VideoInfo>[];
    final seenIds = <String>{};
    
    Logger().logSync('Parse', '解析 original HTML, 长度: ${html.length}');
    
    // 策略1: 完整容器解析 - 匹配 thumbnail 容器
    // <div class="thumbnail">
    //   <a>封面</a>
    //   <div class="caption title">标题</div>
    //   <div class="info"><p>&nbsp;&nbsp;<a href="user.htm?author=xxx">作者名</a></p></div>
    // </div>
    // ✅ 修复：使用平衡 div 计数法替代正则，确保完整捕获包括 info 区域
    final containers = _extractBalancedDivContents(html, 'thumbnail');
    
    for (final container in containers) {
      
      // 提取视频链接和ID
      final videoLinkMatch = RegExp(r'href="(video-(\d+)\.htm)"').firstMatch(container);
      if (videoLinkMatch == null) continue;
      
      final videoHref = videoLinkMatch.group(1)!;
      final videoId = videoLinkMatch.group(2)!;
      
      if (seenIds.contains(videoId)) continue;
      seenIds.add(videoId);
      
      // 提取封面（支持HTML实体编码 &#39; 和普通引号）
      String? cover;
      final coverMatch = RegExp(r'background-image:\s*url\(([^)]+)\)').firstMatch(container);
      if (coverMatch != null) {
        var coverUrl = coverMatch.group(1)!.trim();
        // 去掉引号（包括HTML实体编码）
        coverUrl = coverUrl.replaceAll('&#39;', '').replaceAll('&apos;', '');
        coverUrl = coverUrl.replaceAll(RegExp(r'''['"]'''), '');
        if (coverUrl.startsWith('http')) {
          cover = coverUrl;
        } else if (coverUrl.isNotEmpty) {
          cover = '$baseUrl/$coverUrl';
        }
      }
      
      // 提取标题（允许 title= "xxx" 或 title="xxx" 格式）
      String? title;
      final titleMatch = RegExp(r'title\s*=\s*"([^"]+)"').firstMatch(container);
      if (titleMatch != null) {
        title = titleMatch.group(1)!.trim();
      }
      if (title == null) {
        // 备用：从 h5 或标题区域提取
        final h5Match = RegExp(r'<h5[^>]*>.*?<a[^>]*>([^<]+)</a>').firstMatch(container);
        if (h5Match != null) {
          title = h5Match.group(1)!.trim();
        }
      }
      if (title == null) continue;
      
      // 提取时长 <var class="duration">时长</var>
      String? duration;
      final durationMatch = RegExp(r'<var[^>]*class="[^"]*duration[^"]*"[^>]*>([^<]+)</var>').firstMatch(container);
      if (durationMatch != null) {
        duration = durationMatch.group(1)!.trim();
      }
      
      // 提取作者（多种格式尝试）
      // ml0987 格式: <a href="user.htm?author=xxx">作者名</a>
      String? author;
      String? authorId;
      
      // 格式1: 带链接的作者 <a href="user.htm?author=xxx">作者名</a>
      var authorMatch = RegExp(
        r'<a[^>]*href="[^"]*user\.htm\?author=([^"&]+)"[^>]*>([^<]*)</a>',
        caseSensitive: false
      ).firstMatch(container);
      if (authorMatch != null) {
        authorId = authorMatch.group(1);
        author = authorMatch.group(2)?.replaceAll('&nbsp;', '').replaceAll(CrawlerConfig.htmlEntityPattern, '').trim();
      }
      
      // 格式2: 纯文本作者 作者：xxx（跳过HTML标签）
      if (author == null || author.isEmpty) {
        final textMatch = RegExp(r'作者[：:]\s*(?:</?[^>]+>\s*)*([^<\n\r]+)').firstMatch(container);
        if (textMatch != null) {
          author = textMatch.group(1)?.trim();
        }
      }
      
      // 清理作者名
      if (author != null) {
        // ✅ 修复：先剥离HTML标签，防止标签残留
        author = author.replaceAll(CrawlerConfig.htmlTagPattern, '');
        author = author.replaceAll(CrawlerConfig.whitespacePattern, ' ').trim();
        if (author.isEmpty) author = null;
      }
      
      // 提取上传时间（多种格式：绝对日期 + 相对时间）
      String? uploadDate;
      // 格式1: <span class="added-time">2024-01-15</span> 或 <span class="added-time">3天前</span>
      var dateMatch = RegExp(r'<span[^>]*class="[^"]*added[^"]*"[^>]*>([^<]+)</span>', caseSensitive: false).firstMatch(container);
      if (dateMatch != null) {
        uploadDate = dateMatch.group(1)!.trim();
      }
      // 格式2: 添加/上传/更新 时间标签（中文）
      if (uploadDate == null || uploadDate!.isEmpty) {
        dateMatch = RegExp(r'(?:添加|上传|更新)[时日期\s]*[：:]\s*(.+?)(?:<|\s*$)', caseSensitive: false).firstMatch(container);
        if (dateMatch != null) {
          uploadDate = dateMatch.group(1)!.trim();
        }
      }
      // 格式3: 相对时间（X天前 / X小时前 / X分钟前 / 刚刚）
      // 支持 "43 分钟 前"（带空格）和 "33分钟前"（无空格）两种格式
      if (uploadDate == null || uploadDate!.isEmpty) {
        dateMatch = RegExp(r'(\d+\s*[天时分秒钟小时月周]+\s*前|刚刚|刚才)', caseSensitive: false).firstMatch(container);
        if (dateMatch != null) {
          uploadDate = dateMatch.group(1)!.trim();
        }
      }
      // 格式4: 绝对日期 YYYY-MM-DD 或 YYYY/MM/DD
      if (uploadDate == null || uploadDate!.isEmpty) {
        dateMatch = RegExp(r'(\d{4}[-/]\d{1,2}[-/]\d{1,2})').firstMatch(container);
        if (dateMatch != null) {
          uploadDate = dateMatch.group(1)!.trim();
        }
      }
      
      // 从封面URL提取封面ID
      String? coverId;
      final coverIdMatch = RegExp(r'/(\d+)\.(webp|jpg|png)').firstMatch(cover ?? '');
      if (coverIdMatch != null) {
        coverId = coverIdMatch.group(1);
      }
      
      // 详细日志
      Logger().logSync('Parse', '视频#${videos.length + 1}: ID=$videoId, 封面ID=$coverId, 作者=$author, 作者ID=$authorId, 时长=$duration, 更新时间=$uploadDate, 标题=${title.length > 20 ? title.substring(0, 20) + "..." : title}');
      
      videos.add(VideoInfo(
        id: videoId,
        url: '$baseUrl/$videoHref',
        title: title,
        cover: cover,
        author: author,
        authorId: authorId,
        duration: duration,
        uploadDate: uploadDate,
      ));
    }
    
    Logger().logSync('Parse', '策略1(thumbnail容器)找到 ${videos.length} 个视频');
    
    // 策略2: 简单链接格式（兜底）
    if (videos.isEmpty) {
      // 支持HTML实体编码的封面URL
      final pattern2 = RegExp(
        r'''<a[^>]*href="[^"]*video-(\d+)\.htm[^"]*"[^>]*>.*?background-image:\s*url\(([^)]+)\)''',
        caseSensitive: false,
        dotAll: true,
      );
      
      for (final match in pattern2.allMatches(html)) {
        final videoId = match.group(1)!;
        var coverUrl = match.group(2)!.trim();
        
        // 去掉引号和HTML实体编码
        coverUrl = coverUrl.replaceAll('&#39;', '').replaceAll('&apos;', '');
        coverUrl = coverUrl.replaceAll(RegExp(r'''['"]'''), '');
        
        String? cover;
        if (coverUrl.startsWith('http')) {
          cover = coverUrl;
        } else if (coverUrl.isNotEmpty) {
          cover = '$baseUrl/$coverUrl';
        }
        
        if (seenIds.contains(videoId)) continue;
        seenIds.add(videoId);
        
        // 提取标题（允许 title= "xxx" 或 title="xxx" 格式）
        String? title;
        final pos = match.end;
        final blockEnd = pos + 500 < html.length ? pos + 500 : html.length;
        final block = html.substring(pos, blockEnd);
        final titleMatch = RegExp(r'title\s*=\s*"([^"]+)"').firstMatch(html.substring(match.start, match.end + 500));
        if (titleMatch != null) {
          title = titleMatch.group(1)!.trim();
        }
        if (title == null) continue;
        
        // 尝试从上下文提取时长和作者
        String? duration;
        String? author;
        
        final durationMatch = RegExp(r'<var[^>]*class="[^"]*duration[^"]*"[^>]*>([^<]+)</var>').firstMatch(block);
        if (durationMatch != null) {
          duration = durationMatch.group(1)!.trim();
        }
        
        // 提取作者（多种格式）
        var authorMatch = RegExp(r'<a[^>]*href="[^"]*user\.htm\?author=([^"&]+)"[^>]*>([^<]*)</a>', caseSensitive: false).firstMatch(block);
        if (authorMatch != null) {
          author = authorMatch.group(2)?.replaceAll('&nbsp;', '').trim();
        }
        // 格式2: 纯文本
        if (author == null || author!.isEmpty) {
          final textMatch = RegExp(r'作者[：:]\s*([^<\n\r]{2,20})').firstMatch(block);
          if (textMatch != null) {
            author = textMatch.group(1)?.trim();
          }
        }
        
        // 从封面URL提取封面ID
        String? coverId;
        final coverIdMatch = RegExp(r'/(\d+)\.(webp|jpg|png)').firstMatch(cover ?? '');
        if (coverIdMatch != null) {
          coverId = coverIdMatch.group(1);
        }
        
        // 详细日志
        Logger().logSync('Parse', '视频#${videos.length + 1}: ID=$videoId, 封面ID=$coverId, 作者=$author, 时长=$duration, 标题=${title.length > 20 ? title.substring(0, 20) + "..." : title}');
        
        videos.add(VideoInfo(
          id: videoId,
          url: '$baseUrl/video-$videoId.htm',
          title: title,
          cover: cover,
          author: author,
          authorId: null, // 策略2无法提取作者ID
          duration: duration,
        ));
      }
      
      Logger().logSync('Parse', '策略2找到 ${videos.length} 个视频');
    }
    
    Logger().logSync('Parse', '解析完成: ${videos.length} 个视频');
    return videos;
  }

  /// 没有专属提取策略，全部交给 CrawlerCore 的通用兜底
  @override
  Future<SiteDetail> extractDetail(
          String html, VideoInfo video, String baseUrl) async =>
      const SiteDetail();

  /// ✅ 新增：平衡 div 计数法提取指定 class 的 div 完整内容
  /// 解决正则懒惰匹配无法正确捕获嵌套 div 完整内容的问题
  static List<String> _extractBalancedDivContents(String html, String className) {
    final results = <String>[];
    final openPattern = RegExp(
      '<div[^>]*class="[^"]*$className[^"]*"[^>]*>',
      caseSensitive: false,
    );
    
    // 小写副本只算一次。以前写在 for 循环体内，匹配到 N 个区块就把
    // 整篇 HTML（几百 KB）重复小写化 N 次 —— 一次列表解析里这是最贵的开销。
    final lowerHtml = html.toLowerCase();

    for (final openMatch in openPattern.allMatches(html)) {
      int start = openMatch.end;
      int depth = 1;
      int pos = start;
      
      while (pos < lowerHtml.length && depth > 0) {
        final nextOpen = lowerHtml.indexOf('<div', pos);
        final nextClose = lowerHtml.indexOf('</div>', pos);
        
        if (nextClose == -1) break;
        
        if (nextOpen != -1 && nextOpen < nextClose) {
          // 确认是真正的 div 开标签（后面跟空格或 >）
          final charAfter = nextOpen + 4 < html.length ? html[nextOpen + 4] : '';
          if (charAfter == ' ' || charAfter == '>' || charAfter == '\n' || charAfter == '\r') {
            depth++;
          }
          pos = nextOpen + 1;
        } else {
          depth--;
          if (depth == 0) {
            results.add(html.substring(start, nextClose));
          }
          pos = nextClose + 6;
        }
      }
    }
    return results;
  }
}
