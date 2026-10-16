import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../api_client.dart';
import 'content_hash.dart';
import 'upload_models.dart';
import 'upload_transport.dart';

/// 上传队列：并发、分片、断点续传、重试退避、秒传。
///
/// **这一层刻意不碰任何平台 API。** 文件来自 `dart:io`，网络走
/// [UploadTransport]，"现在能不能传"由注入的 [canUpload] 决定（WiFi-only 就靠它）。
/// 读手机相册和前台保活属于平台层，不在这里。
///
/// 这么切分是因为：队列里真正容易出错的东西——分片边界、续传该补哪几片、
/// 重试会不会重复计数、缺片补齐——全是纯调度逻辑，与网络和平台无关。
/// 把它们绑死在真 HTTP 和真手机上，就只能靠一台手机加一个真服务端来验证，
/// 而那是最慢、最难复现的方式。现在这一层可以在 `flutter test` 里跑遍。
class UploadQueue extends ChangeNotifier {
  UploadQueue({
    required this.transport,
    this.concurrency = 3,
    this.maxAttempts = 4,
    this.canUpload,
    Duration Function(int attempt)? backoff,
    Future<String> Function(File file)? hasher,
  }) : _backoff = backoff ?? defaultBackoff,
       _hasher = hasher ?? ((file) => contentHashOfFile(file));

  /// 传输层。生产环境是 [HttpUploadTransport]，测试里是假实现。
  final UploadTransport transport;

  /// 同时在传的文件数。
  ///
  /// 3 是取舍：手机 WiFi 的并发连接收益很快就饱和，而并发越高，
  /// 单条连接分到的带宽越少、超时越容易触发。手机上还要额外考虑耗电。
  final int concurrency;

  /// 单个文件最多尝试几次（含首次）。
  final int maxAttempts;

  /// 返回 false 时整个队列暂停。用来实现"仅 WiFi 上传"这类策略。
  final Future<bool> Function()? canUpload;

  final Duration Function(int attempt) _backoff;
  final Future<String> Function(File file) _hasher;

  final List<UploadTask> _tasks = [];
  bool _running = false;
  bool _paused = false;
  bool _disposed = false;

  List<UploadTask> get tasks => List.unmodifiable(_tasks);

  bool get isRunning => _running;
  bool get isPaused => _paused;

  /// 还有没有没处理完的任务（排队中或正在传）。
  bool get hasPending => _tasks.any((t) => !t.isTerminal);

  int get succeededCount => _tasks.where((t) => t.succeeded).length;
  int get failedCount =>
      _tasks.where((t) => t.status == UploadStatus.failed).length;

  /// 排队。同一个路径只排一次——相册选择器很容易让用户点两下。
  void enqueue(Iterable<PendingUpload> items) {
    for (final it in items) {
      if (_tasks.any((t) => t.localPath == it.localPath)) continue;
      _tasks.add(
        UploadTask(
          localPath: it.localPath,
          fileName: it.fileName,
          fileSize: it.fileSize,
        ),
      );
    }
    _notify();
  }

  /// 跑完所有任务后返回。重复调用是安全的（正在跑就直接返回）。
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _paused = false;
    _notify();
    try {
      final workers = <Future<void>>[
        for (var i = 0; i < (concurrency < 1 ? 1 : concurrency); i++) _worker(),
      ];
      await Future.wait(workers);
    } finally {
      _running = false;
      _notify();
    }
  }

  /// 暂停：正在传的那一片会传完，剩下的回到排队状态。
  void pause() {
    _paused = true;
    _notify();
  }

  /// 取消单个任务。若已经开了会话，一并让服务端清理。
  Future<void> cancel(UploadTask task) async {
    if (task.isTerminal) return;
    task.status = UploadStatus.canceled;
    final id = task.uploadId;
    task.uploadId = null;
    _notify();
    if (id != null) {
      try {
        await transport.cancel(id);
      } catch (_) {
        // 取消失败不需要打扰用户：服务端有 24 小时回收，临时文件不会永久占盘。
      }
    }
  }

  Future<void> cancelAll() async {
    for (final t in _tasks) {
      if (!t.isTerminal) await cancel(t);
    }
    _paused = true;
  }

  /// 把失败/取消的任务放回队列，供"重试失败项"用。
  void retryFailed() {
    for (final t in _tasks) {
      if (t.status == UploadStatus.failed ||
          t.status == UploadStatus.canceled) {
        t.status = UploadStatus.queued;
        t.error = null;
        t.attempts = 0;
        // 保留 uploadId：服务端那边的分片还在，续传比重传省事得多。
      }
    }
    _notify();
  }

  // ------------------------------------------------------------------ 内部

  Future<void> _worker() async {
    while (true) {
      if (_paused) return;
      final task = _claim();
      if (task == null) return;
      await _process(task);
    }
  }

  /// 取一个排队中的任务并**立刻**改状态。
  ///
  /// 认领和改状态必须是同步的一步：worker 是并发的，中间只要有一个 await，
  /// 两个 worker 就会拿到同一个任务、把同一份文件传两遍。
  UploadTask? _claim() {
    for (final t in _tasks) {
      if (t.status == UploadStatus.queued) {
        t.status = UploadStatus.hashing;
        return t;
      }
    }
    return null;
  }

  Future<void> _process(UploadTask task) async {
    if (!await _gateOpen()) {
      task.status = UploadStatus.queued;
      return;
    }

    var attempt = 0;
    while (true) {
      attempt++;
      task.attempts = attempt;
      try {
        await _attempt(task);
        return;
      } on _SessionLost {
        // 会话没了（过期、临时文件被回收）。重新发起即可，
        // 但这也要受 maxAttempts 约束，否则一个持续失败的会话会变成死循环。
        if (attempt >= maxAttempts) {
          _fail(task, '上传会话反复失效，请稍后重试');
          return;
        }
        task.uploadId = null;
        continue;
      } catch (e) {
        if (!_isRetryable(e) || attempt >= maxAttempts) {
          _fail(task, _describe(e));
          return;
        }
        _notify();
        await Future<void>.delayed(_backoff(attempt));
        if (task.status == UploadStatus.canceled) return;
        if (!await _gateOpen()) {
          task.status = UploadStatus.queued;
          return;
        }
      }
    }
  }

  /// 门禁：说"不"时把整个队列暂停，而不是空转重试。
  Future<bool> _gateOpen() async {
    if (_paused) return false;
    final gate = canUpload;
    if (gate == null) return true;
    if (await gate()) return true;
    _paused = true;
    _notify();
    return false;
  }

  /// 一趟完整尝试：发起（或续传）→ 传缺的分片 → 完成。
  ///
  /// 失败时**不清掉 `task.uploadId`**（除了会话失效），这样重试会走续传分支，
  /// 只补缺的那几片。慢速网络下这一点决定了"重试"是有用还是有害。
  Future<void> _attempt(UploadTask task) async {
    final file = File(task.localPath);
    final size = task.fileSize;

    final String uploadId;
    final int chunkSize;
    final int chunkCount;
    final Set<int> have;

    if (task.uploadId == null) {
      task.status = UploadStatus.hashing;
      _notify();
      final hash = await _hasher(file);

      final created = await transport.create(
        fileName: task.fileName,
        fileSize: size,
        contentHash: hash,
      );
      if (created.deduped) {
        // 服务端已经有这份内容，一个字节都不用传。
        task.mediaId = created.mediaId;
        task.uploadedBytes = size;
        task.status = UploadStatus.deduped;
        _notify();
        return;
      }
      final s = created.session!;
      uploadId = s.uploadId;
      task.uploadId = uploadId;
      chunkSize = s.chunkSize;
      chunkCount = s.chunkCount;
      have = s.received.toSet();
    } else {
      // 续传：先问服务端已经落了哪些片，再只补缺的。
      final s = await _resume(task.uploadId!);
      if (!s.pending) throw const _SessionLost();
      uploadId = s.uploadId;
      chunkSize = s.chunkSize;
      chunkCount = s.chunkCount;
      have = s.received.toSet();
    }

    if (chunkSize <= 0 || chunkCount <= 0 || uploadId.isEmpty) {
      throw const _Permanent('服务端返回了无效的分片参数');
    }

    task.uploadedBytes = have.fold<int>(
      0,
      (sum, i) => sum + _chunkLength(i, chunkSize, size, chunkCount),
    );
    task.status = UploadStatus.uploading;
    _notify();

    final raf = await file.open();
    try {
      for (var i = 0; i < chunkCount; i++) {
        if (task.status == UploadStatus.canceled) return;
        if (have.contains(i)) continue;
        final len = _chunkLength(i, chunkSize, size, chunkCount);
        await transport.putChunk(
          uploadId,
          i,
          await _readAt(raf, i * chunkSize, len),
        );
        task.uploadedBytes += len;
        _notify();
      }

      task.status = UploadStatus.verifying;
      _notify();

      // 完成阶段可能被判"缺片"——服务端的分片表才是权威，客户端的账本可能因为
      // 上一次请求的响应丢失而与它不一致。补齐再试，但要有轮数上限，
      // 否则一个持续返回 409 的服务端会把这里变成死循环。
      for (var round = 0; round < 3; round++) {
        try {
          final res = await transport.complete(uploadId);
          task.mediaId = res.mediaId;
          task.uploadedBytes = size;
          task.status = UploadStatus.done;
          _notify();
          return;
        } on MissingChunksException catch (e) {
          final missing = e.missing
              .where((i) => i >= 0 && i < chunkCount)
              .toList(growable: false);
          if (missing.isEmpty) rethrow;
          for (final i in missing) {
            final len = _chunkLength(i, chunkSize, size, chunkCount);
            await transport.putChunk(
              uploadId,
              i,
              await _readAt(raf, i * chunkSize, len),
            );
          }
          task.status = UploadStatus.uploading;
          _notify();
        }
      }
      throw const _Permanent('服务端持续报告分片不完整，已停止重试');
    } finally {
      await raf.close();
    }
  }

  Future<UploadSession> _resume(String id) async {
    try {
      return await transport.get(id);
    } on ApiException catch (e) {
      if (e.statusCode == 404) throw const _SessionLost();
      rethrow;
    }
  }

  Future<Uint8List> _readAt(RandomAccessFile raf, int start, int length) async {
    await raf.setPosition(start);
    final bytes = await raf.read(length);
    if (bytes.length != length) {
      throw _Permanent('本地文件读取不完整：需要 $length 字节，实际 ${bytes.length} 字节');
    }
    return bytes;
  }

  void _fail(UploadTask task, String message) {
    // 用户已经取消的任务不该被翻成"失败"。
    //
    // 取消是异步的：它把状态置为 canceled 之后，正在途中的那个请求可能才
    // 带着错误回来（服务端会话已被清理，于是 404）。若不拦住，UI 上"已取消"
    // 会自己变成"失败"，失败计数也会凭空多一项 —— 用户明明是自己取消的。
    if (task.status == UploadStatus.canceled) return;
    task.status = UploadStatus.failed;
    task.error = message;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// 第 [index] 片的字节数。最后一片通常不足一整块。
///
/// 必须与服务端 `handleUploadChunk` 的算法一致：最后一片是
/// `总大小 - index * 分片大小`。算错一片的大小，服务端会拿 Content-Length
/// 比对后以 400 拒绝——它不会静默接受一个短分片，所以这里错了会立刻暴露。
int _chunkLength(int index, int chunkSize, int totalSize, int chunkCount) {
  if (index == chunkCount - 1) return totalSize - index * chunkSize;
  return chunkSize;
}

/// 指数退避，但封顶。
///
/// 起始 1 秒：最常见的失败（WiFi 抖动、路由器重连）往往一两秒内就好了。
/// 封顶 30 秒：再长用户会觉得"卡死了"，而更短的重试对服务端也无害。
///
/// 公开是因为它是**用户可见的策略**（"重试要等多久"），而不是实现细节：
/// 队列本身接受 `backoff` 注入，这个函数就是那个注入点的默认值，可以直接测。
Duration defaultBackoff(int attempt) {
  final shift = (attempt - 1).clamp(0, 5);
  final ms = 1000 * (1 << shift);
  return Duration(milliseconds: ms > 30000 ? 30000 : ms);
}

/// 4xx（除 408/429）和本地 IO 错误重试没有意义：我们发的是同一个请求，
/// 或者读的是同一个读不到的文件，再试一次只是白白让用户等退避时间。
///
/// 默认**可重试**：认不出来的异常多半是网络层的瞬时故障，重试一次的成本
/// 只是几秒退避，而误判成不可重试会让用户看到本可自愈的失败。
bool _isRetryable(Object e) {
  if (e is _Permanent) return false;
  if (e is FileSystemException) return false;
  if (e is ApiException) {
    final code = e.statusCode;
    if (code == null) return true; // 网络层错误，没有状态码
    if (code == 408 || code == 429) return true;
    return code >= 500;
  }
  return true;
}

String _describe(Object e) {
  if (e is _Permanent) return e.message;
  if (e is ApiException) return e.message;
  if (e is FileSystemException) return '读取本地文件失败：${e.message}';
  return '$e';
}

/// 我们发错了请求，重试没有意义。
class _Permanent implements Exception {
  const _Permanent(this.message);
  final String message;
}

/// 服务端上的会话没了：清掉 id 重新发起。
class _SessionLost implements Exception {
  const _SessionLost();
}
