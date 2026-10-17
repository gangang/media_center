import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/upload/media_source.dart';
import '../../core/upload/upload_queue.dart';
import '../../core/upload/upload_transport.dart';
import '../albums/albums_page.dart';
import '../cinema/cinema_page.dart';
import '../gallery/gallery_page.dart';
import '../upload/photo_library_source.dart';
import '../upload/upload_page.dart';

/// 应用主壳：在「图库」「相册」「影院」之间切换，手机上多一个「备份」。
///
/// 宽屏（桌面、平板横屏）用侧边 NavigationRail，窄屏（手机）用底部
/// NavigationBar —— 桌面端把导航放在底部是移动端习惯的错位。
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.client,
    required this.onDisconnect,
    this.mediaSource,
    this.uploadQueue,
  });

  final ApiClient client;
  final Future<void> Function() onDisconnect;

  /// 相册来源。不传时按平台创建 —— 桌面端会得到一个 `supported == false`
  /// 的实现，"备份"入口随之消失。
  final MediaSource? mediaSource;

  /// 上传队列。不传时用 [client] 建一个真实的。
  ///
  /// 由这里持有而不是上传页持有：用户切到图库时上传必须继续，
  /// 队列的生命周期要长于任何一个页面。
  final UploadQueue? uploadQueue;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  static const _wideBreakpoint = 720.0;

  /// 相册页在导航里的下标。备份入口只在手机上有，所以它排在最后，
  /// 前面三个的下标在所有平台上都一样。
  static const _albumsIndex = 1;

  int _index = 0;

  /// 每次切到相册页就 +1，作为「该重新拉一次」的信号。
  ///
  /// 相册页常驻在 IndexedStack 里，不会因为切 tab 而重建，所以它启动时拉到的
  /// 那一份列表会一直留着——而用户完全可能在图库或查看器里改了相册内容，
  /// 切回来看到的却还是旧的数量。
  int _albumsRevision = 0;

  /// 上传完成后 +1，让图库页把新内容拉进来。
  int _galleryRevision = 0;

  late final MediaSource _source = widget.mediaSource ?? PhotoLibrarySource();
  late final UploadQueue _queue =
      widget.uploadQueue ??
      UploadQueue(transport: HttpUploadTransport(widget.client));

  bool get _hasUpload => _source.supported;

  List<({IconData icon, IconData selected, String label})> get _destinations => [
    (
      icon: Icons.photo_library_outlined,
      selected: Icons.photo_library,
      label: '图库',
    ),
    (
      icon: Icons.photo_album_outlined,
      selected: Icons.photo_album,
      label: '相册',
    ),
    (icon: Icons.movie_outlined, selected: Icons.movie, label: '影院'),
    if (_hasUpload)
      (
        icon: Icons.cloud_upload_outlined,
        selected: Icons.cloud_upload,
        label: '备份',
      ),
  ];

  @override
  void dispose() {
    // 队列是本页建的才由本页销毁；外面传进来的由外面负责。
    if (widget.uploadQueue == null) _queue.dispose();
    super.dispose();
  }

  void _select(int i) {
    setState(() {
      _index = i;
      if (i == _albumsIndex) _albumsRevision++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final destinations = _destinations;

    // 页面都常驻在 IndexedStack 里，切换 tab 时不会丢失滚动位置，
    // 也不会重新发起请求。
    final pages = <Widget>[
      GalleryPage(
        client: widget.client,
        onDisconnect: widget.onDisconnect,
        revision: _galleryRevision,
      ),
      AlbumsPage(client: widget.client, revision: _albumsRevision),
      CinemaPage(client: widget.client),
      if (_hasUpload)
        UploadPage(
          queue: _queue,
          source: _source,
          onUploaded: () => setState(() => _galleryRevision++),
        ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _wideBreakpoint;

        if (wide) {
          return Scaffold(
            body: Row(
              children: [
                NavigationRail(
                  selectedIndex: _index,
                  onDestinationSelected: _select,
                  labelType: NavigationRailLabelType.all,
                  destinations: [
                    for (final d in destinations)
                      NavigationRailDestination(
                        icon: Icon(d.icon),
                        selectedIcon: Icon(d.selected),
                        label: Text(d.label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(
                  child: IndexedStack(index: _index, children: pages),
                ),
              ],
            ),
          );
        }

        return Scaffold(
          body: IndexedStack(index: _index, children: pages),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: _select,
            destinations: [
              for (final d in destinations)
                NavigationDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.selected),
                  label: d.label,
                ),
            ],
          ),
        );
      },
    );
  }
}
