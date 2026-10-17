import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/media_pager.dart';
import '../../widgets/media_grid.dart';
import 'gallery_filter_sheet.dart';
import 'manage_page.dart';
import 'media_actions_sheet.dart';

/// 图库主页面：分页网格 + 类型筛选。
class GalleryPage extends StatefulWidget {
  const GalleryPage({
    super.key,
    required this.client,
    required this.onDisconnect,
    this.revision = 0,
  });

  final ApiClient client;
  final Future<void> Function() onDisconnect;

  /// 外部改动计数器。数值变化即表示「服务端可能多了内容，重新拉一次」。
  ///
  /// 本页常驻在 IndexedStack 里不会重建，手机上传完一批之后若不靠这个信号，
  /// 用户切回图库看到的还是上传前的那一页。
  final int revision;

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  final _scrollController = ScrollController();
  late MediaPager _pager;
  String _filter = ''; // '' | 'photo' | 'video'

  /// 排序与过滤。后端一直支持，这里是客户端第一次把它们接上。
  GalleryFilter _galleryFilter = GalleryFilter.all;

  @override
  void initState() {
    super.initState();
    _pager = _makePager('');
    _scrollController.addListener(_onScroll);
    _refresh();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant GalleryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.revision != oldWidget.revision) _refresh();
  }

  MediaPager _makePager(String type) => MediaPager(
        fetch: (page, pageSize) => widget.client.listMedia(
          type: type,
          page: page,
          pageSize: pageSize,
          sort: _galleryFilter.sort,
          origin: _galleryFilter.origin,
          from: _galleryFilter.from == null ? null : dayParam(_galleryFilter.from!),
          to: _galleryFilter.to == null ? null : nextDayParam(_galleryFilter.to!),
        ),
      );

  Future<void> _openFilterSheet() async {
    final picked = await GalleryFilterSheet.show(context, _galleryFilter);
    if (picked == null || picked == _galleryFilter) return;
    setState(() {
      _galleryFilter = picked;
      _pager = _makePager(_filter);
    });
    await _refresh();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final remaining = _scrollController.position.maxScrollExtent -
        _scrollController.position.pixels;
    // 提前 600px 触发，滚动到底部时数据通常已经就位。
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

  void _setFilter(String value) {
    if (_filter == value) return;
    setState(() {
      _filter = value;
      _pager = _makePager(value);
    });
    _refresh();
  }

  Future<void> _openItem(int index) => openMediaItem(
        context,
        client: widget.client,
        items: _pager.items,
        index: index,
        onLoadMore: _loadMore,
      );

  /// 长按缩略图 → 文件操作面板（加入相册 / 重命名 / 移动）。
  ///
  /// 面板自己负责每个动作的后续步骤；这里只关心"有没有变化"，有就重拉一次
  /// ——改名和移动都会换掉文件名或所在目录，网格必须反映新状态。
  Future<void> _openActions(int index) async {
    await MediaActionsSheet.show(
      context,
      client: widget.client,
      item: _pager.items[index],
      onChanged: _refresh,
    );
  }

  Future<void> _openManage() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ManagePage(client: widget.client)),
    );
    // 管理页可能新增了目录并触发了扫描，回来刷新一次。
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('图库'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _pager.loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '排序与筛选',
            onPressed: _openFilterSheet,
            // 有过滤条件时换成实心图标：不打开面板也知道当前不是默认视图。
            icon: Icon(_galleryFilter.isActive
                ? Icons.filter_alt
                : Icons.filter_alt_outlined),
          ),
          IconButton(
            tooltip: '服务器管理',
            onPressed: _openManage,
            icon: const Icon(Icons.tune),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'disconnect') widget.onDisconnect();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'disconnect', child: Text('断开连接')),
            ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Wrap(
                spacing: 8,
                children: [
                  _FilterChip(
                    label: '全部',
                    selected: _filter == '',
                    onTap: () => _setFilter(''),
                  ),
                  _FilterChip(
                    label: '照片',
                    selected: _filter == 'photo',
                    onTap: () => _setFilter('photo'),
                  ),
                  _FilterChip(
                    label: '视频',
                    selected: _filter == 'video',
                    onTap: () => _setFilter('video'),
                  ),
                ],
              ),
            ),
          ),
        ),
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
              Icon(Icons.photo_outlined,
                  size: 40, color: theme.colorScheme.outline),
              const SizedBox(height: 14),
              const Text('还没有内容'),
              const SizedBox(height: 6),
              Text(
                '在「服务器管理」中添加一个媒体目录',
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
                (context, i) => MediaThumbnailTile(
                  item: _pager.items[i],
                  client: widget.client,
                  onTap: () => _openItem(i),
                  onLongPress: () => _openActions(i),
                ),
                childCount: _pager.items.length,
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
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
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      labelStyle: TextStyle(
        fontSize: 13,
        color: selected ? theme.colorScheme.onSecondaryContainer : null,
      ),
    );
  }
}
