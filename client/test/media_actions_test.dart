import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_center_client/core/api_client.dart';
import 'package:media_center_client/core/models.dart';
import 'package:media_center_client/features/gallery/media_actions_sheet.dart';

/// 文件操作面板的测试。
///
/// 用假的 [ApiClient] 顶掉网络。要钉住的是三件服务端强约束在界面上的投影：
/// 扩展名锁死（服务端会拒绝）、服务端追加 " (1)" 后以它的返回值为准、
/// 移动目标只从已注册目录里挑且排除当前目录。

class _FakeClient extends ApiClient {
  _FakeClient({this.renameError})
      : super(baseUrl: 'http://server.test', token: 't');

  final ApiException? renameError;

  String? renameName;
  int renameCalls = 0;

  final List<int> movedIds = <int>[];
  int? movedFolderId;

  /// 服务端最终采用的文件名——同名时会被追加 " (1)"。
  String appliedName = 'renamed.jpg';

  @override
  Future<MediaItem> renameMedia(int id, {String? name, int? folderId}) async {
    renameCalls++;
    renameName = name;
    if (renameError != null) throw renameError!;
    return MediaItem.fromJson({
      'id': id,
      'file_name': appliedName,
      'file_path': '/library/2026/10/$appliedName',
      'media_type': 'photo',
      'file_size': 10,
    });
  }

  @override
  Future<MoveResult> moveMedia(List<int> ids, int folderId) async {
    movedIds.addAll(ids);
    movedFolderId = folderId;
    return MoveResult(
      moved: ids.length,
      failed: 0,
      results: ids.map((id) => MoveOutcome(id: id, ok: true)).toList(),
    );
  }

  @override
  Future<List<ScanFolder>> listFolders() async => const [
        ScanFolder(id: 1, path: '/library', enabled: true, lastScan: ''),
        ScanFolder(id: 2, path: '/Volumes/disk', enabled: true, lastScan: ''),
        ScanFolder(id: 3, path: '/disabled', enabled: false, lastScan: ''),
      ];
}

MediaItem photo() => MediaItem.fromJson(const {
      'id': 7,
      'file_name': 'IMG_0001.JPG',
      'file_path': '/library/2026/10/IMG_0001.JPG',
      'media_type': 'photo',
      'file_size': 1234,
      'origin': 'upload',
    });

void main() {
  group('RenameDialog', () {
    testWidgets('扩展名锁死，只提交改过的主名', (tester) async {
      final client = _FakeClient();
      // applied 在对话框关闭后才赋值，所以先打开再读。
      String? applied;

      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                applied = await showDialog<String>(
                  context: ctx,
                  builder: (_) => RenameDialog(client: client, item: photo()),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // 输入框预填去掉扩展名的主名，扩展名以后缀形式钉在旁边。
      expect(find.text('IMG_0001'), findsOneWidget);
      expect(find.text('.JPG'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '海边日落');
      await tester.tap(find.widgetWithText(FilledButton, '确定'));
      await tester.pumpAndSettle();

      expect(client.renameName, '海边日落.JPG');
      expect(applied, 'renamed.jpg');
    });

    testWidgets('服务端追加序号后，以它的返回值为准', (tester) async {
      final client = _FakeClient()..appliedName = '海边日落 (1).JPG';
      String? applied;

      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                applied = await showDialog<String>(
                  context: ctx,
                  builder: (_) => RenameDialog(client: client, item: photo()),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '海边日落');
      await tester.tap(find.widgetWithText(FilledButton, '确定'));
      await tester.pumpAndSettle();

      expect(applied, '海边日落 (1).JPG',
          reason: '目录里已有同名文件时服务端会追加序号，界面要显示真实结果');
    });

    testWidgets('服务端拒绝时错误显示在对话框里，不关窗', (tester) async {
      final client = _FakeClient(renameError: ApiException('不能修改扩展名'));

      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: ElevatedButton(
              onPressed: () => showDialog<String>(
                context: ctx,
                builder: (_) => RenameDialog(client: client, item: photo()),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'whatever');
      await tester.tap(find.widgetWithText(FilledButton, '确定'));
      await tester.pumpAndSettle();

      expect(find.text('不能修改扩展名'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget,
          reason: '关掉对话框用户就忘了自己输的是什么');
    });

    testWidgets('名称没变化时直接提示，不发请求', (tester) async {
      final client = _FakeClient();

      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: ElevatedButton(
              onPressed: () => showDialog<String>(
                context: ctx,
                builder: (_) => RenameDialog(client: client, item: photo()),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, '确定'));
      await tester.pumpAndSettle();

      expect(find.text('名称没有变化'), findsOneWidget);
      expect(client.renameCalls, 0);
    });
  });

  group('MediaActionsSheet', () {
    testWidgets('三个动作都在，并显示文件名与路径', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () => MediaActionsSheet.show(
                ctx,
                client: _FakeClient(),
                item: photo(),
                onChanged: () async {},
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('加入相册'), findsOneWidget);
      expect(find.text('重命名'), findsOneWidget);
      expect(find.text('移动到…'), findsOneWidget);
      expect(find.text('IMG_0001.JPG'), findsOneWidget);
      expect(find.text('/library/2026/10/IMG_0001.JPG'), findsOneWidget);
    });

    testWidgets('移动目标只列已注册目录，且排除当前所在目录', (tester) async {
      final client = _FakeClient();

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () => MediaActionsSheet.show(
                ctx,
                client: client,
                item: photo(),
                onChanged: () async {},
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移动到…'));
      await tester.pumpAndSettle();

      // /library 是当前目录，/disabled 未启用，都不该出现。
      expect(find.text('/library'), findsNothing);
      expect(find.text('/disabled'), findsNothing);
      expect(find.text('/Volumes/disk'), findsOneWidget);

      await tester.tap(find.text('/Volumes/disk'));
      await tester.pumpAndSettle();

      expect(client.movedIds, [7]);
      expect(client.movedFolderId, 2);
      expect(find.text('已移动到 /Volumes/disk'), findsOneWidget);
    });
  });
}
