import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'pages/main_page.dart';
import 'pages/pin_input_dialog.dart';
import 'services/app_state.dart';
import 'services/pin_service.dart';
import 'utils/logger.dart';

/// 悬浮窗入口点 - 必须是顶级函数
@pragma("vm:entry-point")
void overlayMain() {
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Material(
      color: Colors.black,
      child: Center(
        child: Text(
          '视频播放中...',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
      ),
    ),
  ));
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
