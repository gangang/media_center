import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import 'folder_picker_page.dart';

/// 服务器管理：查看索引统计、增删扫描目录、触发扫描。
class ManagePage extends StatefulWidget {
  const ManagePage({super.key, required this.client});

  final ApiClient client;

  @override
  State<ManagePage> createState() => _ManagePageState();
}

class _ManagePageState extends State<ManagePage> {
  LibraryStats? _stats;
  List<ScanFolder> _folders = const [];
  ScanState _scan = ScanState.idle;
  String? _error;
  bool _busy = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    try {
      final results = await Future.wait([
        widget.client.stats(),
        widget.client.listFolders(),
        widget.client.scanStatus(),
      ]);
      if (!mounted) return;
      setState(() {
        _stats = results[0] as LibraryStats;
        _folders = results[1] as List<ScanFolder>;
        _scan = results[2] as ScanState;
        _error = null;
      });
      _syncPolling();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 扫描进行中时轮询进度，结束后自动停掉。
  void _syncPolling() {
    if (_scan.running && _poll == null) {
      _poll = Timer.periodic(const Duration(milliseconds: 800), (_) async {
        try {
          final s = await widget.client.scanStatus();
          if (!mounted) return;
          setState(() => _scan = s);
          if (!s.running) {
            _poll?.cancel();
            _poll = null;
            _refresh();
          }
        } on ApiException {
          _poll?.cancel();
          _poll = null;
        }
      });
    } else if (!_scan.running && _poll != null) {
      _poll?.cancel();
      _poll = null;
    }
  }

  /// 打开目录挑选器。
  ///
  /// 以前这里是个手输绝对路径的对话框，手机用户根本不知道服务端上的路径
  /// 长什么样，等于不可用。现在是服务端列目录、客户端导航的挑选器，
  /// 手输降级成页面里的高级入口。
  Future<void> _addFolder() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => FolderPickerPage(
          client: widget.client,
          registeredPaths:
              _folders.where((f) => f.enabled).map((f) => f.path).toSet(),
        ),
      ),
    );
    if (changed == true) await _refresh();
  }

  Future<void> _deleteFolder(ScanFolder folder) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除目录'),
        content: Text(
          '将从索引中移除 ${folder.path} 下的所有条目。'
          '磁盘上的原始文件不会被删除。',
          style: const TextStyle(fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() => widget.client.deleteFolder(folder.id));
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await _refresh();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('服务器管理'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null)
            _Card(
              child: Row(
                children: [
                  Icon(Icons.error_outline,
                      size: 18, color: theme.colorScheme.error),
                  const SizedBox(width: 10),
                  Expanded(child: Text(_error!)),
                ],
              ),
            ),
          if (_stats != null) _StatsCard(stats: _stats!),
          const SizedBox(height: 12),
          _ScanCard(
            scan: _scan,
            busy: _busy,
            onStart: () => _run(() => widget.client.startScan()),
          ),
          const SizedBox(height: 12),
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text('媒体目录',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w500)),
                    ),
                    TextButton.icon(
                      onPressed: _busy ? null : _addFolder,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('添加'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                if (_folders.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      '还没有配置任何目录。添加一个目录后，'
                      '服务端会递归扫描其中的照片与视频。',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                  )
                else
                  ..._folders.map(
                    (f) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: const Icon(Icons.folder_outlined, size: 20),
                      title: Text(f.path,
                          style: const TextStyle(fontSize: 13),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        f.lastScan.isEmpty
                            ? '尚未扫描'
                            : '上次扫描 ${f.lastScan}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: IconButton(
                        tooltip: '移除',
                        onPressed: _busy ? null : () => _deleteFolder(f),
                        icon: const Icon(Icons.remove_circle_outline, size: 20),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (_stats != null && !_stats!.ffmpegAvailable) ...[
            const SizedBox(height: 12),
            _Card(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_outlined,
                      size: 18, color: theme.colorScheme.error),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '服务端未检测到 ffmpeg。视频的元数据与缩略图无法生成，'
                      '照片功能不受影响。',
                      style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatsCard extends StatelessWidget {
  const _StatsCard({required this.stats});

  final LibraryStats stats;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Row(
        children: [
          _Metric(label: '照片', value: '${stats.photos}'),
          _Metric(label: '视频', value: '${stats.videos}'),
          _Metric(label: '目录', value: '${stats.folders}'),
          _Metric(label: '容量', value: _bytes(stats.totalBytes)),
        ],
      ),
    );
  }

  static String _bytes(int n) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = n.toDouble();
    var u = 0;
    while (v >= 1024 && u < units.length - 1) {
      v /= 1024;
      u++;
    }
    return u == 0 ? '${v.toInt()}${units[u]}' : '${v.toStringAsFixed(1)}${units[u]}';
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        children: [
          Text(value,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500)),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(
                  fontSize: 12, color: theme.colorScheme.outline)),
        ],
      ),
    );
  }
}

class _ScanCard extends StatelessWidget {
  const _ScanCard({
    required this.scan,
    required this.busy,
    required this.onStart,
  });

  final ScanState scan;
  final bool busy;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  scan.running ? '正在扫描…' : '扫描索引',
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w500),
                ),
              ),
              FilledButton.tonal(
                onPressed: (busy || scan.running) ? null : onStart,
                child: Text(scan.running ? '进行中' : '立即扫描'),
              ),
            ],
          ),
          if (scan.running) ...[
            const SizedBox(height: 14),
            const LinearProgressIndicator(),
            const SizedBox(height: 10),
          ] else ...[
            const SizedBox(height: 6),
          ],
          Text(
            '已发现 ${scan.filesSeen} · 新增 ${scan.indexed} · '
            '跳过 ${scan.skipped} · 清理 ${scan.removed} · 失败 ${scan.failed}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          if (scan.running && scan.current.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              scan.current,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
          if (scan.errors.isNotEmpty) ...[
            const SizedBox(height: 10),
            ...scan.errors.take(3).map(
                  (e) => Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '· $e',
                      style: TextStyle(
                          fontSize: 12, color: theme.colorScheme.error),
                    ),
                  ),
                ),
          ],
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE8E8E8)),
      ),
      child: child,
    );
  }
}
