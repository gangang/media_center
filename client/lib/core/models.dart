/// 与后端 API 对应的数据模型。
///
/// 所有字段都做了防御性解析：后端升级新增字段时，旧客户端不应崩溃。
library;

class MediaItem {
  const MediaItem({
    required this.id,
    required this.fileName,
    required this.mediaType,
    required this.mimeType,
    required this.fileSize,
    required this.takenAt,
    required this.width,
    required this.height,
    required this.durationMs,
    required this.videoCodec,
    required this.audioCodec,
    required this.thumbnailUrl,
    required this.originalUrl,
    this.filePath = '',
    this.origin = '',
  });

  final int id;
  final String fileName;
  final String mediaType; // photo | video
  final String mimeType;
  final int fileSize;
  final String takenAt;
  final int width;
  final int height;
  final int durationMs;
  final String videoCodec;
  final String audioCodec;
  final String thumbnailUrl;
  final String originalUrl;

  /// 文件在服务端的绝对路径。用来回答"这张照片到底在哪"，
  /// 也是任何文件操作前必须回显给用户的那一行。
  final String filePath;

  /// `scan`（本地扫来的）或 `upload`（手机传上的）。
  final String origin;

  bool get isVideo => mediaType == 'video';

  /// 拍摄时间。后端统一用 RFC3339 存储，这里转成本地时区展示。
  DateTime? get takenAtLocal => DateTime.tryParse(takenAt)?.toLocal();

  String get resolution => (width > 0 && height > 0) ? '$width × $height' : '未知';

  String get fileSizeLabel {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var size = fileSize.toDouble();
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return unit == 0
        ? '${size.toInt()} ${units[unit]}'
        : '${size.toStringAsFixed(1)} ${units[unit]}';
  }

  String get durationLabel {
    if (durationMs <= 0) return '';
    final total = (durationMs / 1000).round();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$m:$ss';
  }

  factory MediaItem.fromJson(Map<String, dynamic> j) {
    int asInt(String k) {
      final v = j[k];
      if (v is int) return v;
      if (v is num) return v.toInt();
      return 0;
    }

    String asStr(String k) => (j[k] as String?) ?? '';

    return MediaItem(
      id: asInt('id'),
      fileName: asStr('file_name'),
      mediaType: asStr('media_type'),
      mimeType: asStr('mime_type'),
      fileSize: asInt('file_size'),
      takenAt: asStr('taken_at'),
      width: asInt('width'),
      height: asInt('height'),
      durationMs: asInt('duration_ms'),
      videoCodec: asStr('video_codec'),
      audioCodec: asStr('audio_codec'),
      thumbnailUrl: asStr('thumbnail_url'),
      originalUrl: asStr('original_url'),
      filePath: asStr('file_path'),
      origin: asStr('origin'),
    );
  }
}

/// 一页媒体数据。
class MediaPage {
  const MediaPage({
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
  });

  final List<MediaItem> items;
  final int total;
  final int page;
  final int pageSize;

  bool get hasMore => page * pageSize < total;

  factory MediaPage.fromJson(Map<String, dynamic> j) {
    final raw = (j['items'] as List?) ?? const [];
    return MediaPage(
      items: raw
          .whereType<Map<String, dynamic>>()
          .map(MediaItem.fromJson)
          .toList(growable: false),
      total: (j['total'] as num?)?.toInt() ?? 0,
      page: (j['page'] as num?)?.toInt() ?? 1,
      pageSize: (j['page_size'] as num?)?.toInt() ?? 60,
    );
  }
}

/// 服务器发现阶段返回的信息。
class ServerInfo {
  const ServerInfo({
    required this.name,
    required this.version,
    required this.apiVersion,
    required this.authRequired,
  });

  final String name;
  final String version;
  final int apiVersion;
  final bool authRequired;

  factory ServerInfo.fromJson(Map<String, dynamic> j) => ServerInfo(
        name: (j['name'] as String?) ?? 'MediaCenter',
        version: (j['version'] as String?) ?? '?',
        apiVersion: (j['api_version'] as num?)?.toInt() ?? 0,
        authRequired: (j['auth_required'] as bool?) ?? true,
      );
}

/// 索引统计。
class LibraryStats {
  const LibraryStats({
    required this.photos,
    required this.videos,
    required this.totalBytes,
    required this.folders,
    required this.ffmpegAvailable,
  });

  final int photos;
  final int videos;
  final int totalBytes;
  final int folders;
  final bool ffmpegAvailable;

  int get total => photos + videos;

  factory LibraryStats.fromJson(Map<String, dynamic> j) => LibraryStats(
        photos: (j['photos'] as num?)?.toInt() ?? 0,
        videos: (j['videos'] as num?)?.toInt() ?? 0,
        totalBytes: (j['total_bytes'] as num?)?.toInt() ?? 0,
        folders: (j['folders'] as num?)?.toInt() ?? 0,
        ffmpegAvailable: (j['ffmpeg_available'] as bool?) ?? false,
      );
}

/// 扫描进度。
class ScanState {
  const ScanState({
    required this.running,
    required this.filesSeen,
    required this.indexed,
    required this.skipped,
    required this.failed,
    required this.removed,
    required this.current,
    required this.errors,
  });

  final bool running;
  final int filesSeen;
  final int indexed;
  final int skipped;
  final int failed;
  final int removed;
  final String current;
  final List<String> errors;

  static const idle = ScanState(
    running: false,
    filesSeen: 0,
    indexed: 0,
    skipped: 0,
    failed: 0,
    removed: 0,
    current: '',
    errors: [],
  );

  factory ScanState.fromJson(Map<String, dynamic> j) => ScanState(
        running: (j['running'] as bool?) ?? false,
        filesSeen: (j['files_seen'] as num?)?.toInt() ?? 0,
        indexed: (j['indexed'] as num?)?.toInt() ?? 0,
        skipped: (j['skipped'] as num?)?.toInt() ?? 0,
        failed: (j['failed'] as num?)?.toInt() ?? 0,
        removed: (j['removed'] as num?)?.toInt() ?? 0,
        current: (j['current'] as String?) ?? '',
        errors: ((j['errors'] as List?) ?? const [])
            .whereType<String>()
            .toList(growable: false),
      );
}

/// 已配置的扫描目录。
class ScanFolder {
  const ScanFolder({
    required this.id,
    required this.path,
    required this.enabled,
    required this.lastScan,
  });

  final int id;
  final String path;
  final bool enabled;
  final String lastScan;

  factory ScanFolder.fromJson(Map<String, dynamic> j) => ScanFolder(
        id: (j['id'] as num?)?.toInt() ?? 0,
        path: (j['path'] as String?) ?? '',
        enabled: (j['enabled'] as bool?) ?? true,
        lastScan: (j['last_scan'] as String?) ?? '',
      );
}

/// 服务端目录浏览结果里的一个子目录。
class ServerDirEntry {
  const ServerDirEntry({
    required this.name,
    required this.path,
    required this.hidden,
  });

  final String name;
  final String path;

  /// 点号开头。界面置灰显示：扫描父目录时会跳过它，但把它本身注册成
  /// 扫描目录是会扫的，所以不能藏起来让用户找不到。
  final bool hidden;

  factory ServerDirEntry.fromJson(Map<String, dynamic> j) => ServerDirEntry(
        name: (j['name'] as String?) ?? '',
        path: (j['path'] as String?) ?? '',
        hidden: (j['hidden'] as bool?) ?? false,
      );
}

/// 服务端算好的快捷入口（主目录、图片、外接卷…）。
///
/// 放在服务端算是因为只有它知道自己的平台和挂载点，否则每个平台的差异
/// 都会漏进这个 Flutter 界面里。
class ServerDirShortcut {
  const ServerDirShortcut({required this.label, required this.path});

  final String label;
  final String path;

  factory ServerDirShortcut.fromJson(Map<String, dynamic> j) => ServerDirShortcut(
        label: (j['label'] as String?) ?? '',
        path: (j['path'] as String?) ?? '',
      );
}

/// `GET /api/fs/browse` 的响应。
///
/// 存在的原因：挑选器要能浏览服务端的目录——手机打不开服务端上的文件
/// 对话框，两台机器。注意浏览只是导航，**不构成授权**；目录获得管理权限
/// 是在用户通过 `POST /api/folders` 把它注册进来的那一刻。
class ServerBrowse {
  const ServerBrowse({
    required this.path,
    required this.parent,
    required this.home,
    required this.entries,
    required this.shortcuts,
    required this.truncated,
  });

  final String path;

  /// 上一级；已在文件系统根时为空串。
  final String parent;
  final String home;
  final List<ServerDirEntry> entries;
  final List<ServerDirShortcut> shortcuts;

  /// 子目录超过服务端上限（500）被截断。界面要提示改用手动输入，
  /// 否则用户会以为"就这么多目录"。
  final bool truncated;

  factory ServerBrowse.fromJson(Map<String, dynamic> j) => ServerBrowse(
        path: (j['path'] as String?) ?? '',
        parent: (j['parent'] as String?) ?? '',
        home: (j['home'] as String?) ?? '',
        entries: ((j['entries'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ServerDirEntry.fromJson)
            .toList(growable: false),
        shortcuts: ((j['shortcuts'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ServerDirShortcut.fromJson)
            .toList(growable: false),
        truncated: (j['truncated'] as bool?) ?? false,
      );
}

/// 批量移动里单项的结果。
class MoveOutcome {
  const MoveOutcome({
    required this.id,
    required this.ok,
    this.path = '',
    this.error = '',
  });

  final int id;
  final bool ok;
  final String path;
  final String error;
}

/// `POST /api/media/move` 的响应。
///
/// 部分失败是正常形态而不是异常：三个文件里有一个在刚被拔掉的外接盘上，
/// 就该是"两个成功、一个失败并说明原因"。整批回滚会让用户以为什么都没发生，
/// 然后原样重试再失败一遍。
class MoveResult {
  const MoveResult({
    required this.moved,
    required this.failed,
    required this.results,
  });

  final int moved;
  final int failed;
  final List<MoveOutcome> results;

  factory MoveResult.fromJson(Map<String, dynamic> j) => MoveResult(
        moved: (j['moved'] as num?)?.toInt() ?? 0,
        failed: (j['failed'] as num?)?.toInt() ?? 0,
        results: ((j['results'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map((r) => MoveOutcome(
                  id: (r['id'] as num?)?.toInt() ?? 0,
                  ok: (r['ok'] as bool?) ?? false,
                  path: (r['path'] as String?) ?? '',
                  error: (r['error'] as String?) ?? '',
                ))
            .toList(growable: false),
      );
}

/// 批量删除响应的单项结果。
class DeleteOutcome {
  const DeleteOutcome({
    required this.id,
    required this.ok,
    this.error = '',
    this.fileExisted,
  });

  final int id;
  final bool ok;
  final String error;

  /// 文件原本就不在磁盘上时为 false。两者都算删除成功，但界面提示不同：
  /// 文件本来就没有，说明索引和磁盘早已不一致，值得让用户知道。
  final bool? fileExisted;
}

/// `POST /api/media/delete` 的响应。
///
/// 部分失败是正常形态：一个文件在只读盘上、一个 id 刚被别人删掉，
/// 就该是"N 个成功、其余失败并说明原因"，而不是整批 500。
class DeleteResult {
  const DeleteResult({
    required this.deleted,
    required this.failed,
    required this.results,
  });

  final int deleted;
  final int failed;
  final List<DeleteOutcome> results;

  factory DeleteResult.fromJson(Map<String, dynamic> j) => DeleteResult(
        deleted: (j['deleted'] as num?)?.toInt() ?? 0,
        failed: (j['failed'] as num?)?.toInt() ?? 0,
        results: ((j['results'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map((r) => DeleteOutcome(
                  id: (r['id'] as num?)?.toInt() ?? 0,
                  ok: (r['ok'] as bool?) ?? false,
                  error: (r['error'] as String?) ?? '',
                  fileExisted: r['file_existed'] as bool?,
                ))
            .toList(growable: false),
      );
}

/// 相册。
///
/// [itemCount] 与 [coverUrl] 由后端推导（封面取相册内最早加入的一项），
/// 客户端不自己算——否则列表页和详情页很容易算出不一样的结果。
class Album {
  const Album({
    required this.id,
    required this.name,
    required this.description,
    required this.itemCount,
    required this.coverUrl,
    required this.createdAt,
    required this.updatedAt,
  });

  final int id;
  final String name;
  final String description;
  final int itemCount;

  /// 相对路径，形如 `/api/media/3/thumbnail`。空串表示相册里还没有内容。
  final String coverUrl;

  final String createdAt;
  final String updatedAt;

  bool get hasCover => coverUrl.isNotEmpty;

  factory Album.fromJson(Map<String, dynamic> j) => Album(
        id: (j['id'] as num?)?.toInt() ?? 0,
        name: (j['name'] as String?) ?? '',
        description: (j['description'] as String?) ?? '',
        itemCount: (j['item_count'] as num?)?.toInt() ?? 0,
        coverUrl: (j['cover_url'] as String?) ?? '',
        createdAt: (j['created_at'] as String?) ?? '',
        updatedAt: (j['updated_at'] as String?) ?? '',
      );
}
