// 上传链路的端到端验证：客户端的上传队列 + 真实 HTTP + 真实后端。
//
// 为什么这条链路值得单独跑一次真的：
//   * `upload_queue_test.dart` 用的是假 transport，验证的是分片与重试的**调度**；
//   * `scripts/verify-upload.sh` 用 curl，验证的是后端的**接口契约**；
//   * 中间那一段 —— ApiClient 把 JSON 编对、把二进制按 Content-Length 发对、
//     把 409 的 missing 解析成 MissingChunksException —— 两边都盖不到。
//     这一段错了的表现是"传完了但服务端说缺片"，而两边各自的测试都是绿的。
//
// 这个文件刻意不建窗口：它要验的是传输层，不是界面。界面由
// `test/upload_page_test.dart` 覆盖。
//
// 前置条件：后端已在 127.0.0.1:18080 运行。
//
// 运行：
//   flutter test integration_test/upload_test.dart -d macos \
//     --dart-define=MC_BASE_URL=http://127.0.0.1:18080 \
//     --dart-define=MC_TOKEN=<token>

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_center_client/core/api_client.dart';
import 'package:media_center_client/core/upload/upload_models.dart';
import 'package:media_center_client/core/upload/upload_queue.dart';
import 'package:media_center_client/core/upload/upload_transport.dart';

const _baseUrl = String.fromEnvironment(
  'MC_BASE_URL',
  defaultValue: 'http://127.0.0.1:18080',
);
const _token = String.fromEnvironment('MC_TOKEN', defaultValue: '');

/// 一张 64×48 的合法 JPEG，内联在这里而不是从磁盘读。
///
/// 上传接口按扩展名判定媒体类型，`.bin` 会被服务端以"不支持的文件类型"拒绝 ——
/// 所以测试素材必须是真图片。内联一个小图比依赖某个固定路径的文件可靠：
/// 换台机器、换个工作目录，测试照样能跑。
const _tinyJpegBase64 =
    '/9j/4AAQSkZJRgABAgAAAQABAAD//gAQTGF2YzYyLjI4LjEwMgD/2wBDAAgEBAQEBAUFBQUFBQYG'
    'BgYGBgYGBgYGBgYHBwcICAgHBwcGBgcHCAgICAkJCQgICAgJCQoKCgwMCwsODg4RERT/xABNAAEB'
    'AAAAAAAAAAAAAAAAAAAABgEBAQEAAAAAAAAAAAAAAAAAAAYHEAEAAAAAAAAAAAAAAAAAAAAAEQEA'
    'AAAAAAAAAAAAAAAAAAAA/8AAEQgAMABAAwEiAAIRAAMRAP/aAAwDAQACEQMRAD8AiwEm38AAAAAA'
    'AAAAAAAAAAAAAAAB/9k=';

/// 造一个"唯一且合法"的测试文件。
///
/// 唯一很重要：内容固定的素材会在第一次运行后留在服务端，第二次运行就全部命中
/// 秒传，于是"真的传了一遍"这件事不再成立。做法是在 JPEG 的结束标记之后接一段
/// 随机字节 —— 主流解码器都会忽略 EOI 之后的数据，文件仍然是合法图片。
///
/// 随机尾巴同时把文件撑到 [size] 字节，用来覆盖多分片路径。
Uint8List makeJpegBytes(int size, Random rnd) {
  final head = base64Decode(_tinyJpegBase64);
  final out = Uint8List(size < head.length ? head.length : size);
  out.setRange(0, head.length, head);
  for (var i = head.length; i < out.length; i++) {
    out[i] = rnd.nextInt(256);
  }
  return out;
}

/// 反复等待直到 [condition] 成立或超时。
///
/// 上传是异步的：`start()` 返回时队列才刚把所有任务跑完，但服务端索引可能
/// 还没跟上。等条件而不是 `sleep`，失败时能立刻定位到是哪一步没到。
Future<void> waitUntil(
  Future<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 60),
  Duration step = const Duration(milliseconds: 200),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(step);
  }
  fail(reason ?? '等待超时');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('mc_upload_it');
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 写一个唯一的临时 JPEG，返回 (路径, 字节)。
  (String, Uint8List) makeFile(String name, int size) {
    final bytes = makeJpegBytes(size, Random());
    final path = '${tmp.path}/$name';
    File(path).writeAsBytesSync(bytes);
    return (path, bytes);
  }

  test('上传一个多分片文件：全部落盘，服务端能查到', () async {
    expect(_token, isNotEmpty, reason: '需要 --dart-define=MC_TOKEN=<token>');

    final client = ApiClient(baseUrl: _baseUrl, token: _token);
    final queue = UploadQueue(transport: HttpUploadTransport(client));
    addTearDown(queue.dispose);

    // 9 MiB 跨三片（服务端默认 4 MiB）。一片就够的用例覆盖不到分片边界，
    // 而边界正是最容易算错的地方。
    const size = 9 * 1024 * 1024;
    final (path, bytes) = makeFile('it_multi_${DateTime.now().microsecondsSinceEpoch}.jpg', size);

    queue.enqueue([
      PendingUpload(localPath: path, fileName: path.split('/').last, fileSize: size),
    ]);
    await queue.start();

    final task = queue.tasks.single;
    expect(task.status, UploadStatus.done, reason: '失败原因：${task.error}');
    expect(task.mediaId, greaterThan(0));
    expect(task.uploadedBytes, size);

    // 服务端确实收到了完整的字节数，而不是"客户端以为传完了"。
    await waitUntil(
      () async {
        final page = await client.listMedia(pageSize: 200);
        return page.items.any((m) => m.id == task.mediaId && m.fileSize == size);
      },
      reason: '服务端索引里找不到 media ${task.mediaId}，或大小对不上',
    );

    // 原文件能原样取回 —— 分片拼错位时大小仍然对，只有逐字节比对能发现。
    final original = await _download(client, task.mediaId);
    expect(original.length, bytes.length);
    expect(_sameBytes(original, bytes), isTrue, reason: '取回的内容与原文件不一致');
  });

  test('同内容换个文件名再传：命中秒传，一个字节都不传', () async {
    final client = ApiClient(baseUrl: _baseUrl, token: _token);
    final queue = UploadQueue(transport: HttpUploadTransport(client));
    addTearDown(queue.dispose);

    final (path, _) = makeFile('it_dedup_a_${DateTime.now().microsecondsSinceEpoch}.jpg', 64 * 1024);
    final stamp = DateTime.now().microsecondsSinceEpoch;

    // 第一次：正常上传。
    queue.enqueue([
      PendingUpload(localPath: path, fileName: 'dedup_a_$stamp.jpg', fileSize: 64 * 1024),
    ]);
    await queue.start();
    final first = queue.tasks.single;
    expect(first.status, UploadStatus.done, reason: '失败原因：${first.error}');

    // 第二次：同一份内容、不同文件名。队列按路径去重，所以这里要另建一个队列。
    final queue2 = UploadQueue(transport: HttpUploadTransport(client));
    addTearDown(queue2.dispose);
    queue2.enqueue([
      PendingUpload(localPath: path, fileName: 'dedup_b_$stamp.jpg', fileSize: 64 * 1024),
    ]);
    await queue2.start();
    final second = queue2.tasks.single;

    expect(second.status, UploadStatus.deduped, reason: '同内容应命中秒传，实际：${second.status.label}');
    expect(second.mediaId, first.mediaId, reason: '秒传应指回已有的那条媒体');
  });

  test('服务端拒绝时队列给出可读的失败原因，而不是卡住', () async {
    // 指向一个不存在的地址：连不上应当是"失败并说明原因"，不是无限重试。
    final client = ApiClient(baseUrl: 'http://127.0.0.1:1', token: _token);
    final queue = UploadQueue(
      transport: HttpUploadTransport(client),
      maxAttempts: 2,
      backoff: (_) => const Duration(milliseconds: 10),
    );
    addTearDown(queue.dispose);

    final (path, _) = makeFile('it_unreachable.jpg', 1024);
    queue.enqueue([
      PendingUpload(localPath: path, fileName: 'unreachable.jpg', fileSize: 1024),
    ]);

    await queue.start().timeout(const Duration(seconds: 30));

    final task = queue.tasks.single;
    expect(task.status, UploadStatus.failed);
    expect(task.error, isNotNull);
    expect(task.error, isNotEmpty);
  });
}

/// 取回原文件字节。
///
/// 走 `originalUrl` 而不是自己拼 URL：地址的拼法属于 ApiClient 的职责，
/// 测试里再写一遍就等于把被验证的东西复制进了断言。
Future<Uint8List> _download(ApiClient client, int mediaId) async {
  final url = client.originalUrl(mediaId);
  final httpClient = HttpClient();
  try {
    final req = await httpClient.getUrl(Uri.parse(url));
    req.headers.set('Authorization', 'Bearer ${client.token}');
    final res = await req.close();
    if (res.statusCode != 200) {
      fail('下载原文件失败：HTTP ${res.statusCode}');
    }
    final chunks = <int>[];
    await for (final chunk in res) {
      chunks.addAll(chunk);
    }
    return Uint8List.fromList(chunks);
  } finally {
    httpClient.close(force: true);
  }
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
