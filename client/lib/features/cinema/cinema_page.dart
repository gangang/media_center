import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/media_pager.dart';
import '../../core/models.dart';
import 'video_player_page.dart';

/// 影院：以列表形式浏览视频，点击即播放。
///
/// 与图库的区别在于信息密度——视频需要时长、分辨率、编码这些信息，
/// 网格里的一个角标放不下。
class CinemaPage extends StatefulWidget {
  const CinemaPage({super.key, required this.client});

  final ApiClient client;

  @override
  State<CinemaPage> createState() => _CinemaPageState();
}

class _CinemaPageState extends State<CinemaPage> {
  final _scrollController = ScrollController();
  late final MediaPager _pager;

  @override
  void initState() {
    super.initState();
    _pager = MediaPager(
      fetch: (page, pageSize) => widget.client.listMedia(
        type: 'video',
        page: page,
        pageSize: pageSize,
      ),
    );
    _scrollController.addListener(_onScroll);
    _refresh();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final remaining = _scrollController.position.maxScrollExtent -
        _scrollController.position.pixels;
    if (remaining < 600) _loadMore();
  }

  Future<void> _refresh() async {
    setState(() {});
    await _pager.reload();
    if (mounted) setState(() {});
  }

  Future<void> _loadMore() async {
    if (!_pager.hasMore || _pager.loadingMore || _pager.loading) return;
    await _pager.loadMore();
    if (mounted) setState(() {});
  }

  Future<void> _play(MediaItem item) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VideoPlayerPage(client: widget.client, item: item),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('影院'),
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
              Icon(Icons.movie_outlined,
                  size: 40, color: theme.colorScheme.outline),
              const SizedBox(height: 14),
              const Text('还没有视频'),
              const SizedBox(height: 6),
              Text(
                '媒体目录中的视频会出现在这里',
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
      child: ListView.separated(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _pager.items.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: 4),
        itemBuilder: (context, i) {
          if (i == _pager.items.length) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: _pager.loadingMore
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        '已加载 ${_pager.items.length} / ${_pager.total}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline),
                      ),
              ),
            );
          }
          final item = _pager.items[i];
          return _VideoRow(
            item: item,
            client: widget.client,
            onTap: () => _play(item),
          );
        },
      ),
    );
  }
}

class _VideoRow extends StatelessWidget {
  const _VideoRow({
    required this.item,
    required this.client,
    required this.onTap,
  });

  final MediaItem item;
  final ApiClient client;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final meta = [
      item.durationLabel,
      item.resolution,
      if (item.videoCodec.isNotEmpty) item.videoCodec.toUpperCase(),
      if (item.audioCodec.isNotEmpty) item.audioCodec.toUpperCase(),
    ].where((s) => s.isNotEmpty).join(' · ');

    final taken = item.takenAtLocal;
    final takenLabel = taken == null
        ? ''
        : '${taken.year}-${taken.month.toString().padLeft(2, '0')}-'
            '${taken.day.toString().padLeft(2, '0')}';

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 168,
                height: 94,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(color: const Color(0xFFEFEFEF)),
                    Image.network(
                      client.thumbnailUrl(item.id),
                      headers: client.authHeaders,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const Center(
                        child: Icon(Icons.broken_image_outlined,
                            size: 22, color: Colors.black26),
                      ),
                    ),
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          item.durationLabel,
                          style: const TextStyle(
                              fontSize: 11, color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.fileName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    meta,
                    style: TextStyle(
                        fontSize: 12, color: theme.colorScheme.outline),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$takenLabel · ${item.fileSizeLabel}',
                    style: TextStyle(
                        fontSize: 12, color: theme.colorScheme.outline),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
