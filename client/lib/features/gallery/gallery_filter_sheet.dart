import 'package:flutter/material.dart';

/// 排序选项。取值必须落在后端白名单里（见 `ApiClient.listMedia` 的注释）。
///
/// 后端对未知 sort 值是**静默回落**默认排序的——那种"选了却没变化"的现象
/// 最难查，所以这里枚举而不是让调用方随手传字符串。
const List<GallerySortOption> kGallerySortOptions = [
  GallerySortOption('taken_at_desc', '拍摄时间 · 新→旧'),
  GallerySortOption('taken_at_asc', '拍摄时间 · 旧→新'),
  GallerySortOption('name_asc', '文件名 · A→Z'),
  GallerySortOption('size_desc', '大小 · 大→小'),
  GallerySortOption('size_asc', '大小 · 小→大'),
  GallerySortOption('indexed_desc', '入库时间 · 新→旧'),
];

class GallerySortOption {
  const GallerySortOption(this.value, this.label);

  final String value;
  final String label;
}

/// 图库当前的排序与过滤状态。
@immutable
class GalleryFilter {
  const GalleryFilter({
    this.sort = 'taken_at_desc',
    this.origin = '',
    this.from,
    this.to,
  });

  final String sort;

  /// '' 全部 | 'scan' 本地扫描 | 'upload' 手机上传。
  final String origin;
  final DateTime? from;
  final DateTime? to;

  static const all = GalleryFilter();

  bool get isActive =>
      sort != 'taken_at_desc' ||
      origin != '' ||
      from != null ||
      to != null;

  GalleryFilter copyWith({
    String? sort,
    String? origin,
    DateTime? from,
    DateTime? to,
    bool clearRange = false,
  }) {
    return GalleryFilter(
      sort: sort ?? this.sort,
      origin: origin ?? this.origin,
      from: clearRange ? null : (from ?? this.from),
      to: clearRange ? null : (to ?? this.to),
    );
  }

  /// 时间范围的人话描述。
  String get rangeLabel {
    if (from == null && to == null) return '不限';
    if (from != null && to != null) {
      return '${dayParam(from!)} ~ ${dayParam(to!)}';
    }
    return from != null ? '${dayParam(from!)} 起' : '至 ${dayParam(to!)}';
  }

  static String originLabel(String origin) {
    switch (origin) {
      case 'scan':
        return '本地扫描';
      case 'upload':
        return '手机上传';
      default:
        return '全部';
    }
  }
}

/// `YYYY-MM-DD`。
String dayParam(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

/// 结束日期要传"次日"，不能传当天。
///
/// 服务端按字符串比较 RFC3339 的 `taken_at`。同前缀下字符串越长字典序越大，
/// 所以 `"2026-10-17T12:00:00+08:00" <= "2026-10-17"` 不成立——直接传当天
/// 会把结束那天的照片整批切掉，而且看不出是哪里错了。传次日恰好含当天，
/// 也不依赖服务端的时区。
String nextDayParam(DateTime end) {
  final d =
      DateTime(end.year, end.month, end.day).add(const Duration(days: 1));
  return dayParam(d);
}

/// 排序与过滤面板。
///
/// 这些能力后端早就有了，只是客户端一直没接上。做成一个底部面板而不是铺开
/// 一排控件：图库的第一用途是浏览，筛选是低频动作，不该常驻屏幕。
class GalleryFilterSheet extends StatefulWidget {
  const GalleryFilterSheet({super.key, required this.initial});

  final GalleryFilter initial;

  /// 打开面板，返回用户选定的过滤条件（取消返回 null）。
  static Future<GalleryFilter?> show(
    BuildContext context,
    GalleryFilter initial,
  ) {
    return showModalBottomSheet<GalleryFilter>(
      context: context,
      showDragHandle: true,
      // 内容比半屏高（两排 chip + 日期 + 按钮），小屏手机上更明显。
      // 不限高会溢出，全高 + 内部滚动才能既放得下又不需要用户拖。
      isScrollControlled: true,
      builder: (_) => GalleryFilterSheet(initial: initial),
    );
  }

  @override
  State<GalleryFilterSheet> createState() => _GalleryFilterSheetState();
}

class _GalleryFilterSheetState extends State<GalleryFilterSheet> {
  late GalleryFilter _draft;

  @override
  void initState() {
    super.initState();
    _draft = widget.initial;
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(1990),
      lastDate: now.add(const Duration(days: 1)),
      initialDateRange: _draft.from != null && _draft.to != null
          ? DateTimeRange(start: _draft.from!, end: _draft.to!)
          : null,
    );
    if (picked == null) return;
    setState(() {
      _draft = _draft.copyWith(from: picked.start, to: picked.end);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('排序与筛选', style: theme.textTheme.titleMedium),
              const SizedBox(height: 14),
              Text('排序', style: theme.textTheme.labelLarge),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final opt in kGallerySortOptions)
                    ChoiceChip(
                      label: Text(opt.label,
                          style: const TextStyle(fontSize: 13)),
                      selected: _draft.sort == opt.value,
                      onSelected: (_) => setState(
                          () => _draft = _draft.copyWith(sort: opt.value)),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text('来源', style: theme.textTheme.labelLarge),
              Wrap(
                spacing: 8,
                children: [
                  for (final origin in const ['', 'upload', 'scan'])
                    ChoiceChip(
                      label: Text(GalleryFilter.originLabel(origin),
                          style: const TextStyle(fontSize: 13)),
                      selected: _draft.origin == origin,
                      onSelected: (_) => setState(
                          () => _draft = _draft.copyWith(origin: origin)),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text('拍摄时间', style: theme.textTheme.labelLarge),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.date_range_outlined),
                title: Text(_draft.rangeLabel,
                    style: const TextStyle(fontSize: 14)),
                trailing: _draft.from != null || _draft.to != null
                    ? TextButton(
                        onPressed: () => setState(
                            () => _draft = _draft.copyWith(clearRange: true)),
                        child: const Text('清除'),
                      )
                    : null,
                onTap: _pickRange,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton(
                    onPressed: _draft.isActive
                        ? () => Navigator.pop(context, GalleryFilter.all)
                        : null,
                    child: const Text('重置'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, _draft),
                    child: const Text('完成'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
