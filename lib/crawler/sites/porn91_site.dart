/// 91porn 系站点（91porn.com）的解析实现
///
/// 只做 HTML 解析与 URL 拼装，不发任何 HTTP 请求。
/// 「先 GET 取 cookie 再 POST 提交语言」留在 CrawlerCore —— 那是会话级行为，
/// 一旦搬进这里，站点文件就必须持有 Dio，也就没法单独读、单独测了。

import '../config.dart';
import '../../models/video_info.dart';
import '../../utils/logger.dart';
import 'site_handler.dart';

class Porn91Site extends SiteHandler {
  const Porn91Site();

  @override
  String get siteType => 'porn91';

  /// 列表/详情/作者页都带 _t 时间戳防缓存（站点 CDN 会缓存页面）
  @override
  bool get addCacheBuster => true;

  @override
  String buildAuthorUrl(String baseUrl, String authorId, int page) =>
      baseUrl + '/author.php?author=' + authorId + '&page=' + page.toString();

  @override
  String buildAuthorSearchUrl(String baseUrl, String keyword) =>
      baseUrl +
      '/search_result.php?search_id=' +
      Uri.encodeComponent(keyword) +
      '&search_type=author';

  /// 解析视频列表 HTML - porn91 CMS（91porn 风格）
  @override
  List<VideoInfo> parseVideoList(String html, String baseUrl) {
    final videos = <VideoInfo>[];
    final seenIds = <String>{};
    
    Logger().logSync('Parse', '解析 porn91 HTML, 长度: ${html.length}');
    
    // 策略1：只匹配 col-lg-3 容器内的视频卡片（过滤 col-lg-8 广告）
    // 找到所有容器位置
    final containerMatches = CrawlerConfig.containerPattern.allMatches(html).toList();
    Logger().logSync('Parse', '找到 ${containerMatches.length} 个容器匹配');
    
    for (var i = 0; i < containerMatches.length; i++) {
      final match = containerMatches[i];
      final start = match.start;
      
      // 确定容器结束位置：找到下一个 <div class="col-xs-12 开始
      // 这样可以避开中间的广告位
      final nextDivPattern = RegExp(r'<div[^>]*class="[^"]*col-xs-12[^"]*"', caseSensitive: false);
      int? end;
      for (final m in nextDivPattern.allMatches(html)) {
        if (m.start > start) {
          end = m.start;
          break;
        }
      }
      
      final containerEnd = end ?? html.length;
      final wellContent = html.substring(start, containerEnd);
      
      // 提取 viewkey
      final viewkeyMatch = CrawlerConfig.viewkeyPattern.firstMatch(wellContent);
      if (viewkeyMatch == null) continue;
      
      final videoHref = viewkeyMatch.group(1)!.replaceAll('&amp;', '&');
      final viewkey = viewkeyMatch.group(2)!;
      
      // ✅ 修复：直接提取 img-responsive 的 src 属性获取封面ID
      // 注意：不能依赖容器ID（如 playvthumb_XXXXXX），因为它与实际图片文件名不一致！
      String? cover;
      String? coverId;
      
      // 优先从 img-responsive 标签提取（这是实际正确的封面URL）
      final imgMatch = RegExp(r'<img[^>]+class="img-responsive"[^>]+src="([^"]+)"')
          .firstMatch(wellContent);
      if (imgMatch != null) {
        final imgSrc = imgMatch.group(1)!;
        // 从URL中提取文件名作为封面ID（如 .../1191387.jpg -> 1191387）
        final idMatch = RegExp(r'/(\d+)\.(?:jpe?g|webp|png)', caseSensitive: false)
            .firstMatch(imgSrc);
        if (idMatch != null && idMatch.group(1) != null) {
          coverId = idMatch.group(1);
          cover = VideoInfo.buildCoverUrl(coverId!);
        } else if (imgSrc.startsWith('http')) {
          cover = imgSrc;
        }
      }
      
      // 提取标题
      final titleMatch = CrawlerConfig.titlePattern.firstMatch(wellContent);
      if (titleMatch == null) continue;
      
      // 站点把标题逐字拆开并插入变体选择符（U+FE00~U+FE0F），
      // 这些字符没有字形但占位，不剔除的话界面上看着就是字间多了空格。
      final title = CrawlerConfig.stripInvisible(titleMatch.group(1)!).trim();
      if (title.isEmpty) continue;
      
      // 提取作者（尝试多种格式）
      String? author;
      
      // 格式1: 作者：</span>xxx
      var authorMatch = CrawlerConfig.authorPattern.firstMatch(wellContent);
      if (authorMatch != null) {
        author = authorMatch.group(1)!.trim();
      }
      
      // 格式2: <a href="...author=xxx">作者名</a>
      if (author == null || author.isEmpty) {
        final linkMatch = RegExp(r'href="[^"]*author=([^"&]+)[^"]*"[^>]*>([^<]+)</a>', caseSensitive: false).firstMatch(wellContent);
        if (linkMatch != null) {
          author = linkMatch.group(2)?.trim();
        }
      }

      // 格式2b: <span class="info">From:</span> 后紧跟作者名。
      // 91porn 卡片里作者的写法是 From:，不是「作者：」，
      // 只认中文标签会漏掉一半视频的作者。
      if (author == null || author.isEmpty) {
        final fromMatch = RegExp(
          r'From[：:]\s*</span>\s*([^<\n\r]+)',
          caseSensitive: false,
        ).firstMatch(wellContent);
        if (fromMatch != null) {
          author = fromMatch.group(1)?.trim();
        }
      }
      
      // 格式3: 作者：xxx（直接文本，跳过HTML标签）
      if (author == null || author.isEmpty) {
        final textMatch = RegExp(r'作者[：:]\s*(?:</?[^>]+>\s*)*([^<\n\r]+)').firstMatch(wellContent);
        if (textMatch != null) {
          author = textMatch.group(1)?.trim();
        }
      }
      
      // 清理作者名（去掉HTML标签和特殊字符）
      if (author != null) {
        // ✅ 修复：先剥离HTML标签，防止 </span> 等标签残留
        author = author.replaceAll(CrawlerConfig.htmlTagPattern, '');
        author = author.replaceAll('&nbsp;', '');
        author = author.replaceAll(CrawlerConfig.htmlEntityPattern, '');
        // 作者名和标题一样被塞了变体选择符，必须一并剔除；
        // 放在 whitespacePattern 之前，否则这些字符会被当成空白折叠成空格。
        author = CrawlerConfig.stripInvisible(author);
        author = author.replaceAll(CrawlerConfig.whitespacePattern, ' ').trim();
        if (author.isEmpty) author = null;
      }
      
      // 提取时长
      String? duration;
      final durationMatch = CrawlerConfig.durationPattern.firstMatch(wellContent);
      if (durationMatch != null) {
        duration = durationMatch.group(1)!.trim();
      }
      
      // 提取上传时间（多种格式：绝对日期 + 相对时间）
      String? uploadDate;
      // 格式1: <span class="added-time">2024-01-15</span> 或 <span class="added-time">3天前</span>
      var dateMatch = RegExp(r'<span[^>]*class="[^"]*added[^"]*"[^>]*>([^<]+)</span>', caseSensitive: false).firstMatch(wellContent);
      if (dateMatch != null) {
        uploadDate = dateMatch.group(1)!.trim();
      }
      // 格式2: 添加/上传/更新 时间标签（中文）
      if (uploadDate == null || uploadDate!.isEmpty) {
        dateMatch = RegExp(r'(?:添加|上传|更新)[时日期\s]*[：:]\s*(.+?)(?:<|\s*$)', caseSensitive: false).firstMatch(wellContent);
        if (dateMatch != null) {
          uploadDate = dateMatch.group(1)!.trim();
        }
      }
      // 格式3: 相对时间（X天前 / X小时前 / X分钟前 / 刚刚）
      // 支持 "43 分钟 前"（带空格）和 "33分钟前"（无空格）两种格式
      if (uploadDate == null || uploadDate!.isEmpty) {
        dateMatch = RegExp(r'(\d+\s*[天时分秒钟小时月周]+\s*前|刚刚|刚才)', caseSensitive: false).firstMatch(wellContent);
        if (dateMatch != null) {
          uploadDate = dateMatch.group(1)!.trim();
        }
      }
      // 格式4: 绝对日期 YYYY-MM-DD 或 YYYY/MM/DD
      if (uploadDate == null || uploadDate!.isEmpty) {
        dateMatch = RegExp(r'(\d{4}[-/]\d{1,2}[-/]\d{1,2})').firstMatch(wellContent);
        if (dateMatch != null) {
          uploadDate = dateMatch.group(1)!.trim();
        }
      }
      
      // 构造完整 URL
      String videoUrl;
      if (videoHref.startsWith('http')) {
        videoUrl = videoHref;
      } else if (videoHref.startsWith('/')) {
        videoUrl = '$baseUrl$videoHref';
      } else {
        videoUrl = '$baseUrl/$videoHref';
      }
      
      // 去重
      if (seenIds.contains(viewkey)) continue;
      seenIds.add(viewkey);
      
      // 详细日志
      Logger().logSync('Parse', '视频#${videos.length + 1}: ID=$viewkey, 封面ID=$coverId, 作者=$author, 时长=$duration, 标题=${title.length > 20 ? title.substring(0, 20) + "..." : title}');
      
      videos.add(VideoInfo(
        id: viewkey,
        url: videoUrl,
        title: title,
        cover: cover,
        author: author,
        authorId: null, // porn91 没有作者ID
        duration: duration,
        uploadDate: uploadDate,
      ));
    }
    
    Logger().logSync('Parse', '解析完成: ${videos.length} 个视频');
    
    return videos;
  }

  /// 详情页：播放地址藏在掺了变形的 <source> 标签里，三条策略依次尝试
  @override
  Future<SiteDetail> extractDetail(
      String html, VideoInfo video, String baseUrl) async {
    String? videoUrl;
    String? extractionMethod;

    
    // ✅ 从播放页 poster 属性提取视频ID（如 poster="https://.../thumb/848765.jpg"）
    // 注意：列表页封面ID与视频ID无关，必须用播放页poster ID
    String? posterVideoId;
    // 站点同时存在 .jpg / .webp 两种封面后缀，两种都要认，
    // 否则 poster ID 取不到，下面按 ID 匹配真实视频地址那步会失效。
    final posterMatch =
        RegExp(r'poster="[^"]*thumb/(\d+)\.(?:jpe?g|webp|png)"')
            .firstMatch(html);
    if (posterMatch != null) {
      posterVideoId = posterMatch.group(1);
      await logger.log('Debug', '播放页poster ID: $posterVideoId');
    } else {
      await logger.log('Debug', '⚠️ 未找到播放页poster属性');
    }
    
    // 策略 A: strencode2("%3c%73%6f...") — URL 编码的 <source> 标签
    // 可能有多个strencode2调用，优先匹配poster ID
    final strencodePattern = RegExp(r'''strencode2\(["'](%[0-9a-fA-F]{2}[^"']+)["']\)''');
    final strencodeMatches = strencodePattern.allMatches(html).toList();
    await logger.log('Debug', '找到 ${strencodeMatches.length} 个strencode2调用');
    
    for (var i = 0; i < strencodeMatches.length; i++) {
      final m = strencodeMatches[i];
      try {
        final encoded = m.group(1)!;
        final decoded = Uri.decodeComponent(encoded);
        await logger.log('Debug', 'strencode2#${i+1} 解码结果: ${decoded.length > 200 ? decoded.substring(0, 200) + "..." : decoded}');
        
        // 提取 src 属性
        final srcPattern = RegExp(r'''src=["']([^"']+)["']''', caseSensitive: false);
        final srcMatch = srcPattern.firstMatch(decoded);
        
        if (srcMatch != null) {
          final src = srcMatch.group(1)?.replaceAll('&amp;', '&') ?? '';
          if (src.contains('.mp4') || src.contains('.m3u8')) {
            // 广告片也可能被站点塞进 strencode2。取「首个」时若不排掉，
            // 用户下到的就是那条几十秒的推广片（与正片完全无关）。
            if (CrawlerConfig.knownAdVideoIds.any(src.contains)) {
              await logger.log('Debug', '跳过广告视频地址(strencode2): ${src.substring(0, 60)}...');
              continue;
            }
            // 提取视频URL中的ID
            final urlIdMatch = RegExp(r'/(\d+)\.(?:mp4|m3u8)').firstMatch(src);
            final urlVideoId = urlIdMatch?.group(1);
            await logger.log('Debug', '提取到视频URL: ID=$urlVideoId, URL=${src.length > 100 ? src.substring(0, 100) + "..." : src}');
            
            // 优先匹配poster ID
            if (posterVideoId != null && urlVideoId == posterVideoId) {
              videoUrl = src;
              extractionMethod = 'strencode2解码(ID匹配)';
              await logger.log('Debug', '✅ poster ID匹配成功: posterVideoId=$posterVideoId');
              break;  // 找到匹配的，退出循环
            } else if (videoUrl == null) {
              // 没有poster ID时，取第一个作为候选
              videoUrl = src;
              extractionMethod = 'strencode2解码(首个)';
              await logger.log('Debug', '⚠️ poster ID不匹配 (posterID=$posterVideoId, 视频ID=$urlVideoId)');
            }
          }
        }
      } catch (e) {
        await logger.log('Debug', 'strencode2解码失败: $e');
      }
    }
    
    // 策略 B: 直接查找 <source> 标签
    // 优先匹配封面ID，排除已知广告
    if (videoUrl == null) {
      
      final sourcePattern = RegExp(r'''<source[^>]+src=["']([^"']+)["']''', caseSensitive: false);
      final sourceMatches = sourcePattern.allMatches(html).toList();
      
      // 优先匹配poster ID
      for (var i = 0; i < sourceMatches.length; i++) {
        final match = sourceMatches[i];
        final src = match.group(1)?.replaceAll('&amp;', '&') ?? '';
        
        if (src.contains('.mp4') || src.contains('.m3u8')) {
          // 提取视频URL中的ID
          final urlIdMatch = RegExp(r'/(\d+)\.(?:mp4|m3u8)').firstMatch(src);
          final urlVideoId = urlIdMatch?.group(1);
          
          // 优先匹配poster ID
          if (posterVideoId != null && urlVideoId == posterVideoId) {
            videoUrl = src;
            extractionMethod = 'source标签(ID匹配)';
            break;
          }
        }
      }
      
      // 如果没有匹配到封面ID，取第一个非广告的source
      if (videoUrl == null) {
        for (var i = 0; i < sourceMatches.length; i++) {
          final match = sourceMatches[i];
          final src = match.group(1)?.replaceAll('&amp;', '&') ?? '';
          
          if (src.contains('.mp4') || src.contains('.m3u8')) {
            // 排除已知的广告视频ID
            //
            // 91porn 的播放页里 <source> 常常整段就是广告片（358999），
            // 真实地址只藏在下面的 strencode2 里。这里必须认出来，
            // 否则会拿广告地址去下载，用户下到的是几十秒的推广片。
            if (CrawlerConfig.knownAdVideoIds.any(src.contains)) {
              await logger.log('Debug', '跳过广告视频地址: ${src.substring(0, 60)}...');
              continue;
            }
            videoUrl = src;
            extractionMethod = 'source标签(首个非广告)';
            break;
          }
        }
      }
    }
    
    // 策略 C: 查找内嵌 JavaScript 中的视频 URL
    if (videoUrl == null) {
      final jsPatterns = [
        r'''\.(?:mp4|m3u8)["']?\s*;''',  // 简化匹配
        r'''["']https?://[^"']+\.(?:mp4|m3u8)[^"']*["']''',
      ];
      
      for (final pattern in jsPatterns) {
        final match = RegExp(pattern, caseSensitive: false).firstMatch(html);
        if (match != null) {
          final urlMatch = RegExp(r'''https?://[^"'\s]+\.(?:mp4|m3u8)[^"'\s]*''').firstMatch(match.group(0)!);
          if (urlMatch != null) {
            videoUrl = urlMatch.group(0);
            extractionMethod = 'JS内嵌';
            break;
          }
        }
      }
    }

    return SiteDetail(videoUrl: videoUrl, method: extractionMethod);
  }
}
