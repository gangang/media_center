import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'core/api_client.dart';
import 'core/server_discovery.dart';
import 'core/settings_store.dart';
import 'features/connect/connect_page.dart';
import 'features/home/home_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 必须在创建任何 Player 之前调用，否则 libmpv 的原生库不会被加载。
  MediaKit.ensureInitialized();
  runApp(const MediaCenterApp());
}

class MediaCenterApp extends StatelessWidget {
  const MediaCenterApp({super.key, this.discoverer});

  /// 服务器发现实现，一路传给连接页。
  ///
  /// 只为一件事而存在：让「启动后进入连接页」这个流程可测。不注入时用真实的
  /// mDNS 发现，而真实发现会开 socket、等网络，widget 测试里既慢又会留下未
  /// 完成的异步任务。
  final ServerDiscoverer? discoverer;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '本地媒体中心',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF2F6BFF),
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFFAFAFA),
      ),
      home: _Boot(discoverer: discoverer),
    );
  }
}

/// 启动时读取已保存的连接信息：有就直接进主界面，没有就去连接页。
class _Boot extends StatefulWidget {
  const _Boot({this.discoverer});

  final ServerDiscoverer? discoverer;

  @override
  State<_Boot> createState() => _BootState();
}

class _BootState extends State<_Boot> {
  final _settingsStore = SettingsStore();
  late Future<ServerSettings?> _future;

  @override
  void initState() {
    super.initState();
    _future = _settingsStore.load();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ServerSettings?>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final settings = snapshot.data;
        if (settings == null) {
          return ConnectPage(
            settingsStore: _settingsStore,
            discoverer: widget.discoverer,
            onConnected: () => setState(() => _future = _settingsStore.load()),
          );
        }
        return HomeShell(
          client: ApiClient(baseUrl: settings.baseUrl, token: settings.token),
          onDisconnect: () async {
            await _settingsStore.clear();
            if (mounted) {
              setState(() => _future = _settingsStore.load());
            }
          },
        );
      },
    );
  }
}
