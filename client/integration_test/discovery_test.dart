// 端到端自动发现验证。
//
// 这条用例存在的唯一理由：`dart run tool/mdns_probe.dart` 能发现服务，
// 不代表**应用包里的客户端**也能。两者差别很大——应用有 bundle、有沙箱、
// 有 macOS 15 起的本地网络隐私授权，任何一条都能让组播静默失效。而静默
// 失效正是这里最危险的地方：界面只会显示「没有发现服务器」，看起来像是
// 局域网里确实没有服务端，实际是被系统拦了。
//
// 所以这条用例刻意不预置服务器信息，让连接页自己发现。
//
// 前置条件：后端已在 127.0.0.1:18080 运行（且它正在广播 _mediacenter._tcp）。
//
// 运行：
//   flutter test integration_test/discovery_test.dart -d macos

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:media_center_client/main.dart';

/// 反复 pump 直到 [condition] 成立或超时。
///
/// 集成测试跑在真实时钟上，`tester.pump` 会真的推进时间，所以这里可以等
/// 真实的网络往返。
Future<bool> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 20),
  Duration step = const Duration(milliseconds: 150),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await tester.pump(step);
  }
  return condition();
}

/// 读地址框里当前的内容。
///
/// 页面还没渲染出来时返回空串，而不是让 `tester.widget` 抛 "Bad state: No
/// element"——这个函数会被轮询条件反复调用，启动瞬间的连接页还没挂上去，
/// 那是正常状态，不是错误。
String urlText(WidgetTester tester) {
  final finder = find.widgetWithText(TextFormField, '服务器地址');
  if (finder.evaluate().isEmpty) return '';
  final field = tester.widget<TextFormField>(finder);
  return field.controller?.text ?? '';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 关键：不预置 server_base_url，让连接页走「自动发现」这条路。
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('连接页能自动发现局域网内的服务端', (tester) async {
    await tester.pumpWidget(const MediaCenterApp());

    // 等发现跑完：结果是「地址被自动填好」或「给出没发现的解释」二选一。
    final settled = await pumpUntil(
      tester,
      () =>
          urlText(tester).isNotEmpty ||
          find.textContaining('没有发现服务器').evaluate().isNotEmpty ||
          find.textContaining('mDNS').evaluate().isNotEmpty,
      timeout: const Duration(seconds: 20),
    );
    expect(settled, isTrue, reason: '等了 20 秒，发现流程仍未给出任何结果');

    final found = urlText(tester);
    if (found.isEmpty) {
      // 把界面上的说法带进失败信息，省得再去翻日志猜是哪一种失败。
      final hint = find.textContaining('没有发现服务器').evaluate().isNotEmpty
          ? '界面显示：没有发现服务器。请确认后端在跑，且启动日志里有 mDNS 一行。'
          : '界面显示的是发现异常，见上方渲染文本。';
      fail('应用包内未能发现服务端。$hint');
    }

    debugPrint('[discovery] 自动发现到地址：$found');
    expect(found, contains(':'), reason: '自动填入的应当是 host:port');

    // 发现只是省去输入地址，令牌仍要用户自己填，所以连接按钮必须还在。
    expect(find.widgetWithText(FilledButton, '连接'), findsOneWidget);
    expect(find.text('访问令牌'), findsOneWidget);

    // 重新搜索一次，确认反复搜索不会把状态搞坏。
    await tester.tap(find.byTooltip('重新搜索'));
    await pumpUntil(tester, () => urlText(tester).isNotEmpty);
    expect(urlText(tester), contains(':'));
  });
}
