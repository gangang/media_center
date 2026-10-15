// 端到端相册验证。
//
// 会真的启动 macOS 窗口、真的走 HTTP：新建相册 → 从图库长按加入 →
// 相册里看到内容 → 移出 → 删除相册。
//
// 相册功能的价值全在「这一串操作连起来到底成不成」——单测能覆盖模型解析，
// 覆盖不了「长按之后弹层有没有出来」「加完之后相册页的数量是不是真的变了」。
//
// 前置条件：后端已在 127.0.0.1:18080 运行，且索引里有媒体。
//
// 运行：
//   flutter test integration_test/album_test.dart -d macos \
//     --dart-define=MC_BASE_URL=http://127.0.0.1:18080 \
//     --dart-define=MC_TOKEN=<token>

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:media_center_client/main.dart';
import 'package:media_center_client/widgets/media_grid.dart';

const _baseUrl = String.fromEnvironment(
  'MC_BASE_URL',
  defaultValue: 'http://127.0.0.1:18080',
);
const _token = String.fromEnvironment('MC_TOKEN', defaultValue: '');

/// 反复 pump 直到 [condition] 成立或超时。
Future<bool> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 20),
  Duration step = const Duration(milliseconds: 120),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await tester.pump(step);
  }
  return condition();
}

Future<void> pumpFor(WidgetTester tester, Duration d) async {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// 定位导航栏里的某一项。
///
/// 不能用裸的 find.text('相册')：相册页的 AppBar 标题也叫「相册」，而它一直
/// 活在 IndexedStack 里，两个同名文本会同时被匹配到。
Finder navTo(String label) {
  final inRail = find.descendant(
    of: find.byType(NavigationRail),
    matching: find.text(label),
  );
  if (inRail.evaluate().isNotEmpty) return inRail;
  return find.descendant(
    of: find.byType(NavigationBar),
    matching: find.text(label),
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'server_base_url': _baseUrl,
      'server_token': _token,
    });
  });

  testWidgets('新建相册 -> 从图库加入 -> 相册内可见 -> 移出 -> 删除', (tester) async {
    expect(_token, isNotEmpty, reason: '必须通过 --dart-define=MC_TOKEN 传入访问令牌');

    // 名字带时间戳，避免重复运行撞上「同名相册」的 409。
    final albumName = '测试相册-${DateTime.now().millisecondsSinceEpoch}';

    // --- 1. 启动，应直接进入主界面 ---
    await tester.pumpWidget(const MediaCenterApp());
    await pumpFor(tester, const Duration(seconds: 1));
    expect(
      await pumpUntil(
        tester,
        () => find.text('图库').evaluate().isNotEmpty,
        timeout: const Duration(seconds: 15),
      ),
      isTrue,
      reason: '未能进入主界面（可能卡在连接页）',
    );
    debugPrint('[1] 已进入主界面');

    // --- 2. 图库应加载出缩略图 ---
    expect(
      await pumpUntil(
        tester,
        () => find.byType(MediaThumbnailTile).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 20),
      ),
      isTrue,
      reason: '图库没有加载出任何缩略图',
    );
    debugPrint(
        '[2] 图库已加载缩略图: ${find.byType(MediaThumbnailTile).evaluate().length} 个');

    // --- 3. 切到相册页并新建一个相册 ---
    await tester.tap(navTo('相册'));
    await pumpFor(tester, const Duration(seconds: 1));
    expect(find.text('新建相册'), findsOneWidget, reason: '相册页没有新建入口');

    await tester.tap(find.text('新建相册'));
    await pumpFor(tester, const Duration(milliseconds: 600));
    await tester.enterText(find.byType(TextField), albumName);
    await tester.tap(find.text('创建'));
    await pumpFor(tester, const Duration(seconds: 2));

    expect(find.text(albumName), findsOneWidget, reason: '新建的相册没有出现在列表里');
    debugPrint('[3] 已新建相册: $albumName');

    // --- 4. 回图库，长按一项加入相册 ---
    await tester.tap(navTo('图库'));
    await pumpFor(tester, const Duration(seconds: 1));

    await tester.longPress(find.byType(MediaThumbnailTile).first);
    expect(
      await pumpUntil(
        tester,
        () => find.byType(CheckboxListTile).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 15),
      ),
      isTrue,
      reason: '长按缩略图没有打开相册选择器',
    );
    debugPrint('[4] 相册选择器已打开');

    final albumRow = find.widgetWithText(CheckboxListTile, albumName);
    expect(albumRow, findsOneWidget, reason: '选择器里找不到刚建的相册');
    await tester.tap(albumRow);

    // 勾选状态要等真实的 POST 回来才会变。
    final gotChecked = await pumpUntil(tester, () {
      final rows = find.widgetWithText(CheckboxListTile, albumName).evaluate();
      if (rows.isEmpty) return false;
      return (rows.first.widget as CheckboxListTile).value == true;
    }, timeout: const Duration(seconds: 15));
    expect(gotChecked, isTrue, reason: '勾选之后状态没有变成「已加入」');
    debugPrint('[5] 已加入相册');

    // 点弹层外的区域关闭选择器
    await tester.tapAt(const Offset(400, 30));
    await pumpFor(tester, const Duration(seconds: 1));

    // --- 5. 切回相册页，数量应已更新 ---
    await tester.tap(navTo('相册'));
    await pumpFor(tester, const Duration(seconds: 2));
    expect(
      find.text('1 项'),
      findsWidgets,
      reason: '相册数量没有更新为 1（IndexedStack 里的旧数据没刷新？）',
    );
    debugPrint('[6] 相册列表已显示 1 项');

    // --- 6. 打开相册，应能看到刚加入的内容 ---
    await tester.tap(find.text(albumName));
    await pumpFor(tester, const Duration(seconds: 2));
    expect(
      find.byType(MediaThumbnailTile),
      findsWidgets,
      reason: '相册详情里没有内容',
    );
    debugPrint('[7] 相册详情已加载内容');

    // --- 7. 长按进入选择模式，移出 ---
    await tester.longPress(find.byType(MediaThumbnailTile).first);
    await pumpFor(tester, const Duration(milliseconds: 600));
    expect(find.textContaining('已选'), findsOneWidget, reason: '长按没有进入选择模式');

    await tester.tap(find.byIcon(Icons.playlist_remove));
    expect(
      await pumpUntil(
        tester,
        () => find.textContaining('还是空的').evaluate().isNotEmpty,
        timeout: const Duration(seconds: 15),
      ),
      isTrue,
      reason: '移出之后相册没有变成空相册',
    );
    debugPrint('[8] 已移出，相册变空');

    // --- 8. 返回并删除相册 ---
    await tester.pageBack();
    await pumpFor(tester, const Duration(seconds: 2));

    final ourCard = find.ancestor(
      of: find.text(albumName),
      matching: find.byType(Card),
    );
    expect(ourCard, findsOneWidget, reason: '返回后找不到刚才的相册卡片');

    await tester.tap(
      find.descendant(
        of: ourCard,
        matching: find.byType(PopupMenuButton<String>),
      ),
    );
    await pumpFor(tester, const Duration(milliseconds: 600));
    await tester.tap(find.text('删除相册'));
    await pumpFor(tester, const Duration(milliseconds: 600));
    await tester.tap(find.text('删除'));
    await pumpFor(tester, const Duration(seconds: 2));

    expect(find.text(albumName), findsNothing, reason: '相册没有被删除');
    debugPrint('[9] 已删除相册');
  });
}
