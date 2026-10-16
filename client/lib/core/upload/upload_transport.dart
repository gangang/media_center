import 'dart:typed_data';

import '../api_client.dart';
import 'upload_models.dart';

/// 上传所需的五个后端操作。
///
/// 抽成接口是为了让队列**可以脱离 HTTP 被验证**。上传队列里真正容易出错的东西
/// ——分片边界、断点续传该补哪几片、重试之后会不会重复计数、缺片补齐——
/// 全都是纯粹的调度逻辑，和网络无关。把它们绑死在真 HTTP 上，就只能靠一台
/// 手机和一个真服务端来测，而那是最慢、最难复现的验证方式。
///
/// 所以：队列只依赖这个接口，生产环境注入 [HttpUploadTransport]，
/// 测试注入一个记录调用的假实现。
abstract class UploadTransport {
  Future<CreateUploadResult> create({
    required String fileName,
    required int fileSize,
    required String contentHash,
    int chunkSize,
  });

  Future<ChunkAck> putChunk(String uploadId, int index, Uint8List bytes);

  Future<CompleteUploadResult> complete(String uploadId);

  Future<UploadSession> get(String uploadId);

  Future<void> cancel(String uploadId);
}

/// 走真实 HTTP 的实现。所有逻辑都在 [ApiClient] 里，这里只是转接。
class HttpUploadTransport implements UploadTransport {
  const HttpUploadTransport(this.client);

  final ApiClient client;

  @override
  Future<CreateUploadResult> create({
    required String fileName,
    required int fileSize,
    required String contentHash,
    int chunkSize = 0,
  }) => client.createUpload(
    fileName: fileName,
    fileSize: fileSize,
    contentHash: contentHash,
    chunkSize: chunkSize,
  );

  @override
  Future<ChunkAck> putChunk(String uploadId, int index, Uint8List bytes) =>
      client.putUploadChunk(uploadId, index, bytes);

  @override
  Future<CompleteUploadResult> complete(String uploadId) =>
      client.completeUpload(uploadId);

  @override
  Future<UploadSession> get(String uploadId) => client.getUpload(uploadId);

  @override
  Future<void> cancel(String uploadId) => client.cancelUpload(uploadId);
}
