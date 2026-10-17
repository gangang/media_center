import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_center_client/core/api_client.dart';
import 'package:media_center_client/core/models.dart';
import 'package:media_center_client/features/gallery/media_actions_sheet.dart';

/// 删除的测试。
///
/// 删除是这个功能里唯一不可逆的操作，所以要钉住的恰好是那些"删错了"的场景：
/// 确认框必须显示**完整路径**（分不清删的是手机副本还是 Mac 原图 = 删错）、
/// 取消不发请求、服务端报错时说原话、文件本来就不在时也要如实告知。

class _FakeClient extends ApiClient {
  _FakeClient({this.deleteError, this.fileExisted})
      : super(baseUrl: 'http://server.test', token: 't');

  final ApiException? deleteError;

  /// 假造服务端的 file_existed。null 表示别覆盖，用真实语义。
  final bool? fileExisted;

  int deleteCalls = 0;
  final List<int> deletedIds = <int>[];

  @override
  Future<DeleteOutcome> deleteMedia(int id) async {
    deleteCalls++;
    deletedIds.add(id);
    if (deleteError != null) throw deleteError!;
    return DeleteOutcome(id: id, ok: true, fileExisted: fileExisted);
  }
}

MediaItem _photo() => MediaItem.fromJson(const {
      'id': 7,
      'file_name': '故宫日落.jpg',
      'file_path': '/Users/you/Pictures/故宫日落.jpg',
      'media_type': 'photo',
      'file_size': 2048,
    });

void main() {
  group('DeleteConfirmDialog', () {
    testWidgets('确认框显示完整路径和不可恢复的警告', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          // 这一版 Dart 的 _ 是真正的通配符，不能再引用；外层上下文要起名
          // 才能传给 showDialog。
          builder: (rootCtx) => Scaffold(
            body: ElevatedButton(
              onPressed: () => showDialog<bool>(
                context: rootCtx,
                builder: (_) => const DeleteConfirmDialog(
                  title: '删除这个文件？',
                  fileName: '故宫日落.jpg',
                  filePath: '/Users/you/Pictures/故宫日落.jpg',
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // 路径是删除真正的作用对象，必须原样出现。
      expect(find.text('/Users/you/Pictures/故宫日落.jpg'), findsOneWidget);
      expect(find.textContaining('无法恢复'), findsOneWidget);
    });

    testWidgets('取消返回 false', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          // 这一版 Dart 的 _ 是真正的通配符，不能再引用；外层上下文要起名
          // 才能传给 showDialog。
          builder: (rootCtx) => Scaffold(
            body: ElevatedButton(
              onPressed: () => showDialog<bool>(
                context: rootCtx,
                builder: (_) => DeleteConfirmDialog(
                  title: '删除这个文件？',
                  fileName: 'a.jpg',
                  filePath: '/library/2026/10/a.jpg',
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      // 弹窗已消失即取消生效；请求由上层流程发，这里只验证决策。
      expect(find.byType(DeleteConfirmDialog), findsNothing);
    });
  });

  group('删除流程', () {
    testWidgets('确认后删除，并提示已删除', (tester) async {
      final client = _FakeClient();
      var refreshes = 0;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () => MediaActionsSheet.show(
                ctx,
                client: client,
                item: _photo(),
                onChanged: () async => refreshes++,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      // 确认框出现，这一步还没发请求。
      expect(client.deleteCalls, 0);
      expect(find.text('/Users/you/Pictures/故宫日落.jpg'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();

      expect(client.deletedIds, [7]);
      expect(refreshes, 1);
      expect(find.textContaining('已删除'), findsOneWidget);
    });

    testWidgets('取消确认不发请求', (tester) async {
      final client = _FakeClient();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () => MediaActionsSheet.show(
                ctx,
                client: client,
                item: _photo(),
                onChanged: () async {},
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(client.deleteCalls, 0);
    });

    testWidgets('服务端拒绝时原话提示，且不刷新', (tester) async {
      final client = _FakeClient(deleteError: ApiException('文件在只读目录中'));
      var refreshes = 0;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () => MediaActionsSheet.show(
                ctx,
                client: client,
                item: _photo(),
                onChanged: () async => refreshes++,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();

      expect(client.deleteCalls, 1);
      expect(refreshes, 0);
      expect(find.textContaining('文件在只读目录中'), findsOneWidget);
    });

    testWidgets('文件原本就不在磁盘上时如实说明', (tester) async {
      final client = _FakeClient(fileExisted: false);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () => MediaActionsSheet.show(
                ctx,
                client: client,
                item: _photo(),
                onChanged: () async {},
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();

      expect(find.textContaining('此前已不在磁盘上'), findsOneWidget);
    });
  });
}
