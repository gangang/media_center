import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_center_client/core/api_client.dart';
import 'package:media_center_client/core/upload/upload_models.dart';
import 'package:media_center_client/core/upload/upload_queue.dart';
import 'package:media_center_client/core/upload/upload_transport.dart';

/// 上传队列的单元测试。
///
/// **这里一条真实 HTTP 都不发，也不碰手机相册。** 队列依赖的只是
/// [UploadTransport] 这个接口，所以把"服务端"换成一个记录调用的假实现之后，
/// 那些真正容易错的东西就都能被直接观察到：到底传了哪几片、补了哪几片、
/// 退避了几次、并发有没有超过上限。
///
/// 断言尽量落在**可观测的字节**上（把收到的分片拼回去和原文件比），
/// 而不是落在"调用了某个方法"上 —— 后者在实现改坏时经常照样通过。
void main() {
  late Directory tmp;
  var fileSeq = 0;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('mc_upload_test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 写一个内容确定的临时文件，返回 (路径, 字节)。
  (String, Uint8List) makeFile(int size) {
    final bytes = Uint8List(size);
    for (var i = 0; i < size; i++) {
      bytes[i] = (i * 31 + 7) % 256;
    }
    final path = '${tmp.path}/f${fileSeq++}.bin';
    File(path).writeAsBytesSync(bytes);
    return (path, bytes);
  }

  PendingUpload pending(String path, int size) => PendingUpload(
    localPath: path,
    fileName: path.split('/').last,
    fileSize: size,
  );

  /// 测试里不需要真的去算哈希：队列的分片逻辑与哈希值无关。
  Future<String> fakeHasher(File file) async => 'hash-of-${file.path}';

  UploadQueue newQueue(
    FakeTransport t, {
    int concurrency = 3,
    int maxAttempts = 4,
    Future<bool> Function()? canUpload,
    List<int>? backoffCalls,
  }) {
    return UploadQueue(
      transport: t,
      concurrency: concurrency,
      maxAttempts: maxAttempts,
      canUpload: canUpload,
      hasher: fakeHasher,
      backoff: (attempt) {
        backoffCalls?.add(attempt);
        return Duration.zero;
      },
    );
  }

  // ------------------------------------------------------------------ 分片边界

  group('分片边界', () {
    test('最后一片不足整块时，按剩余字节切，拼回去和原文件逐字节相同', () async {
      final t = FakeTransport(serverChunkSize: 4);
      final (path, bytes) = makeFile(10); // 10 = 4 + 4 + 2
      final q = newQueue(t);

      q.enqueue([pending(path, 10)]);
      await q.start();

      final task = q.tasks.single;
      expect(task.status, UploadStatus.done);
      expect(t.putIndexes, [0, 1, 2]);

      final lengths = t.chunkLengthsOf(task.uploadId!);
      expect(lengths, [4, 4, 2], reason: '最后一片必须是 10 - 2*4 = 2 字节');

      // 最硬的断言：服务端收到的分片按序拼接，必须等于原文件。
      expect(t.assemble(task.uploadId!), equals(bytes));

      q.dispose();
    });

    test('总大小正好是分片整数倍时，不会多出一个空片', () async {
      final t = FakeTransport(serverChunkSize: 4);
      final (path, bytes) = makeFile(8);
      final q = newQueue(t);

      q.enqueue([pending(path, 8)]);
      await q.start();

      final task = q.tasks.single;
      expect(t.putIndexes, [0, 1]);
      expect(t.chunkLengthsOf(task.uploadId!), [4, 4]);
      expect(t.assemble(task.uploadId!), equals(bytes));

      q.dispose();
    });

    test('文件小于一片时只有一片，长度等于文件大小', () async {
      final t = FakeTransport(serverChunkSize: 4);
      final (path, bytes) = makeFile(3);
      final q = newQueue(t);

      q.enqueue([pending(path, 3)]);
      await q.start();

      final task = q.tasks.single;
      expect(t.putIndexes, [0]);
      expect(t.chunkLengthsOf(task.uploadId!), [3]);
      expect(t.assemble(task.uploadId!), equals(bytes));

      q.dispose();
    });

    test('服务端给出无效分片参数时立即失败，而不是死循环', () async {
      final t = FakeTransport(serverChunkSize: 4)..forcedChunkCount = 0;
      final (path, _) = makeFile(10);
      final backoff = <int>[];
      final q = newQueue(t, backoffCalls: backoff);

      q.enqueue([pending(path, 10)]);
      await q.start();

      final task = q.tasks.single;
      expect(task.status, UploadStatus.failed);
      expect(task.attempts, 1, reason: '_Permanent 不该被重试');
      expect(backoff, isEmpty);
      expect(task.error, isNotNull);

      q.dispose();
    });
  });

  // ------------------------------------------------------------------ 断点续传

  group('断点续传', () {
    test('只补服务端缺的分片，已经落盘的不重传', () async {
      final t = FakeTransport(serverChunkSize: 4);
      final (path, bytes) = makeFile(16); // 4 片
      final q = newQueue(t);
      q.enqueue([pending(path, 16)]);

      // 模拟"上次传到一半就断了"：服务端已经有第 0、2 片。
      final task = q.tasks.single;
      task.uploadId = t.seedSession('sess-old', bytes, received: [0, 2]);

      await q.start();

      expect(task.status, UploadStatus.done);
      expect(t.putIndexes, [1, 3], reason: '只该补 1 和 3');
      expect(t.createCount, 0, reason: '会话还在，不该重新发起');
      expect(t.assemble(task.uploadId!), equals(bytes));

      q.dispose();
    });

    test('续传时进度从服务端已有分片起算，而不是从 0', () async {
      final t = FakeTransport(serverChunkSize: 4);
      final (path, bytes) = makeFile(16);
      final q = newQueue(t);
      q.enqueue([pending(path, 16)]);
      final task = q.tasks.single;
      task.uploadId = t.seedSession('sess-old', bytes, received: [0, 1]);

      final seen = <int>[];
      q.addListener(() => seen.add(task.uploadedBytes));

      await q.start();

      expect(task.uploadedBytes, 16);
      // start() 自己会先通知一次（此时还是 0），所以跳过开头的 0 再看。
      final afterStart = seen.skipWhile((v) => v == 0).toList();
      // 起算点必须是 8（两片已落盘），而不是从 0 重新爬 —— 否则进度条会倒退。
      expect(afterStart.first, 8);
      expect(afterStart.toSet(), {8, 12, 16}, reason: '中间不该出现 0 或 4');

      q.dispose();
    });

    test('会话过期(404)时清掉 id 重新发起，且不消耗掉整次机会', () async {
      final t = FakeTransport(serverChunkSize: 4)
        ..getError = ApiException('上传会话不存在', statusCode: 404);
      final (path, bytes) = makeFile(8);
      final q = newQueue(t);
      q.enqueue([pending(path, 8)]);
      final task = q.tasks.single;
      task.uploadId = 'sess-stale';

      await q.start();

      expect(task.status, UploadStatus.done);
      expect(t.createCount, 1, reason: '会话没了就得重新发起');
      expect(task.attempts, 2, reason: '第一次尝试走续传失败，第二次重新发起');
      expect(t.assemble(task.uploadId!), equals(bytes));

      q.dispose();
    });

    test('会话反复失效时受 maxAttempts 约束，不会无限重试', () async {
      // 构造"每次续传都发现会话没了"：分片请求持续失败触发重试，而每次重试
      // 回去查会话都被判 404。若没有 attempt 上限，这里会变成死循环。
      final t = FakeTransport(serverChunkSize: 4)
        ..getError = ApiException('上传会话不存在', statusCode: 404)
        ..alwaysFailPut = ApiException('服务端开小差', statusCode: 500);
      final (path, _) = makeFile(8);
      final q = newQueue(t, maxAttempts: 4);
      q.enqueue([pending(path, 8)]);
      q.tasks.single.uploadId = 'sess-stale';

      await q.start();

      final task = q.tasks.single;
      expect(task.status, UploadStatus.failed);
      expect(task.attempts, 4, reason: '到上限就停，不多试一次');
      // 两次"重新发起"分别发生在 attempt 1 与 3 之后 —— 这才是"会话失效被识别并
      // 重建"的证据。展示给用户的原因是**最后一次**失败的原因（这里是 500），
      // 而不是会话过期，因为那才是当下该修的东西。
      expect(t.createCount, 2);
      expect(task.error, isNotNull);
      expect(task.error, isNotEmpty);

      q.dispose();
    });
  });

  // ------------------------------------------------------------------ 缺片补齐

  group('缺片补齐', () {
    test('complete 报缺片时补齐再试，最终完成', () async {
      final t = FakeTransport(serverChunkSize: 4)
        ..completeFailures.add(const MissingChunksException([2]));
      final (path, bytes) = makeFile(16);
      final q = newQueue(t);

      q.enqueue([pending(path, 16)]);
      await q.start();

      final task = q.tasks.single;
      expect(task.status, UploadStatus.done);
      expect(t.putAttempts, [0, 1, 2, 3, 2], reason: '第 2 片被补传了一次');
      expect(t.completeCount, 2);
      expect(t.assemble(task.uploadId!), equals(bytes));

      q.dispose();
    });

    test('服务端持续报缺片时有轮数上限，不会变成死循环', () async {
      final t = FakeTransport(serverChunkSize: 4);
      for (var i = 0; i < 8; i++) {
        t.completeFailures.add(const MissingChunksException([0]));
      }
      final (path, _) = makeFile(8);
      final q = newQueue(t);

      q.enqueue([pending(path, 8)]);
      await q.start();

      final task = q.tasks.single;
      expect(task.status, UploadStatus.failed);
      // 3 轮补齐之后放弃（_Permanent，不再重试）。
      expect(t.completeCount, 3);
      expect(task.attempts, 1);
      expect(task.error, isNotNull);

      q.dispose();
    });

    test('缺片序号越界时不被采纳，也不会卡住', () async {
      final t = FakeTransport(serverChunkSize: 4)
        ..completeFailures.add(const MissingChunksException([99]));
      final (path, bytes) = makeFile(8);
      final q = newQueue(t);

      q.enqueue([pending(path, 8)]);
      await q.start();

      final task = q.tasks.single;
      // 越界的"缺片"说明账本已经不可信；不补它，交给外层整体重试一次。
      expect(task.status, UploadStatus.done);
      expect(t.putIndexes, [0, 1], reason: '不该为不存在的第 99 片发请求');
      expect(t.assemble(task.uploadId!), equals(bytes));

      q.dispose();
    });
  });

  // ------------------------------------------------------------------ 重试与退避

  group('重试与退避', () {
    test('可重试错误按退避重试后成功', () async {
      final t = FakeTransport(serverChunkSize: 4)
        ..putFailures.add(ApiException('服务端开小差', statusCode: 500));
      final (path, bytes) = makeFile(8);
      final backoff = <int>[];
      final q = newQueue(t, backoffCalls: backoff);

      q.enqueue([pending(path, 8)]);
      await q.start();

      final task = q.tasks.single;
      expect(task.status, UploadStatus.done);
      expect(task.attempts, 2);
      expect(backoff, [1], reason: '第一次失败后按 attempt=1 退避');
      expect(t.putAttempts, [0, 0, 1], reason: '第 0 片试了两次');
      expect(t.assemble(task.uploadId!), equals(bytes));

      q.dispose();
    });

    test('退避拿到的尝试次数逐次递增', () async {
      final t = FakeTransport(serverChunkSize: 4)
        ..putFailures.addAll([
          ApiException('500', statusCode: 500),
          ApiException('500', statusCode: 500),
          ApiException('500', statusCode: 500),
        ]);
      final (path, _) = makeFile(8);
      final backoff = <int>[];
      final q = newQueue(t, backoffCalls: backoff);

      q.enqueue([pending(path, 8)]);
      await q.start();

      expect(q.tasks.single.status, UploadStatus.done);
      expect(backoff, [1, 2, 3]);

      q.dispose();
    });

    test('默认退避是指数增长且封顶 30 秒', () {
      expect(defaultBackoff(1), const Duration(seconds: 1));
      expect(defaultBackoff(2), const Duration(seconds: 2));
      expect(defaultBackoff(3), const Duration(seconds: 4));
      expect(defaultBackoff(4), const Duration(seconds: 8));
      expect(defaultBackoff(5), const Duration(seconds: 16));
      expect(
        defaultBackoff(6),
        const Duration(seconds: 30),
        reason: '32s 被削到 30s',
      );
      expect(
        defaultBackoff(50),
        const Duration(seconds: 30),
        reason: '永远不超过 30s',
      );
    });

    test('4xx（非 408/429）不可重试，立即失败', () async {
      final t = FakeTransport(serverChunkSize: 4)
        ..putFailures.add(ApiException('文件太大', statusCode: 413));
      final (path, _) = makeFile(8);
      final backoff = <int>[];
      final q = newQueue(t, backoffCalls: backoff);

      q.enqueue([pending(path, 8)]);
      await q.start();

      final task = q.tasks.single;
      expect(task.status, UploadStatus.failed);
      expect(task.attempts, 1);
      expect(backoff, isEmpty, reason: '不该白白让用户等退避');
      expect(task.error, contains('文件太大'));

      q.dispose();
    });

    test('429 与 408 属于可重试', () async {
      for (final code in [408, 429]) {
        final t = FakeTransport(serverChunkSize: 4)
          ..putFailures.add(ApiException('稍后再试', statusCode: code));
        final (path, _) = makeFile(8);
        final q = newQueue(t);
        q.enqueue([pending(path, 8)]);
        await q.start();

        final task = q.tasks.single;
        expect(task.status, UploadStatus.done, reason: 'HTTP $code 应该重试');
        expect(task.attempts, 2);
        q.dispose();
      }
    });

    test('本地文件读取失败不重试', () async {
      final t = FakeTransport(serverChunkSize: 4)
        ..putFailures.add(const FileSystemException('设备已拔出'));
      final (path, _) = makeFile(8);
      final backoff = <int>[];
      final q = newQueue(t, backoffCalls: backoff);

      q.enqueue([pending(path, 8)]);
      await q.start();

      final task = q.tasks.single;
      expect(task.status, UploadStatus.failed);
      expect(task.attempts, 1);
      expect(backoff, isEmpty);
      expect(task.error, contains('本地文件'));

      q.dispose();
    });

    test('超过最大尝试次数后放弃，并留下可展示的原因', () async {
      final t = FakeTransport(serverChunkSize: 4)
        ..alwaysFailPut = ApiException('持续失败', statusCode: 503);
      final (path, _) = makeFile(8);
      final q = newQueue(t, maxAttempts: 3);

      q.enqueue([pending(path, 8)]);
      await q.start();

      final task = q.tasks.single;
      expect(task.status, UploadStatus.failed);
      expect(task.attempts, 3);
      expect(task.error, contains('持续失败'));
      expect(q.failedCount, 1);

      q.dispose();
    });
  });

  // ------------------------------------------------------------------ 秒传

  group('秒传', () {
    test('服务端已有内容时一个字节都不传', () async {
      final t = FakeTransport(serverChunkSize: 4)..dedupMediaId = 42;
      final (path, _) = makeFile(100);
      final q = newQueue(t);

      q.enqueue([pending(path, 100)]);
      await q.start();

      final task = q.tasks.single;
      expect(task.status, UploadStatus.deduped);
      expect(task.mediaId, 42);
      expect(task.uploadedBytes, 100);
      expect(task.progress, 1.0);
      expect(task.succeeded, isTrue);
      expect(t.putAttempts, isEmpty, reason: '秒传不该传任何分片');
      expect(t.completeCount, 0, reason: '秒传不该调 complete');
      expect(q.succeededCount, 1);

      q.dispose();
    });

    test('秒传也算成功，不计入失败数', () async {
      final t = FakeTransport(serverChunkSize: 4)..dedupMediaId = 7;
      final (path, _) = makeFile(20);
      final q = newQueue(t);

      q.enqueue([pending(path, 20)]);
      await q.start();

      expect(q.succeededCount, 1);
      expect(q.failedCount, 0);
      expect(q.hasPending, isFalse);

      q.dispose();
    });
  });

  // ------------------------------------------------------------------ 并发

  group('并发', () {
    test('同时在传的任务数不超过 concurrency', () async {
      final t = FakeTransport(serverChunkSize: 4)
        ..chunkDelay = const Duration(milliseconds: 20);
      final q = newQueue(t, concurrency: 3);

      q.enqueue([for (var i = 0; i < 8; i++) pending(makeFile(4).$1, 4)]);
      await q.start();

      expect(q.tasks.length, 8);
      expect(q.tasks.every((x) => x.status == UploadStatus.done), isTrue);
      expect(
        t.maxInFlightChunks,
        lessThanOrEqualTo(3),
        reason: '并发上限必须真的生效，否则手机会被拖垮',
      );
      expect(t.maxInFlightChunks, greaterThan(1), reason: '应该真的并行过，而不是退化成串行');

      q.dispose();
    });

    test('concurrency 传 0 或负数时至少跑一个 worker', () async {
      for (final c in [0, -1]) {
        final t = FakeTransport(serverChunkSize: 4);
        final (path, _) = makeFile(8);
        final q = newQueue(t, concurrency: c);

        q.enqueue([pending(path, 8)]);
        await q.start();

        expect(
          q.tasks.single.status,
          UploadStatus.done,
          reason: 'concurrency=$c',
        );
        q.dispose();
      }
    });
  });

  // ------------------------------------------------------------------ 取消

  group('取消', () {
    test('取消已开会话的任务会通知服务端清理临时文件', () async {
      final t = FakeTransport(serverChunkSize: 4);
      final (path, _) = makeFile(8);
      final q = newQueue(t);
      q.enqueue([pending(path, 8)]);
      final task = q.tasks.single;
      task.uploadId = 'sess-live';

      await q.cancel(task);

      expect(task.status, UploadStatus.canceled);
      expect(task.uploadId, isNull);
      expect(t.cancelled, ['sess-live']);
      expect(q.hasPending, isFalse);

      q.dispose();
    });

    test('上传途中取消会停止后续分片', () async {
      final t = FakeTransport(serverChunkSize: 4)
        ..chunkDelay = const Duration(milliseconds: 30);
      final (path, _) = makeFile(32); // 8 片，每片 30ms
      final q = newQueue(t, concurrency: 1);

      q.enqueue([pending(path, 32)]);
      final task = q.tasks.single;

      final running = q.start();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await q.cancel(task);
      await running;

      expect(task.status, UploadStatus.canceled);
      expect(t.putAttempts.length, lessThan(8), reason: '取消之后不该把剩下的分片传完');

      q.dispose();
    });

    test('cancelAll 会取消所有未完成的任务', () async {
      final t = FakeTransport(serverChunkSize: 4);
      final q = newQueue(t);
      q.enqueue([for (var i = 0; i < 3; i++) pending(makeFile(8).$1, 8)]);
      for (final task in q.tasks) {
        task.uploadId = 'sess-${task.fileName}';
      }

      await q.cancelAll();

      expect(q.tasks.every((x) => x.status == UploadStatus.canceled), isTrue);
      expect(t.cancelled.length, 3);
      expect(q.isPaused, isTrue);

      q.dispose();
    });
  });

  // ------------------------------------------------------------------ 门禁

  group('门禁（仅 WiFi 上传）', () {
    test('canUpload 说不时整个队列暂停，而不是空转重试', () async {
      final t = FakeTransport(serverChunkSize: 4);
      final (path, _) = makeFile(8);
      var allowed = false;
      final q = newQueue(t, canUpload: () async => allowed);

      q.enqueue([pending(path, 8)]);
      await q.start();

      final task = q.tasks.single;
      expect(q.isPaused, isTrue);
      expect(task.status, UploadStatus.queued, reason: '回到排队状态等下次');
      expect(t.putAttempts, isEmpty);
      expect(t.createCount, 0);
      expect(q.hasPending, isTrue);

      // 网络换成 WiFi 之后再跑一次，应该照常完成。
      allowed = true;
      await q.start();

      expect(task.status, UploadStatus.done);
      expect(q.isPaused, isFalse);

      q.dispose();
    });
  });

  // ------------------------------------------------------------------ 入队与重试

  group('入队与重试失败项', () {
    test('同一路径只入队一次', () {
      final t = FakeTransport();
      final (path, _) = makeFile(8);
      final q = newQueue(t);

      q.enqueue([pending(path, 8), pending(path, 8)]);

      expect(q.tasks.length, 1, reason: '相册选择器很容易让用户点两下');
      q.dispose();
    });

    test('retryFailed 把失败项放回队列，并保留会话以走续传', () async {
      final t = FakeTransport(serverChunkSize: 4)
        ..alwaysFailPut = ApiException('网络断了', statusCode: 503);
      final (path, bytes) = makeFile(8);
      final q = newQueue(t, maxAttempts: 1);

      q.enqueue([pending(path, 8)]);
      await q.start();

      final task = q.tasks.single;
      expect(task.status, UploadStatus.failed);
      final sessionId = task.uploadId;
      expect(sessionId, isNotNull);

      // 网络恢复。
      t.alwaysFailPut = null;
      q.retryFailed();

      expect(task.status, UploadStatus.queued);
      expect(task.attempts, 0);
      expect(task.error, isNull);
      expect(task.uploadId, sessionId, reason: '保留会话，重试才能只补缺的分片');

      await q.start();

      expect(task.status, UploadStatus.done);
      expect(t.createCount, 1, reason: '走了续传，没有重新发起');
      expect(t.assemble(task.uploadId!), equals(bytes));

      q.dispose();
    });

    test('retryFailed 不会动已完成或正在排队的任务', () async {
      final t = FakeTransport(serverChunkSize: 4)..dedupMediaId = 5;
      final (path, _) = makeFile(8);
      final q = newQueue(t);
      q.enqueue([pending(path, 8)]);
      await q.start();

      final task = q.tasks.single;
      expect(task.status, UploadStatus.deduped);
      q.retryFailed();
      expect(task.status, UploadStatus.deduped, reason: '成功的不该被拉回队列');

      q.dispose();
    });
  });
}

/// 假传输层：把"服务端"建模成一张分片表，并记录每一次调用。
///
/// 刻意不做任何网络动作。队列里容易错的地方——分片边界、续传补哪几片、
/// 缺片补齐、退避重试——全是纯调度逻辑，套上真 HTTP 只会让失败原因变模糊。
class FakeTransport implements UploadTransport {
  FakeTransport({this.serverChunkSize = 4});

  /// 服务端给的分片大小。
  int serverChunkSize;

  int createCount = 0;
  int completeCount = 0;
  int getCount = 0;

  /// 每次 putChunk **尝试**的序号（含失败的那次）。
  final List<int> putAttempts = [];

  /// 每次 putChunk **成功落盘**的序号。
  final List<int> putIndexes = [];

  final List<String> cancelled = [];

  /// uploadId -> 分片序号 -> 字节内容。
  final Map<String, Map<int, Uint8List>> _chunks = {};

  /// uploadId -> 元信息。
  final Map<String, _Session> _sessions = {};

  /// 非空时 create 直接秒传，返回这个媒体 id。
  int? dedupMediaId;

  /// 每次 putChunk 都抛这个错（用来模拟持续故障）。
  Object? alwaysFailPut;

  /// 按顺序消费，每次 putChunk 弹一个；非空就抛。
  final List<Object?> putFailures = [];

  /// 按顺序消费，每次 complete 弹一个；非空就抛。
  final List<Object?> completeFailures = [];

  /// 非空时 get 抛这个错（用来模拟 404 会话过期）。
  Object? getError;

  /// 强制 create 返回的分片参数（用来构造畸形响应）。
  int? forcedChunkSize;
  int? forcedChunkCount;

  /// 每片的人为延迟，用来制造并发重叠。
  Duration chunkDelay = Duration.zero;

  /// 并发探针：同时进行中的 putChunk 数。
  int inFlightChunks = 0;
  int maxInFlightChunks = 0;

  int _seq = 0;
  int _mediaSeq = 100;

  /// 预先在"服务端"造一个会话，并假装已经收到了 [received] 这几片。
  ///
  /// 必须传入真实内容：收到的那几片要存**正确的切片**，否则"把分片拼回去
  /// 和原文件比对"这条断言就成了摆设。
  String seedSession(
    String id,
    Uint8List content, {
    required List<int> received,
  }) {
    final cs = serverChunkSize;
    final cc = content.isEmpty ? 0 : (content.length + cs - 1) ~/ cs;
    _sessions[id] = _Session(
      fileName: '$id.bin',
      totalSize: content.length,
      chunkSize: cs,
      chunkCount: cc,
    );
    final store = _chunks.putIfAbsent(id, () => {});
    for (final i in received) {
      final start = i * cs;
      final end = start + cs > content.length ? content.length : start + cs;
      store[i] = Uint8List.sublistView(content, start, end);
    }
    return id;
  }

  List<int> chunkLengthsOf(String uploadId) {
    final store = _chunks[uploadId] ?? const {};
    final indexes = store.keys.toList()..sort();
    return [for (final i in indexes) store[i]!.length];
  }

  Uint8List assemble(String uploadId) {
    final store = _chunks[uploadId] ?? const {};
    final indexes = store.keys.toList()..sort();
    final out = BytesBuilder();
    for (final i in indexes) {
      out.add(store[i]!);
    }
    return out.takeBytes();
  }

  UploadSession _sessionOf(String id, _Session s) => UploadSession(
    uploadId: id,
    fileName: s.fileName,
    status: 'pending',
    totalSize: s.totalSize,
    chunkSize: s.chunkSize,
    chunkCount: s.chunkCount,
    receivedChunks: (_chunks[id] ?? const {}).length,
    received: ((_chunks[id] ?? const {}).keys.toList()..sort()),
    expiresAt: '2099-01-01T00:00:00Z',
  );

  @override
  Future<CreateUploadResult> create({
    required String fileName,
    required int fileSize,
    required String contentHash,
    int chunkSize = 0,
  }) async {
    createCount++;
    if (dedupMediaId != null) {
      return CreateUploadResult(deduped: true, mediaId: dedupMediaId!);
    }
    final id = 'sess-${++_seq}';
    final cs = forcedChunkSize ?? serverChunkSize;
    final cc =
        forcedChunkCount ??
        (fileSize <= 0 || cs <= 0 ? 0 : (fileSize + cs - 1) ~/ cs);
    _sessions[id] = _Session(
      fileName: fileName,
      totalSize: fileSize,
      chunkSize: cs,
      chunkCount: cc,
    );
    _chunks[id] = {};
    return CreateUploadResult(
      session: _sessionOf(id, _sessions[id]!),
      deduped: false,
      mediaId: 0,
    );
  }

  @override
  Future<ChunkAck> putChunk(String uploadId, int index, Uint8List bytes) async {
    inFlightChunks++;
    if (inFlightChunks > maxInFlightChunks) maxInFlightChunks = inFlightChunks;
    try {
      if (chunkDelay > Duration.zero) {
        await Future<void>.delayed(chunkDelay);
      }
      putAttempts.add(index);

      if (alwaysFailPut != null) throw alwaysFailPut!;
      if (putFailures.isNotEmpty) {
        final f = putFailures.removeAt(0);
        if (f != null) throw f;
      }

      final s = _sessions[uploadId];
      if (s == null) throw ApiException('上传会话不存在', statusCode: 404);
      _chunks.putIfAbsent(uploadId, () => {})[index] = Uint8List.fromList(
        bytes,
      );
      putIndexes.add(index);
      return ChunkAck(
        receivedChunks: _chunks[uploadId]!.length,
        chunkCount: s.chunkCount,
      );
    } finally {
      inFlightChunks--;
    }
  }

  @override
  Future<CompleteUploadResult> complete(String uploadId) async {
    completeCount++;
    if (completeFailures.isNotEmpty) {
      final f = completeFailures.removeAt(0);
      if (f != null) throw f;
    }
    final s = _sessions[uploadId];
    if (s == null) throw ApiException('上传会话不存在', statusCode: 404);

    final have = (_chunks[uploadId] ?? const {}).keys.toSet();
    final missing = [
      for (var i = 0; i < s.chunkCount; i++)
        if (!have.contains(i)) i,
    ];
    if (missing.isNotEmpty) throw MissingChunksException(missing);

    return CompleteUploadResult(mediaId: ++_mediaSeq, deduped: false);
  }

  @override
  Future<UploadSession> get(String uploadId) async {
    getCount++;
    if (getError != null) throw getError!;
    final s = _sessions[uploadId];
    if (s == null) throw ApiException('上传会话不存在', statusCode: 404);
    return _sessionOf(uploadId, s);
  }

  @override
  Future<void> cancel(String uploadId) async {
    cancelled.add(uploadId);
    _sessions.remove(uploadId);
    _chunks.remove(uploadId);
  }
}

class _Session {
  _Session({
    required this.fileName,
    required this.totalSize,
    required this.chunkSize,
    required this.chunkCount,
  });

  final String fileName;
  final int totalSize;
  final int chunkSize;
  final int chunkCount;
}
