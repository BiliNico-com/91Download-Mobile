import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:video_player/video_player.dart';
import 'dart:io';
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
  double _windowWidth = 360;
  double _windowHeight = 240;
  
  @override
  void initState() {
    super.initState();
    _listenToMessages();
    // 自动隐藏控件
    _startHideControlsTimer();
  }
  
  void _startHideControlsTimer() {
    Future.delayed(Duration(seconds: 3), () {
      if (mounted && _isPlaying) {
        setState(() => _showControls = false);
      }
    });
  }
  
  void _listenToMessages() {
    FlutterOverlayWindow.overlayListener.listen((event) {
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
      _controller = VideoPlayerController.file(File(path));
      await _controller!.initialize();
      
      if (mounted) {
        setState(() {
          _isInitialized = true;
          _isPlaying = true;
        });
        _controller!.play();
        _controller!.setLooping(true);
      }
    } catch (e) {
      print('[OverlayVideo] 加载视频失败: $e');
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
  
  void _resizeOverlay(int delta) async {
    final newWidth = (_windowWidth + delta).clamp(240.0, 600.0);
    final aspectRatio = _controller?.value.aspectRatio ?? 16 / 9;
    final newHeight = (newWidth / aspectRatio).clamp(180.0, 400.0);
    
    await FlutterOverlayWindow.resizeOverlay(
      newWidth.round(),
      newHeight.round(),
      true,
    );
    
    setState(() {
      _windowWidth = newWidth;
      _windowHeight = newHeight;
    });
  }
  
  void _closeOverlay() async {
    await _controller?.pause();
    await FlutterOverlayWindow.closeOverlay();
  }
  
  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
    });
    if (_showControls && _isPlaying) {
      _startHideControlsTimer();
    }
  }
  
  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Material(
        color: Colors.black,
        child: GestureDetector(
          onTap: _toggleControls,
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
                  color: Colors.black45,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // 顶部栏
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            // 关闭按钮
                            GestureDetector(
                              onTap: _closeOverlay,
                              child: Container(
                                padding: EdgeInsets.all(4),
                                child: Icon(Icons.close, color: Colors.white, size: 20),
                              ),
                            ),
                            // 大小调整按钮
                            Row(
                              children: [
                                GestureDetector(
                                  onTap: () => _resizeOverlay(-40),
                                  child: Container(
                                    padding: EdgeInsets.all(4),
                                    child: Icon(Icons.zoom_out, color: Colors.white, size: 18),
                                  ),
                                ),
                                GestureDetector(
                                  onTap: () => _resizeOverlay(40),
                                  child: Container(
                                    padding: EdgeInsets.all(4),
                                    child: Icon(Icons.zoom_in, color: Colors.white, size: 18),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      
                      // 中间播放/暂停按钮
                      GestureDetector(
                        onTap: _togglePlayPause,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          padding: EdgeInsets.all(12),
                          child: Icon(
                            _isPlaying ? Icons.pause : Icons.play_arrow,
                            color: Colors.white,
                            size: 32,
                          ),
                        ),
                      ),
                      
                      // 底部进度条
                      if (_isInitialized && _controller != null)
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          child: ValueListenableBuilder<VideoPlayerValue>(
                            valueListenable: _controller!,
                            builder: (context, value, child) {
                              final position = value.position;
                              final duration = value.duration;
                              final progress = duration.inMilliseconds > 0
                                  ? position.inMilliseconds / duration.inMilliseconds
                                  : 0.0;
                              
                              return Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  LinearProgressIndicator(
                                    value: progress,
                                    backgroundColor: Colors.white24,
                                    valueColor: AlwaysStoppedAnimation(Colors.blue),
                                  ),
                                  SizedBox(height: 4),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        _formatDuration(position),
                                        style: TextStyle(color: Colors.white70, fontSize: 10),
                                      ),
                                      Text(
                                        _formatDuration(duration),
                                        style: TextStyle(color: Colors.white70, fontSize: 10),
                                      ),
                                    ],
                                  ),
                                ],
                              );
                            },
                          ),
                        )
                      else
                        SizedBox(height: 20),
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
