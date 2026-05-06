import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'pages/main_page.dart';
import 'pages/pin_input_dialog.dart';
import 'services/app_state.dart';
import 'services/pin_service.dart';

/// 悬浮窗入口点 - 保留但不再使用（已切换到原生方案）
// @pragma("vm:entry-point")
// void overlayMain() {
//   // 已废弃：使用原生 FloatingWindowService 替代
// }

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAuthentication();
    });
  }
  
  Future<void> _checkAuthentication() async {
    final appState = context.read<AppState>();
    
    await appState.init();
    
    if (!appState.appLockEnabled || appState.isAuthenticated) {
      return;
    }
    
    setState(() {
      _isAuthenticating = true;
    });
  }
  
  Future<void> _authenticate() async {
    final appState = context.read<AppState>();
    
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
    
    if (!appState.appLockEnabled || appState.isAuthenticated || !_isAuthenticating) {
      return widget.child;
    }
    
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

class ThemeWrapper extends StatefulWidget {
  final Widget child;
  
  const ThemeWrapper({super.key, required this.child});
  
  @override
  State<ThemeWrapper> createState() => _ThemeWrapperState();
}

class _ThemeWrapperState extends State<ThemeWrapper> {
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
