/// 上传相关的数据模型：既有与后端 `uploadDTO` 对应的线上格式，
/// 也有队列自己的任务状态。
///
/// 全部字段都做防御性解析：后端升级新增字段时，旧客户端不应崩溃。
library;

/// 一个上传会话，对应后端 `uploadDTO`。
class UploadSession {
  const UploadSession({
    required this.uploadId,
    required this.fileName,
    required this.status,
    required this.totalSize,
    required this.chunkSize,
    required this.chunkCount,
    required this.receivedChunks,
    required this.received,
    required this.expiresAt,
  });

  final String uploadId;
  final String fileName;
  final String status;
  final int totalSize;
  final int chunkSize;
  final int chunkCount;
  final int receivedChunks;

  /// 已经在服务端落盘的分片序号。
  ///
  /// 后端返回的是**序号列表**而不是计数，正是为了断点续传：重连的客户端需要
  /// 知道到底该补哪几片，只给一个数字是答不上来的。
  final List<int> received;

  final String expiresAt;

  bool get pending => status == 'pending';

  factory UploadSession.fromJson(Map<String, dynamic> j) => UploadSession(
    uploadId: (j['upload_id'] as String?) ?? '',
    fileName: (j['file_name'] as String?) ?? '',
    status: (j['status'] as String?) ?? '',
    totalSize: (j['total_size'] as num?)?.toInt() ?? 0,
    chunkSize: (j['chunk_size'] as num?)?.toInt() ?? 0,
    chunkCount: (j['chunk_count'] as num?)?.toInt() ?? 0,
    receivedChunks: (j['received_chunks'] as num?)?.toInt() ?? 0,
    received: ((j['received'] as List?) ?? const [])
        .whereType<num>()
        .map((e) => e.toInt())
        .toList(growable: false),
    expiresAt: (j['expires_at'] as String?) ?? '',
  );
}

/// `POST /api/uploads` 的结果。
///
/// 两种可能：开了一个新会话，或者服务端已经有这份内容（秒传）。
/// 用 [deduped] 区分，而不是用 [session] 是否为 null 来判断 ——
/// 调用方读到的是一个有名字的概念，不是一次空指针检查。
class CreateUploadResult {
  const CreateUploadResult({
    this.session,
    required this.deduped,
    required this.mediaId,
  });

  final UploadSession? session;
  final bool deduped;

  /// 秒传命中时是服务端已有媒体的 id；否则为 0。
  final int mediaId;

  factory CreateUploadResult.fromJson(Map<String, dynamic> j) {
    final deduped = (j['dedup'] as bool?) ?? false;
    if (deduped) {
      final media = j['media'];
      final id = media is Map ? ((media['id'] as num?)?.toInt() ?? 0) : 0;
      return CreateUploadResult(deduped: true, mediaId: id);
    }
    return CreateUploadResult(
      session: UploadSession.fromJson(j),
      deduped: false,
      mediaId: 0,
    );
  }
}

/// 单片上传的应答。
class ChunkAck {
  const ChunkAck({required this.receivedChunks, required this.chunkCount});

  final int receivedChunks;
  final int chunkCount;

  bool get done => receivedChunks >= chunkCount;

  factory ChunkAck.fromJson(Map<String, dynamic> j) => ChunkAck(
    receivedChunks: (j['received_chunks'] as num?)?.toInt() ?? 0,
    chunkCount: (j['chunk_count'] as num?)?.toInt() ?? 0,
  );
}

/// `POST .../complete` 的结果。
class CompleteUploadResult {
  const CompleteUploadResult({required this.mediaId, required this.deduped});

  final int mediaId;

  /// 服务端在收完之后才发现内容重复（客户端事先没给出哈希时的兜底去重）。
  final bool deduped;

  factory CompleteUploadResult.fromJson(Map<String, dynamic> j) {
    final media = j['media'];
    return CompleteUploadResult(
      mediaId: media is Map ? ((media['id'] as num?)?.toInt() ?? 0) : 0,
      deduped: (j['dedup'] as bool?) ?? false,
    );
  }
}

/// 服务端说"分片不完整，无法完成"，并告诉缺哪几片。
///
/// 单独建模成异常而不是一个布尔返回值：调用方必须**处理**它（补齐再试），
/// 而忽略一个返回值比忽略一个异常容易得多。
class MissingChunksException implements Exception {
  const MissingChunksException(this.missing);

  final List<int> missing;

  @override
  String toString() => '服务端报告缺少分片：$missing';
}

/// 单个上传任务的状态。
enum UploadStatus {
  queued,

  /// 正在算内容指纹（读文件头尾）。
  hashing,

  /// 正在传分片。
  uploading,

  /// 分片传完，等服务端校验并入库。
  verifying,

  /// 成功入库。
  done,

  /// 服务端已有这份内容，一个字节都没传。
  deduped,

  /// 重试若干次后放弃。会话仍留在服务端，下次可以续传。
  failed,

  /// 用户取消。
  canceled,
}

extension UploadStatusX on UploadStatus {
  bool get isTerminal =>
      this == UploadStatus.done ||
      this == UploadStatus.deduped ||
      this == UploadStatus.failed ||
      this == UploadStatus.canceled;

  String get label => switch (this) {
    UploadStatus.queued => '排队中',
    UploadStatus.hashing => '计算校验值',
    UploadStatus.uploading => '上传中',
    UploadStatus.verifying => '服务器校验中',
    UploadStatus.done => '已完成',
    UploadStatus.deduped => '已存在（秒传）',
    UploadStatus.failed => '失败',
    UploadStatus.canceled => '已取消',
  };
}

/// 队列里的一项。
///
/// 可变对象，由 [UploadQueue] 持有并在状态变化时通知监听者 —— 上传进度每传完
/// 一片就变一次，为每次变化重建整个列表没有意义。
class UploadTask {
  UploadTask({
    required this.localPath,
    required this.fileName,
    required this.fileSize,
  });

  final String localPath;
  final String fileName;
  final int fileSize;

  UploadStatus status = UploadStatus.queued;

  /// 已成功落盘到服务端的字节数（用于进度条）。
  int uploadedBytes = 0;

  /// 入库后的媒体 id（秒传时是已有媒体的 id）。
  int mediaId = 0;

  /// 失败原因，已是可直接展示的中文说明。
  String? error;

  /// 已重试次数，用于退避计算与 UI 提示。
  int attempts = 0;

  /// 服务端给的上传会话 id。非空且任务失败时，下次可以续传。
  String? uploadId;

  double get progress {
    if (fileSize <= 0) return 0;
    final p = uploadedBytes / fileSize;
    return p > 1 ? 1 : p;
  }

  bool get isTerminal => status.isTerminal;

  /// 秒传或已完成的算成功。
  bool get succeeded =>
      status == UploadStatus.done || status == UploadStatus.deduped;
}

/// 待上传项：平台层扫完手机相册后交给队列的东西。
///
/// 只是一个"路径 + 名字 + 大小"的载体，刻意不带任何平台类型（没有 AssetEntity、
/// 没有 Uri）。这样队列就不必知道照片是从相册读来的还是从文件系统里挑的，
/// 测试里也能直接拿临时文件构造。
class PendingUpload {
  const PendingUpload({
    required this.localPath,
    required this.fileName,
    required this.fileSize,
  });

  final String localPath;
  final String fileName;
  final int fileSize;
}
