import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../albums/album_picker_sheet.dart';
import '../cinema/video_player_page.dart';
import 'media_actions_sheet.dart';

/// 全屏查看器：左右滑动切换，双指/滚轮缩放。
///
/// 照片就地缩放查看；视频显示封面帧，点击后交给 [VideoPlayerPage] 播放。
class MediaViewerPage extends StatefulWidget {
  const MediaViewerPage({
    super.key,
    required this.client,
    required this.items,
    required this.initialIndex,
    required this.onLoadMore,
    this.onChanged,
  });

  final ApiClient client;
  final List<MediaItem> items;
  final int initialIndex;
  final Future<void> Function() onLoadMore;

  /// 改名/移动/删除发生后调用，让调用方重拉列表。查看器自己不知道外层
  /// 用的是哪个分页器，所以只发信号不自己动。
  final Future<void> Function()? onChanged;

  @override
  State<MediaViewerPage> createState() => _MediaViewerPageState();
}

class _MediaViewerPageState extends State<MediaViewerPage> {
  late final PageController _controller;
  late int _index;
  bool _showChrome = true;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _controller = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onPageChanged(int i) {
    setState(() => _index = i);
    // 快滑到底部时提前取下一页，避免出现空白。
    if (i >= widget.items.length - 3) {
      widget.onLoadMore();
    }
  }

  void _toggleChrome() => setState(() => _showChrome = !_showChrome);

  void _showInfo(MediaItem item) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.fileName,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w500)),
              const SizedBox(height: 16),
              _InfoRow(label: '类型', value: item.isVideo ? '视频' : '照片'),
              _InfoRow(label: '分辨率', value: item.resolution),
              if (item.isVideo)
                _InfoRow(label: '时长', value: item.durationLabel),
              _InfoRow(label: '大小', value: item.fileSizeLabel),
              _InfoRow(
                label: '拍摄时间',
                value: item.takenAtLocal?.toString().split('.').first ??
                    item.takenAt,
              ),
              _InfoRow(label: '格式', value: item.mimeType),
            ],
          ),
        ),
      ),
    );
  }

  /// 把当前这一项加入相册。
  ///
  /// 先查一次既有成员关系，让选择器里的勾选状态反映真实情况。
  Future<void> _addToAlbum(MediaItem item) async {
    Set<int>? memberIds;
    try {
      memberIds = (await widget.client.albumsForMedia(item.id))
          .map((a) => a.id)
          .toSet();
    } catch (_) {
      // 拿不到既有成员关系时，选择器仍可按「未知」完成加入。
    }
    if (!mounted) return;
    await AlbumPickerSheet.show(
      context,
      client: widget.client,
      mediaIds: [item.id],
      knownMemberIds: memberIds,
    );
  }

  /// ⋮ 菜单的三个动作全部复用图库操作面板那一套实现。
  ///
  /// 复制一份到查看器里会立刻分叉：改名对话框的扩展名锁死、删除确认框的
  /// 完整路径显示，两处各改一半就会不一致。所以这里只做薄封装，把
  /// "有变化"抛给外层——查看器自己持有的 items 是快照，不刷新就会出现
  /// "删了还在列表里"。
  Future<void> _onMenu(String value, MediaItem item) async {
    bool changed = false;
    if (value == 'rename') {
      changed = await MediaActionsSheet.rename(
            context,
            client: widget.client,
            item: item,
          ) !=
          null;
    } else if (value == 'move') {
      changed = await MediaActionsSheet.move(
        context,
        client: widget.client,
        item: item,
      );
    } else if (value == 'delete') {
      changed = await MediaActionsSheet.delete(
        context,
        client: widget.client,
        item: item,
      );
    }
    if (changed && widget.onChanged != null) {
      await widget.onChanged!();
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.items[_index.clamp(0, widget.items.length - 1)];

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _toggleChrome,
        child: Stack(
          children: [
            PageView.builder(
              controller: _controller,
              itemCount: widget.items.length,
              onPageChanged: _onPageChanged,
              itemBuilder: (context, i) {
                final it = widget.items[i];
                if (it.isVideo) {
                  return _VideoPlaceholder(
                    item: it,
                    client: widget.client,
                    onPlay: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => VideoPlayerPage(
                          client: widget.client,
                          item: it,
                        ),
                      ),
                    ),
                  );
                }
                return _ZoomableImage(item: it, client: widget.client);
              },
            ),
            if (_showChrome) ...[
              _TopBar(
                index: _index,
                total: widget.items.length,
                item: item,
                onClose: () => Navigator.of(context).maybePop(),
                onInfo: () => _showInfo(item),
                onAddToAlbum: () => _addToAlbum(item),
                onMenu: (value) => _onMenu(value, item),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 可缩放的图片视图。
class _ZoomableImage extends StatelessWidget {
  const _ZoomableImage({required this.item, required this.client});

  final MediaItem item;
  final ApiClient client;

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      minScale: 1,
      maxScale: 6,
      child: Center(
        child: Image.network(
          client.originalUrl(item.id),
          headers: client.authHeaders,
          fit: BoxFit.contain,
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            final expected = progress.expectedTotalBytes;
            final value = expected == null
                ? null
                : progress.cumulativeBytesLoaded / expected;
            return SizedBox(
              width: 160,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(value: value),
                  const SizedBox(height: 12),
                  const Text('加载中…',
                      style: TextStyle(color: Colors.white54, fontSize: 12)),
                ],
              ),
            );
          },
          errorBuilder: (_, _, _) => const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.broken_image_outlined, color: Colors.white38, size: 40),
              SizedBox(height: 12),
              Text('无法加载原图',
                  style: TextStyle(color: Colors.white54, fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 视频封面：显示首帧与元数据，点击进入播放器。
class _VideoPlaceholder extends StatelessWidget {
  const _VideoPlaceholder({
    required this.item,
    required this.client,
    required this.onPlay,
  });

  final MediaItem item;
  final ApiClient client;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPlay,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Center(
            child: Image.network(
              client.thumbnailUrl(item.id),
              headers: client.authHeaders,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.play_circle_fill,
                  size: 64, color: Colors.white.withValues(alpha: 0.9)),
              const SizedBox(height: 18),
              Text(
                '${item.durationLabel} · ${item.resolution}',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 6),
              const Text(
                '点击播放',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.index,
    required this.total,
    required this.item,
    required this.onClose,
    required this.onInfo,
    required this.onAddToAlbum,
    required this.onMenu,
  });

  final int index;
  final int total;
  final MediaItem item;
  final VoidCallback onClose;
  final VoidCallback onInfo;
  final VoidCallback onAddToAlbum;

  /// ⋮ 菜单的动作标识（rename/move/delete）。顶栏自己不知道 ApiClient，
  /// 收菜单的活不干，只把选择抛给上层 State。
  final ValueSetter<String> onMenu;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.55),
              Colors.transparent,
            ],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                IconButton(
                  onPressed: onClose,
                  icon: const Icon(Icons.close, color: Colors.white),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w500),
                      ),
                      Text(
                        '${index + 1} / $total',
                        style: const TextStyle(
                            color: Colors.white60, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '加入相册',
                  onPressed: onAddToAlbum,
                  icon: const Icon(Icons.photo_album_outlined,
                      color: Colors.white),
                ),
                // "正在看这张"是最自然的整理场景，但顶栏放不下四个操作，
                // 所以收进 ⋮。三个界面里只有图库网格原来能改能删。
                PopupMenuButton<String>(
                  tooltip: '更多操作',
                  icon: const Icon(Icons.more_vert, color: Colors.white),
                  color: const Color(0xFF2C2C2E),
                  onSelected: onMenu,
                  itemBuilder: (_) => const [
                    PopupMenuItem<String>(
                      value: 'rename',
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.drive_file_rename_outline,
                            color: Colors.white70),
                        title: Text('重命名',
                            style: TextStyle(color: Colors.white)),
                      ),
                    ),
                    PopupMenuItem<String>(
                      value: 'move',
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.drive_folder_upload_outlined,
                            color: Colors.white70),
                        title: Text('移动到…',
                            style: TextStyle(color: Colors.white)),
                      ),
                    ),
                    PopupMenuItem<String>(
                      value: 'delete',
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.delete_outline,
                            color: Colors.redAccent),
                        title: Text('删除',
                            style: TextStyle(color: Colors.redAccent)),
                      ),
                    ),
                  ],
                ),
                IconButton(
                  onPressed: onInfo,
                  icon: const Icon(Icons.info_outline, color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(label,
                style: TextStyle(
                    fontSize: 13, color: theme.colorScheme.outline)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
