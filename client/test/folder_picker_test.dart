import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_center_client/core/api_client.dart';
import 'package:media_center_client/core/models.dart';
import 'package:media_center_client/features/gallery/folder_picker_page.dart';

/// 目录挑选器的测试。
///
/// 分两组：纯逻辑（面包屑切分、导航链）单独测；页面行为用一个假的
/// [ApiClient] 顶掉网络——挑选器要保证的是"面包屑点的路径和服务端返回的
/// 路径逐字节一致"，以及"真机上最容易踩的软链接成环被截断"，这两件事都不
/// 需要真服务端。

/// 记录调用、按路径返回不同目录的假客户端。
///
/// 继承而不是另造一套接口：要验的正是 [ApiClient] 的这两个方法被页面以正确
/// 的参数调用，替身换成另一套签名就测不到这点了。
class _FakeClient extends ApiClient {
  _FakeClient({this.browseError})
      : super(baseUrl: 'http://server.test', token: 't');

  /// 非空时 browseDirectories 抛错，用来测错误分支。
  final ApiException? browseError;

  final List<String> browseCalls = <String>[];
  final List<String> addFolderCalls = <String>[];

  @override
  Future<ServerBrowse> browseDirectories(String path) async {
    browseCalls.add(path);
    if (browseError != null) throw browseError!;
    return ServerBrowse(
      path: path.isEmpty ? '/Users/you' : path,
      parent: path.isEmpty || path == '/Users/you' ? '/Users' : '/Users/you',
      home: '/Users/you',
      entries: path.isEmpty
          ? const [
              ServerDirEntry(
                  name: 'Pictures', path: '/Users/you/Pictures', hidden: false),
              ServerDirEntry(
                  name: '.ssh', path: '/Users/you/.ssh', hidden: true),
            ]
          : const [],
      shortcuts: const [
        ServerDirShortcut(label: '主目录', path: '/Users/you'),
        ServerDirShortcut(label: '图片', path: '/Users/you/Pictures'),
      ],
      truncated: false,
    );
  }

  @override
  Future<void> addFolder(String path) async {
    addFolderCalls.add(path);
  }
}

Map<String, dynamic> decodeJson(String s) =>
    jsonDecode(s) as Map<String, dynamic>;

void main() {
  group('breadcrumbsFor', () {
    test('unix 路径按段切开，每一级的路径都与原串一致', () {
      final crumbs = breadcrumbsFor('/Users/you/Pictures');
      expect(crumbs.map((c) => c.path).toList(),
          ['/', '/Users', '/Users/you', '/Users/you/Pictures']);
      expect(crumbs.map((c) => c.label).toList(),
          ['/', 'Users', 'you', 'Pictures']);
    });

    test('根目录只有一颗，且能回到根本身', () {
      final crumbs = breadcrumbsFor('/');
      expect(crumbs.single.path, '/');
    });

    test('尾斜杠被去掉，否则最后一级的路径和服务端返回的不相等', () {
      final crumbs = breadcrumbsFor('/Users/you/');
      expect(crumbs.last.path, '/Users/you');
    });

    test('windows 路径按反斜杠切，盘符单独一颗', () {
      final crumbs = breadcrumbsFor(r'C:\Users\you\Pictures');
      expect(crumbs.map((c) => c.label).toList(),
          ['C:', 'Users', 'you', 'Pictures']);
      expect(crumbs.last.path, r'C:\Users\you\Pictures');
    });
  });

  group('NavChain', () {
    test('一路向下，每级都开新的一级', () {
      final chain = NavChain();
      expect(chain.enter('/Users'), -1);
      expect(chain.enter('/Users/you'), -1);
      expect(chain.depth, 2);
      expect(chain.canGoUp, true);
    });

    test('指向祖先进目录的软链接被截断成"跳回去"，链不会无限变深', () {
      final chain = NavChain();
      chain.enter('/Users');
      chain.enter('/Users/you');
      chain.enter('/Users/you/trips');

      // 软链接 /Users/you/trips/link -> /Users/you
      final at = chain.enter('/Users/you');
      expect(at, 1, reason: '命中的是链上第二级');
      expect(chain.depth, 2);
      expect(chain.current, '/Users/you');
    });

    test('同一路径重复进入不增长', () {
      final chain = NavChain();
      chain.enter('/Users');
      chain.enter('/Users');
      expect(chain.depth, 1);
      expect(chain.canGoUp, false);
    });
  });

  group('ServerBrowse.fromJson', () {
    test('解析出全部字段，含 hidden 与 truncated', () {
      final b = ServerBrowse.fromJson(decodeJson('''
{
  "path": "/Users/you",
  "parent": "/Users",
  "home": "/Users/you",
  "entries": [
    {"name": "Pictures", "path": "/Users/you/Pictures", "hidden": false},
    {"name": ".ssh", "path": "/Users/you/.ssh", "hidden": true}
  ],
  "shortcuts": [{"label": "主目录", "path": "/Users/you"}],
  "truncated": true
}
'''));

      expect(b.path, '/Users/you');
      expect(b.parent, '/Users');
      expect(b.entries.length, 2);
      expect(b.entries[1].hidden, true);
      expect(b.shortcuts.single.label, '主目录');
      expect(b.truncated, true);
    });

    test('缺字段不致炸，用保守默认值', () {
      final b = ServerBrowse.fromJson(decodeJson('{"path": "/"}'));
      expect(b.entries, isEmpty);
      expect(b.shortcuts, isEmpty);
      expect(b.truncated, false);
    });
  });

  group('FolderPickerPage', () {
    testWidgets('打开即浏览主目录，显示快捷入口与目录', (tester) async {
      final client = _FakeClient();
      await tester.pumpWidget(MaterialApp(
        home: FolderPickerPage(client: client),
      ));
      await tester.pumpAndSettle();

      expect(client.browseCalls, ['']);
      expect(find.text('主目录'), findsOneWidget);
      expect(find.text('图片'), findsOneWidget);
      expect(find.text('Pictures'), findsOneWidget);
      expect(find.text('添加当前目录'), findsOneWidget);
      // 隐藏目录也要显示（置灰），否则用户找不到它
      expect(find.text('.ssh'), findsOneWidget);
    });

    testWidgets('点目录进入，点面包屑回来', (tester) async {
      final client = _FakeClient();
      await tester.pumpWidget(MaterialApp(
        home: FolderPickerPage(client: client),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Pictures'));
      await tester.pumpAndSettle();
      expect(client.browseCalls, ['', '/Users/you/Pictures']);

      // 面包屑最后一级是当前目录（不可点），点它的上一级
      await tester.tap(find.widgetWithText(TextButton, 'you'));
      await tester.pumpAndSettle();
      expect(client.browseCalls.last, '/Users/you');
    });

    testWidgets('已注册的子目录打"已添加"角标', (tester) async {
      final client = _FakeClient();
      await tester.pumpWidget(MaterialApp(
        home: FolderPickerPage(
          client: client,
          registeredPaths: const {'/Users/you/Pictures'},
        ),
      ));
      await tester.pumpAndSettle();

      // 角标挂在目录行上，不是挂在当前目录上
      expect(find.text('已添加'), findsOneWidget);
      expect(find.text('添加当前目录'), findsOneWidget);
    });

    testWidgets('当前目录已注册时，按钮变成重新扫描', (tester) async {
      final client = _FakeClient();
      await tester.pumpWidget(MaterialApp(
        home: FolderPickerPage(
          client: client,
          registeredPaths: const {'/Users/you'},
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('重新扫描'), findsOneWidget);
      expect(find.text('添加当前目录'), findsNothing);
    });

    testWidgets('添加当前目录：调接口后带着"有变化"退出', (tester) async {
      final client = _FakeClient();
      Object? popped;

      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () async {
              popped = await Navigator.push<bool>(
                ctx,
                MaterialPageRoute(
                  builder: (_) => FolderPickerPage(client: client),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加当前目录'));
      await tester.pumpAndSettle();

      expect(client.addFolderCalls, ['/Users/you']);
      expect(popped, true, reason: '管理页靠这个返回值决定要不要刷新');
      expect(find.byType(FolderPickerPage), findsNothing);
    });

    testWidgets('浏览失败时给出可读错误和重试', (tester) async {
      final client = _FakeClient(
        browseError: ApiException('服务端读不了这个目录'),
      );
      await tester.pumpWidget(MaterialApp(
        home: FolderPickerPage(client: client),
      ));
      await tester.pumpAndSettle();

      expect(find.text('服务端读不了这个目录'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(client.browseCalls.length, 2);
    });

    testWidgets('手动输入是保留的高级入口', (tester) async {
      final client = _FakeClient();
      await tester.pumpWidget(MaterialApp(
        home: FolderPickerPage(client: client),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('手动输入'));
      await tester.pumpAndSettle();

      expect(find.text('手动输入路径'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '/Volumes/disk/photos');
      await tester.tap(find.widgetWithText(FilledButton, '添加'));
      await tester.pumpAndSettle();

      expect(client.addFolderCalls, ['/Volumes/disk/photos']);
    });
  });
}
