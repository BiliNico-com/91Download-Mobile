import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'pages/main_page.dart';
import 'services/app_state.dart';
import 'services/pin_service.dart';
import 'routes/app_routes.dart';
import 'theme/app_theme.dart';

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
///
/// 设计要点：
/// 1. 锁屏是**内嵌界面**，不使用 showDialog。
///    因为本组件挂在 MaterialApp.builder 下，其 context 位于 Navigator 之上，
///    showDialog 找不到 Navigator，会导致点击按钮无反应（键盘弹不出来）。
/// 2. 启动初期必须**先显示遮罩**，等 appState.init() 读完配置再决定放行，
///    否则在配置加载完成前会短暂露出主界面（既闪屏又漏内容）。
class AuthWrapper extends StatefulWidget {
  final Widget child;
  
  const AuthWrapper({super.key, required this.child});
  
  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  final PinService _pinService = PinService();

  /// 是否已完成启动检查（init 是否跑完）
  bool _initialized = false;

  /// 锁屏输入的 PIN
  String _pin = '';
  static const int _pinLength = 4;

  /// 正在校验，防止重复提交
  bool _verifying = false;
  String? _authError;

  /// 是否显示「无法解锁」的二次确认（内联，不用 Dialog）
  bool _showResetConfirm = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAuthentication();
    });
  }
  
  Future<void> _checkAuthentication() async {
    final appState = context.read<AppState>();
    
    try {
      await appState.init();
    } catch (_) {
      // init 失败也要放行，避免永久卡在加载遮罩
    }
    
    if (!mounted) return;
    setState(() {
      _initialized = true;
    });
  }

  void _onNumberPressed(String number) {
    if (_verifying || _pin.length >= _pinLength) return;
    HapticFeedback.lightImpact();
    setState(() {
      _pin += number;
      _authError = null;
    });

    if (_pin.length == _pinLength) {
      _verify();
    }
  }

  void _onDeletePressed() {
    if (_verifying || _pin.isEmpty) return;
    HapticFeedback.lightImpact();
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _authError = null;
    });
  }

  Future<void> _verify() async {
    if (_verifying) return;
    setState(() => _verifying = true);

    final input = _pin;
    bool ok = false;
    try {
      ok = await _pinService.verifyPin(input);
    } catch (e) {
      // 安全存储读取异常时给出明确提示，而不是静默失败
      if (mounted) {
        setState(() {
          _verifying = false;
          _pin = '';
          _authError = '无法读取PIN码，请重试';
        });
      }
      return;
    }

    if (!mounted) return;

    if (ok) {
      context.read<AppState>().setAuthenticated(true);
      setState(() {
        _verifying = false;
        _pin = '';
        _authError = null;
      });
    } else {
      HapticFeedback.heavyImpact();
      setState(() {
        _verifying = false;
        _pin = '';                       // 清空，可直接重输
        _authError = 'PIN码错误，请重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();

    // 启动检查未完成：显示加载遮罩，避免主界面提前露出
    if (!_initialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final locked = appState.appLockEnabled && !appState.isAuthenticated;
    if (!locked) {
      return widget.child;
    }

    return _buildLockScreen();
  }

  Widget _buildLockScreen() {
    if (_showResetConfirm) {
      return _buildResetConfirm();
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.lock_outline, size: 64, color: Colors.white70),
                const SizedBox(height: 20),
                const Text(
                  '请输入PIN码解锁',
                  style: TextStyle(fontSize: 20, color: Colors.white),
                ),
                const SizedBox(height: 24),

                // PIN 指示点
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(_pinLength, (index) {
                    final filled = index < _pin.length;
                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 10),
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: filled ? Colors.white : Colors.transparent,
                        border: Border.all(color: Colors.white54, width: 2),
                      ),
                    );
                  }),
                ),

                const SizedBox(height: 16),
                SizedBox(
                  height: 24,
                  child: _authError != null
                      ? Text(_authError!, style: const TextStyle(color: Colors.redAccent))
                      : (_verifying
                          ? const Text('验证中…', style: TextStyle(color: Colors.white54))
                          : const SizedBox()),
                ),
                const SizedBox(height: 12),

                // 数字键盘：内嵌，直接输入，无需弹出系统键盘
                _buildKeypad(),

                const SizedBox(height: 24),
                // 兜底入口：若 PIN 无法读取（安全存储异常/换机恢复等），
                // 允许用户在确认后关闭应用锁，避免被永久锁在外面。
                TextButton(
                  onPressed: _verifying
                      ? null
                      : () => setState(() => _showResetConfirm = true),
                  child: const Text(
                    '无法解锁？',
                    style: TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 无法解锁时的兜底：二次确认后关闭应用锁
  ///
  /// 使用**内联确认界面**（_showResetConfirm 状态），完全不依赖 Navigator / Overlay。
  /// 本组件挂在 MaterialApp.builder 下、位于 Navigator 之上，
  /// showDialog / showModalBottomSheet 在这里都无法弹出
  /// —— 这正是原先"点击输入PIN码没反应"的根因。
  ///
  /// 安全取舍说明：宁可让用户能进入应用重新设置，也不要因为安全存储
  /// 读取异常而永久锁死。视频与数据库都在外部存储，重装即可绕过，
  /// 因此"锁死"并不能提供额外的真实安全性。
  Future<void> _performResetLock() async {
    try {
      await _pinService.removePin();
    } catch (_) {}

    if (!mounted) return;
    await context.read<AppState>().toggleAppLock(false);
    if (!mounted) return;
    setState(() {
      _pin = '';
      _authError = null;
      _showResetConfirm = false;
    });
  }

  /// 内联的「关闭应用锁」二次确认界面
  Widget _buildResetConfirm() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.help_outline, size: 56, color: Colors.orangeAccent),
                const SizedBox(height: 20),
                const Text(
                  '无法解锁？',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  '如果你已忘记PIN码，可以关闭应用锁后重新设置。\n\n'
                  '注意：关闭后进入应用将不再需要PIN码验证。',
                  style: TextStyle(color: Colors.white70, height: 1.6),
                ),
                const SizedBox(height: 28),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () =>
                            setState(() => _showResetConfirm = false),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70,
                          side: const BorderSide(color: Colors.white24),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text('取消'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _performResetLock,
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text('关闭应用锁'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildKeypad() {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 280),
      child: GridView.count(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: 3,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        childAspectRatio: 1.8,
        children: [
          ...List.generate(9, (i) => _buildKey('${i + 1}')),
          const SizedBox(),
          _buildKey('0'),
          _buildKey('⌫', isBackspace: true),
        ],
      ),
    );
  }

  Widget _buildKey(String label, {bool isBackspace = false}) {
    return InkWell(
      onTap: isBackspace ? _onDeletePressed : () => _onNumberPressed(label),
      borderRadius: BorderRadius.circular(40),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey[850],
          borderRadius: BorderRadius.circular(40),
        ),
        child: Center(
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w500,
              color: Colors.white,
            ),
          ),
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
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: appState.themeMode == 0 
                ? ThemeMode.light 
                : (appState.themeMode == 1 ? ThemeMode.dark : ThemeMode.system),
            onGenerateRoute: AppRoutes.onGenerateRoute,
            initialRoute: '/',
            builder: (context, child) => AuthWrapper(
              child: ThemeWrapper(
                child: child ?? MainPage(),
              ),
            ),
          );
        },
      ),
    );
  }
}
