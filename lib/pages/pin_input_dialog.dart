import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_tokens.dart';

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

  static const int _pinLength = 4; // 固定4位

  void _onNumberPressed(String number) {
    if (_pin.length < _pinLength) {
      HapticFeedback.lightImpact();
      setState(() {
        _pin += number;
      });

      // 输入完成自动提交
      if (_pin.length == _pinLength) {
        Future.delayed(const Duration(milliseconds: 150), () {
          if (mounted) Navigator.of(context).pop(_pin);
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
    final t = AppTokens.of(context);

    return Dialog(
      backgroundColor: t.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xxl),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 图标
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: t.accentSoft,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.lock_outline_rounded, size: 25, color: t.accent),
            ),
            const SizedBox(height: 14),

            // 标题
            Text(
              widget.title,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: t.text1,
              ),
            ),

            if (widget.subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                widget.subtitle!,
                style: TextStyle(fontSize: 12.5, color: t.text3),
              ),
            ],

            const SizedBox(height: 26),

            // PIN码显示点（固定4个）
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_pinLength, (index) {
                final filled = index < _pin.length;
                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 11),
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: filled ? t.accent : Colors.transparent,
                    border: Border.all(
                      color: filled ? t.accent : t.line,
                      width: 2,
                    ),
                  ),
                );
              }),
            ),

            const SizedBox(height: 24),

            // 数字键盘
            GridView.count(
              shrinkWrap: true,
              crossAxisCount: 3,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.6,
              children: [
                ...List.generate(9, (index) => _buildKeyButton('${index + 1}')),
                _buildKeyButton('', isBlank: true), // 空白
                _buildKeyButton('0'),
                _buildKeyButton('⌫', isBackspace: true),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKeyButton(String label,
      {bool isBlank = false, bool isBackspace = false}) {
    final t = AppTokens.of(context);

    if (isBlank) {
      return const SizedBox();
    }

    return Material(
      color: t.surface2,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: isBackspace ? _onDeletePressed : () => _onNumberPressed(label),
        child: Center(
          child: isBackspace
              ? Icon(Icons.backspace_outlined, size: 20, color: t.text2)
              : Text(
                  label,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: t.text1,
                  ),
                ),
        ),
      ),
    );
  }
}
