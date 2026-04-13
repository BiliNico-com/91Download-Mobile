import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// PIN码输入类型
enum PinInputType {
  setNew,      // 设置新PIN
  confirmPin,  // 确认PIN
  verify,      // 验证PIN
}

/// PIN码输入对话框
class PinInputDialog extends StatefulWidget {
  final String title;
  final String? subtitle;
  final PinInputType inputType;
  final String? confirmValue;  // 用于确认PIN时的原始值
  
  const PinInputDialog({
    super.key,
    required this.title,
    this.subtitle,
    required this.inputType,
    this.confirmValue,
  });

  /// 显示设置新PIN的对话框
  static Future<String?> showSetNewPin(BuildContext context) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PinInputDialog(
        title: '设置PIN码',
        subtitle: '请输入4-6位数字PIN码',
        inputType: PinInputType.setNew,
      ),
    );
  }
  
  /// 显示确认PIN的对话框
  static Future<String?> showConfirmPin(BuildContext context, String originalPin) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PinInputDialog(
        title: '确认PIN码',
        subtitle: '请再次输入PIN码确认',
        inputType: PinInputType.confirmPin,
        confirmValue: originalPin,
      ),
    );
  }
  
  /// 显示验证PIN的对话框
  static Future<String?> showVerifyPin(BuildContext context) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PinInputDialog(
        title: '输入PIN码',
        subtitle: '请输入PIN码解锁',
        inputType: PinInputType.verify,
      ),
    );
  }

  @override
  State<PinInputDialog> createState() => _PinInputDialogState();
}

class _PinInputDialogState extends State<PinInputDialog> {
  String _pin = '';
  String? _error;
  bool _isLoading = false;
  
  static const int _minLength = 4;
  static const int _maxLength = 6;
  
  void _onNumberPressed(String number) {
    if (_pin.length < _maxLength) {
      HapticFeedback.lightImpact();
      setState(() {
        _pin += number;
        _error = null;
      });
      
      // 自动提交
      if (_pin.length >= _minLength && widget.inputType != PinInputType.confirmPin) {
        _submitPin();
      } else if (widget.inputType == PinInputType.confirmPin && 
                 _pin.length == widget.confirmValue?.length) {
        _submitPin();
      }
    }
  }
  
  void _onDeletePressed() {
    if (_pin.isNotEmpty) {
      HapticFeedback.lightImpact();
      setState(() {
        _pin = _pin.substring(0, _pin.length - 1);
        _error = null;
      });
    }
  }
  
  void _onClearPressed() {
    HapticFeedback.lightImpact();
    setState(() {
      _pin = '';
      _error = null;
    });
  }
  
  void _submitPin() {
    if (_pin.length < _minLength) {
      setState(() {
        _error = 'PIN码至少$_minLength位';
      });
      return;
    }
    
    if (widget.inputType == PinInputType.confirmPin) {
      if (_pin != widget.confirmValue) {
        HapticFeedback.heavyImpact();
        setState(() {
          _error = '两次输入的PIN码不一致';
          _pin = '';
        });
        return;
      }
    }
    
    Navigator.of(context).pop(_pin);
  }
  
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题
            Text(
              widget.title,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            
            // 副标题
            Text(
              widget.subtitle ?? '',
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.grey,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            
            // PIN显示
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_maxLength, (index) {
                final isFilled = index < _pin.length;
                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isFilled 
                        ? theme.colorScheme.primary 
                        : Colors.grey.withOpacity(0.3),
                    border: Border.all(
                      color: _error != null 
                          ? Colors.red 
                          : (isFilled ? theme.colorScheme.primary : Colors.grey),
                      width: 2,
                    ),
                  ),
                );
              }),
            ),
            
            // 错误信息
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: Colors.red, fontSize: 13),
              ),
            ],
            
            const SizedBox(height: 24),
            
            // 数字键盘
            _buildNumberPad(theme),
            
            const SizedBox(height: 16),
            
            // 按钮
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(null),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _pin.length >= _minLength ? _submitPin : null,
                    child: const Text('确认'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildNumberPad(ThemeData theme) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildNumberButton('1', theme),
            _buildNumberButton('2', theme),
            _buildNumberButton('3', theme),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildNumberButton('4', theme),
            _buildNumberButton('5', theme),
            _buildNumberButton('6', theme),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildNumberButton('7', theme),
            _buildNumberButton('8', theme),
            _buildNumberButton('9', theme),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildActionButton(
              icon: Icons.clear_all,
              onPressed: _onClearPressed,
              color: Colors.orange,
            ),
            _buildNumberButton('0', theme),
            _buildActionButton(
              icon: Icons.backspace_outlined,
              onPressed: _onDeletePressed,
              color: Colors.grey,
            ),
          ],
        ),
      ],
    );
  }
  
  Widget _buildNumberButton(String number, ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    return Material(
      color: isDark ? Colors.grey[800] : Colors.grey[200],
      borderRadius: BorderRadius.circular(40),
      child: InkWell(
        onTap: () => _onNumberPressed(number),
        borderRadius: BorderRadius.circular(40),
        child: Container(
          width: 64,
          height: 64,
          alignment: Alignment.center,
          child: Text(
            number,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
  
  Widget _buildActionButton({
    required IconData icon,
    required VoidCallback onPressed,
    required Color color,
  }) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(40),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(40),
        child: Container(
          width: 64,
          height: 64,
          alignment: Alignment.center,
          child: Icon(icon, size: 28, color: color),
        ),
      ),
    );
  }
}
