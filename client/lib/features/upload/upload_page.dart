import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/upload/media_source.dart';
import '../../core/upload/upload_models.dart';
import '../../core/upload/upload_queue.dart';
import 'upload_keep_alive.dart';

/// 相册备份页：要权限 → 选片 → 排队上传。
///
/// 页面上有两种模式而不是两块常驻区域：选片时用户关心的是"传哪些"，
/// 传的时候关心的是"还剩多少"。两者同时堆在一屏上，进度会被选择网格挤到
/// 看不见的地方。
class UploadPage extends StatefulWidget {
  const UploadPage({
    super.key,
    required this.queue,
    required this.source,
    this.keepAlive = const NoopUploadKeepAlive(),
    this.onUploaded,
  });

  /// 上传队列。由外面持有 —— 它要活过这个页面，用户切到图库时上传不能停。
  final UploadQueue queue;

  final MediaSource source;
  final UploadKeepAlive keepAlive;

  /// 一批传完后回调，用来让图库页重新拉一次。
  final VoidCallback? onUploaded;

  @override
  State<UploadPage> createState() => _UploadPageState();
}

class _UploadPageState extends State<UploadPage> {
  /// null 表示还在查权限。
  MediaAccess? _access;

  List<MediaCandidate> _candidates = const [];
  bool _loadingList = false;
  bool _preparing = false;
  String? _error;

  final Set<String> _selected = {};

  /// true 时显示队列，false 时显示选择网格。
  bool _queueMode = false;

  bool _keepAliveHeld = false;
  int _reportedSucceeded = 0;

  @override
  void initState() {
    super.initState();
    widget.queue.addListener(_onQueueChanged);
    _reportedSucceeded = widget.queue.succeededCount;
    _bootstrap();
  }

  @override
  void dispose() {
    widget.queue.removeListener(_onQueueChanged);
    // 队列还在跑就不收服务：页面没了不等于上传停了。
    if (_keepAliveHeld && !widget.queue.isRunning) {
      widget.keepAlive.release();
    }
    super.dispose();
  }

  // ------------------------------------------------------------------ 权限

  Future<void> _bootstrap() async {
    // 桌面端没有相册这回事，连权限都不用查 —— 页面会直接显示说明。
    if (!widget.source.supported) return;
    try {
      final access = await widget.source.currentAccess();
      if (!mounted) return;
      setState(() => _access = access);
      if (access == MediaAccess.granted) await _loadList();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _access = MediaAccess.denied;
        _error = '读取相册失败：$e';
      });
    }
  }

  Future<void> _requestAccess() async {
    setState(() => _error = null);
    try {
      final access = await widget.source.requestAccess();
      if (!mounted) return;
      setState(() => _access = access);
      if (access == MediaAccess.granted) await _loadList();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '申请相册权限失败：$e');
    }
  }

  // ------------------------------------------------------------------ 列表

  Future<void> _loadList() async {
    setState(() {
      _loadingList = true;
      _error = null;
    });
    try {
      final list = await widget.source.recent();
      if (!mounted) return;
      setState(() {
        _candidates = list;
        _loadingList = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '读取相册列表失败：$e';
        _loadingList = false;
      });
    }
  }

  // ------------------------------------------------------------------ 上传

  Future<void> _startUpload() async {
    final chosen = _candidates
        .where((c) => _selected.contains(c.id))
        .toList(growable: false);
    if (chosen.isEmpty || _preparing) return;

    setState(() => _preparing = true);
    final items = <PendingUpload>[];
    var skipped = 0;

    for (final c in chosen) {
      try {
        final pending = await widget.source.materialize(c);
        if (pending == null) {
          skipped++;
          continue;
        }
        items.add(pending);
      } catch (_) {
        // 单条读不出来（iCloud 未下载、文件被删）不该让整批失败。
        skipped++;
      }
    }

    if (!mounted) return;
    widget.queue.enqueue(items);
    setState(() {
      _selected.clear();
      _preparing = false;
      _queueMode = true;
    });

    if (skipped > 0) {
      _toast('有 $skipped 项读不出来，已跳过');
    }
    if (items.isNotEmpty) unawaited(widget.queue.start());
  }

  void _onQueueChanged() {
    final q = widget.queue;

    if (q.isRunning) {
      if (!_keepAliveHeld) {
        _keepAliveHeld = true;
        unawaited(widget.keepAlive.acquire(text: _progressText()));
      } else {
        unawaited(widget.keepAlive.update(text: _progressText()));
      }
    } else if (_keepAliveHeld) {
      _keepAliveHeld = false;
      unawaited(widget.keepAlive.release());
      if (q.succeededCount > _reportedSucceeded) {
        _reportedSucceeded = q.succeededCount;
        widget.onUploaded?.call();
      }
    }

    if (mounted) setState(() {});
  }

  String _progressText() {
    final q = widget.queue;
    final done = q.tasks.where((t) => t.isTerminal).length;
    return '${q.succeededCount} / ${q.tasks.length} 已完成'
        '${done < q.tasks.length ? '，继续中' : ''}';
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ------------------------------------------------------------------ 界面

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('备份'),
        actions: [
          if (_queueMode && widget.queue.tasks.isNotEmpty)
            TextButton(
              onPressed: () => setState(() => _queueMode = false),
              child: const Text('继续添加'),
            ),
          if (!_queueMode &&
              widget.source.supported &&
              _access == MediaAccess.granted)
            IconButton(
              tooltip: '刷新',
              onPressed: _loadingList ? null : _loadList,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (!widget.source.supported) return const _UnsupportedHint();
    if (_access == null) return const Center(child: CircularProgressIndicator());
    if (_access != MediaAccess.granted) return _buildPermissionGate();
    if (_queueMode && widget.queue.tasks.isNotEmpty) return _buildQueue();
    return _buildPicker();
  }

  Widget _buildPermissionGate() {
    final theme = Theme.of(context);
    final blocked = _access == MediaAccess.blocked;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              blocked ? Icons.lock_outline : Icons.photo_library_outlined,
              size: 44,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              blocked ? '相册权限已被拒绝' : '需要相册权限',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              blocked
                  ? '系统不会再弹授权框了。请到「设置 → 应用 → 本地媒体中心 → 权限」里打开照片和视频的访问权。'
                  : '备份要把手机里的照片和视频读出来传给媒体中心，需要先获得相册访问权限。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: blocked
                  ? () => widget.source.openSettings()
                  : _requestAccess,
              child: Text(blocked ? '去设置' : '允许访问相册'),
            ),
            if (blocked) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: _bootstrap,
                child: const Text('我已经改好了'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPicker() {
    if (_loadingList && _candidates.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null && _candidates.isEmpty) {
      final theme = Theme.of(context);
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined,
                  size: 40, color: theme.colorScheme.outline),
              const SizedBox(height: 14),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 18),
              OutlinedButton(onPressed: _loadList, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    if (_candidates.isEmpty) {
      final theme = Theme.of(context);
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.photo_outlined,
                  size: 40, color: theme.colorScheme.outline),
              const SizedBox(height: 14),
              const Text('相册里没有可备份的照片或视频'),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(8),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 116,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
            ),
            itemCount: _candidates.length,
            itemBuilder: (context, i) {
              final c = _candidates[i];
              return _CandidateTile(
                candidate: c,
                source: widget.source,
                selected: _selected.contains(c.id),
                onTap: () => setState(() {
                  if (!_selected.remove(c.id)) _selected.add(c.id);
                }),
              );
            },
          ),
        ),
        _buildSelectionBar(),
      ],
    );
  }

  Widget _buildSelectionBar() {
    final theme = Theme.of(context);
    final count = _selected.length;
    final allSelected = count == _candidates.length && _candidates.isNotEmpty;

    return Material(
      elevation: 3,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  count == 0 ? '选择要备份的内容' : '已选 $count 项',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              TextButton(
                onPressed: () => setState(() {
                  if (allSelected) {
                    _selected.clear();
                  } else {
                    _selected
                      ..clear()
                      ..addAll(_candidates.map((c) => c.id));
                  }
                }),
                child: Text(allSelected ? '清空' : '全选'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: count == 0 || _preparing ? null : _startUpload,
                child: _preparing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('开始上传'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQueue() {
    final theme = Theme.of(context);
    final q = widget.queue;
    final tasks = q.tasks;
    final totalBytes = tasks.fold<int>(0, (s, t) => s + t.fileSize);
    final doneBytes = tasks.fold<int>(0, (s, t) => s + t.uploadedBytes);
    final progress = totalBytes <= 0 ? 0.0 : doneBytes / totalBytes;
    final finished = !q.hasPending;

    return Column(
      children: [
        Card(
          margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        finished
                            ? '本批已结束：成功 ${q.succeededCount}，失败 ${q.failedCount}'
                            : q.isPaused
                                ? '已暂停：成功 ${q.succeededCount}，失败 ${q.failedCount}'
                                : '正在上传：成功 ${q.succeededCount}，失败 ${q.failedCount}',
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress.clamp(0.0, 1.0),
                    minHeight: 6,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${_sizeLabel(doneBytes)} / ${_sizeLabel(totalBytes)}'
                  '　共 ${tasks.length} 项',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    if (q.isRunning)
                      OutlinedButton.icon(
                        onPressed: q.pause,
                        icon: const Icon(Icons.pause, size: 18),
                        label: const Text('暂停'),
                      )
                    else if (q.hasPending)
                      FilledButton.icon(
                        onPressed: () => unawaited(q.start()),
                        icon: const Icon(Icons.play_arrow, size: 18),
                        label: const Text('继续'),
                      ),
                    if (q.failedCount > 0 ||
                        tasks.any((t) => t.status == UploadStatus.canceled))
                      OutlinedButton.icon(
                        onPressed: () {
                          q.retryFailed();
                          unawaited(q.start());
                        },
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('重试失败项'),
                      ),
                    if (q.hasPending)
                      TextButton(
                        onPressed: () => unawaited(q.cancelAll()),
                        child: const Text('全部取消'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            itemCount: tasks.length,
            itemBuilder: (context, i) => _TaskTile(
              task: tasks[i],
              onCancel: () => unawaited(q.cancel(tasks[i])),
            ),
          ),
        ),
      ],
    );
  }

  static String _sizeLabel(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}

/// 桌面端的说明页。
class _UnsupportedHint extends StatelessWidget {
  const _UnsupportedHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.computer_outlined,
                size: 40, color: theme.colorScheme.outline),
            const SizedBox(height: 14),
            const Text('桌面端不需要相册备份'),
            const SizedBox(height: 8),
            Text(
              '这个页面是把手机相册里的内容传进媒体中心用的。\n'
              '在电脑上，直接把照片放进已经扫描的目录就行。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}

class _CandidateTile extends StatelessWidget {
  const _CandidateTile({
    required this.candidate,
    required this.source,
    required this.selected,
    required this.onTap,
  });

  final MediaCandidate candidate;
  final MediaSource source;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: theme.colorScheme.surfaceContainerHighest),
            _Thumb(source: source, candidate: candidate),
            if (candidate.isVideo)
              const Positioned(
                left: 4,
                bottom: 4,
                child: Icon(Icons.play_circle_fill,
                    size: 18, color: Colors.white),
              ),
            if (selected)
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: theme.colorScheme.primary,
                    width: 3,
                  ),
                  borderRadius: BorderRadius.circular(8),
                  color: theme.colorScheme.primary.withValues(alpha: 0.18),
                ),
              ),
            Positioned(
              right: 4,
              top: 4,
              child: Icon(
                selected
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked,
                size: 20,
                color: selected
                    ? theme.colorScheme.primary
                    : Colors.white.withValues(alpha: 0.85),
                shadows: const [Shadow(blurRadius: 4, color: Colors.black45)],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单张缩略图。
///
/// 每个格子各自去要缩略图，而不是进页面时批量取：一次备份动辄几百项，
/// 全量取一遍会占掉几十兆内存，而且用户往往只选前几十张。
class _Thumb extends StatelessWidget {
  const _Thumb({required this.source, required this.candidate});

  final MediaSource source;
  final MediaCandidate candidate;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: source.thumbnail(candidate, size: 200),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) {
          return Center(
            child: Icon(
              candidate.isVideo ? Icons.movie_outlined : Icons.image_outlined,
              color: Theme.of(context).colorScheme.outline,
            ),
          );
        }
        return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
      },
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.task, required this.onCancel});

  final UploadTask task;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showBar = task.status == UploadStatus.uploading ||
        task.status == UploadStatus.hashing ||
        task.status == UploadStatus.verifying;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              _iconFor(task.status),
              size: 18,
              color: _colorFor(task.status, theme),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  task.status == UploadStatus.uploading
                      ? '${task.status.label}　${(task.progress * 100).toStringAsFixed(0)}%'
                      : task.status.label,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
                if (task.error != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    task.error!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ],
                if (showBar) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: task.status == UploadStatus.uploading
                          ? task.progress
                          : null,
                      minHeight: 4,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (!task.isTerminal)
            IconButton(
              tooltip: '取消',
              visualDensity: VisualDensity.compact,
              onPressed: onCancel,
              icon: const Icon(Icons.close, size: 18),
            ),
        ],
      ),
    );
  }

  static IconData _iconFor(UploadStatus s) => switch (s) {
    UploadStatus.done => Icons.check_circle,
    UploadStatus.deduped => Icons.bolt,
    UploadStatus.failed => Icons.error_outline,
    UploadStatus.canceled => Icons.remove_circle_outline,
    _ => Icons.arrow_circle_up_outlined,
  };

  static Color _colorFor(UploadStatus s, ThemeData theme) => switch (s) {
    UploadStatus.done => Colors.green,
    UploadStatus.deduped => theme.colorScheme.primary,
    UploadStatus.failed => theme.colorScheme.error,
    UploadStatus.canceled => theme.colorScheme.outline,
    _ => theme.colorScheme.outline,
  };
}
