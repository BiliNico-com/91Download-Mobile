import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';

/// PIN码锁服务
class PinService {
  static final PinService _instance = PinService._internal();
  factory PinService() => _instance;
  PinService._internal();
  
  final _storage = FlutterSecureStorage();
  static const _pinKey = 'app_pin_hash';
  
  /// 检查是否已设置PIN码
  Future<bool> hasPin() async {
    final pinHash = await _storage.read(key: _pinKey);
    return pinHash != null && pinHash.isNotEmpty;
  }
  
  /// 设置PIN码
  /// 返回 true 表示设置成功
  Future<bool> setPin(String pin) async {
    if (pin.length < 4) {
      return false;  // PIN码至少4位
    }
    final hash = _hashPin(pin);
    await _storage.write(key: _pinKey, value: hash);
    return true;
  }
  
  /// 验证PIN码
  Future<bool> verifyPin(String pin) async {
    final storedHash = await _storage.read(key: _pinKey);
    if (storedHash == null || storedHash.isEmpty) {
      return false;
    }
    final inputHash = _hashPin(pin);
    return storedHash == inputHash;
  }
  
  /// 删除PIN码
  Future<void> removePin() async {
    await _storage.delete(key: _pinKey);
  }
  
  /// PIN码哈希（SHA256）
  String _hashPin(String pin) {
    final bytes = utf8.encode(pin + '91download_salt');  // 加盐
    final digest = sha256.convert(bytes);
    return digest.toString();
  }
}
