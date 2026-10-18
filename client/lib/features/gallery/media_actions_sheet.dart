import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../albums/album_picker_sheet.dart';

/// 长按媒体后的操作面板：加入相册、重命名、移动。
///
/// 这些操作直接对应服务端的文件管理接口。两条约束决定了交互的样子：
///
/// 1. **只能管理已注册目录里的文件。** 服务端会拒绝其它路径，所以"移动"的
///    目标是从已注册目录里挑，而不是任意路径。
/// 2. **改名必须保留扩展名。** 服务端按扩展名判定媒体类型，改成 `.txt` 会让
///    索引和实际内容不符，所以这里直接把扩展名锁死、只让改主名。
class MediaActionsSheet {
  static Future<void> show(
    BuildContext context, {
    required ApiClient client,
    required MediaItem item,
    required Future<void> Function() onChanged,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        // 四个操作项加标题在小屏手机上已经超过半屏高。直接 Column 会从
        // 「移动到…」开始往下溢出二十多像素——这个溢出是测试先发现的，
        // 但真机一样会撞上。可滚动是必要的，不是保险。
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  dense: true,
                  title: Text(item.fileName,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    item.filePath.isEmpty ? '路径未知' : item.filePath,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.photo_album_outlined),
                  title: const Text('加入相册'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _addToAlbum(context, client: client, item: item);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.drive_file_rename_outline),
                  title: const Text('重命名'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final applied =
                        await rename(context, client: client, item: item);
                    if (applied != null) await onChanged();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.drive_folder_upload_outlined),
                  title: const Text('移动到…'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final moved =
                        await move(context, client: client, item: item);
                    if (moved) await onChanged();
                  },
                ),
                ListTile(
                  leading:
                      Icon(Icons.delete_outline, color: theme.colorScheme.error),
                  title: Text('删除',
                      style: TextStyle(color: theme.colorScheme.error)),
                  subtitle: const Text('删除磁盘文件，不可恢复'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final deleted =
                        await delete(context, client: client, item: item);
                    if (deleted) await onChanged();
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  static Future<void> _addToAlbum(
    BuildContext context, {
    required ApiClient client,
    required MediaItem item,
  }) async {
    Set<int>? memberIds;
    try {
      memberIds = (await client.albumsForMedia(item.id))
          .map((a) => a.id)
          .toSet();
    } catch (_) {
      // 忽略：拿不到既有成员关系时，选择器仍然可以完成「加入」。
    }
    if (!context.mounted) return;
    await AlbumPickerSheet.show(
      context,
      client: client,
      mediaIds: [item.id],
      knownMemberIds: memberIds,
    );
  }

  /// 返回服务端最终采用的文件名；取消或失败返回 null。
  ///
  /// 失败时不关闭对话框、把服务端的原话显示在里面——"扩展名不能改"这类提示
  /// 关掉对话框再弹个 SnackBar，用户早就忘了自己输的是什么。
  static Future<String?> rename(
    BuildContext context, {
    required ApiClient client,
    required MediaItem item,
  }) async {
    final applied = await showDialog<String>(
      context: context,
      builder: (_) => RenameDialog(client: client, item: item),
    );
    if (applied == null || applied.isEmpty || !context.mounted) return null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已重命名为 $applied')),
    );
    return applied;
  }

  /// 删除单个文件。返回 true 表示调用方应该重拉列表。
  static Future<bool> delete(
    BuildContext context, {
    required ApiClient client,
    required MediaItem item,
  }) async {
    return deleteMany(
      context,
      client: client,
      items: [item],
      // 单项也要显示完整路径：分不清删的是手机传上来的副本还是
      // `~/Pictures` 下的原图，就等于让用户盲删。
      confirmTitle: '删除这个文件？',
    );
  }

  /// 批量删除。返回 true 表示至少删成了一个，调用方应该重拉列表。
  ///
  /// 和单项共用一条实现，因为服务端的部分失败语义两者完全一样：
  /// 三个文件里有一个在只读盘上，就该是"两个成功、一个失败并说明原因"。
  static Future<bool> deleteMany(
    BuildContext context, {
    required ApiClient client,
    required List<MediaItem> items,
    String confirmTitle = '删除这些文件？',
  }) async {
    if (items.isEmpty) return false;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => DeleteConfirmDialog(
        title: confirmTitle,
        fileName: items.length == 1 ? items.first.fileName : '共 ${items.length} 个文件',
        filePath: items.length == 1 ? items.first.filePath : '',
        body: items.length == 1
            ? null
            : items.map((i) => i.fileName).take(3).join('、') +
                (items.length > 3 ? ' 等' : ''),
      ),
    );
    if (confirmed != true || !context.mounted) return false;

    try {
      // 一个文件走单项接口：响应里的 file_existed 能区分
      // "文件本来就不在"和"真删掉了"，提示因此更准。
      if (items.length == 1) {
        final outcome = await client.deleteMedia(items.first.id);
        if (!context.mounted) return true;
        _toast(context, outcome.fileExisted == false
            ? '已从媒体库移除（文件此前已不在磁盘上）'
            : '已删除 ${items.first.fileName}');
        return true;
      }

      final result = await client.deleteMediaBatch(items.map((i) => i.id).toList());
      if (!context.mounted) return result.deleted > 0;
      if (result.failed == 0) {
        _toast(context, '已删除 ${result.deleted} 个文件');
      } else {
        final why = result.results
            .where((r) => !r.ok)
            .map((r) => r.error)
            .firstWhere((_) => true, orElse: () => '未知原因');
        _toast(context, '删除 ${result.deleted} 个，${result.failed} 个失败：$why');
      }
      return result.deleted > 0;
    } on ApiException catch (e) {
      if (context.mounted) _toast(context, '删除失败：${e.message}');
      return false;
    }
  }

  static void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  static Future<bool> move(
    BuildContext context, {
    required ApiClient client,
    required MediaItem item,
  }) async {
    final folders = await client.listFolders();
    if (!context.mounted) return false;

    final enabled = folders.where((f) => f.enabled).toList(growable: false)
      ..sort((a, b) => a.path.compareTo(b.path));

    // 当前所在目录不列为目标：移过去等于没动，服务端也会当成无变化。
    final targets =
        enabled.where((f) => !item.filePath.startsWith('${f.path}/')).toList();
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有其它已注册的目录可移动')),
      );
      return false;
    }

    final picked = await showModalBottomSheet<ScanFolder>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('移动到哪个目录',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: targets.length,
                itemBuilder: (_, i) => ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(targets[i].path,
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.pop(ctx, targets[i]),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null || !context.mounted) return false;

    try {
      final result = await client.moveMedia([item.id], picked.id);
      if (!context.mounted) return result.moved > 0;
      final failure = result.results
          .where((r) => !r.ok)
          .map((r) => r.error)
          .firstWhere((_) => true, orElse: () => '');
      if (failure.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('移动失败：$failure')));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已移动到 ${picked.path}')),
        );
      }
      return result.moved > 0;
    } on ApiException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('移动失败：${e.message}')));
      }
      return false;
    }
  }
}

/// 删除确认框。
///
/// 公开理由同 [RenameDialog]：让测试直接驱动真的这一个，而不是复制一份。
/// 确认文案刻意分成两段——文件名是用户认识的那个东西，路径是这次操作真正的
/// 作用对象（删 `library/` 里的副本还是删用户自己的原图，全看这一行）。
class DeleteConfirmDialog extends StatelessWidget {
  const DeleteConfirmDialog({
    super.key,
    required this.title,
    required this.fileName,
    required this.filePath,
    this.body,
  });

  final String title;
  final String fileName;

  /// 服务端返回的绝对路径；空字符串时只显示"路径未知"，不猜。
  final String filePath;

  /// 批量删除时的摘要（前几个文件名），单项时为 null。
  final String? body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(fileName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Text(
            filePath.isEmpty ? '路径未知' : filePath,
            style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
          ),
          if (body != null) ...[
            const SizedBox(height: 6),
            Text(
              body!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 13, color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            '文件将从磁盘上删除，媒体库和相册里的记录一并移除，且无法恢复。',
            style: TextStyle(fontSize: 13, color: theme.colorScheme.error),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.error,
            foregroundColor: theme.colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('删除'),
        ),
      ],
    );
  }
}

/// 重命名对话框。
///
/// 做成 StatefulWidget 只为一件事：让输入框的 controller 由对话框自己持有并在
/// 自己的 dispose 里释放。若改成调用方 await 返回后立刻 dispose，就会踩到
/// 「A TextEditingController was used after being disposed」——`showDialog` 的
/// future 在 `Navigator.pop` 那一刻就完成了，而退场动画还没播完，TextField
/// 仍在树上。
///
/// 公开是为了让 widget 测试直接驱动它：复制一份等价逻辑去测，测的就不是
/// 用户碰到的那个对话框了。
class RenameDialog extends StatefulWidget {
  const RenameDialog({super.key, required this.client, required this.item});

  final ApiClient client;
  final MediaItem item;

  @override
  State<RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<RenameDialog> {
  late final TextEditingController _controller;
  String? _error;
  bool _busy = false;

  /// 扩展名锁死：服务端拒绝改扩展名（类型判定依据它），这里就不让改。
  late final String _ext;
  late final String _stem;

  @override
  void initState() {
    super.initState();
    final name = widget.item.fileName;
    final dot = name.lastIndexOf('.');
    _stem = dot <= 0 ? name : name.substring(0, dot);
    _ext = dot <= 0 ? '' : name.substring(dot);
    _controller = TextEditingController(text: _stem);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final stem = _controller.text.trim();
    if (stem.isEmpty) {
      setState(() => _error = '名称不能为空');
      return;
    }
    final newName = '$stem$_ext';
    if (newName == widget.item.fileName) {
      setState(() => _error = '名称没有变化');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final updated = await widget.client.renameMedia(widget.item.id, name: newName);
      if (!mounted) return;
      // 服务端可能在同名时追加了 " (1)"，以它返回的为准。
      Navigator.pop(context, updated.fileName);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重命名'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _ext.isEmpty ? '只能修改名称部分' : '扩展名 $_ext 不可修改',
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _controller,
            autofocus: true,
            enabled: !_busy,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              suffixText: _ext.isEmpty ? null : _ext,
              errorText: _error,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('确定'),
        ),
      ],
    );
  }
}
