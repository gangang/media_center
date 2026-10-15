// 端到端播放验证。
//
// 这个测试不是单元测试——它会真的启动 macOS 窗口、真的发 HTTP 请求、
// 真的让 libmpv 去解码。它要回答的是方案里唯一无法靠推理保证的问题：
// 「点开一个视频，到底能不能播」。
//
// 前置条件：后端已在 127.0.0.1:18080 运行，且索引里有测试媒体。
//
// 运行：
//   flutter test integration_test/playback_test.dart -d macos \
//     --dart-define=MC_BASE_URL=http://127.0.0.1:18080 \
//     --dart-define=MC_TOKEN=<token>

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:media_center_client/features/cinema/video_player_page.dart';
import 'package:media_center_client/main.dart';

const _baseUrl = String.fromEnvironment(
  'MC_BASE_URL',
  defaultValue: 'http://127.0.0.1:18080',
);
const _token = String.fromEnvironment('MC_TOKEN', defaultValue: '');

/// 反复 pump 直到 [condition] 成立或超时。
/// 播放器有持续动画，pumpAndSettle 会一直等不到静止，所以自己控制节奏。
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'server_base_url': _baseUrl,
      'server_token': _token,
    });
  });

  testWidgets('图库加载 -> 切到影院 -> 点开视频 -> 真正开始播放', (tester) async {
    expect(_token, isNotEmpty, reason: '必须通过 --dart-define=MC_TOKEN 传入访问令牌');

    // --- 1. 启动 App，应直接进入主界面（配置已预置） ---
    await tester.pumpWidget(const MediaCenterApp());
    await pumpFor(tester, const Duration(seconds: 1));

    final gotShell = await pumpUntil(
      tester,
      () => find.text('图库').evaluate().isNotEmpty,
      timeout: const Duration(seconds: 15),
    );
    expect(gotShell, isTrue, reason: '未能进入主界面（可能卡在连接页）');
    debugPrint('[1] 已进入主界面');

    // --- 2. 图库应加载出缩略图（走真实 HTTP） ---
    final gotPhotos = await pumpUntil(
      tester,
      () => find.byType(Image).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 20),
    );
    expect(gotPhotos, isTrue, reason: '图库没有加载出任何缩略图');
    final imgCount = find.byType(Image).evaluate().length;
    debugPrint('[2] 图库已加载缩略图: $imgCount 个');

    // --- 3. 切到影院 ---
    await tester.tap(find.text('影院').first);
    await pumpFor(tester, const Duration(seconds: 1));

    final gotVideos = await pumpUntil(
      tester,
      () => find.textContaining('.mkv').evaluate().isNotEmpty ||
          find.textContaining('.mp4').evaluate().isNotEmpty,
      timeout: const Duration(seconds: 20),
    );
    expect(gotVideos, isTrue, reason: '影院列表没有加载出视频');
    debugPrint('[3] 影院列表已加载');

    // --- 4. 点开 MKV（多音轨 + 内封字幕，最苛刻的用例） ---
    final mkvFinder = find.textContaining('.mkv');
    expect(mkvFinder.evaluate(), isNotEmpty, reason: '测试媒体里没有 mkv');

    // 记录该行文件名，后面用来核对播放页标题
    final mkvName = (tester.widget<Text>(mkvFinder.first)).data!;
    debugPrint('[4] 准备播放: $mkvName');

    await tester.tap(mkvFinder.first);
    await pumpFor(tester, const Duration(milliseconds: 600));

    final gotPlayer = await pumpUntil(
      tester,
      () => find.byType(VideoPlayerPage).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 15),
    );
    expect(gotPlayer, isTrue, reason: '点击视频后没有进入播放页');
    debugPrint('[5] 已进入播放页');

    // --- 5. 等播放真正开始 ---
    // 判定依据来自播放页自身的三种可见状态：
    //   buffering 中  -> 右上角转圈
    //   已暂停        -> 左下角「已暂停」提示
    //   播放中        -> 两者都不出现
    // 同时不允许出现错误浮层。
    Finder scoped(Finder f) => find.descendant(
          of: find.byType(VideoPlayerPage),
          matching: f,
        );

    var playing = false;
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));

      final hasError = scoped(find.text('无法播放这个视频')).evaluate().isNotEmpty;
      if (hasError) {
        final msg = tester
            .widgetList<Text>(scoped(find.byType(Text)))
            .map((t) => t.data)
            .whereType<String>()
            .join(' | ');
        fail('播放失败，播放页显示错误浮层。页面文案: $msg');
      }

      final spinning = scoped(find.byType(CircularProgressIndicator))
          .evaluate()
          .isNotEmpty;
      final paused = scoped(find.text('已暂停')).evaluate().isNotEmpty;

      if (!spinning && !paused) {
        playing = true;
        break;
      }
    }

    expect(playing, isTrue,
        reason: '25 秒内播放器一直处于缓冲/暂停状态，说明流没有真正跑起来');
    debugPrint('[6] 播放已开始（无错误、无缓冲、无暂停提示）');

    // --- 6. 让它继续播一会儿，便于观察后端 Range 请求 ---
    await pumpFor(tester, const Duration(seconds: 6));

    final stillAlive =
        find.byType(VideoPlayerPage).evaluate().isNotEmpty;
    expect(stillAlive, isTrue, reason: '播放过程中播放页消失了');
    debugPrint('[7] 持续播放 6 秒无异常');

    // --- 7. 打开音轨/字幕选择器，验证轨道确实被解析出来 ---
    final trackBtn = scoped(find.byIcon(Icons.subtitles_outlined));
    if (trackBtn.evaluate().isNotEmpty) {
      await tester.tap(trackBtn.first);
      await pumpFor(tester, const Duration(seconds: 1));

      final hasAudioSection = find.text('音轨').evaluate().isNotEmpty;
      final hasSubSection = find.text('字幕').evaluate().isNotEmpty;
      final tiles = find.byType(ListTile).evaluate().length;
      debugPrint('[8] 轨道面板: 音轨=$hasAudioSection 字幕=$hasSubSection '
          '条目数=$tiles');

      expect(hasAudioSection && hasSubSection, isTrue,
          reason: '轨道选择器缺少音轨或字幕分区');

      // 关掉面板
      await tester.tapAt(const Offset(10, 10));
      await pumpFor(tester, const Duration(milliseconds: 600));
    }

    debugPrint('=== 播放验证通过 ===');
  });
}
