import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';

/// 视频播放页。
///
/// 播放策略是「原文件直连 + HTTP Range」：后端不转码，客户端把
/// `http://host/api/media/{id}/original` 交给 libmpv，拖动进度时由 Range
/// 请求按需拉取。因此这里的实现重点是三件事——把令牌带给播放器、
/// 暴露音轨/字幕轨切换、以及把播放失败的原因如实显示出来。
class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({
    super.key,
    required this.client,
    required this.item,
  });

  final ApiClient client;
  final MediaItem item;

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  late final Player _player;
  late final VideoController _controller;
  final List<StreamSubscription<dynamic>> _subs = [];

  Tracks _tracks = const Tracks();
  Track _current = const Track();
  bool _buffering = true;
  bool _playing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _subscribe();
    unawaited(_open());
  }

  void _subscribe() {
    _subs.add(_player.stream.tracks.listen((t) {
      if (mounted) setState(() => _tracks = t);
    }));
    _subs.add(_player.stream.track.listen((t) {
      if (mounted) setState(() => _current = t);
    }));
    _subs.add(_player.stream.buffering.listen((b) {
      if (mounted) setState(() => _buffering = b);
    }));
    _subs.add(_player.stream.playing.listen((p) {
      if (mounted) setState(() => _playing = p);
    }));
    _subs.add(_player.stream.error.listen((e) {
      if (mounted) setState(() => _error = e);
    }));
  }

  Future<void> _open() async {
    try {
      await _player.open(
        Media(
          widget.client.originalUrl(widget.item.id),
          // 原文件接口需要令牌。mpv 自己发起的 Range 请求会带上这些头。
          httpHeaders: widget.client.authHeaders,
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  Future<void> _showTrackPicker() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              const _SectionLabel('音轨'),
              for (final e in _tracks.audio.asMap().entries)
                _TrackTile(
                  title: _audioLabel(e.value, e.key),
                  subtitle: _trackSubtitle(e.value, theme),
                  selected: _current.audio.id == e.value.id,
                  onTap: () {
                    _player.setAudioTrack(e.value);
                    Navigator.pop(ctx);
                  },
                ),
              const Divider(height: 24),
              const _SectionLabel('字幕'),
              for (final e in _tracks.subtitle.asMap().entries)
                _TrackTile(
                  title: _subtitleLabel(e.value, e.key),
                  subtitle: _trackSubtitle(e.value, theme),
                  selected: _current.subtitle.id == e.value.id,
                  onTap: () {
                    _player.setSubtitleTrack(e.value);
                    Navigator.pop(ctx);
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  String _audioLabel(AudioTrack t, int index) {
    switch (t.id) {
      case 'auto':
        return '自动';
      case 'no':
        return '关闭声音';
    }
    final name = t.title ?? t.language ?? '音轨 ${index + 1}';
    return t.isDefault == true ? '$name（默认）' : name;
  }

  String _subtitleLabel(SubtitleTrack t, int index) {
    switch (t.id) {
      case 'auto':
        return '自动';
      case 'no':
        return '关闭字幕';
    }
    return t.title ?? t.language ?? '字幕 ${index + 1}';
  }

  Widget? _trackSubtitle(dynamic t, ThemeData theme) {
    final parts = <String>[];
    if (t.codec != null) parts.add('${t.codec}');
    if (t.channels != null) parts.add('${t.channels}');
    if (t.language != null && t.title != null) parts.add('${t.language}');
    if (parts.isEmpty) return null;
    return Text(parts.join(' · '),
        style: TextStyle(fontSize: 12, color: theme.colorScheme.outline));
  }

  bool get _hasMultipleTracks =>
      _tracks.audio.length > 2 || _tracks.subtitle.length > 2;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.item.fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
            Text(
              [
                widget.item.resolution,
                widget.item.durationLabel,
                if (widget.item.videoCodec.isNotEmpty) widget.item.videoCodec,
              ].where((s) => s.isNotEmpty).join(' · '),
              style: const TextStyle(fontSize: 12, color: Colors.white60),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '音轨与字幕',
            onPressed: _showTrackPicker,
            icon: Badge(
              isLabelVisible: _hasMultipleTracks,
              child: const Icon(Icons.subtitles_outlined),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          Center(
            child: Video(
              controller: _controller,
              fill: Colors.black,
              controls: AdaptiveVideoControls,
            ),
          ),
          if (_buffering && _error == null)
            const Positioned(
              top: 12,
              right: 12,
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white54),
              ),
            ),
          if (_error != null) _ErrorOverlay(message: _error!, onRetry: _retry),
          if (!_playing && !_buffering && _error == null)
            const Positioned(
              bottom: 12,
              left: 12,
              child: _HintChip(text: '已暂停'),
            ),
        ],
      ),
    );
  }

  void _retry() {
    setState(() => _error = null);
    unawaited(_open());
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: theme.colorScheme.outline,
        ),
      ),
    );
  }
}

/// 轨道列表项。用勾选标记而不是 Radio 表达选中态，
/// 既避免了已废弃的 RadioListTile API，也更符合「切换轨道」这个动作的语义。
class _TrackTile extends StatelessWidget {
  const _TrackTile({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final Widget? subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      onTap: onTap,
      title: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
          color: selected ? theme.colorScheme.primary : null,
        ),
      ),
      subtitle: subtitle,
      trailing: selected
          ? Icon(Icons.check, size: 18, color: theme.colorScheme.primary)
          : null,
    );
  }
}

class _HintChip extends StatelessWidget {
  const _HintChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text,
          style: const TextStyle(fontSize: 12, color: Colors.white70)),
    );
  }
}

class _ErrorOverlay extends StatelessWidget {
  const _ErrorOverlay({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.82),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline,
                    size: 40, color: Colors.white70),
                const SizedBox(height: 16),
                const Text('无法播放这个视频',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w500)),
                const SizedBox(height: 10),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 12, height: 1.6),
                ),
                const SizedBox(height: 22),
                OutlinedButton(
                  onPressed: onRetry,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white38),
                  ),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
