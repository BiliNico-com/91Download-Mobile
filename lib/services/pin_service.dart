import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'dart:math';

/// PIN码锁服务
///
/// 存储格式 v2 = `v2$<salt>$<iterations>$<hash>`，每位用户独立随机盐。
/// 旧格式（固定盐 + 单次 sha256）仍可校验，验证通过后会自动升级到 v2，
/// 老用户不需要重新设置 PIN。
class PinService {
  static final PinService _instance = PinService._internal();
  factory PinService() => _instance;
  PinService._internal();
  
  final _storage = FlutterSecureStorage();
  static const _pinKey = 'app_pin_hash';

  /// 固定盐（仅用于校验历史遗留的 v1 哈希）
  static const _legacySalt = '91download_salt';

  /// PBKDF2 迭代次数。4 位纯数字 PIN 的密钥空间只有 10^4，
  /// 单次 sha256 在本地几微秒就能暴力枚举完；迭代拉高到 2 万次，
  /// 单次校验仍有感知不到的开销，但把离线爆破成本提高约 4 个数量级。
  static const _iterations = 20000;
  static const _keyLength = 32;

  /// 检查是否已设置PIN码
  Future<bool> hasPin() async {
    final pinHash = await _storage.read(key: _pinKey);
    return pinHash != null && pinHash.isNotEmpty;
  }
  
  /// 设置PIN码
  /// 返回 true 表示设置成功
  Future<bool> setPin(String pin) async {
    if (!_isValidPin(pin)) {
      return false;
    }
    final hash = _hashPinV2(pin);
    await _storage.write(key: _pinKey, value: hash);
    return true;
  }
  
  /// 验证PIN码
  Future<bool> verifyPin(String pin) async {
    final stored = await _storage.read(key: _pinKey);
    if (stored == null || stored.isEmpty) {
      return false;
    }

    // v2 格式
    if (stored.startsWith('v2\$')) {
      final parts = stored.split('\$');
      if (parts.length != 4) return false;
      final salt = parts[1];
      final iterations = int.tryParse(parts[2]);
      if (iterations == null || iterations <= 0) return false;
      final expected = parts[3];
      final actual = _pbkdf2(pin, salt, iterations);
      return _constantTimeEquals(expected, actual);
    }

    // v1 旧格式：固定盐 + 单次 sha256。校验通过后原地升级。
    final legacy = _hashPinLegacy(pin);
    final ok = _constantTimeEquals(stored, legacy);
    if (ok) {
      try {
        await _storage.write(key: _pinKey, value: _hashPinV2(pin));
      } catch (_) {
        // 升级失败不影响本次校验结果，下次再试
      }
    }
    return ok;
  }
  
  /// 删除PIN码
  Future<void> removePin() async {
    await _storage.delete(key: _pinKey);
  }

  /// PIN 合法性：4~12 位纯数字
  bool _isValidPin(String pin) {
    if (pin.length < 4 || pin.length > 12) return false;
    return RegExp(r'^\d+$').hasMatch(pin);
  }

  /// 生成 v2 格式哈希
  String _hashPinV2(String pin) {
    final salt = _randomSalt();
    final hash = _pbkdf2(pin, salt, _iterations);
    return 'v2\$$salt\$$_iterations\$$hash';
  }

  /// 16 字节随机盐，hex 编码
  String _randomSalt() {
    final rand = Random.secure();
    final bytes = List<int>.generate(16, (_) => rand.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// PBKDF2-HMAC-SHA256（手写实现，避免引入 pointycastle 依赖 ——
  /// CI 的 Dart 3.2 对新增依赖很敏感）
  String _pbkdf2(String pin, String saltHex, int iterations) {
    final salt = _hexToBytes(saltHex);
    final password = utf8.encode(pin);
    final hmac = Hmac(sha256, password);
    final blocks = (_keyLength / 32).ceil();
    final out = <int>[];

    for (var block = 1; block <= blocks; block++) {
      // U1 = HMAC(password, salt || INT_32_BE(block))
      var u = hmac.convert([
        ...salt,
        (block >> 24) & 0xff,
        (block >> 16) & 0xff,
        (block >> 8) & 0xff,
        block & 0xff,
      ]).bytes;
      final acc = List<int>.from(u);

      for (var i = 1; i < iterations; i++) {
        u = hmac.convert(u).bytes;
        for (var j = 0; j < acc.length; j++) {
          acc[j] ^= u[j];
        }
      }
      out.addAll(acc);
    }

    return out
        .sublist(0, _keyLength)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  List<int> _hexToBytes(String hex) {
    final result = <int>[];
    for (var i = 0; i + 1 < hex.length; i += 2) {
      final byte = int.tryParse(hex.substring(i, i + 2), radix: 16);
      if (byte == null) return <int>[];
      result.add(byte);
    }
    return result;
  }

  /// 固定盐 + 单次 sha256（仅用于兼容旧数据）
  String _hashPinLegacy(String pin) {
    final bytes = utf8.encode(pin + _legacySalt);
    return sha256.convert(bytes).toString();
  }

  /// 常量时间比较，避免通过响应时间差逐位猜出哈希
  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
