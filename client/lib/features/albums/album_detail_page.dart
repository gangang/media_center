import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/media_pager.dart';
import '../../core/models.dart';
import '../../widgets/media_grid.dart';

/// 相册详情：网格展示相册内容，支持多选移出。
///
/// 移出用「选择模式」而不是每张一个菜单，是因为相册最常见的操作是
/// 「这几张不该放进来」——逐个点开菜单移出的成本高得多。
class AlbumDetailPage extends StatefulWidget {
  const AlbumDetailPage({
    super.key,
    required this.client,
    required this.album,
  });

  final ApiClient client;
  final Album album;

  @override
  State<AlbumDetailPage> createState() => _AlbumDetailPageState();
}

class _AlbumDetailPageState extends State<AlbumDetailPage> {
  final _scrollController = ScrollController();
  late MediaPager _pager;
  late Album _album;

  /// 选择模式下被勾选的媒体 id。用 id 而不是下标：加载更多会让下标失效。
  final Set<int> _selected = {};
  bool _selecting = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _album = widget.album;
    _pager = _makePager();
    _scrollController.addListener(_onScroll);
    _refresh();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  MediaPager _makePager() => MediaPager(
        fetch: (page, pageSize) => widget.client.listAlbumMedia(
          _album.id,
          page: page,
          pageSize: pageSize,
        ),
      );

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final remaining = _scrollController.position.maxScrollExtent -
        _scrollController.position.pixels;
    if (remaining < 600) _loadMore();
  }

  Future<void> _refresh() async {
    await _pager.reload();
    if (mounted) setState(() {});
  }

  Future<void> _loadMore() async {
    if (!_pager.hasMore || _pager.loadingMore || _pager.loading) return;
    await _pager.loadMore();
    if (mounted) setState(() {});
  }

  Future<void> _reloadAlbum() async {
    try {
      final album = await widget.client.getAlbum(_album.id);
      if (mounted) setState(() => _album = album);
    } catch (_) {
      // 详情页的标题/计数刷新失败不该打断用户，列表本身仍然可用。
    }
  }

  void _enterSelection(int index) {
    setState(() {
      _selecting = true;
      _selected.add(_pager.items[index].id);
    });
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _toggleAt(int index) {
    final id = _pager.items[index].id;
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
      if (_selected.isEmpty) _selecting = false;
    });
  }

  Future<void> _onTap(int index) async {
    if (_selecting) {
      _toggleAt(index);
      return;
    }
    await openMediaItem(
      context,
      client: widget.client,
      items: _pager.items,
      index: index,
      onLoadMore: _loadMore,
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _removeSelected() async {
    final ids = _selected.toList();
    if (ids.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final removed = await widget.client.removeAlbumMedia(_album.id, ids);
      if (!mounted) return;
      _exitSelection();
      await _refresh();
      await _reloadAlbum();
      _toast(removed > 0 ? '已移出 $removed 项' : '这些内容已不在相册中');
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: _selecting
          ? AppBar(
              leading: IconButton(
                tooltip: '取消选择',
                icon: const Icon(Icons.close),
                onPressed: _exitSelection,
              ),
              title: Text('已选 ${_selected.length} 项'),
              actions: [
                IconButton(
                  tooltip: '移出相册',
                  onPressed:
                      _selected.isEmpty || _busy ? null : _removeSelected,
                  icon: const Icon(Icons.playlist_remove),
                ),
              ],
            )
          : AppBar(
              title: Text(_album.name),
              actions: [
                IconButton(
                  tooltip: '刷新',
                  onPressed: _pager.loading ? null : _refresh,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_pager.loading && _pager.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_pager.error != null && _pager.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined,
                  size: 40, color: theme.colorScheme.outline),
              const SizedBox(height: 14),
              Text(_pager.error!, textAlign: TextAlign.center),
              const SizedBox(height: 18),
              OutlinedButton(onPressed: _refresh, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    if (_pager.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.photo_album_outlined,
                  size: 40, color: theme.colorScheme.outline),
              const SizedBox(height: 14),
              const Text('这个相册还是空的'),
              const SizedBox(height: 6),
              Text(
                '在图库里长按一项，或在查看器里点「加入相册」',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: CustomScrollView(
        controller: _scrollController,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.all(3),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                mainAxisSpacing: 3,
                crossAxisSpacing: 3,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) => _buildTile(i),
                childCount: _pager.items.length,
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text(
                  '共 ${_album.itemCount} 项',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTile(int i) {
    final item = _pager.items[i];
    final selected = _selected.contains(item.id);

    return GestureDetector(
      onLongPress: _selecting ? null : () => _enterSelection(i),
      child: Stack(
        fit: StackFit.expand,
        children: [
          MediaThumbnailTile(
            item: item,
            client: widget.client,
            onTap: () => _onTap(i),
          ),
          if (_selecting)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: selected
                      ? Colors.blue.withValues(alpha: 0.35)
                      : Colors.transparent,
                  alignment: Alignment.topRight,
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: selected ? Colors.white : Colors.white70,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
