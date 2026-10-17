import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_center_client/core/models.dart';
import 'package:media_center_client/features/gallery/gallery_filter_sheet.dart';

/// 排序与筛选的测试。
///
/// 重点在那两个日期函数上：`to` 传当天会把结束那天的照片整批切掉
/// （服务端按字符串比较 RFC3339），这种 bug 在界面上表现为"筛了却少东西"，
/// 不钉住就会复发。

void main() {
  group('dayParam / nextDayParam', () {
    test('补零到两位，否则拼不出服务端能比较的日期串', () {
      expect(dayParam(DateTime(2026, 1, 5)), '2026-01-05');
    });

    test('结束日期传次日，当天完整保留', () {
      expect(nextDayParam(DateTime(2026, 10, 17)), '2026-10-18');
    });

    test('跨月与跨年都进一位', () {
      expect(nextDayParam(DateTime(2026, 1, 31)), '2026-02-01');
      expect(nextDayParam(DateTime(2026, 12, 31)), '2027-01-01');
    });
  });

  group('GalleryFilter', () {
    test('默认状态不算激活，图标才不会常亮', () {
      expect(GalleryFilter.all.isActive, false);
    });

    test('任一条件变化即激活', () {
      expect(GalleryFilter.all.copyWith(sort: 'size_desc').isActive, true);
      expect(GalleryFilter.all.copyWith(origin: 'upload').isActive, true);
      expect(
        GalleryFilter.all
            .copyWith(from: DateTime(2026), to: DateTime(2026))
            .isActive,
        true,
      );
    });

    test('clearRange 只清时间范围，不动排序和来源', () {
      final f = GalleryFilter(
        sort: 'name_asc',
        origin: 'scan',
        from: DateTime(2026, 1, 1),
        to: DateTime(2026, 3, 31),
      );
      final cleared = f.copyWith(clearRange: true);
      expect(cleared.from, isNull);
      expect(cleared.to, isNull);
      expect(cleared.sort, 'name_asc');
      expect(cleared.origin, 'scan');
    });

    test('时间范围的人话描述', () {
      expect(GalleryFilter.all.rangeLabel, '不限');
      expect(
        GalleryFilter(from: DateTime(2026, 1, 1)).rangeLabel,
        '2026-01-01 起',
      );
      expect(
        GalleryFilter(to: DateTime(2026, 3, 31)).rangeLabel,
        '至 2026-03-31',
      );
      expect(
        GalleryFilter(
          from: DateTime(2026, 1, 1),
          to: DateTime(2026, 3, 31),
        ).rangeLabel,
        '2026-01-01 ~ 2026-03-31',
      );
    });
  });

  group('GalleryFilterSheet', () {
    testWidgets('选排序后完成，返回选中的条件', (tester) async {
      GalleryFilter? result;

      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                result = await GalleryFilterSheet.show(ctx, GalleryFilter.all);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('大小 · 大→小'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.sort, 'size_desc');
      expect(result!.origin, '');
    });

    testWidgets('重置回到默认条件', (tester) async {
      GalleryFilter? result;

      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                result = await GalleryFilterSheet.show(
                  ctx,
                  const GalleryFilter(sort: 'name_asc', origin: 'upload'),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('重置'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.isActive, false);
    });
  });

  group('MediaItem 新字段', () {
    test('解析 file_path 与 origin', () {
      final item = MediaItem.fromJson(const {
        'id': 7,
        'file_name': 'a.jpg',
        'media_type': 'photo',
        'file_size': 10,
        'file_path': '/library/2026/10/a.jpg',
        'origin': 'upload',
      });
      expect(item.filePath, '/library/2026/10/a.jpg');
      expect(item.origin, 'upload');
    });

    test('老服务端没有这两个字段时退化为空串，不炸', () {
      final item = MediaItem.fromJson(const {
        'id': 7,
        'file_name': 'a.jpg',
        'media_type': 'photo',
        'file_size': 10,
      });
      expect(item.filePath, '');
      expect(item.origin, '');
    });
  });
}
