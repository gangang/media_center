import 'package:shared_preferences/shared_preferences.dart';

/// 已保存的服务器连接信息。
class ServerSettings {
  const ServerSettings({required this.baseUrl, required this.token});

  final String baseUrl;
  final String token;
}

/// 连接信息的本地持久化。
///
/// 令牌存在 SharedPreferences 中。桌面端它落在应用沙盒内，Android 上落在
/// 应用私有目录，其他应用读不到。这不是密钥库级别的保护，但对一个局域网
/// 媒体服务器而言是合理的权衡；将来如果要做多设备独立令牌，这里换成
/// flutter_secure_storage 即可。
class SettingsStore {
  static const _keyUrl = 'server_base_url';
  static const _keyToken = 'server_token';

  Future<ServerSettings?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(_keyUrl);
    final token = prefs.getString(_keyToken);
    if (url == null || url.isEmpty || token == null || token.isEmpty) {
      return null;
    }
    return ServerSettings(baseUrl: url, token: token);
  }

  Future<void> save(ServerSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyUrl, settings.baseUrl);
    await prefs.setString(_keyToken, settings.token);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyUrl);
    await prefs.remove(_keyToken);
  }
}
