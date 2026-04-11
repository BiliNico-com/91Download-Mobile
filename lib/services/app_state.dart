import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'dart:io';
import '../crawler/crawler_core.dart';
import '../models/video_info.dart';
import '../utils/logger.dart';
import 'download_manager.dart';

class AppState extends ChangeNotifier {
  // 站点配置 - 默认为空，用户必须选择
  String? currentSite;
  
  // 下载目录
  String downloadDir = '';
  bool permissionGranted = false;
  
  // Debug模式
  bool debugMode = false;

  // 实时日志开关
  bool realtimeLogEnabled = false;

  // 主题
  bool isDarkMode = true;
  
  // 回顶部按钮设置
  bool showBackToTop = true;
  String backToTopPosition = 'right'; // 'left' 或 'right'

  // 外部播放器设置
  bool useExternalPlayer = false;
  
  // 视频显示模式: 'grid' 大图模式, 'list' 列表模式
  String videoDisplayMode = 'grid';

  // 当前页面索引（用于导航）
  int currentPageIndex = 0;
  Function(int)? navigateToPage;  // 由 MainPage 设置

  // 爬虫实例
  CrawlerCore? _crawler;
  
  // 下载管理器
  final DownloadManager downloadManager = DownloadManager();

  CrawlerCore? get crawler {
    if (currentSite == null) return null;
    _crawler ??= CrawlerCore(baseUrl: currentSite!);
    // 设置下载管理器
    if (_crawler != null && downloadDir.isNotEmpty) {
      downloadManager.setup(_crawler!, downloadDir);
    }
    return _crawler;
  }

  // 初始化 - 请求权限并设置默认下载目录
  Future<void> init() async {
    await logger.init(debugMode);
    await logger.i('AppState', '初始化开始');
    await requestPermissions();
    await initDownloadDir();
    await logger.i('AppState', '初始化完成, 权限: $permissionGranted, 下载目录: $downloadDir');
  }

  // 请求存储权限 - 适配 Android 13+ 的细粒度媒体权限
  Future<bool> requestPermissions() async {
    if (Platform.isAndroid) {
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = await deviceInfo.androidInfo;
      final sdkInt = androidInfo.version.sdkInt;
      
      await logger.i('AppState', 'Android SDK: $sdkInt');
      
      PermissionStatus status;
      
      if (sdkInt >= 34) {
        // Android 14+: 请求视频和图片权限
        await logger.i('AppState', 'Android 14+: 请求细粒度媒体权限');
        final videoStatus = await Permission.videos.request();
        final imageStatus = await Permission.photos.request();
        permissionGranted = videoStatus.isGranted || imageStatus.isGranted;
        
        // 如果细粒度权限被拒绝，尝试全盘访问
        if (!permissionGranted) {
          await logger.i('AppState', '细粒度权限被拒绝，尝试MANAGE_EXTERNAL_STORAGE');
          final manageStatus = await Permission.manageExternalStorage.request();
          permissionGranted = manageStatus.isGranted;
        }
      } else if (sdkInt >= 33) {
        // Android 13: 使用 READ_MEDIA_* 权限
        await logger.i('AppState', 'Android 13: 请求READ_MEDIA权限');
        final videoStatus = await Permission.videos.request();
        final audioStatus = await Permission.audio.request();
        permissionGranted = videoStatus.isGranted;
        
        if (!permissionGranted) {
          final manageStatus = await Permission.manageExternalStorage.request();
          permissionGranted = manageStatus.isGranted;
        }
      } else {
        // Android 12及以下: 使用传统存储权限
        await logger.i('AppState', 'Android 12-: 请求传统存储权限');
        status = await Permission.storage.request();
        permissionGranted = status.isGranted;
      }
      
      await logger.i('AppState', '权限请求结果: $permissionGranted');
    } else {
      permissionGranted = true;
    }
    notifyListeners();
    return permissionGranted;
  }

  // 初始化下载目录
  Future<void> initDownloadDir() async {
    await logger.i('AppState', '开始初始化下载目录');
    
    if (downloadDir.isEmpty) {
      if (Platform.isAndroid) {
        try {
          // 优先使用外部存储的 Download 目录
          final dir = Directory('/storage/emulated/0/Download/91Download');
          await logger.d('AppState', '尝试创建目录: ${dir.path}');
          
          if (!await dir.exists()) {
            await dir.create(recursive: true);
            await logger.i('AppState', '目录创建成功: ${dir.path}');
          }
          downloadDir = dir.path;
        } catch (e) {
          // 如果失败，使用应用私有目录
          await logger.w('AppState', '外部存储目录创建失败: $e');
          try {
            final appDir = await getExternalStorageDirectory();
            if (appDir != null) {
              final dir = Directory('${appDir.path}/91Download');
              if (!await dir.exists()) {
                await dir.create(recursive: true);
              }
              downloadDir = dir.path;
              await logger.i('AppState', '使用应用目录: $downloadDir');
            } else {
              // 最后使用内部存储
              final internalDir = await getApplicationDocumentsDirectory();
              downloadDir = '${internalDir.path}/91Download';
              await logger.i('AppState', '使用内部存储: $downloadDir');
            }
          } catch (e2) {
            await logger.e('AppState', '创建下载目录失败: $e2');
            downloadDir = '';
          }
        }
      } else {
        // iOS: 使用应用文档目录
        final appDir = await getApplicationDocumentsDirectory();
        downloadDir = '${appDir.path}/91Download';
      }
    }
    
    await logger.i('AppState', '下载目录初始化完成: $downloadDir');
    notifyListeners();
  }

  // 检查站点是否已选择
  bool get isSiteSelected => currentSite != null && currentSite!.isNotEmpty;

  // 切换站点
  void changeSite(String site) {
    currentSite = site;
    _crawler?.changeSite(site);
    notifyListeners();
  }

  // 切换主题
  void toggleTheme() {
    isDarkMode = !isDarkMode;
    notifyListeners();
  }

  // 设置下载目录
  void setDownloadDir(String dir) {
    downloadDir = dir;
    notifyListeners();
  }

  // 切换Debug模式
  Future<void> toggleDebug(bool enable) async {
    debugMode = enable;
    await logger.toggle(enable);
    notifyListeners();
  }

  // 切换外部播放器
  void toggleExternalPlayer() {
    useExternalPlayer = !useExternalPlayer;
    notifyListeners();
  }

  // 设置外部播放器
  void setExternalPlayer(bool enabled) {
    useExternalPlayer = enabled;
    notifyListeners();
  }
  
  // 设置视频显示模式
  void setVideoDisplayMode(String mode) {
    videoDisplayMode = mode;
    notifyListeners();
  }
}
