import 'package:flutter_test/flutter_test.dart';
import 'package:media_center_client/core/api_client.dart';
import 'package:media_center_client/core/media_pager.dart';
import 'package:media_center_client/core/models.dart';
import 'package:media_center_client/core/server_discovery.dart';

void main() {
  group('ApiClient.normalizeBaseUrl', () {
    test('补全缺失的协议', () {
      expect(ApiClient.normalizeBaseUrl('192.168.1.5:8080'),
          'http://192.168.1.5:8080');
      expect(ApiClient.normalizeBaseUrl('media-server.local'),
          'http://media-server.local');
    });

    test('去掉尾部斜杠', () {
      expect(ApiClient.normalizeBaseUrl('http://host:8080/'),
          'http://host:8080');
    });

    test('保留已有协议', () {
      expect(ApiClient.normalizeBaseUrl('https://example.com'),
          'https://example.com');
    });

    test('去掉首尾空白', () {
      expect(ApiClient.normalizeBaseUrl('  10.0.0.2:9000  '),
          'http://10.0.0.2:9000');
    });

    test('空字符串保持为空', () {
      expect(ApiClient.normalizeBaseUrl('   '), '');
    });
  });

  group('MediaItem', () {
    test('从后端 JSON 解析', () {
      final item = MediaItem.fromJson({
        'id': 42,
        'file_name': 'IMG_0002.jpg',
        'media_type': 'photo',
        'mime_type': 'image/jpeg',
        'file_size': 3145728,
        'taken_at': '2019-07-14T18:30:00+08:00',
        'width': 2400,
        'height': 1350,
        'duration_ms': 0,
        'thumbnail_url': '/api/media/42/thumbnail',
        'original_url': '/api/media/42/original',
      });

      expect(item.id, 42);
      expect(item.isVideo, isFalse);
      expect(item.resolution, '2400 × 1350');
      expect(item.fileSizeLabel, '3.0 MB');
      expect(item.takenAtLocal?.year, 2019);
    });

    test('缺失字段不会崩溃', () {
      final item = MediaItem.fromJson({'id': 1});
      expect(item.id, 1);
      expect(item.fileName, '');
      expect(item.resolution, '未知');
      expect(item.isVideo, isFalse);
    });

    test('数值字段兼容浮点表示', () {
      final item = MediaItem.fromJson({'id': 7, 'file_size': 2048.0});
      expect(item.fileSize, 2048);
    });

    test('视频时长格式化', () {
      final short = MediaItem.fromJson(
          {'id': 1, 'media_type': 'video', 'duration_ms': 95000});
      expect(short.durationLabel, '1:35');

      final long = MediaItem.fromJson(
          {'id': 2, 'media_type': 'video', 'duration_ms': 3723000});
      expect(long.durationLabel, '1:02:03');
      expect(long.isVideo, isTrue);

      final unknown = MediaItem.fromJson({'id': 3, 'media_type': 'video'});
      expect(unknown.durationLabel, '');
    });
  });

  group('MediaPage', () {
    test('hasMore 依据总数与已加载数量判断', () {
      final page = MediaPage.fromJson({
        'items': [
          {'id': 1},
          {'id': 2},
        ],
        'total': 100,
        'page': 1,
        'page_size': 60,
      });
      expect(page.items.length, 2);
      expect(page.total, 100);
      expect(page.hasMore, isTrue);
    });

    test('空列表不报错', () {
      final page = MediaPage.fromJson({'items': [], 'total': 0});
      expect(page.items, isEmpty);
      expect(page.hasMore, isFalse);
    });
  });

  group('ScanState', () {
    test('解析进度与错误列表', () {
      final s = ScanState.fromJson({
        'running': true,
        'files_seen': 120,
        'indexed': 30,
        'skipped': 90,
        'failed': 0,
        'removed': 2,
        'current': '/photos/a.jpg',
        'errors': ['thumbnail /photos/b.heic: unsupported'],
      });
      expect(s.running, isTrue);
      expect(s.filesSeen, 120);
      expect(s.removed, 2);
      expect(s.errors, hasLength(1));
    });

    test('errors 为 null 时返回空列表', () {
      final s = ScanState.fromJson({'running': false, 'errors': null});
      expect(s.errors, isEmpty);
    });
  });

  group('Album', () {
    test('从后端 JSON 解析', () {
      final a = Album.fromJson({
        'id': 3,
        'name': '2024 夏天',
        'description': '海边',
        'item_count': 12,
        'cover_url': '/api/media/7/thumbnail',
        'created_at': '2026-10-15T12:00:00Z',
        'updated_at': '2026-10-15T12:30:00Z',
      });

      expect(a.id, 3);
      expect(a.name, '2024 夏天');
      expect(a.description, '海边');
      expect(a.itemCount, 12);
      expect(a.hasCover, isTrue);
    });

    test('空相册没有封面', () {
      final a = Album.fromJson({
        'id': 1,
        'name': '空相册',
        'item_count': 0,
        'cover_url': '',
      });
      expect(a.itemCount, 0);
      expect(a.hasCover, isFalse);
    });

    test('缺失字段不会崩溃', () {
      final a = Album.fromJson({'id': 9});
      expect(a.id, 9);
      expect(a.name, '');
      expect(a.itemCount, 0);
      expect(a.hasCover, isFalse);
    });
  });

  group('ApiClient.albumCoverUrl', () {
    test('把相对封面路径补成完整地址', () {
      final client = ApiClient(baseUrl: '192.168.1.5:8080', token: 't');
      final a = Album.fromJson({
        'id': 1,
        'name': 'x',
        'cover_url': '/api/media/7/thumbnail',
      });
      expect(
        client.albumCoverUrl(a),
        'http://192.168.1.5:8080/api/media/7/thumbnail',
      );
    });
  });

  group('parseTxt', () {
    test('把多行 TXT 拆成键值对', () {
      // multicast_dns 把多个 length-prefixed 字符串用换行拼成一条，
      // 末尾通常还会多一个换行。
      final txt = parseTxt('name=MediaCenter-bogon\nversion=0.1.0\napi=1\npath=/\n');
      expect(txt, {
        'name': 'MediaCenter-bogon',
        'version': '0.1.0',
        'api': '1',
        'path': '/',
      });
    });

    test('只按第一个等号切分，值里可以再带等号', () {
      final txt = parseTxt('url=http://a/b?x=1&y=2');
      expect(txt['url'], 'http://a/b?x=1&y=2');
    });

    test('忽略空行和不含等号的行', () {
      final txt = parseTxt('\n  \n没有等号\nk=v\n');
      expect(txt, {'k': 'v'});
    });

    test('空文本得到空表', () {
      expect(parseTxt(''), isEmpty);
    });
  });

  group('DiscoveredServer', () {
    DiscoveredServer server({
      List<String> addresses = const ['192.168.1.49'],
      int port = 18080,
      Map<String, String> txt = const {'name': 'MediaCenter-bogon'},
    }) =>
        DiscoveredServer(
          instance: 'MediaCenter-bogon._mediacenter._tcp.local',
          name: txt['name'] ?? 'MediaCenter-bogon',
          host: 'bogon.local',
          port: port,
          addresses: addresses,
          txt: txt,
        );

    test('baseUrl 用解析出的地址和端口拼出 http 地址', () {
      expect(server().baseUrl, 'http://192.168.1.49:18080');
    });

    test('path 为 / 时不拼到地址里', () {
      expect(server(txt: {'path': '/'}).baseUrl, 'http://192.168.1.49:18080');
    });

    test('path 非根时拼上去，以便将来服务端挂在子路径下', () {
      final s = server(txt: {'path': '/media'});
      expect(s.baseUrl, 'http://192.168.1.49:18080/media');
    });

    test('没有地址时 baseUrl 为 null', () {
      final s = server(addresses: const []);
      expect(s.address, isNull);
      expect(s.baseUrl, isNull);
    });

    test('version 与 apiVersion 取自 TXT', () {
      final s = server(txt: {'name': 'n', 'version': '0.1.0', 'api': '1'});
      expect(s.version, '0.1.0');
      expect(s.apiVersion, '1');
    });
  });

  group('MediaPager', () {
    MediaPage pageOf(List<int> ids, {required int total, required int page}) =>
        MediaPage.fromJson({
          'items': ids.map((i) => {'id': i}).toList(),
          'total': total,
          'page': page,
          'page_size': 2,
        });

    test('reload 拉取第一页并记录总数', () async {
      final pager = MediaPager(
        pageSize: 2,
        fetch: (page, size) async => pageOf([1, 2], total: 5, page: page),
      );
      await pager.reload();

      expect(pager.items.map((e) => e.id), [1, 2]);
      expect(pager.total, 5);
      expect(pager.hasMore, isTrue);
      expect(pager.loading, isFalse);
      expect(pager.error, isNull);
    });

    test('loadMore 追加下一页，取完后 hasMore 变为 false', () async {
      final pager = MediaPager(
        pageSize: 2,
        fetch: (page, size) async =>
            pageOf(page == 1 ? [1, 2] : [3], total: 3, page: page),
      );
      await pager.reload();
      await pager.loadMore();

      expect(pager.items.map((e) => e.id), [1, 2, 3]);
      expect(pager.hasMore, isFalse);
    });

    test('已取完时 loadMore 不再发起请求', () async {
      var calls = 0;
      final pager = MediaPager(
        pageSize: 2,
        fetch: (page, size) async {
          calls++;
          return pageOf([1, 2], total: 2, page: page);
        },
      );
      await pager.reload();
      await pager.loadMore();

      expect(calls, 1, reason: '总数已达上限，不应再请求');
    });

    test('重复返回的条目按 id 去重', () async {
      final pager = MediaPager(
        pageSize: 2,
        fetch: (page, size) async =>
            pageOf(page == 1 ? [1, 2] : [2, 3], total: 4, page: page),
      );
      await pager.reload();
      await pager.loadMore();

      expect(pager.items.map((e) => e.id), [1, 2, 3]);
    });

    test('请求失败时记录错误且不抛出异常', () async {
      final pager = MediaPager(
        pageSize: 2,
        fetch: (page, size) async => throw Exception('无法连接到服务器'),
      );
      await pager.reload();

      expect(pager.error, '无法连接到服务器');
      expect(pager.items, isEmpty);
      expect(pager.loading, isFalse);
    });
  });
}
