import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_center_client/core/server_discovery.dart';
import 'package:media_center_client/core/settings_store.dart';
import 'package:media_center_client/features/connect/connect_page.dart';
import 'package:media_center_client/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一个立刻返回固定结果的发现器。
///
/// 用假的而不是真的：真实实现要开组播 socket 并等网络，widget 测试里既慢
/// 又依赖局域网，而且搜索期间的转圈动画会让 `pumpAndSettle` 永远等不到静止。
class _FakeDiscoverer implements ServerDiscoverer {
  _FakeDiscoverer({this.result = const [], this.error});

  final List<DiscoveredServer> result;
  final Object? error;

  int calls = 0;
  bool disposed = false;

  @override
  Future<List<DiscoveredServer>> discover() async {
    calls++;
    if (error != null) throw error!;
    return result;
  }

  @override
  void dispose() => disposed = true;
}

/// 一直挂着、由用例决定何时返回的发现器。
///
/// 「用户先输入了地址」这类竞态只能这样测：如果发现器立刻返回，自动填充在
/// `pumpWidget` 期间就完成了，用例再怎么输入也测不到那个分支。
class _PendingDiscoverer implements ServerDiscoverer {
  final completer = Completer<List<DiscoveredServer>>();
  bool disposed = false;

  @override
  Future<List<DiscoveredServer>> discover() => completer.future;

  @override
  void dispose() => disposed = true;
}

DiscoveredServer _server({
  String name = 'MediaCenter-bogon',
  String address = '192.168.1.49',
  int port = 18080,
  String? version = '0.1.0',
}) {
  return DiscoveredServer(
    instance: '$name._mediacenter._tcp.local',
    name: name,
    host: 'bogon.local',
    port: port,
    addresses: [address],
    txt: {
      'name': name,
      'path': '/',
      // 空值即整条不写入，避免出现 'version': null 这种半个字段。
      'version': ?version,
    },
  );
}

/// 起一个只装了连接页的壳，避免整个 App 的启动流程干扰用例。
Widget _harness(ServerDiscoverer discoverer, {VoidCallback? onConnected}) {
  return MaterialApp(
    home: ConnectPage(
      settingsStore: SettingsStore(),
      onConnected: onConnected ?? () {},
      discoverer: discoverer,
    ),
  );
}

/// 读地址框里当前的内容。
String _urlText(WidgetTester tester) {
  final field = tester.widget<TextFormField>(
    find.widgetWithText(TextFormField, '服务器地址'),
  );
  return field.controller?.text ?? '';
}

void main() {
  setUp(() {
    // 每个用例都从「从未连接过服务器」的干净状态开始。
    SharedPreferences.setMockInitialValues({});
  });

  group('启动流程', () {
    testWidgets('没有已保存的服务器时，启动进入连接页', (tester) async {
      // 注入假发现器：这条用例要验的是启动分支，不是 mDNS。
      await tester.pumpWidget(MediaCenterApp(discoverer: _FakeDiscoverer()));
      await tester.pumpAndSettle();

      expect(find.text('本地媒体中心'), findsOneWidget);
      expect(find.text('服务器地址'), findsOneWidget);
      expect(find.text('访问令牌'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '连接'), findsOneWidget);
    });
  });

  group('手动输入', () {
    testWidgets('地址与令牌为空时提交，给出必填提示', (tester) async {
      await tester.pumpWidget(_harness(_FakeDiscoverer()));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, '连接'));
      await tester.pumpAndSettle();

      expect(find.text('请输入服务器地址'), findsOneWidget);
      expect(find.text('请输入访问令牌'), findsOneWidget);
    });

    testWidgets('只填地址不填令牌，仍然拦住提交', (tester) async {
      await tester.pumpWidget(_harness(_FakeDiscoverer()));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextFormField, '服务器地址'), '192.168.1.5:8080');
      await tester.tap(find.widgetWithText(FilledButton, '连接'));
      await tester.pumpAndSettle();

      expect(find.text('请输入服务器地址'), findsNothing);
      expect(find.text('请输入访问令牌'), findsOneWidget);
    });
  });

  group('自动发现', () {
    testWidgets('发现到服务器时列出名称与地址', (tester) async {
      final fake = _FakeDiscoverer(result: [_server()]);
      await tester.pumpWidget(_harness(fake));
      await tester.pumpAndSettle();

      expect(fake.calls, 1);
      expect(find.text('MediaCenter-bogon'), findsOneWidget);
      expect(find.text('192.168.1.49:18080 · v0.1.0'), findsOneWidget);
    });

    testWidgets('只发现到一台时自动填好地址', (tester) async {
      await tester.pumpWidget(_harness(_FakeDiscoverer(result: [_server()])));
      await tester.pumpAndSettle();

      // 自动填的是 host:port 写法，与输入框提示一致。
      expect(_urlText(tester), '192.168.1.49:18080');
    });

    testWidgets('发现到多台时不自动填，让用户自己选', (tester) async {
      await tester.pumpWidget(_harness(_FakeDiscoverer(result: [
        _server(name: 'A', address: '192.168.1.10'),
        _server(name: 'B', address: '192.168.1.11'),
      ])));
      await tester.pumpAndSettle();

      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
      expect(_urlText(tester), isEmpty);
    });

    testWidgets('点选一台服务器会填入地址并选中该项', (tester) async {
      await tester.pumpWidget(_harness(_FakeDiscoverer(result: [
        _server(name: 'A', address: '192.168.1.10'),
        _server(name: 'B', address: '192.168.1.11'),
      ])));
      await tester.pumpAndSettle();

      await tester.tap(find.text('B'));
      await tester.pumpAndSettle();

      expect(_urlText(tester), '192.168.1.11:18080');
      // 选中态换成对勾图标，其余仍是普通图标。
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.byIcon(Icons.dns_outlined), findsWidgets);
    });

    testWidgets('用户已经填过地址时，自动填不覆盖它', (tester) async {
      final pending = _PendingDiscoverer();
      await tester.pumpWidget(_harness(pending));
      await tester.pump();

      // 在发现返回之前先自己输入。
      await tester.enterText(
          find.widgetWithText(TextFormField, '服务器地址'), '10.0.0.9:9000');
      await tester.pump();

      pending.completer.complete([_server()]);
      await tester.pumpAndSettle();

      expect(_urlText(tester), '10.0.0.9:9000');
    });

    testWidgets('没发现到服务器时给出解释并保留手动入口', (tester) async {
      await tester.pumpWidget(_harness(_FakeDiscoverer()));
      await tester.pumpAndSettle();

      expect(find.textContaining('没有发现服务器'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '连接'), findsOneWidget);
    });

    testWidgets('发现失败时显示原因，不影响手动连接', (tester) async {
      await tester.pumpWidget(_harness(
        _FakeDiscoverer(error: const ServerDiscoveryException('无法监听 mDNS 端口 5353')),
      ));
      await tester.pumpAndSettle();

      expect(find.text('无法监听 mDNS 端口 5353'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '连接'), findsOneWidget);
    });

    testWidgets('重新搜索会再跑一次发现', (tester) async {
      final fake = _FakeDiscoverer();
      await tester.pumpWidget(_harness(fake));
      await tester.pumpAndSettle();
      expect(fake.calls, 1);

      await tester.tap(find.byTooltip('重新搜索'));
      await tester.pumpAndSettle();
      expect(fake.calls, 2);
    });

    testWidgets('外部传入的发现器不由页面释放', (tester) async {
      final fake = _FakeDiscoverer();
      await tester.pumpWidget(_harness(fake));
      await tester.pumpAndSettle();

      // 换掉整棵树，触发连接页 dispose。
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();

      expect(fake.disposed, isFalse);
    });
  });
}
