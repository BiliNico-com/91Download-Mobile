import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import '../crawler/crawler_core.dart';
import '../models/video_info.dart';
import '../utils/logger.dart';
import 'download_manager.dart';
import 'followed_authors_service.dart';
import 'version_service.dart';
import 'floating_video_service.dart';

class AppState extends ChangeNotifier {
  // 初始化标志（公共变量，供 main.dart 访问）
  bool initialized = false;
  
  // 站点配置 - 默认为空，用户必须选择
  String? currentSite;
  
  // 返回键处理回调（由子页面设置，用于作者模式等特殊状态）
  bool Function()? onWillPopCallback;
  
  // 下载目录
  String downloadDir = '';
  bool permissionGranted = false;
  bool overlayPermissionGranted = false;
  
  // Debug模式
  bool debugMode = false;
  
  // Debug: 保存HTML到文件
  bool saveDebugHtml = false;

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
  
  // 同时下载任务数（任务级别并发限制）
  int maxConcurrentTasks = 2;
  
  // TS切片并发下载数
  int maxConcurrentSegments = 32;
  
  // 视频显示模式: 'grid' 大图模式, 'list' 列表模式
  String videoDisplayMode = 'grid';

  // 隐私模式：模糊预览图
  bool privacyMode = false;
  
  // .nomedia：防止下载目录被系统媒体扫描器索引
  bool nomediaEnabled = false;
  
  // 应用锁：进入APP需要生物识别认证
  bool appLockEnabled = false;
  bool isAuthenticated = false;  // 当前会话是否已认证

  // 当前页面索引（用于导航）
  int currentPageIndex = 0;
  Function(int)? navigateToPage;  // 由 MainPage 设置

  // 爬虫实例
  CrawlerCore? _crawler;
  
  // 下载管理器
  late final DownloadManager _downloadManager;
  
  DownloadManager get downloadManager => _downloadManager;
  
  // 关注作者服务
  FollowedAuthorsService get followedAuthorsService => FollowedAuthorsService.instance;
  
  AppState() {
    // 监听下载管理器的变化并转发通知
    _downloadManager = DownloadManager()..addListener(_onDownloadManagerChanged);
    // 监听关注服务的变化并转发通知
    followedAuthorsService.addListener(_onFollowedAuthorsChanged);
  }
  
  void _onDownloadManagerChanged() {
    // 转发下载管理器的通知
    notifyListeners();
  }
  
  void _onFollowedAuthorsChanged() {
    // 转发关注服务的变化通知
    notifyListeners();
  }

  CrawlerCore? get crawler {
    if (currentSite == null) return null;
    _crawler ??= CrawlerCore(
      baseUrl: currentSite!,
      externalDbPath: downloadDir.isNotEmpty ? downloadDir : null,
    );
    // 设置调试HTML开关
    _crawler!.saveDebugHtml = saveDebugHtml;
    // 同步TS切片并发数到 CrawlerCore
    _crawler!.maxConcurrentDownloads = maxConcurrentSegments;
    // 同步并发设置到 DownloadManager
    _downloadManager.maxConcurrentTasks = maxConcurrentTasks;
    _downloadManager.maxConcurrentSegments = maxConcurrentSegments;
    // 设置外部数据库路径
    _downloadManager.externalDbPath = downloadDir.isNotEmpty ? downloadDir : null;
    // 设置下载管理器
    if (_crawler != null && downloadDir.isNotEmpty) {
      _downloadManager.setup(_crawler!, downloadDir);
    }
    return _crawler;
  }

  // 初始化 - 请求权限并设置默认下载目录
  Future<void> init() async {
    await _loadSettings();  // 先加载保存的设置
    await requestPermissions();
    overlayPermissionGranted = await NativeFloatingService.isPermissionGranted();
    await initDownloadDir();
    // 设置外部数据库路径
    _downloadManager.externalDbPath = downloadDir.isNotEmpty ? downloadDir : null;
    // 设置关注作者服务的外部数据库路径
    followedAuthorsService.setExternalDbPath(downloadDir.isNotEmpty ? downloadDir : null);
    // 初始化关注作者服务并加载关注列表
    await followedAuthorsService.refresh();
    // 初始化版本服务
    await VersionService.init();
    // 恢复未完成的下载任务
    await _downloadManager.restorePendingTasks();
  }

  // 从持久化存储加载设置
  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    
    currentSite = prefs.getString('currentSite');
    themeMode = prefs.getInt('themeMode') ?? 1;
    _isDarkMode = prefs.getBool('isDarkMode') ?? true;
    videoDisplayMode = prefs.getString('videoDisplayMode') ?? 'grid';
    showBackToTop = prefs.getBool('showBackToTop') ?? true;
    backToTopPosition = prefs.getString('backToTopPosition') ?? 'right';
    useExternalPlayer = prefs.getBool('useExternalPlayer') ?? false;
    maxConcurrentTasks = prefs.getInt('maxConcurrentTasks') ?? 2;
    maxConcurrentSegments = prefs.getInt('maxConcurrentSegments') ?? 32;
    appLockEnabled = prefs.getBool('appLockEnabled') ?? false;
    privacyMode = prefs.getBool('privacyMode') ?? false;
    nomediaEnabled = prefs.getBool('nomediaEnabled') ?? false;
    
    notifyListeners();
  }

  // 保存设置到持久化存储
  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    
    if (currentSite != null) {
      await prefs.setString('currentSite', currentSite!);
    } else {
      await prefs.remove('currentSite');
    }
    await prefs.setInt('themeMode', themeMode);
    await prefs.setBool('isDarkMode', _isDarkMode);
    await prefs.setString('videoDisplayMode', videoDisplayMode);
    await prefs.setBool('showBackToTop', showBackToTop);
    await prefs.setString('backToTopPosition', backToTopPosition);
    await prefs.setBool('useExternalPlayer', useExternalPlayer);
    await prefs.setInt('maxConcurrentTasks', maxConcurrentTasks);
    await prefs.setInt('maxConcurrentSegments', maxConcurrentSegments);
    await prefs.setBool('appLockEnabled', appLockEnabled);
    await prefs.setBool('privacyMode', privacyMode);
    await prefs.setBool('nomediaEnabled', nomediaEnabled);
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

  /// 检查/刷新悬浮窗权限状态（从设置页调用）
  Future<bool> checkOverlayPermission() async {
    overlayPermissionGranted = await NativeFloatingService.isPermissionGranted();
    notifyListeners();
    return overlayPermissionGranted;
  }

  /// 跳转悬浮窗权限设置页面
  Future<void> requestOverlayPermission() async {
    await NativeFloatingService.openSettings();
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
    
    // 同步 .nomedia 文件状态
    if (downloadDir.isNotEmpty && nomediaEnabled) {
      try {
        final nomediaFile = File('$downloadDir/.nomedia');
        if (!await nomediaFile.exists()) {
          await nomediaFile.create();
        }
      } catch (_) {}
    }
    
    notifyListeners();
  }

  // 检查站点是否已选择
  bool get isSiteSelected => currentSite != null && currentSite!.isNotEmpty;

  // 切换站点
  void changeSite(String site) {
    currentSite = site;
    if (_crawler != null) {
      _crawler!.changeSite(site);
    } else {
      _crawler = null; // 强制下次访问时重新创建
    }
    _saveSettings();
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
    _saveSettings();
    notifyListeners();
  }
  
  // 切换到日间模式
  void setLightMode() {
    themeMode = 0;
    _isDarkMode = false;
    _saveSettings();
    notifyListeners();
  }
  
  // 切换到夜间模式
  void setDarkMode() {
    themeMode = 1;
    _isDarkMode = true;
    _saveSettings();
    notifyListeners();
  }
  
  // 切换到跟随系统
  void setAutoTheme() {
    themeMode = 2;
    _saveSettings();
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
      _saveSettings();
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
  
  // 切换保存HTML开关
  void toggleSaveDebugHtml(bool enable) {
    saveDebugHtml = enable;
    // 同步到crawler
    if (_crawler != null) {
      _crawler!.saveDebugHtml = enable;
    }
    notifyListeners();
  }

  // 切换外部播放器
  void toggleExternalPlayer() {
    useExternalPlayer = !useExternalPlayer;
    _saveSettings();
    notifyListeners();
  }

  // 设置外部播放器
  void setExternalPlayer(bool enabled) {
    useExternalPlayer = enabled;
    _saveSettings();
    notifyListeners();
  }
  
  // 设置同时下载任务数
  void setMaxConcurrentTasks(int value) {
    maxConcurrentTasks = value.clamp(1, 5);
    // ✅ 同步到 DownloadManager
    _downloadManager.maxConcurrentTasks = maxConcurrentTasks;
    _saveSettings();
    notifyListeners();
  }
  
  // 设置TS切片并发数
  void setMaxConcurrentSegments(int value) {
    maxConcurrentSegments = value.clamp(1, 64);
    // ✅ 同步到 DownloadManager 和 CrawlerCore
    _downloadManager.maxConcurrentSegments = maxConcurrentSegments;
    if (_crawler != null) {
      _crawler!.maxConcurrentDownloads = maxConcurrentSegments;
    }
    _saveSettings();
    notifyListeners();
  }
  
  // 设置视频显示模式
  void setVideoDisplayMode(String mode) {
    videoDisplayMode = mode;
    _saveSettings();
    notifyListeners();
  }
  
  // 设置回顶部按钮显示
  void setShowBackToTop(bool show) {
    showBackToTop = show;
    _saveSettings();
    notifyListeners();
  }
  
  // 设置回顶部按钮位置
  void setBackToTopPosition(String position) {
    backToTopPosition = position;
    _saveSettings();
    notifyListeners();
  }
  
  // 切换隐私模式
  Future<void> togglePrivacyMode() async {
    privacyMode = !privacyMode;
    await _saveSettings();
    notifyListeners();
  }
  
  // 切换应用锁
  Future<void> toggleAppLock(bool enable) async {
    appLockEnabled = enable;
    await _saveSettings();
    notifyListeners();
  }
  
  // 切换 .nomedia（防止媒体扫描）
  Future<void> toggleNomedia(bool enable) async {
    nomediaEnabled = enable;
    if (downloadDir.isNotEmpty) {
      try {
        final nomediaFile = File('$downloadDir/.nomedia');
        if (enable) {
          if (!await nomediaFile.exists()) {
            await nomediaFile.create();
          }
        } else {
          if (await nomediaFile.exists()) {
            await nomediaFile.delete();
          }
        }
      } catch (_) {}
    }
    await _saveSettings();
    notifyListeners();
  }
  
  // 设置已认证状态
  void setAuthenticated(bool authenticated) {
    isAuthenticated = authenticated;
    notifyListeners();
  }
  
  @override
  void dispose() {
    _downloadManager.removeListener(_onDownloadManagerChanged);
    _downloadManager.dispose();
    super.dispose();
  }
}
