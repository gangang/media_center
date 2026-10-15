import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import 'album_dialogs.dart';

/// 「加入相册」选择器。
///
/// 单张媒体（查看器 / 图库长按）与多张媒体共用。勾选即加入、取消勾选即移出，
/// 每一下都立刻发请求——不做「确定/取消」的批量提交，是因为相册成员关系是
/// 低风险的增量操作，而攒着不提交会让用户不确定自己到底改了什么。
///
/// [knownMemberIds] 传入时勾选状态反映真实的既有成员关系；不传则一律显示未勾选。
/// 多选场景下逐张查询成员关系需要 N 次请求，代价不值得，而未勾选的默认值也不会
/// 造成错误——重复加入在后端是幂等的。
class AlbumPickerSheet extends StatefulWidget {
  const AlbumPickerSheet._({
    required this.client,
    required this.mediaIds,
    required this.knownMemberIds,
    required this.onChanged,
  });

  final ApiClient client;
  final List<int> mediaIds;
  final Set<int> knownMemberIds;
  final VoidCallback onChanged;

  /// 打开选择器。返回期间是否真的改动过成员关系。
  static Future<bool> show(
    BuildContext context, {
    required ApiClient client,
    required List<int> mediaIds,
    Set<int>? knownMemberIds,
  }) async {
    if (mediaIds.isEmpty) return false;
    var changed = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => AlbumPickerSheet._(
        client: client,
        mediaIds: mediaIds,
        knownMemberIds: knownMemberIds ?? const <int>{},
        onChanged: () => changed = true,
      ),
    );
    return changed;
  }

  @override
  State<AlbumPickerSheet> createState() => _AlbumPickerSheetState();
}

class _AlbumPickerSheetState extends State<AlbumPickerSheet> {
  List<Album> _albums = const [];
  late Set<int> _member;
  final Set<int> _busy = {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _member = {...widget.knownMemberIds};
    _load();
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

  Future<void> _toggle(Album album) async {
    if (_busy.contains(album.id)) return;
    final wasMember = _member.contains(album.id);
    setState(() => _busy.add(album.id));
    try {
      if (wasMember) {
        await widget.client.removeAlbumMedia(album.id, widget.mediaIds);
      } else {
        await widget.client.addAlbumMedia(album.id, widget.mediaIds);
      }
      if (!mounted) return;
      setState(() {
        if (wasMember) {
          _member.remove(album.id);
        } else {
          _member.add(album.id);
        }
      });
      widget.onChanged();
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) setState(() => _busy.remove(album.id));
    }
  }

  Future<void> _createAndAdd() async {
    final name = await promptAlbumName(context);
    if (name == null || !mounted) return;
    try {
      final album = await widget.client.createAlbum(name);
      await widget.client.addAlbumMedia(album.id, widget.mediaIds);
      if (!mounted) return;
      setState(() {
        _albums = [..._albums, album];
        _member.add(album.id);
      });
      widget.onChanged();
    } catch (e) {
      _toast('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = widget.mediaIds.length;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 10, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      count == 1 ? '加入相册' : '将 $count 项加入相册',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _createAndAdd,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('新建'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(child: _buildBody(theme)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 14),
            OutlinedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }

    if (_albums.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.photo_album_outlined,
                size: 36, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            const Text('还没有相册'),
            const SizedBox(height: 4),
            Text(
              '点右上角「新建」创建一个',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      itemCount: _albums.length,
      itemBuilder: (context, i) {
        final album = _albums[i];
        final selected = _member.contains(album.id);
        final busy = _busy.contains(album.id);

        return CheckboxListTile(
          value: selected,
          onChanged: busy ? null : (_) => _toggle(album),
          title: Text(album.name),
          subtitle: album.description.isEmpty ? null : Text(album.description),
          secondary: busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
          controlAffinity: ListTileControlAffinity.leading,
        );
      },
    );
  }
}
