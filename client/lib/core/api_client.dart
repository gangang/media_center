import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';

/// 调用后端失败时抛出，[message] 已是可直接展示给用户的中文说明。
class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

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
  }) async {
    final http.Response res;
    try {
      res = await http
          .get(_uri(path, query), headers: authenticated ? authHeaders : null)
          .timeout(_timeout);
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
    Map<String, dynamic> body,
  ) =>
      _sendJson('POST', path, body);

  Future<Map<String, dynamic>> _patchJson(
    String path,
    Map<String, dynamic> body,
  ) =>
      _sendJson('PATCH', path, body);

  /// DELETE 允许带 body：后端移出相册成员时两种传参都支持。
  Future<Map<String, dynamic>> _deleteJson(
    String path, [
    Map<String, dynamic>? body,
  ]) =>
      _sendJson('DELETE', path, body);

  /// 统一的 JSON 请求发送口。
  ///
  /// 用 [http.Request] 而不是 `http.post`/`http.patch` 这类快捷方法，是因为
  /// `http` 包没有提供带 body 的 DELETE，而这些快捷方法本质上只是它的包装。
  Future<Map<String, dynamic>> _sendJson(
    String method,
    String path,
    Map<String, dynamic>? body,
  ) async {
    final req = http.Request(method, _uri(path));
    req.headers.addAll(authHeaders);
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }

    final http.Response res;
    try {
      final streamed = await req.send().timeout(_timeout);
      res = await http.Response.fromStream(streamed);
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
      try {
        final body = jsonDecode(utf8.decode(res.bodyBytes));
        if (body is Map && body['error'] is String) {
          detail = body['error'] as String;
        }
      } catch (_) {
        // 保留原始状态码即可
      }
      throw ApiException('服务器返回错误：$detail', statusCode: res.statusCode);
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

  Future<MediaPage> listMedia({
    String? type,
    int page = 1,
    int pageSize = 60,
    String sort = 'taken_at_desc',
    String? query,
  }) async {
    final q = <String, String>{
      'page': '$page',
      'page_size': '$pageSize',
      'sort': sort,
    };
    if (type != null && type.isNotEmpty) q['type'] = type;
    if (query != null && query.isNotEmpty) q['q'] = query;

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

  Future<void> deleteFolder(int id) async {
    await _deleteJson('/api/folders/$id');
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
      query: {
        'page': '$page',
        'page_size': '$pageSize',
        'sort': sort,
      },
    );
    return MediaPage.fromJson(json);
  }

  /// 返回真正新增的数量（重复加入的会被后端忽略）。
  Future<int> addAlbumMedia(int albumId, List<int> mediaIds) async {
    final json = await _postJson(
      '/api/albums/$albumId/media',
      {'media_ids': mediaIds},
    );
    return (json['added'] as num?)?.toInt() ?? 0;
  }

  Future<int> removeAlbumMedia(int albumId, List<int> mediaIds) async {
    final json = await _deleteJson(
      '/api/albums/$albumId/media',
      {'media_ids': mediaIds},
    );
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

  /// 缩略图与原文件的完整 URL。
  ///
  /// 这两个地址会被交给 [Image.network] 与视频播放器，因此需要能直接访问，
  /// 令牌通过请求头传递。
  String thumbnailUrl(int id) => '$baseUrl/api/media/$id/thumbnail';
  String originalUrl(int id) => '$baseUrl/api/media/$id/original';

  /// 相册封面：后端返回的是相对路径，这里补成可直接给 [Image.network] 的地址。
  String albumCoverUrl(Album album) => '$baseUrl${album.coverUrl}';
}
