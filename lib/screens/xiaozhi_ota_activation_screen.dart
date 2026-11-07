import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:ai_assistant/models/conversation.dart';
import 'package:ai_assistant/models/xiaozhi_config.dart';
import 'package:ai_assistant/providers/config_provider.dart';
import 'package:ai_assistant/providers/conversation_provider.dart';
import 'package:ai_assistant/screens/chat_screen.dart';
import 'package:ai_assistant/services/xiaozhi_ota_service.dart';

/// 官网六位数字码连接：与原生 xiaozhi-ios 相同的 OTA 激活流程
/// 请求 OTA -> 未绑定则显示六位码，用户在小智官网输入绑定 -> 轮询至绑定成功，
/// 拿到 WebSocket 地址和 token 后保存配置并进入对话
class XiaozhiOtaActivationScreen extends StatefulWidget {
  const XiaozhiOtaActivationScreen({super.key});

  @override
  State<XiaozhiOtaActivationScreen> createState() =>
      _XiaozhiOtaActivationScreenState();
}

class _XiaozhiOtaActivationScreenState
    extends State<XiaozhiOtaActivationScreen> {
  String? _code;
  String? _message;
  String? _error;
  bool _loading = true;
  bool _navigated = false;
  Timer? _pollTimer;
  int _pollCount = 0;

  @override
  void initState() {
    super.initState();
    _runOta();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _runOta() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await XiaozhiOtaService.fetchOta();
      if (!mounted) return;
      if (result.needsActivation) {
        setState(() {
          _loading = false;
          _code = result.activationCode;
          _message = result.activationMessage;
        });
        _startPolling();
      } else if (result.isBound) {
        await _finishWith(result.websocketUrl!, result.token ?? '');
      } else {
        setState(() {
          _loading = false;
          _error = '服务器未返回绑定信息，请重试';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '连接失败：$e';
      });
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollCount = 0;
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      _pollCount++;
      if (_pollCount > 100) {
        // 约 5 分钟
        _pollTimer?.cancel();
        if (mounted) {
          setState(() {
            _error = '等待绑定超时，请确认已在官网输入验证码后重试';
          });
        }
        return;
      }
      try {
        final result = await XiaozhiOtaService.fetchOta();
        if (!mounted) return;
        if (result.isBound && !result.needsActivation) {
          _pollTimer?.cancel();
          await _finishWith(result.websocketUrl!, result.token ?? '');
        } else if (result.needsActivation &&
            result.activationCode != _code) {
          setState(() {
            _code = result.activationCode;
            _message = result.activationMessage;
          });
        }
      } catch (_) {
        // 轮询失败忽略，继续等
      }
    });
  }

  Future<void> _finishWith(String websocketUrl, String token) async {
    if (_navigated) return;
    _navigated = true;
    _pollTimer?.cancel();
    final mac = await XiaozhiOtaService.getMacAddress();
    final configProvider =
        Provider.of<ConfigProvider>(context, listen: false);
    // 已有同 MAC 的配置则更新地址和 token，否则新建
    XiaozhiConfig? existing;
    for (final c in configProvider.xiaozhiConfigs) {
      if (c.macAddress.toLowerCase() == mac.toLowerCase()) {
        existing = c;
        break;
      }
    }
    XiaozhiConfig config;
    if (existing != null) {
      config = existing.copyWith(websocketUrl: websocketUrl, token: token);
      await configProvider.updateXiaozhiConfig(config);
    } else {
      config = await configProvider.addXiaozhiConfigWithToken(
        '小智（官网绑定）',
        websocketUrl,
        mac,
        token,
      );
    }
    if (!mounted) return;
    final conversation =
        await Provider.of<ConversationProvider>(context, listen: false)
            .createConversation(
      title: '与 ${config.name} 的对话',
      type: ConversationType.xiaozhi,
      configId: config.id,
    );
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(conversation: conversation),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('官网六位数字码连接')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? _buildError()
                : _buildCode(),
      ),
    );
  }

  Widget _buildError() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(_error!, textAlign: TextAlign.center),
        const SizedBox(height: 24),
        ElevatedButton(onPressed: _runOta, child: const Text('重试')),
      ],
    );
  }

  Widget _buildCode() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text(
          '请在小智官网输入以下六位数字码绑定设备',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16),
        ),
        const SizedBox(height: 24),
        SelectableText(
          _code ?? '',
          style: const TextStyle(
            fontSize: 48,
            fontWeight: FontWeight.bold,
            letterSpacing: 8,
          ),
        ),
        if (_message != null && _message!.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(_message!, textAlign: TextAlign.center),
        ],
        const SizedBox(height: 24),
        const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('正在等待绑定…'),
          ],
        ),
      ],
    );
  }
}
