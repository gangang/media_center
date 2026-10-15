import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../albums/albums_page.dart';
import '../cinema/cinema_page.dart';
import '../gallery/gallery_page.dart';

/// 应用主壳：在「图库」「相册」「影院」之间切换。
///
/// 宽屏（桌面、平板横屏）用侧边 NavigationRail，窄屏（手机）用底部
/// NavigationBar —— 桌面端把导航放在底部是移动端习惯的错位。
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.client,
    required this.onDisconnect,
  });

  final ApiClient client;
  final Future<void> Function() onDisconnect;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  static const _wideBreakpoint = 720.0;

  /// 相册页在 `_destinations` 里的下标。
  static const _albumsIndex = 1;

  int _index = 0;

  /// 每次切到相册页就 +1，作为「该重新拉一次」的信号。
  ///
  /// 相册页常驻在 IndexedStack 里，不会因为切 tab 而重建，所以它启动时拉到的
  /// 那一份列表会一直留着——而用户完全可能在图库或查看器里改了相册内容，
  /// 切回来看到的却还是旧的数量。
  int _albumsRevision = 0;

  static const _destinations = [
    (icon: Icons.photo_library_outlined, selected: Icons.photo_library, label: '图库'),
    (icon: Icons.photo_album_outlined, selected: Icons.photo_album, label: '相册'),
    (icon: Icons.movie_outlined, selected: Icons.movie, label: '影院'),
  ];

  void _select(int i) {
    setState(() {
      _index = i;
      if (i == _albumsIndex) _albumsRevision++;
    });
  }

  @override
  Widget build(BuildContext context) {
    // 三个页面都常驻在 IndexedStack 里，切换 tab 时不会丢失滚动位置，
    // 也不会重新发起请求。
    final pages = <Widget>[
      GalleryPage(client: widget.client, onDisconnect: widget.onDisconnect),
      AlbumsPage(client: widget.client, revision: _albumsRevision),
      CinemaPage(client: widget.client),
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
                    for (final d in _destinations)
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
              for (final d in _destinations)
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
