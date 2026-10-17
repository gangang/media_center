import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';

/// 面包屑的一项。
@immutable
class Breadcrumb {
  const Breadcrumb({required this.label, required this.path});

  final String label;
  final String path;
}

/// 把绝对路径拆成面包屑。
///
/// 按分隔符从尾部一段段切，前缀用原串拼回去——这样每一级的 [path] 都与
/// 服务端返回的目录路径逐字节相同，"已添加"角标和导航链的判断才不会因为
/// 一个尾斜杠或盘符大小写而失配。unix 的根 `/` 单独补一颗，否则没有回根的入口。
List<Breadcrumb> breadcrumbsFor(String path) {
  final sep = RegExp(r'[\\/]').firstMatch(path)?.group(0) ?? '/';

  var p = path;
  while (p.length > 1 && (p.endsWith('/') || p.endsWith('\\'))) {
    p = p.substring(0, p.length - 1);
  }
  if (p.isEmpty) return const [Breadcrumb(label: '/', path: '/')];

  final out = <Breadcrumb>[];
  // 绝对路径的第一段要带上分隔符：'/Users' 而不是 'Users'。少了这个前导，
  // 面包屑点出来的路径和服务端返回的就不相等，"已添加"角标会失配。
  final absolute = p.startsWith('/') || p.startsWith('\\');
  var prefix = absolute ? sep : '';
  for (final seg in p.split(RegExp(r'[\\/]'))) {
    if (seg.isEmpty) continue;
    if (prefix.isEmpty) {
      prefix = seg;
    } else if (prefix.endsWith(sep)) {
      prefix = '$prefix$seg';
    } else {
      prefix = '$prefix$sep$seg';
    }
    out.add(Breadcrumb(label: seg, path: prefix));
  }
  if (out.isEmpty) return [Breadcrumb(label: p, path: p)];

  if (p.startsWith('/') || p.startsWith('\\')) {
    out.insert(0, Breadcrumb(label: sep, path: sep));
  }
  return out;
}

/// 本次导航走过的目录链。
///
/// 唯一目的是防符号链接成环：指向祖先进目录的软链接，一路点进去可以无限循环。
/// 规则：要去的路径已在链里，就截断到那一级（面包屑跳转本来就是这个行为），
/// 不开新级。于是链的深度永远不超过本次走过的不同目录数，环自然被截断，
/// 而正常的"往上走"体验不受影响。
class NavChain {
  final List<String> _chain = <String>[];

  String? get current => _chain.isEmpty ? null : _chain.last;
  bool get canGoUp => _chain.length > 1;
  int get depth => _chain.length;

  /// 进入 [path]；返回它在链中的位置（-1 表示新开一级）。
  int enter(String path) {
    final at = _chain.indexOf(path);
    if (at >= 0) {
      _chain.removeRange(at + 1, _chain.length);
      return at;
    }
    _chain.add(path);
    return -1;
  }
}

/// 添加媒体目录的挑选器。
///
/// 它替代了原来那个"手输绝对路径"的输入框——手机用户不可能知道服务端主机上
/// 的路径长什么样，那个输入框对手机端等于不存在。现在是服务端列目录、客户端
/// 导航：面包屑 + 快捷入口 + 目录列表，底部一键添加。
///
/// 浏览只是导航，**不构成授权**。授权发生在用户点"添加当前目录"、目录被注册
/// 进 `scan_folders` 的那一刻；文件管理（改名/移动/删除）也只对已注册目录生效。
class FolderPickerPage extends StatefulWidget {
  const FolderPickerPage({
    super.key,
    required this.client,
    this.registeredPaths = const <String>{},
  });

  final ApiClient client;

  /// 已注册的目录路径，用于给列表打"已添加"角标。
  final Set<String> registeredPaths;

  @override
  State<FolderPickerPage> createState() => _FolderPickerPageState();
}

class _FolderPickerPageState extends State<FolderPickerPage> {
  ServerBrowse? _browse;
  bool _loading = true;
  String? _error;
  bool _adding = false;
  final NavChain _chain = NavChain();

  @override
  void initState() {
    super.initState();
    // 空路径 = 服务端主目录，用户第一眼看到的就是自己最可能想要的地方。
    _load('');
  }

  Future<void> _load(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final b = await widget.client.browseDirectories(path);
      if (!mounted) return;
      // 用服务端规范化过的路径入链，面包屑才能和列表里的路径逐字节对齐。
      _chain.enter(b.path);
      setState(() {
        _browse = b;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  Future<void> _goUp() async {
    final parent = _browse?.parent ?? '';
    if (parent.isEmpty) return;
    await _load(parent);
  }

  Future<void> _addCurrent() async {
    final path = _browse?.path ?? '';
    if (path.isEmpty) return;
    setState(() => _adding = true);
    try {
      await widget.client.addFolder(path);
      if (!mounted) return;
      // true 告诉管理页有变化，要重新拉目录列表（服务端已自动开始扫描）。
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _adding = false);
      _toast(e.message);
    }
  }

  Future<void> _manualInput() async {
    final path = await showDialog<String>(
      context: context,
      builder: (_) => const _PathDialog(),
    );
    if (path == null || path.isEmpty || !mounted) return;
    // 直接走添加，和改造前的手输路径行为保持一致——这是给知道确切路径的
    // 用户和开发者留的高级入口，也是"目录太大被截断"时的退路。
    setState(() => _adding = true);
    try {
      await widget.client.addFolder(path);
      if (!mounted) return;
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _adding = false);
      _toast(e.message);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final browse = _browse;

    return Scaffold(
      appBar: AppBar(
        title: const Text('添加媒体目录'),
        actions: [
          if (browse != null && _chain.canGoUp)
            IconButton(
              tooltip: '上一级',
              onPressed: _loading ? null : _goUp,
              icon: const Icon(Icons.arrow_upward),
            ),
        ],
      ),
      body: _loading && browse == null
          ? const Center(child: CircularProgressIndicator())
          : browse == null
              ? _ErrorView(message: _error ?? '无法读取服务端目录', onRetry: () => _load(''))
              : Column(
                  children: [
                    _BreadcrumbBar(
                      breadcrumbs: breadcrumbsFor(browse.path),
                      currentPath: browse.path,
                      onTap: _load,
                    ),
                    if (browse.shortcuts.isNotEmpty)
                      _ShortcutRow(
                        shortcuts: browse.shortcuts,
                        onTap: _load,
                      ),
                    if (browse.truncated)
                      Container(
                        width: double.infinity,
                        color: theme.colorScheme.secondaryContainer,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        child: Text(
                          '这个目录下的子目录超过 500 个，只显示了前一部分。'
                          '请用右下角"手动输入"直接填写路径。',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSecondaryContainer),
                        ),
                      ),
                    if (_error != null)
                      Container(
                        width: double.infinity,
                        color: theme.colorScheme.errorContainer,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        child: Text(
                          _error!,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onErrorContainer),
                        ),
                      ),
                    Expanded(
                      child: _loading
                          ? const Center(child: CircularProgressIndicator())
                          : browse.entries.isEmpty
                              ? _EmptyHint(path: browse.path)
                              : ListView.builder(
                                  itemCount: browse.entries.length,
                                  itemBuilder: (_, i) {
                                    final e = browse.entries[i];
                                    final registered = widget
                                        .registeredPaths
                                        .contains(e.path);
                                    return ListTile(
                                      leading: Icon(
                                        Icons.folder_outlined,
                                        color: e.hidden
                                            ? theme.colorScheme.outline
                                            : null,
                                      ),
                                      title: Text(
                                        e.name,
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: e.hidden
                                              ? theme.colorScheme.outline
                                              : null,
                                        ),
                                      ),
                                      trailing: registered
                                          ? Text('已添加',
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                      color: theme
                                                          .colorScheme.outline))
                                          : null,
                                      onTap: _loading
                                          ? null
                                          : () => _load(e.path),
                                    );
                                  },
                                ),
                    ),
                  ],
                ),
      bottomNavigationBar: browse == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      browse.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _adding ? null : _addCurrent,
                            icon: const Icon(Icons.add, size: 18),
                            label: Text(
                              widget.registeredPaths.contains(browse.path)
                                  ? '重新扫描'
                                  : '添加当前目录',
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: _adding ? null : _manualInput,
                          child: const Text('手动输入'),
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

class _BreadcrumbBar extends StatelessWidget {
  const _BreadcrumbBar({
    required this.breadcrumbs,
    required this.currentPath,
    required this.onTap,
  });

  final List<Breadcrumb> breadcrumbs;
  final String currentPath;
  final Future<void> Function(String) onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: breadcrumbs.length,
        separatorBuilder: (_, _) => Icon(Icons.chevron_right,
            size: 16, color: theme.colorScheme.outline),
        itemBuilder: (_, i) {
          final c = breadcrumbs[i];
          final isLast = c.path == currentPath;
          return Center(
            child: TextButton(
              onPressed: isLast ? null : () => onTap(c.path),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
              ),
              child: Text(
                c.label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isLast ? FontWeight.w600 : FontWeight.normal,
                  color: isLast ? null : theme.colorScheme.primary,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({required this.shortcuts, required this.onTap});

  final List<ServerDirShortcut> shortcuts;
  final Future<void> Function(String) onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final s in shortcuts)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ActionChip(
                label: Text(s.label, style: const TextStyle(fontSize: 13)),
                onPressed: () => onTap(s.path),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open_outlined,
                size: 40, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              '这个目录下没有子目录。\n'
              '如果照片视频就直接放在这里，点"添加当前目录"即可。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                size: 40, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(height: 1.6)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

/// 手动输入路径的对话框。
///
/// 做成 StatefulWidget 只为一件事：让输入框的 controller 由对话框自己持有并在
/// 自己的 dispose 里释放。若改成调用方 await 返回后立刻 dispose，就会踩到
/// 「A TextEditingController was used after being disposed」——`showDialog` 的
/// future 在 `Navigator.pop` 那一刻就完成了，而退场动画还没播完，TextField
/// 仍在树上。
class _PathDialog extends StatefulWidget {
  const _PathDialog();

  @override
  State<_PathDialog> createState() => _PathDialogState();
}

class _PathDialogState extends State<_PathDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('手动输入路径'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '填写服务端主机上的绝对路径。添加后会自动开始扫描。',
            style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.outline),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '/Users/you/Pictures',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('添加'),
        ),
      ],
    );
  }
}
