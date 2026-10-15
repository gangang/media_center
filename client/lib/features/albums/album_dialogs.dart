import 'package:flutter/material.dart';

import '../../core/models.dart';

/// 弹出「输入相册名」对话框。
///
/// 返回去掉首尾空白后的名称；用户取消或只输入空白时返回 null。
/// 这里只做「非空」这一层校验，长度上限与重名交给后端判定——
/// 客户端再实现一遍唯一性检查只会和后端规则分叉。
Future<String?> promptAlbumName(
  BuildContext context, {
  String title = '新建相册',
  String initial = '',
  String confirmLabel = '创建',
}) async {
  final result = await showDialog<String>(
    context: context,
    builder: (context) => _NameDialog(
      title: title,
      initial: initial,
      confirmLabel: confirmLabel,
    ),
  );
  if (result == null || result.trim().isEmpty) return null;
  return result.trim();
}

/// 对话框本体。
///
/// 做成 StatefulWidget 只为一件事：让输入框的 controller 由对话框自己持有并在
/// 自己的 dispose 里释放。若改成在 `promptAlbumName` 里 await 返回后立刻 dispose，
/// 就会踩到「A TextEditingController was used after being disposed」——`showDialog`
/// 的 future 在 `Navigator.pop` 那一刻就完成了，而此时退场动画还没播完，
/// TextField 仍在树上。
class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.initial,
    required this.confirmLabel,
  });

  final String title;
  final String initial;
  final String confirmLabel;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        maxLength: 200,
        decoration: const InputDecoration(
          labelText: '相册名称',
          hintText: '例如：2024 夏天',
        ),
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// 删除相册前的确认。
///
/// 文案里明确说明「不会删除文件本身」，因为这正是用户此刻最担心的事。
Future<bool> confirmDeleteAlbum(BuildContext context, Album album) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('删除相册「${album.name}」？'),
      content: Text(
        album.itemCount > 0
            ? '相册里的 ${album.itemCount} 项内容不会被删除，只是不再属于这个相册。'
            : '这个相册是空的。照片与视频文件本身不会受到影响。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  return ok ?? false;
}
