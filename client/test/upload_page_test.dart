import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_center_client/core/upload/media_source.dart';
import 'package:media_center_client/core/upload/upload_models.dart';
import 'package:media_center_client/core/upload/upload_queue.dart';
import 'package:media_center_client/core/upload/upload_transport.dart';
import 'package:media_center_client/features/upload/upload_page.dart';

/// 备份页的 widget 测试。
///
/// 相册用假实现顶替：真的 `photo_manager` 要一台手机和一堆系统权限，而这一层
/// 要验证的东西（权限引导文案、选片、排队、传完通知图库刷新）跟相册从哪来
/// 完全无关。上传走的是真 [UploadQueue] 加一个内存版 [UploadTransport] ——
/// 队列本身已经被 `upload_queue_test.dart` 单独覆盖，这里要确认的是**页面把它
/// 接对了**：选了 2 项就该有 2 个任务，传完就该回调一次。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('mc_upload_page_test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String makeFile(String name, int size) {
    final bytes = Uint8List(size);
    for (var i = 0; i < size; i++) {
      bytes[i] = (i * 17 + 3) % 256;
    }
    final path = '${tmp.path}/$name';
    File(path).writeAsBytesSync(bytes);
    return path;
  }

  UploadQueue newQueue(_FakeTransport transport) => UploadQueue(
    transport: transport,
    hasher: (file) async => 'hash-of-${file.path}',
    backoff: (_) => Duration.zero,
  );

  Widget wrap(Widget child) => MaterialApp(home: child);

  group('平台与权限', () {
    testWidgets('桌面端不显示授权引导，只说明这里用不上', (tester) async {
      final source = _FakeSource(supported: false);
      final queue = newQueue(_FakeTransport());
      addTearDown(queue.dispose);

      await tester.pumpWidget(
        wrap(UploadPage(queue: queue, source: source)),
      );
      await tester.pump();

      expect(find.text('桌面端不需要相册备份'), findsOneWidget);
      expect(find.text('允许访问相册'), findsNothing);
    });

    testWidgets('未授权时显示引导，点授权后进入选片', (tester) async {
      final source = _FakeSource(access: MediaAccess.denied)
        ..items = [
          const MediaCandidate(id: 'a', fileName: 'a.jpg', isVideo: false),
        ];
      final queue = newQueue(_FakeTransport());
      addTearDown(queue.dispose);

      await tester.pumpWidget(
        wrap(UploadPage(queue: queue, source: source)),
      );
      await tester.pump();

      expect(find.text('需要相册权限'), findsOneWidget);

      // 用户点了「允许」，系统给了权限。
      source.access = MediaAccess.granted;
      await tester.tap(find.text('允许访问相册'));
      await tester.pumpAndSettle();

      expect(source.requestCount, 1);
      expect(find.text('选择要备份的内容'), findsOneWidget);
    });

    testWidgets('被永久拒绝时只提供「去设置」，并说明原因', (tester) async {
      final source = _FakeSource(access: MediaAccess.blocked);
      final queue = newQueue(_FakeTransport());
      addTearDown(queue.dispose);

      await tester.pumpWidget(
        wrap(UploadPage(queue: queue, source: source)),
      );
      await tester.pump();

      expect(find.text('相册权限已被拒绝'), findsOneWidget);
      expect(find.text('允许访问相册'), findsNothing);

      await tester.tap(find.text('去设置'));
      await tester.pump();
      expect(source.settingsOpened, isTrue);
    });
  });

  group('选片与上传', () {
    testWidgets('相册为空时给出空状态，而不是一片空白', (tester) async {
      final queue = newQueue(_FakeTransport());
      addTearDown(queue.dispose);

      await tester.pumpWidget(
        wrap(UploadPage(queue: queue, source: _FakeSource())),
      );
      await tester.pump();

      expect(find.text('相册里没有可备份的照片或视频'), findsOneWidget);
    });

    testWidgets('选中两项后上传：两个任务都传完，回调一次', (tester) async {
      final source = _FakeSource();
      source.items = const [
        MediaCandidate(id: 'a', fileName: 'a.jpg', isVideo: false),
        MediaCandidate(id: 'b', fileName: 'b.mp4', isVideo: true),
        MediaCandidate(id: 'c', fileName: 'c.jpg', isVideo: false),
      ];
      source.paths['a'] = makeFile('a.jpg', 10);
      source.paths['b'] = makeFile('b.mp4', 7);

      final transport = _FakeTransport();
      final queue = newQueue(transport);
      addTearDown(queue.dispose);

      var uploadedCallbacks = 0;
      await tester.pumpWidget(
        wrap(
          UploadPage(
            queue: queue,
            source: source,
            onUploaded: () => uploadedCallbacks++,
          ),
        ),
      );
      await tester.pump();

      // 全选之后取消一个，剩两项 —— 顺便验证"取消勾选"真的生效。
      await tester.tap(find.text('全选'));
      await tester.pump();
      expect(find.text('已选 3 项'), findsOneWidget);

      await tester.tap(find.byType(GestureDetector).at(2));
      await tester.pump();
      expect(find.text('已选 2 项'), findsOneWidget);

      // 真实文件 IO 要走 runAsync，否则 testWidgets 的假时钟不会推进它。
      await tester.runAsync(() async {
        await tester.tap(find.text('开始上传'));
        await tester.pump();
        while (queue.hasPending) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();

      expect(queue.tasks.length, 2, reason: '只该为选中的两项建任务');
      expect(queue.succeededCount, 2);
      expect(transport.completed, 2);
      expect(uploadedCallbacks, 1, reason: '一批传完只通知一次');
    });

    testWidgets('读不出来的条目被跳过，其余照常上传', (tester) async {
      final source = _FakeSource();
      source.items = const [
        MediaCandidate(id: 'a', fileName: 'a.jpg', isVideo: false),
        MediaCandidate(id: 'gone', fileName: 'gone.jpg', isVideo: false),
      ];
      source.paths['a'] = makeFile('a.jpg', 5);
      // 'gone' 没有对应路径：模拟 iCloud 上还没下载下来的照片。

      final transport = _FakeTransport();
      final queue = newQueue(transport);
      addTearDown(queue.dispose);

      await tester.pumpWidget(
        wrap(UploadPage(queue: queue, source: source)),
      );
      await tester.pump();

      await tester.tap(find.text('全选'));
      await tester.pump();

      await tester.runAsync(() async {
        await tester.tap(find.text('开始上传'));
        await tester.pump();
        while (queue.hasPending) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();

      expect(queue.tasks.length, 1);
      expect(queue.succeededCount, 1);
      expect(find.text('有 1 项读不出来，已跳过'), findsOneWidget);
    });
  });
}

/// 假的相册来源：条目和"文件"都由用例直接给定。
class _FakeSource implements MediaSource {
  _FakeSource({
    this.supported = true,
    this.access = MediaAccess.granted,
  });

  @override
  bool supported;

  MediaAccess access;
  List<MediaCandidate> items = const [];

  /// 候选 id → 本地文件路径。没有条目就当作"读不出来"。
  final Map<String, String> paths = {};

  int requestCount = 0;
  bool settingsOpened = false;

  @override
  Future<MediaAccess> currentAccess() async => access;

  @override
  Future<MediaAccess> requestAccess() async {
    requestCount++;
    return access;
  }

  @override
  Future<List<MediaCandidate>> recent({int limit = 300}) async => items;

  @override
  Future<PendingUpload?> materialize(MediaCandidate candidate) async {
    final path = paths[candidate.id];
    if (path == null) return null;
    return PendingUpload(
      localPath: path,
      fileName: candidate.fileName,
      fileSize: File(path).lengthSync(),
    );
  }

  @override
  Future<Uint8List?> thumbnail(
    MediaCandidate candidate, {
    int size = 200,
  }) async => null;

  @override
  Future<void> openSettings() async => settingsOpened = true;
}

/// 内存版"服务端"：只记账，不校验内容 —— 分片正确性由队列自己的测试负责。
class _FakeTransport implements UploadTransport {
  static const _chunkSize = 4;

  int _seq = 0;
  final Map<String, int> _sizes = {};
  int completed = 0;

  @override
  Future<CreateUploadResult> create({
    required String fileName,
    required int fileSize,
    required String contentHash,
    int chunkSize = 0,
  }) async {
    final id = 'u${_seq++}';
    _sizes[id] = fileSize;
    return CreateUploadResult(
      deduped: false,
      mediaId: 0,
      session: UploadSession(
        uploadId: id,
        fileName: fileName,
        status: 'pending',
        totalSize: fileSize,
        chunkSize: _chunkSize,
        chunkCount: (fileSize / _chunkSize).ceil(),
        receivedChunks: 0,
        received: const [],
        expiresAt: '',
      ),
    );
  }

  @override
  Future<ChunkAck> putChunk(String uploadId, int index, Uint8List bytes) async =>
      const ChunkAck(receivedChunks: 1, chunkCount: 1);

  @override
  Future<CompleteUploadResult> complete(String uploadId) async {
    completed++;
    return const CompleteUploadResult(mediaId: 42, deduped: false);
  }

  @override
  Future<UploadSession> get(String uploadId) async => UploadSession(
    uploadId: uploadId,
    fileName: '',
    status: 'pending',
    totalSize: _sizes[uploadId] ?? 0,
    chunkSize: _chunkSize,
    chunkCount: ((_sizes[uploadId] ?? 0) / _chunkSize).ceil(),
    receivedChunks: 0,
    received: const [],
    expiresAt: '',
  );

  @override
  Future<void> cancel(String uploadId) async {}
}
