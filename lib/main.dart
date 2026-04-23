import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:video_player/video_player.dart';
import 'dart:io';
import 'dart:async';
import 'pages/main_page.dart';
import 'pages/pin_input_dialog.dart';
import 'services/app_state.dart';
import 'services/pin_service.dart';
import 'utils/logger.dart';

/// 悬浮窗入口点 - 必须是顶级函数
@pragma("vm:entry-point")
void overlayMain() {
  runApp(const OverlayVideoApp());
}

/// 悬浮窗视频播放应用
class OverlayVideoApp extends StatefulWidget {
  const OverlayVideoApp({super.key});

  @override
  State<OverlayVideoApp> createState() => _OverlayVideoAppState();
}

class _OverlayVideoAppState extends State<OverlayVideoApp> {
  VideoPlayerController? _controller;
  String? _videoPath;
  bool _isInitialized = false;
  bool _isPlaying = false;
  bool _showControls = true;
  bool _hasError = false;
  String _errorMessage = '';
  double _windowWidth = 320;
  double _windowHeight = 200;
  Timer? _hideControlsTimer;
  StreamSubscription<dynamic>? _messageSubscription;
  
  @override
  void initState() {
    super.initState();
    _listenToMessages();
  }

  @override
  void dispose() {
    // 修复：正确清理消息订阅，防止内存泄漏
    _messageSubscription?.cancel();
    _messageSubscription = null;
    _hideControlsTimer?.cancel();
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }
  
  void _restartHideControlsTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(Duration(seconds: 4), () {
      if (mounted && _isPlaying && _showControls) {
        setState(() => _showControls = false);
      }
    });
  }
  
  void _listenToMessages() {
    // 修复：保存订阅引用，防止重复订阅导致内存泄漏
    _messageSubscription?.cancel();
    _messageSubscription = FlutterOverlayWindow.overlayListener.listen((event) {
      if (event is Map) {
        // 处理视频路径
        final path = event['path'] as String?;
        if (path != null && path != _videoPath) {
          _loadVideo(path);
        }
        
        // 处理窗口大小
        final width = event['width'] as num?;
        final height = event['height'] as num?;
        if (width != null && height != null) {
          setState(() {
            _windowWidth = width.toDouble();
            _windowHeight = height.toDouble();
          });
        }
        
        // 处理命令
        final command = event['command'] as String?;
        if (command == 'togglePlayPause' && _controller != null) {
          _togglePlayPause();
        } else if (command == 'close') {
          _closeOverlay();
        }
      }
    });
  }
  
  Future<void> _loadVideo(String path) async {
    try {
      // 释放旧的控制器
      await _controller?.dispose();
      
      _videoPath = path;
      _hasError = false;
      _errorMessage = '';
      
      if (mounted) {
        setState(() {
          _isInitialized = false;
          _isPlaying = false;
        });
      }
      
      _controller = VideoPlayerController.file(File(path));
      await _controller!.initialize();
      
      if (mounted) {
        setState(() {
          _isInitialized = true;
          _isPlaying = true;
          _showControls = true; // 确保控件显示
        });
        _controller!.play();
        _controller!.setLooping(true);
        // 启动自动隐藏控件计时器
        _restartHideControlsTimer();
      }
    } catch (e, stackTrace) {
      // 修复：视频加载失败时设置错误状态，允许用户看到错误提示
      print('[OverlayVideo] 加载视频失败: $e');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        setState(() {
          _isInitialized = false;
          _hasError = true;
          _errorMessage = e.toString();
        });
      }
    }
  }
  
  void _togglePlayPause() {
    if (_controller == null) return;
    
    setState(() {
      if (_controller!.value.isPlaying) {
        _controller!.pause();
        _isPlaying = false;
      } else {
        _controller!.play();
        _isPlaying = true;
      }
    });
  }
  
  // 后退10秒
  void _seekBackward() {
    if (_controller == null) return;
    final currentPos = _controller!.value.position;
    final newPos = Duration(
      seconds: (currentPos.inSeconds - 10).clamp(0, _controller!.value.duration.inSeconds)
    );
    _controller!.seekTo(newPos);
  }
  
  // 前进10秒
  void _seekForward() {
    if (_controller == null) return;
    final currentPos = _controller!.value.position;
    final newPos = Duration(
      seconds: (currentPos.inSeconds + 10).clamp(0, _controller!.value.duration.inSeconds)
    );
    _controller!.seekTo(newPos);
  }
  
  // 双指缩放调整大小
  double _baseWidth = 320;
  double _baseHeight = 180;
  
  void _onScaleStart(ScaleStartDetails details) {
    // 记录当前窗口大小作为基准
    _baseWidth = _windowWidth;
    _baseHeight = _windowHeight;
  }
  
  void _onScaleUpdate(ScaleUpdateDetails details) {
    // 缩放比例
    final scale = details.scale;
    if (scale == 1.0) return;
    
    // 基于基准大小计算新大小
    final newWidth = (_baseWidth * scale).clamp(200.0, 450.0);
    final aspectRatio = _controller?.value.aspectRatio ?? 16 / 9;
    final newHeight = (newWidth / aspectRatio).clamp(140.0, 320.0);
    
    // 调整窗口大小
    FlutterOverlayWindow.resizeOverlay(
      newWidth.round(),
      newHeight.round(),
      true,
    );
    
    setState(() {
      _windowWidth = newWidth;
      _windowHeight = newHeight;
    });
  }
  
  // 双击返回主应用
  void _onDoubleTap() async {
    // 先暂停视频
    await _controller?.pause();
    
    final position = _controller?.value.position.inMilliseconds ?? 0;
    
    // 发送消息让主应用知道要恢复播放
    await FlutterOverlayWindow.shareData({
      'action': 'returnToApp',
      'position': position,
    });
    
    // 等待消息发送
    await Future.delayed(Duration(milliseconds: 200));
    
    // 关闭悬浮窗
    await FlutterOverlayWindow.closeOverlay();
  }
  
  void _closeOverlay() async {
    await _controller?.pause();
    // 通知主应用悬浮窗已关闭
    await FlutterOverlayWindow.shareData({
      'action': 'overlayClosed',
    });
    await Future.delayed(Duration(milliseconds: 100));
    await FlutterOverlayWindow.closeOverlay();
  }
  
  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
    });
    // 如果显示控件且正在播放，启动自动隐藏计时器
    if (_showControls && _isPlaying) {
      _restartHideControlsTimer();
    } else {
      _hideControlsTimer?.cancel();
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Material(
        color: Colors.black,
        child: GestureDetector(
          onTap: _toggleControls,
          onDoubleTap: _onDoubleTap,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 视频内容
              if (_isInitialized && _controller != null)
                Center(
                  child: AspectRatio(
                    aspectRatio: _controller!.value.aspectRatio,
                    child: VideoPlayer(_controller!),
                  ),
                )
              else if (_hasError)
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.error_outline, color: Colors.red, size: 36),
                      SizedBox(height: 12),
                      Text(
                        '视频加载失败',
                        style: TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                      SizedBox(height: 8),
                      TextButton(
                        onPressed: () {
                          if (_videoPath != null) {
                            _loadVideo(_videoPath!);
                          }
                        },
                        child: Text('重试', style: TextStyle(color: Colors.blue, fontSize: 13)),
                      ),
                    ],
                  ),
                )
              else
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(color: Colors.white),
                      SizedBox(height: 16),
                      Text(
                        '加载视频中...',
                        style: TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              
              // 控件层
              if (_showControls)
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withOpacity(0.6),
                        Colors.transparent,
                        Colors.transparent,
                        Colors.black.withOpacity(0.6),
                      ],
                      stops: [0.0, 0.15, 0.85, 1.0],
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // 顶部栏 - 右上角关闭按钮
                      Container(
                        padding: EdgeInsets.all(6),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            GestureDetector(
                              onTap: _closeOverlay,
                              behavior: HitTestBehavior.opaque,
                              child: Container(
                                padding: EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: Colors.black45,
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(Icons.close, color: Colors.white, size: 18),
                              ),
                            ),
                          ],
                        ),
                      ),
                      
                      // 中间空白区域
                      Expanded(child: Container()),
                      
                      // 底部三个控制按钮
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // 后退10秒按钮
                            GestureDetector(
                              onTap: _seekBackward,
                              behavior: HitTestBehavior.opaque,
                              child: Container(
                                padding: EdgeInsets.all(8),
                                child: Icon(Icons.replay_10, color: Colors.white, size: 24),
                              ),
                            ),
                            SizedBox(width: 16),
                            // 播放/暂停按钮
                            GestureDetector(
                              onTap: _togglePlayPause,
                              behavior: HitTestBehavior.opaque,
                              child: Container(
                                padding: EdgeInsets.all(8),
                                child: Icon(
                                  _isPlaying ? Icons.pause : Icons.play_arrow,
                                  color: Colors.white,
                                  size: 32,
                                ),
                              ),
                            ),
                            SizedBox(width: 16),
                            // 前进10秒按钮
                            GestureDetector(
                              onTap: _seekForward,
                              behavior: HitTestBehavior.opaque,
                              child: Container(
                                padding: EdgeInsets.all(8),
                                child: Icon(Icons.forward_10, color: Colors.white, size: 24),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
  
  String _formatDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds.remainder(60);
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 初始化日志
  
  runApp(const MyApp());
}

/// 认证包装组件 - 处理应用锁（PIN码）
class AuthWrapper extends StatefulWidget {
  final Widget child;
  
  const AuthWrapper({super.key, required this.child});
  
  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  final PinService _pinService = PinService();
  bool _isAuthenticating = false;
  String? _authError;
  
  @override
  void initState() {
    super.initState();
    // 延迟检查认证
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAuthentication();
    });
  }
  
  Future<void> _checkAuthentication() async {
    final appState = context.read<AppState>();
    
    // 先初始化，读取保存的状态
    await appState.init();
    
    // 如果未启用应用锁或已认证，直接进入
    if (!appState.appLockEnabled || appState.isAuthenticated) {
      return;
    }
    
    // 需要认证
    setState(() {
      _isAuthenticating = true;
    });
  }
  
  Future<void> _authenticate() async {
    final appState = context.read<AppState>();
    
    // 显示PIN码输入对话框
    final pin = await PinInputDialog.showVerifyPin(context);
    if (pin == null || !mounted) return;
    
    final success = await _pinService.verifyPin(pin);
    
    if (success) {
      appState.setAuthenticated(true);
      setState(() {
        _isAuthenticating = false;
      });
    } else {
      setState(() {
        _authError = 'PIN码错误，请重试';
      });
    }
  }
  
  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    
    // 不需要认证或已认证
    if (!appState.appLockEnabled || appState.isAuthenticated || !_isAuthenticating) {
      return widget.child;
    }
    
    // 显示认证界面
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_outline, size: 80, color: Colors.white70),
            SizedBox(height: 24),
            Text(
              '请输入PIN码解锁',
              style: TextStyle(fontSize: 24, color: Colors.white),
            ),
            SizedBox(height: 16),
            if (_authError != null)
              Text(
                _authError!,
                style: TextStyle(color: Colors.red),
              ),
            SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _authenticate,
              icon: Icon(Icons.pin),
              label: Text('输入PIN码'),
              style: ElevatedButton.styleFrom(
                padding: EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 主题状态包装组件，监听系统主题变化
class ThemeWrapper extends StatefulWidget {
  final Widget child;
  
  const ThemeWrapper({super.key, required this.child});
  
  @override
  State<ThemeWrapper> createState() => _ThemeWrapperState();
}

class _ThemeWrapperState extends State<ThemeWrapper> {
  @override
  void initState() {
    super.initState();
  }
  
  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppState()),
      ],
      child: Consumer<AppState>(
        builder: (context, appState, _) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            title: '91Download 移动端',
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: Colors.blue,
                brightness: Brightness.light,
              ),
              useMaterial3: true,
            ),
            darkTheme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: Colors.blue,
                brightness: Brightness.dark,
              ),
              useMaterial3: true,
            ),
            themeMode: appState.themeMode == 0 
                ? ThemeMode.light 
                : (appState.themeMode == 1 ? ThemeMode.dark : ThemeMode.system),
            home: AuthWrapper(
              child: ThemeWrapper(
                child: MainPage(),
              ),
            ),
          );
        },
      ),
    );
  }
}
