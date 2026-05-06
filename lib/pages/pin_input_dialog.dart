import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// PIN码输入对话框（固定4位）
class PinInputDialog extends StatefulWidget {
  final String title;
  final String? subtitle;

  const PinInputDialog({
    super.key,
    required this.title,
    this.subtitle,
  });

  /// 显示设置PIN对话框（包含输入和确认两步）
  static Future<String?> showSetPin(BuildContext context) async {
    // 第一步：输入PIN
    final pin1 = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PinInputDialog(
        title: '设置PIN码',
        subtitle: '请输入4位数字',
      ),
    );
    
    if (pin1 == null || !context.mounted) return null;
    
    // 第二步：确认PIN
    final pin2 = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PinInputDialog(
        title: '确认PIN码',
        subtitle: '请再次输入',
      ),
    );
    
    if (pin2 == null || !context.mounted) return null;
    
    if (pin1 != pin2) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('两次输入不一致，请重试')),
      );
      return null;
    }
    
    return pin1;
  }

  /// 显示验证PIN对话框
  static Future<String?> showVerifyPin(BuildContext context) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PinInputDialog(
        title: '输入PIN码',
        subtitle: '请输入PIN码解锁',
      ),
    );
  }

  @override
  State<PinInputDialog> createState() => _PinInputDialogState();
}

class _PinInputDialogState extends State<PinInputDialog> {
  String _pin = '';
  
  static const int _pinLength = 4;  // 固定4位

  void _onNumberPressed(String number) {
    if (_pin.length < _pinLength) {
      HapticFeedback.lightImpact();
      setState(() {
        _pin += number;
      });
      
      // 输入完成自动提交
      if (_pin.length == _pinLength) {
        Future.delayed(const Duration(milliseconds: 150), () {
          Navigator.of(context).pop(_pin);
        });
      }
    }
  }

  void _onDeletePressed() {
    if (_pin.isNotEmpty) {
      HapticFeedback.lightImpact();
      setState(() {
        _pin = _pin.substring(0, _pin.length - 1);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    return Dialog(
      backgroundColor: isDark ? Colors.grey[900] : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 图标
            Icon(
              Icons.lock_outline,
              size: 48,
              color: isDark ? Colors.white70 : Colors.black54,
            ),
            const SizedBox(height: 16),
            
            // 标题
            Text(
              widget.title,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black,
              ),
            ),
            
            if (widget.subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                widget.subtitle!,
                style: TextStyle(
                  fontSize: 14,
                  color: isDark ? Colors.white54 : Colors.black54,
                ),
              ),
            ],
            
            const SizedBox(height: 32),
            
            // PIN码显示点（固定4个）
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_pinLength, (index) {
                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: index < _pin.length
                        ? (isDark ? Colors.white : Colors.black)
                        : Colors.transparent,
                    border: Border.all(
                      color: isDark ? Colors.white54 : Colors.black26,
                      width: 2,
                    ),
                  ),
                );
              }),
            ),
            
            const SizedBox(height: 32),
            
            // 数字键盘
            GridView.count(
              shrinkWrap: true,
              crossAxisCount: 3,
              mainAxisSpacing: 16,
              crossAxisSpacing: 16,
              childAspectRatio: 1.5,
              children: [
                ...List.generate(9, (index) => _buildKeyButton('${index + 1}')),
                _buildKeyButton('', isBlank: true),  // 空白
                _buildKeyButton('0'),
                _buildKeyButton('⌫', isBackspace: true),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKeyButton(String label, {bool isBlank = false, bool isBackspace = false}) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    if (isBlank) {
      return const SizedBox();
    }
    
    return InkWell(
      onTap: isBackspace ? _onDeletePressed : () => _onNumberPressed(label),
      borderRadius: BorderRadius.circular(40),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? Colors.grey[800] : Colors.grey[200],
          borderRadius: BorderRadius.circular(40),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w500,
              color: isDark ? Colors.white : Colors.black,
            ),
          ),
        ),
      ),
    );
  }
}
