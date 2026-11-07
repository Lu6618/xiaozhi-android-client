import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// OTA 返回结果：已绑定时带 websocket，未绑定时带六位激活码
class OtaResult {
  final String? websocketUrl;
  final String? token;
  final String? activationCode;
  final String? activationMessage;

  OtaResult({
    this.websocketUrl,
    this.token,
    this.activationCode,
    this.activationMessage,
  });

  bool get needsActivation =>
      activationCode != null && activationCode!.isNotEmpty;
  bool get isBound => websocketUrl != null && websocketUrl!.isNotEmpty;
}

/// 小智 OTA 服务：与原生 xiaozhi-ios 相同的官网六位数字码绑定流程
/// POST https://api.tenclass.net/xiaozhi/ota/ -> 未绑定返回 activation.code，
/// 用户在小智官网输入该码绑定后，再请求即返回 websocket.url + token
class XiaozhiOtaService {
  static const String otaEndpoint = 'https://api.tenclass.net/xiaozhi/ota/';
  static const String _uuidKey = 'xiaozhi_ota_uuid';

  /// 设备 MAC：与 ConfigProvider 相同算法（deviceId 的 md5 前 12 位格式化）
  static Future<String> getMacAddress() async {
    final deviceId = await _getDeviceId();
    final bytes = utf8.encode(deviceId);
    final digest = md5.convert(bytes);
    final hash = digest.toString();
    final parts = <String>[];
    for (int i = 0; i < 6; i++) {
      parts.add(hash.substring(i * 2, i * 2 + 2));
    }
    return parts.join(':');
  }

  static Future<String> _getDeviceId() async {
    final deviceInfo = DeviceInfoPlugin();
    String deviceId = '';
    try {
      try {
        final androidInfo = await deviceInfo.androidInfo;
        deviceId = androidInfo.id;
      } catch (_) {
        try {
          final iosInfo = await deviceInfo.iosInfo;
          deviceId = iosInfo.identifierForVendor ?? '';
        } catch (_) {
          final webInfo = await deviceInfo.webBrowserInfo;
          deviceId = webInfo.userAgent ?? '';
        }
      }
    } catch (_) {
      deviceId = DateTime.now().millisecondsSinceEpoch.toString();
    }
    if (deviceId.isEmpty) {
      deviceId = DateTime.now().millisecondsSinceEpoch.toString();
    }
    return deviceId;
  }

  /// 设备 UUID（clientId），持久化保存，OTA 与 WebSocket 共用
  static Future<String> getClientUuid() async {
    final prefs = await SharedPreferences.getInstance();
    String? uuid = prefs.getString(_uuidKey);
    if (uuid == null || uuid.isEmpty) {
      uuid = const Uuid().v4();
      await prefs.setString(_uuidKey, uuid);
    }
    return uuid;
  }

  static Future<String> getDeviceModel() async {
    final deviceInfo = DeviceInfoPlugin();
    try {
      if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        return iosInfo.model;
      } else if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        return '${androidInfo.manufacturer} ${androidInfo.model}';
      }
    } catch (_) {}
    return 'Unknown';
  }

  /// 发一次 OTA 请求，返回绑定状态或六位激活码
  static Future<OtaResult> fetchOta() async {
    final mac = await getMacAddress();
    final uuid = await getClientUuid();
    final model = await getDeviceModel();
    final isIOS = Platform.isIOS;

    final body = {
      'version': 2,
      'language': 'zh-CN',
      'flash_size': 16777216,
      'minimum_free_heap_size': 8457848,
      'mac_address': mac,
      'chip_model_name': isIOS ? 'Apple-Silicon' : 'Android',
      'uuid': uuid,
      'application': {
        'name': 'xiaozhi-ios',
        'version': '1.0.0',
        'compile_time': 'Now',
        'idf_version': 'N/A',
        'elf_sha256': 'fake',
      },
      'partition_table': [],
      'ota': {'partition': 'ota_0'},
      'board': {
        'type': 'xingzhi-ios',
        'name': model,
        'ssid': 'Wifi',
        'rssi': -50,
        'channel': 0,
        'ip': '127.0.0.1',
        'mac': mac,
      },
    };

    final resp = await http
        .post(
          Uri.parse(otaEndpoint),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 15));

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('OTA 请求失败：HTTP ${resp.statusCode}');
    }

    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final ws = json['websocket'] as Map<String, dynamic>?;
    final act = json['activation'] as Map<String, dynamic>?;
    final code = act?['code']?.toString() ?? '';
    final message = act?['message']?.toString() ?? '';
    return OtaResult(
      websocketUrl: ws?['url']?.toString(),
      token: ws?['token']?.toString(),
      activationCode: code.isEmpty ? null : code,
      activationMessage: message.isEmpty ? null : message,
    );
  }
}
