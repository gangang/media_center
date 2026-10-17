import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'upload/upload_models.dart';

/// 调用后端失败时抛出，[message] 已是可直接展示给用户的中文说明。
class ApiException implements Exception {
  ApiException(this.message, {this.statusCode, this.body});

  final String message;
  final int? statusCode;

  /// 服务端返回的原始 JSON body（能解析出来时）。
  ///
  /// 有些错误是**结构化的**，不只是给人看的一句话：上传完成时的 409 会带上
  /// `missing: [3, 7]`，客户端要靠它补片。把 body 挂在这里，比让每个调用点
  /// 各自重新解析一遍响应要可靠。
  final Map<String, dynamic>? body;

  @override
  String toString() => message;
}

/// 后端 HTTP 客户端。
///
/// 刻意保持无状态：所有请求都在调用时传入当前配置，避免客户端实例持有
/// 过期的服务器地址或令牌。
class ApiClient {
  ApiClient({required String baseUrl, required this.token})
    : baseUrl = normalizeBaseUrl(baseUrl);

  final String baseUrl;
  final String token;

  static const _timeout = Duration(seconds: 15);

  /// 单片上传的时限。
  ///
  /// 比默认的 15 秒宽松得多：4 MiB 在慢速 WiFi 上花掉 15 秒以上是常态，
  /// 用默认值会把"网慢"误判成"上传失败"，然后重试整片 —— 越慢越糟。
  static const _chunkTimeout = Duration(minutes: 2);

  /// create / complete 的时限。
  ///
  /// `complete` 在服务端要做的事不少：重算哈希、抢目标文件名、移动文件、建索引、
  /// 生成缩略图。一个 4 GB 视频这几步加起来远超 15 秒。而它一旦超时，
  /// 客户端会以为失败、服务端其实已经成功 —— 正是最不该出现的状态。
  static const _uploadOpTimeout = Duration(minutes: 5);

  /// 把用户随手输入的地址补全成规范形式。
  ///
  /// 接受 `192.168.1.5`、`192.168.1.5:8080`、`http://host:8080/` 等写法，
  /// 统一成 `http://host:8080`（无尾斜杠）。
  static String normalizeBaseUrl(String input) {
    var s = input.trim();
    if (s.isEmpty) return '';
    if (!s.contains('://')) {
      s = 'http://$s';
    }
    if (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  Map<String, String> get authHeaders => {'Authorization': 'Bearer $token'};

  Uri _uri(String path, [Map<String, String>? query]) {
    final uri = Uri.parse('$baseUrl$path');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(queryParameters: {...uri.queryParameters, ...query});
  }

  Future<Map<String, dynamic>> _getJson(
    String path, {
    Map<String, String>? query,
    bool authenticated = true,
    Duration? timeout,
  }) async {
    final http.Response res;
    try {
      res = await http
          .get(_uri(path, query), headers: authenticated ? authHeaders : null)
          .timeout(timeout ?? _timeout);
    } on SocketException {
      throw ApiException('无法连接到服务器，请检查地址与网络');
    } on http.ClientException catch (e) {
      throw ApiException('网络请求失败：${e.message}');
    } catch (e) {
      throw ApiException('请求失败：$e');
    }
    return _decode(res);
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> body, {
    Duration? timeout,
  }) => _sendJson('POST', path, body, timeout: timeout);

  Future<Map<String, dynamic>> _patchJson(
    String path,
    Map<String, dynamic> body,
  ) => _sendJson('PATCH', path, body);

  /// DELETE 允许带 body：后端移出相册成员时两种传参都支持。
  Future<Map<String, dynamic>> _deleteJson(
    String path, [
    Map<String, dynamic>? body,
  ]) => _sendJson('DELETE', path, body);

  /// 统一的 JSON 请求发送口。
  ///
  /// 用 [http.Request] 而不是 `http.post`/`http.patch` 这类快捷方法，是因为
  /// `http` 包没有提供带 body 的 DELETE，而这些快捷方法本质上只是它的包装。
  Future<Map<String, dynamic>> _sendJson(
    String method,
    String path,
    Map<String, dynamic>? body, {
    Duration? timeout,
  }) async {
    final req = http.Request(method, _uri(path));
    req.headers.addAll(authHeaders);
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }

    final http.Response res;
    try {
      final limit = timeout ?? _timeout;
      final streamed = await req.send().timeout(limit);
      // 读 body 也要限时：服务端可能在响应头之后卡住，只给 send() 加超时
      // 会在这种情况下一直挂着。
      res = await http.Response.fromStream(streamed).timeout(limit);
    } on SocketException {
      throw ApiException('无法连接到服务器，请检查地址与网络');
    } on http.ClientException catch (e) {
      throw ApiException('网络请求失败：${e.message}');
    } catch (e) {
      throw ApiException('请求失败：$e');
    }
    return _decode(res);
  }

  Map<String, dynamic> _decode(http.Response res) {
    if (res.statusCode == 401) {
      throw ApiException('访问令牌不正确，请重新输入', statusCode: 401);
    }
    if (res.statusCode >= 400) {
      String detail = 'HTTP ${res.statusCode}';
      Map<String, dynamic>? body;
      try {
        final decoded = jsonDecode(utf8.decode(res.bodyBytes));
        if (decoded is Map) {
          body = decoded.cast<String, dynamic>();
          if (body['error'] is String) detail = body['error'] as String;
        }
      } catch (_) {
        // 保留原始状态码即可
      }
      throw ApiException(
        '服务器返回错误：$detail',
        statusCode: res.statusCode,
        body: body,
      );
    }
    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is Map<String, dynamic>) return decoded;
      throw ApiException('服务器返回了非预期的数据格式');
    } on FormatException {
      throw ApiException('无法解析服务器返回的数据');
    }
  }

  /// 探测服务器。此接口无需令牌，用于在连接页面校验地址是否有效。
  Future<ServerInfo> ping() async {
    final json = await _getJson('/api/ping', authenticated: false);
    return ServerInfo.fromJson(json);
  }

  Future<LibraryStats> stats() async {
    final json = await _getJson('/api/stats');
    return LibraryStats.fromJson(json);
  }

  /// 拉一页媒体。
  ///
  /// [sort] 取值受后端白名单约束（`taken_at_desc`/`taken_at_asc`/`name_asc`/
  /// `size_desc`/`size_asc`/`indexed_desc`），传别的值后端会静默回落默认，
  /// 所以客户端只从自己那份枚举里选。
  /// [from]/[to] 是 `YYYY-MM-DD`，按拍摄时间过滤。
  ///
  /// **`to` 必须传结束日期的次日，不能传当天。** 服务端是按字符串比较
  /// RFC3339 的 `taken_at`：`"2026-10-17T12:00:00+08:00" <= "2026-10-17"`
  /// 字典序不成立（同前缀越长越大），直接传当天会把结束那天的照片整批切掉。
  /// 传次日则恰好含当天、不含次日晚于零点——且不依赖服务端时区。
  /// [origin] 为 `scan`/`upload` 时只列对应来源。
  Future<MediaPage> listMedia({
    String? type,
    int page = 1,
    int pageSize = 60,
    String sort = 'taken_at_desc',
    String? query,
    String? origin,
    String? from,
    String? to,
  }) async {
    final q = <String, String>{
      'page': '$page',
      'page_size': '$pageSize',
      'sort': sort,
    };
    if (type != null && type.isNotEmpty) q['type'] = type;
    if (query != null && query.isNotEmpty) q['q'] = query;
    if (origin != null && origin.isNotEmpty) q['origin'] = origin;
    if (from != null && from.isNotEmpty) q['from'] = from;
    if (to != null && to.isNotEmpty) q['to'] = to;

    final json = await _getJson('/api/media', query: q);
    return MediaPage.fromJson(json);
  }

  Future<List<ScanFolder>> listFolders() async {
    final json = await _getJson('/api/folders');
    final raw = (json['items'] as List?) ?? const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(ScanFolder.fromJson)
        .toList(growable: false);
  }

  Future<void> addFolder(String path) =>
      _postJson('/api/folders', {'path': path});

  /// 浏览服务端目录，给"添加媒体目录"的挑选器用。
  ///
  /// 只有主令牌能调：目录树会暴露服务端的用户名、挂载盘这类信息，
  /// 设备令牌拿不到。[path] 为空时服务端回到主目录。
  Future<ServerBrowse> browseDirectories(String path) async {
    final json = await _getJson('/api/fs/browse', query: {'path': path});
    return ServerBrowse.fromJson(json);
  }

  Future<void> deleteFolder(int id) async {
    await _deleteJson('/api/folders/$id');
  }

  /// 改名，或（带 [folderId] 时）移动到另一个已注册目录。
  ///
  /// 服务端是原地更新那一行索引，媒体 id 不变——所以相册成员关系不会丢。
  /// 返回更新后的条目；目录里已有同名文件时服务端会自动追加 " (1)"，
  /// 文件名以返回值为准（[MediaItem.fileName] 与调用方传入的可能不同）。
  Future<MediaItem> renameMedia(int id, {String? name, int? folderId}) async {
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (folderId != null) body['folder_id'] = folderId;
    final json = await _patchJson('/api/media/$id', body);
    return MediaItem.fromJson(json['item'] as Map<String, dynamic>);
  }

  /// 删除单个媒体：索引行 + 磁盘文件 + 缩略图一起删。
  ///
  /// **只删索引行是不够的**——文件还在，下次扫描会把它当新文件重新索引，
  /// 用户看到"删了又回来"。
  Future<DeleteOutcome> deleteMedia(int id) async {
    final json = await _deleteJson('/api/media/$id');
    return DeleteOutcome(
      id: id,
      ok: (json['deleted'] as bool?) ?? true,
      fileExisted: json['file_existed'] as bool?,
    );
  }

  /// 批量删除。部分失败是正常结果，[DeleteResult.failed] > 0 不代表没删成。
  Future<DeleteResult> deleteMediaBatch(List<int> ids) async {
    final json = await _postJson('/api/media/delete', {'ids': ids});
    return DeleteResult.fromJson(json);
  }

  /// 批量移动。部分失败是正常结果，由调用方决定怎么提示。
  Future<MoveResult> moveMedia(List<int> ids, int folderId) async {
    final json = await _postJson('/api/media/move', {
      'ids': ids,
      'folder_id': folderId,
    });
    return MoveResult.fromJson(json);
  }

  Future<void> startScan({int folderId = 0}) =>
      _postJson('/api/scan/start', {'folder_id': folderId});

  Future<ScanState> scanStatus() async {
    final json = await _getJson('/api/scan/status');
    return ScanState.fromJson(json);
  }

  // ---------------------------------------------------------------- 相册

  Future<List<Album>> listAlbums() async {
    final json = await _getJson('/api/albums');
    final raw = (json['items'] as List?) ?? const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(Album.fromJson)
        .toList(growable: false);
  }

  Future<Album> createAlbum(String name, {String description = ''}) async {
    final json = await _postJson('/api/albums', {
      'name': name,
      'description': description,
    });
    return Album.fromJson(json);
  }

  /// 重新读取单个相册。
  ///
  /// 改动成员后需要它：`item_count` 与 `cover_url` 都是后端推导的，
  /// 本地自己加减会在封面那一项被移出时算错。
  Future<Album> getAlbum(int id) async {
    final json = await _getJson('/api/albums/$id');
    return Album.fromJson(json);
  }

  /// 只更新传入的字段；未传的字段后端会保持原值。
  Future<Album> updateAlbum(int id, {String? name, String? description}) async {
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (description != null) body['description'] = description;
    final json = await _patchJson('/api/albums/$id', body);
    return Album.fromJson(json);
  }

  Future<void> deleteAlbum(int id) async {
    await _deleteJson('/api/albums/$id');
  }

  Future<MediaPage> listAlbumMedia(
    int albumId, {
    int page = 1,
    int pageSize = 60,
    String sort = 'taken_at_desc',
  }) async {
    final json = await _getJson(
      '/api/albums/$albumId/media',
      query: {'page': '$page', 'page_size': '$pageSize', 'sort': sort},
    );
    return MediaPage.fromJson(json);
  }

  /// 返回真正新增的数量（重复加入的会被后端忽略）。
  Future<int> addAlbumMedia(int albumId, List<int> mediaIds) async {
    final json = await _postJson('/api/albums/$albumId/media', {
      'media_ids': mediaIds,
    });
    return (json['added'] as num?)?.toInt() ?? 0;
  }

  Future<int> removeAlbumMedia(int albumId, List<int> mediaIds) async {
    final json = await _deleteJson('/api/albums/$albumId/media', {
      'media_ids': mediaIds,
    });
    return (json['removed'] as num?)?.toInt() ?? 0;
  }

  Future<List<Album>> albumsForMedia(int mediaId) async {
    final json = await _getJson('/api/media/$mediaId/albums');
    final raw = (json['items'] as List?) ?? const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(Album.fromJson)
        .toList(growable: false);
  }

  // ---------------------------------------------------------------- 上传

  /// 开一个上传会话，或者命中秒传。
  ///
  /// 传 [contentHash] 是值得的：服务端拿它去查已有内容，命中就一个字节都不用传。
  /// 手机反复备份同一个相册时，这一步把绝大部分文件变成了一个小请求。
  Future<CreateUploadResult> createUpload({
    required String fileName,
    required int fileSize,
    required String contentHash,
    int chunkSize = 0,
  }) async {
    final json = await _postJson('/api/uploads', {
      'file_name': fileName,
      'file_size': fileSize,
      'content_hash': contentHash,
      // 0 表示"你替我定"，服务端会用它自己的默认值（4 MiB）。
      if (chunkSize > 0) 'chunk_size': chunkSize,
    }, timeout: _uploadOpTimeout);
    return CreateUploadResult.fromJson(json);
  }

  /// 上传一片。分片是**直落目标偏移**的，服务端不缓存也不拼装。
  Future<ChunkAck> putUploadChunk(
    String uploadId,
    int index,
    Uint8List bytes,
  ) async {
    final req = http.Request(
      'PUT',
      _uri('/api/uploads/$uploadId/chunks/$index'),
    );
    req.headers.addAll(authHeaders);
    req.headers['Content-Type'] = 'application/octet-stream';
    // 用 bodyBytes 而不是 body：body 会按字符串编码，二进制会坏。
    // 它同时会设好 Content-Length，而服务端正是拿它校验分片大小的。
    req.bodyBytes = bytes;

    final http.Response res;
    try {
      final streamed = await req.send().timeout(_chunkTimeout);
      res = await http.Response.fromStream(streamed).timeout(_chunkTimeout);
    } on SocketException {
      throw ApiException('无法连接到服务器，请检查地址与网络');
    } on http.ClientException catch (e) {
      throw ApiException('网络请求失败：${e.message}');
    } catch (e) {
      throw ApiException('请求失败：$e');
    }
    return ChunkAck.fromJson(_decode(res));
  }

  /// 请服务端校验并入库。
  ///
  /// 分片不齐时后端返回 409 并附上缺哪几片，这里转成
  /// [MissingChunksException] —— 调用方必须处理它（补齐再试），
  /// 而忽略一个返回值比忽略一个异常容易得多。
  Future<CompleteUploadResult> completeUpload(String uploadId) async {
    try {
      final json = await _postJson(
        '/api/uploads/$uploadId/complete',
        const {},
        timeout: _uploadOpTimeout,
      );
      return CompleteUploadResult.fromJson(json);
    } on ApiException catch (e) {
      final missing = _missingFrom(e);
      if (missing != null) throw MissingChunksException(missing);
      rethrow;
    }
  }

  List<int>? _missingFrom(ApiException e) {
    if (e.statusCode != 409) return null;
    final raw = e.body?['missing'];
    if (raw is! List) return null;
    return raw.whereType<num>().map((n) => n.toInt()).toList(growable: false);
  }

  /// 查会话进度。断点续传靠它拿到"已经在服务端落盘的分片序号"。
  Future<UploadSession> getUpload(String uploadId) async {
    final json = await _getJson('/api/uploads/$uploadId');
    return UploadSession.fromJson(json);
  }

  /// 放弃一次上传并让服务端清理临时文件与数据库行。
  Future<void> cancelUpload(String uploadId) async {
    await _deleteJson('/api/uploads/$uploadId');
  }

  /// 缩略图与原文件的完整 URL。
  ///
  /// 这两个地址会被交给 [Image.network] 与视频播放器，因此需要能直接访问，
  /// 令牌通过请求头传递。
  String thumbnailUrl(int id) => '$baseUrl/api/media/$id/thumbnail';
  String originalUrl(int id) => '$baseUrl/api/media/$id/original';

  /// 相册封面：后端返回的是相对路径，这里补成可直接给 [Image.network] 的地址。
  String albumCoverUrl(Album album) => '$baseUrl${album.coverUrl}';
}
