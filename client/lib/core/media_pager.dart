import 'models.dart';

/// 分页加载媒体列表。
///
/// 把「翻页、累积、判断是否还有更多」这部分纯逻辑从 widget 里抽出来：
/// 图库网格与影院列表可以共用同一份实现，而且这部分能脱离 Flutter 单独测试。
///
/// 调用方负责在 await 之后调用 setState —— 这里刻意不依赖任何 Flutter 类型。
class MediaPager {
  MediaPager({
    required this.fetch,
    this.pageSize = 60,
  });

  /// 取第 [page] 页（从 1 开始计数）。
  final Future<MediaPage> Function(int page, int pageSize) fetch;
  final int pageSize;

  final List<MediaItem> items = [];

  int total = 0;
  int page = 0;
  bool loading = false;
  bool loadingMore = false;
  String? error;

  bool get hasMore => items.length < total;
  bool get isEmpty => items.isEmpty;

  /// 重新从第一页加载。
  ///
  /// 成功后才替换列表，避免刷新时先闪一下空白。
  Future<void> reload() async {
    if (loading) return;
    loading = true;
    error = null;
    try {
      final result = await fetch(1, pageSize);
      items
        ..clear()
        ..addAll(result.items);
      total = result.total;
      page = result.page;
    } catch (e) {
      error = _describe(e);
    } finally {
      loading = false;
    }
  }

  /// 加载下一页。已经在加载、或已经没有更多数据时直接返回。
  Future<void> loadMore() async {
    if (loading || loadingMore || !hasMore) return;
    loadingMore = true;
    try {
      final result = await fetch(page + 1, pageSize);
      // 后端可能返回重复项（例如加载期间有文件被重新索引），按 id 去重。
      final seen = items.map((e) => e.id).toSet();
      items.addAll(result.items.where((e) => !seen.contains(e.id)));
      total = result.total;
      page = result.page;
    } catch (e) {
      error = _describe(e);
    } finally {
      loadingMore = false;
    }
  }

  static String _describe(Object e) {
    // ApiException 的 message 已经是可直接展示的文案；其他异常退化为字符串。
    final s = e.toString();
    return s.startsWith('Exception: ') ? s.substring(11) : s;
  }
}
