import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/models.dart';
import '../features/cinema/video_player_page.dart';
import '../features/gallery/media_viewer_page.dart';

/// 网格中的单个媒体缩略图。
///
/// 图库与相册详情共用它，这样两处的观感、缓存策略（`cacheWidth`）和加载/失败
/// 占位都必然一致——复制一份出来迟早会只改一处。
class MediaThumbnailTile extends StatelessWidget {
  const MediaThumbnailTile({
    super.key,
    required this.item,
    required this.client,
    required this.onTap,
    this.onLongPress,
  });

  final MediaItem item;
  final ApiClient client;
  final VoidCallback onTap;

  /// 可选的长按行为。相册详情用它进入选择模式，图库用它打开「加入相册」。
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(color: const Color(0xFFEFEFEF)),
          Image.network(
            client.thumbnailUrl(item.id),
            headers: client.authHeaders,
            fit: BoxFit.cover,
            // 缩略图按内容哈希寻址、永不变更，可以长期缓存。
            cacheWidth: 320,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return const Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              );
            },
            errorBuilder: (_, _, _) => const Center(
              child: Icon(Icons.broken_image_outlined,
                  size: 22, color: Colors.black26),
            ),
          ),
          if (item.isVideo)
            Positioned(
              left: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.play_arrow, size: 12, color: Colors.white),
                    const SizedBox(width: 2),
                    Text(
                      item.durationLabel,
                      style: const TextStyle(fontSize: 11, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 打开一个媒体项：视频直接进播放器，照片进可左右滑动的查看器。
///
/// 放在共享位置而不是各页面里，是为了让"点开一项"的行为只有一份实现。
/// 这里需要引用两个 feature 页面，属于有意为之：这段逻辑本质上是导航，
/// 而导航的目标就是那些页面。
///
/// [onLoadMore] 是必需的——查看器要靠它在滑到末尾时继续取下一页；
/// 打开视频时用不到，但由调用方统一提供比按类型分叉简单。
///
/// [onChanged] 在查看器里改名/移动/删除成功后触发，让调用方重拉列表。
/// 查看器自己持有的 items 是快照，不刷新就会出现"删了还在列表里"。
Future<void> openMediaItem(
  BuildContext context, {
  required ApiClient client,
  required List<MediaItem> items,
  required int index,
  required Future<void> Function() onLoadMore,
  Future<void> Function()? onChanged,
}) async {
  if (index < 0 || index >= items.length) return;
  final item = items[index];

  if (item.isVideo) {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VideoPlayerPage(client: client, item: item),
      ),
    );
    return;
  }

  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => MediaViewerPage(
        client: client,
        items: items,
        initialIndex: index,
        onLoadMore: onLoadMore,
        onChanged: onChanged,
      ),
    ),
  );
}
