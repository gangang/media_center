import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_center_client/core/api_client.dart';
import 'package:media_center_client/core/models.dart';
import 'package:media_center_client/features/gallery/media_actions_sheet.dart';

/// 删除入口补齐后的测试（相册详情批量删除 / 查看器 ⋮ 菜单）。
///
/// 前一轮只钉了"确认框像不像样"，这一轮钉的是新暴露给用户的两条路径
/// 真能删掉东西：相册里长按多选后删除、大图查看器里删除。以及它们
/// 都会走同一条部分失败语义——三个文件里有一个失败，另外两个必须删成。

class _FakeClient extends ApiClient {
  _FakeClient({
    this.batchError,
    this.batchFailedIds = const <int>{},
  }) : super(baseUrl: 'http://server.test', token: 't');

  final ApiException? batchError;

  /// 假造"这些 id 删不掉"，用来验证部分失败提示。
  final Set<int> batchFailedIds;

  int singleCalls = 0;
  int batchCalls = 0;
  final List<List<int>> batchIds = <List<int>>[];

  @override
  Future<DeleteOutcome> deleteMedia(int id) async {
    singleCalls++;
    return DeleteOutcome(id: id, ok: true, fileExisted: true);
  }

  @override
  Future<DeleteResult> deleteMediaBatch(List<int> ids) async {
    batchCalls++;
    batchIds.add(ids);
    if (batchError != null) throw batchError!;
    final ok = ids.where((i) => !batchFailedIds.contains(i)).toList();
    return DeleteResult(
      failed: ids.length - ok.length,
      deleted: ok.length,
      results: [
        for (final id in ok) DeleteOutcome(id: id, ok: true),
        for (final id in ids.where(batchFailedIds.contains))
          DeleteOutcome(id: id, ok: false, error: '文件在只读目录中'),
      ],
    );
  }
}

MediaItem _photo(int id, String name, {String? path}) => MediaItem.fromJson({
      'id': id,
      'file_name': name,
      'file_path': path ?? '/Users/you/Pictures/$name',
      'media_type': 'photo',
      'file_size': 2048,
    });

void main() {
  group('deleteMany', () {
    testWidgets('多个文件走批量接口，且一次请求带全部 id', (tester) async {
      final client = _FakeClient();
      final items = [_photo(1, 'a.jpg'), _photo(2, 'b.jpg'), _photo(3, 'c.jpg')];
      var refreshes = 0;

      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (rootCtx) => Scaffold(
            body: ElevatedButton(
              onPressed: () => MediaActionsSheet.deleteMany(
                rootCtx,
                client: client,
                items: items,
                confirmTitle: '删除这 3 个文件？',
              ).then((ok) {
                if (ok) refreshes++;
              }),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // 确认框要说清是几个文件、删的是什么。
      expect(find.text('删除这 3 个文件？'), findsOneWidget);
      expect(find.text('共 3 个文件'), findsOneWidget);
      expect(find.textContaining('无法恢复'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();

      expect(client.singleCalls, 0, reason: '多项不该拆成多次单项请求');
      expect(client.batchCalls, 1);
      expect(client.batchIds.single, [1, 2, 3]);
      expect(refreshes, 1);
      expect(find.textContaining('已删除 3 个文件'), findsOneWidget);
    });

    testWidgets('部分失败时报出原因，不谎称全部成功', (tester) async {
      final client = _FakeClient(batchFailedIds: {2});
      final items = [_photo(1, 'a.jpg'), _photo(2, 'b.jpg'), _photo(3, 'c.jpg')];

      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (rootCtx) => Scaffold(
            body: ElevatedButton(
              onPressed: () => MediaActionsSheet.deleteMany(
                rootCtx,
                client: client,
                items: items,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();

      // 删成了 2 个、失败 1 个，且失败原因要原样带出来。
      expect(find.textContaining('删除 2 个，1 个失败'), findsOneWidget);
      expect(find.textContaining('只读目录中'), findsOneWidget);
    });

    testWidgets('整个请求失败时说原话且不算删成', (tester) async {
      final client = _FakeClient(batchError: ApiException('数据库繁忙'));
      final items = [_photo(1, 'a.jpg'), _photo(2, 'b.jpg')];
      var refreshes = 0;

      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (rootCtx) => Scaffold(
            body: ElevatedButton(
              onPressed: () => MediaActionsSheet.deleteMany(
                rootCtx,
                client: client,
                items: items,
              ).then((ok) {
                if (ok) refreshes++;
              }),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();

      expect(refreshes, 0);
      expect(find.textContaining('数据库繁忙'), findsOneWidget);
    });

    testWidgets('单项仍走单项接口，保住 file_existed 语义', (tester) async {
      final client = _FakeClient();
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (rootCtx) => Scaffold(
            body: ElevatedButton(
              onPressed: () => MediaActionsSheet.deleteMany(
                rootCtx,
                client: client,
                items: [_photo(9, 'solo.jpg')],
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();

      expect(client.singleCalls, 1);
      expect(client.batchCalls, 0);
    });
  });
}
