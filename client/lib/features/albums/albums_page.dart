import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import 'album_detail_page.dart';
import 'album_dialogs.dart';

/// 相册列表：封面 + 名称 + 数量，支持新建 / 改名 / 删除。
class AlbumsPage extends StatefulWidget {
  const AlbumsPage({
    super.key,
    required this.client,
    this.revision = 0,
  });

  final ApiClient client;

  /// 外部改动计数器。数值变化即表示「相册内容可能被改过，重新拉一次」。
  ///
  /// 本页常驻在 IndexedStack 里不会重建，靠这个信号才能在图库/查看器改动
  /// 相册之后把数量刷新过来。
  final int revision;

  @override
  State<AlbumsPage> createState() => _AlbumsPageState();
}

class _AlbumsPageState extends State<AlbumsPage> {
  List<Album> _albums = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant AlbumsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.revision != oldWidget.revision) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final albums = await widget.client.listAlbums();
      if (!mounted) return;
      setState(() {
        _albums = albums;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _create() async {
    final name = await promptAlbumName(context);
    if (name == null) return;
    try {
      await widget.client.createAlbum(name);
      await _load();
    } catch (e) {
      _toast('$e');
    }
  }

  Future<void> _rename(Album album) async {
    final name = await promptAlbumName(
      context,
      title: '重命名相册',
      initial: album.name,
      confirmLabel: '保存',
    );
    if (name == null || name == album.name) return;
    try {
      await widget.client.updateAlbum(album.id, name: name);
      await _load();
    } catch (e) {
      _toast('$e');
    }
  }

  Future<void> _delete(Album album) async {
    if (!await confirmDeleteAlbum(context, album)) return;
    try {
      await widget.client.deleteAlbum(album.id);
      await _load();
      _toast('已删除「${album.name}」');
    } catch (e) {
      _toast('$e');
    }
  }

  Future<void> _open(Album album) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AlbumDetailPage(client: widget.client, album: album),
      ),
    );
    // 详情页里可能移出了内容，封面和数量都会变，回来必须重新拉一次。
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('相册'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('新建相册'),
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading && _albums.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null && _albums.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined,
                  size: 40, color: theme.colorScheme.outline),
              const SizedBox(height: 14),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 18),
              OutlinedButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    if (_albums.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.photo_album_outlined,
                  size: 40, color: theme.colorScheme.outline),
              const SizedBox(height: 14),
              const Text('还没有相册'),
              const SizedBox(height: 6),
              Text(
                '点右下角新建，然后在图库里长按内容加入',
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
      onRefresh: _load,
      child: ListView.separated(
        // 给 FAB 留出空间，否则最后一张卡片会被挡住。
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
        itemCount: _albums.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, i) => _AlbumCard(
          album: _albums[i],
          client: widget.client,
          onTap: () => _open(_albums[i]),
          onRename: () => _rename(_albums[i]),
          onDelete: () => _delete(_albums[i]),
        ),
      ),
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({
    required this.album,
    required this.client,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final Album album;
  final ApiClient client;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 76,
                  height: 76,
                  child: album.hasCover
                      ? Image.network(
                          client.albumCoverUrl(album),
                          headers: client.authHeaders,
                          fit: BoxFit.cover,
                          cacheWidth: 200,
                          errorBuilder: (_, _, _) => _placeholder(theme),
                        )
                      : _placeholder(theme),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      album.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      album.itemCount > 0 ? '${album.itemCount} 项' : '空相册',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                    if (album.description.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        album.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '更多',
                onSelected: (v) {
                  if (v == 'rename') onRename();
                  if (v == 'delete') onDelete();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('重命名')),
                  PopupMenuItem(value: 'delete', child: Text('删除相册')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeholder(ThemeData theme) => Container(
        color: theme.colorScheme.surfaceContainerHighest,
        child: Icon(
          Icons.photo_album_outlined,
          color: theme.colorScheme.outline,
        ),
      );
}
