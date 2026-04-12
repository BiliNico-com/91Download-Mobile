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
  // 初始化标志
  bool _initialized = false;
  
  // 站点配置 - 默认为空，用户必须选择
  String? currentSite;
  
  // 下载目录
  String downloadDir = '';
  bool permissionGranted = false;
  
  // Debug模式
  bool debugMode = false;

  // 实时日志开关
  bool realtimeLogEnabled = false;

  // 主题模式: 0=日间, 1=夜间, 2=跟随系统
  int themeMode = 1;  // 默认夜间模式
  bool _isDarkMode = true;  // 内部记录（非跟随系统时的实际主题）
  
  // 回顶部按钮设置
  bool showBackToTop = true;
  String backToTopPosition = 'right'; // 'left' 或 'right'

  // 外部播放器设置
  bool useExternalPlayer = false;
  
  // 视频显示模式: 'grid' 大图模式, 'list' 列表模式
  String videoDisplayMode = 'grid';

  // 隐私模式：模糊预览图
  bool privacyMode = false;

  // 当前页面索引（用于导航）
  int currentPageIndex = 0;
  Function(int)? navigateToPage;  // 由 MainPage 设置

  // 爬虫实例
  CrawlerCore? _crawler;
  
  // 下载管理器
  late final DownloadManager _downloadManager;
  
  DownloadManager get downloadManager => _downloadManager;
  
  AppState() {
    // 监听下载管理器的变化并转发通知
    _downloadManager = DownloadManager()..addListener(_onDownloadManagerChanged);
  }
  
  void _onDownloadManagerChanged() {
    // 转发下载管理器的通知
    notifyListeners();
  }

  CrawlerCore? get crawler {
    if (currentSite == null) return null;
    _crawler ??= CrawlerCore(baseUrl: currentSite!);
    // 设置下载管理器
    if (_crawler != null && downloadDir.isNotEmpty) {
      _downloadManager.setup(_crawler!, downloadDir);
    }
    return _crawler;
  }

  // 初始化 - 请求权限并设置默认下载目录
  Future<void> init() async {
    await requestPermissions();
    await initDownloadDir();
    // 恢复未完成的下载任务
    await _downloadManager.restorePendingTasks();
  }

  // 请求存储权限 - 适配 Android 13+ 的细粒度媒体权限
  Future<bool> requestPermissions() async {
    if (Platform.isAndroid) {
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = await deviceInfo.androidInfo;
      final sdkInt = androidInfo.version.sdkInt;
      
      
      PermissionStatus status;
      
      if (sdkInt >= 34) {
        // Android 14+: 请求视频和图片权限
        final videoStatus = await Permission.videos.request();
        final imageStatus = await Permission.photos.request();
        permissionGranted = videoStatus.isGranted || imageStatus.isGranted;
        
        // 如果细粒度权限被拒绝，尝试全盘访问
        if (!permissionGranted) {
          final manageStatus = await Permission.manageExternalStorage.request();
          permissionGranted = manageStatus.isGranted;
        }
      } else if (sdkInt >= 33) {
        // Android 13: 使用 READ_MEDIA_* 权限
        final videoStatus = await Permission.videos.request();
        final audioStatus = await Permission.audio.request();
        permissionGranted = videoStatus.isGranted;
        
        if (!permissionGranted) {
          final manageStatus = await Permission.manageExternalStorage.request();
          permissionGranted = manageStatus.isGranted;
        }
      } else {
        // Android 12及以下: 使用传统存储权限
        status = await Permission.storage.request();
        permissionGranted = status.isGranted;
      }
      
    } else {
      permissionGranted = true;
    }
    notifyListeners();
    return permissionGranted;
  }

  // 初始化下载目录
  Future<void> initDownloadDir() async {
    
    if (downloadDir.isEmpty) {
      if (Platform.isAndroid) {
        try {
          // 优先使用外部存储的 Download 目录
          final dir = Directory('/storage/emulated/0/Download/91Download');
          
          if (!await dir.exists()) {
            await dir.create(recursive: true);
          }
          downloadDir = dir.path;
        } catch (e) {
          // 如果失败，使用应用私有目录
          try {
            final appDir = await getExternalStorageDirectory();
            if (appDir != null) {
              final dir = Directory('${appDir.path}/91Download');
              if (!await dir.exists()) {
                await dir.create(recursive: true);
              }
              downloadDir = dir.path;
            } else {
              // 最后使用内部存储
              final internalDir = await getApplicationDocumentsDirectory();
              downloadDir = '${internalDir.path}/91Download';
            }
          } catch (e2) {
            downloadDir = '';
          }
        }
      } else {
        // iOS: 使用应用文档目录
        final appDir = await getApplicationDocumentsDirectory();
        downloadDir = '${appDir.path}/91Download';
      }
    }
    
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

  // 主题相关
  // 当前实际主题（考虑跟随系统）
  bool get isDarkMode {
    if (themeMode == 2) {
      // 跟随系统：通过MediaQuery获取系统主题
      return WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
    }
    return _isDarkMode;
  }
  
  // 是否跟随系统
  bool get isAutoTheme => themeMode == 2;
  
  // 切换主题模式
  void setThemeMode(int mode) {
    themeMode = mode;
    if (mode == 2) {
      // 跟随系统模式，根据系统主题设置_isDarkMode
      _isDarkMode = WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
    }
    notifyListeners();
  }
  
  // 切换到日间模式
  void setLightMode() {
    themeMode = 0;
    _isDarkMode = false;
    notifyListeners();
  }
  
  // 切换到夜间模式
  void setDarkMode() {
    themeMode = 1;
    _isDarkMode = true;
    notifyListeners();
  }
  
  // 切换到跟随系统
  void setAutoTheme() {
    themeMode = 2;
    notifyListeners();
  }
  
  // 兼容旧代码的toggleTheme方法
  void toggleTheme() {
    if (themeMode == 2) {
      // 当前是跟随系统，切换到日间模式
      setLightMode();
    } else {
      // 切换日间/夜间
      _isDarkMode = !_isDarkMode;
      notifyListeners();
    }
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
  
  // 切换隐私模式
  void togglePrivacyMode() {
    privacyMode = !privacyMode;
    notifyListeners();
  }
  
  @override
  void dispose() {
    _downloadManager.removeListener(_onDownloadManagerChanged);
    super.dispose();
  }
}
