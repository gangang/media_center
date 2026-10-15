import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/server_discovery.dart';
import '../../core/settings_store.dart';

/// 连接服务器页面。
///
/// 主路径是自动发现：进入页面就开始搜局域网，列出找到的服务器，点一下就填好
/// 地址。手动输入保留在下面作为兜底——跨网段、VPN、以及被系统权限拦住时，
/// 自动发现本来就不可能成功，这时不能让用户无路可走。
///
/// 令牌始终要手动填：后端刻意不把令牌放进 mDNS 的 TXT 记录里，因为同一网段
/// 上任何设备都能读到它，那样等于把令牌公开广播出去。
class ConnectPage extends StatefulWidget {
  const ConnectPage({
    super.key,
    required this.settingsStore,
    required this.onConnected,
    this.discoverer,
  });

  final SettingsStore settingsStore;
  final VoidCallback onConnected;

  /// 服务器发现实现。留空则用真实的 mDNS 发现；测试注入假实现，
  /// 这样用例不必开真实 socket，也不会被转圈动画卡住。
  final ServerDiscoverer? discoverer;

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  final _urlController = TextEditingController();
  final _tokenController = TextEditingController();
  final _tokenFocus = FocusNode();
  final _formKey = GlobalKey<FormState>();

  /// 发现器在页面存活期间一直留着：每次搜索都重建 socket 没有必要，而且
  /// 5353 上的监听反复开关反而更容易出问题。
  late final ServerDiscoverer _discovery = widget.discoverer ?? ServerDiscovery();

  /// 只释放自己创建的那个。外部传进来的由外部负责，页面不该替它做主。
  late final bool _ownsDiscovery = widget.discoverer == null;

  bool _busy = false;
  String? _error;
  String? _probeResult;

  bool _scanning = false;
  List<DiscoveredServer> _servers = const [];
  String? _scanError;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    if (_ownsDiscovery) _discovery.dispose();
    _urlController.dispose();
    _tokenController.dispose();
    _tokenFocus.dispose();
    super.dispose();
  }

  /// 搜索局域网内的服务器。失败不弹错误页，只是把原因写在卡片里——
  /// 发现失败并不影响手动连接，没必要把它渲染成一个阻塞性的错误。
  Future<void> _scan() async {
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _scanError = null;
    });

    try {
      final found = await _discovery.discover();
      if (!mounted) return;
      setState(() {
        _servers = found;
        _scanning = false;

        // 只发现到一台、且地址框还是空的时候顺手填上：省一次输入，又不会
        // 覆盖用户已经打进去的内容。用「框里是否为空」而不是另设一个
        // 「用户是否碰过」的标志位——后者要额外区分程序填充和用户输入，
        // 而它想表达的其实就是「别覆盖用户打的字」。
        if (found.length == 1 && _urlController.text.trim().isEmpty) {
          final only = found.first;
          if (only.address != null) {
            _urlController.text = _displayAddress(only);
          }
        }
      });
    } on ServerDiscoveryException catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _scanError = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _scanError = '搜索失败：$e';
      });
    }
  }

  /// 地址框里显示的写法。用 `host:port` 而不是完整 URL，是为了和输入框的
  /// 提示保持一致，用户看到的样子就是他手动输入时会打的样子。
  String _displayAddress(DiscoveredServer s) => '${s.address}:${s.port}';

  void _pick(DiscoveredServer s) {
    // 必须包在 setState 里：地址框内容变了，但列表项的选中态是在 build 里
    // 按地址框内容算出来的，不重建的话高亮不会跟着变。
    setState(() => _urlController.text = _displayAddress(s));
    _tokenFocus.requestFocus();
  }

  Future<void> _connect() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _busy = true;
      _error = null;
      _probeResult = null;
    });

    final baseUrl = ApiClient.normalizeBaseUrl(_urlController.text);
    final token = _tokenController.text.trim();

    try {
      final client = ApiClient(baseUrl: baseUrl, token: token);

      // 先 ping 确认地址可达，再用 stats 验证令牌是否正确。
      final info = await client.ping();
      final stats = await client.stats();

      if (!mounted) return;
      setState(() => _probeResult =
          '已连接 ${info.name} · v${info.version} · 照片 ${stats.photos} / 视频 ${stats.videos}');

      await widget.settingsStore
          .save(ServerSettings(baseUrl: baseUrl, token: token));
      if (!mounted) return;
      widget.onConnected();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.photo_library_outlined,
                      size: 44, color: theme.colorScheme.primary),
                  const SizedBox(height: 16),
                  Text('本地媒体中心',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 6),
                  Text(
                    '连接到你在本机运行的服务端',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                  const SizedBox(height: 24),
                  _buildDiscovery(theme),
                  const SizedBox(height: 22),
                  Row(
                    children: [
                      Text('手动输入',
                          style: theme.textTheme.labelLarge
                              ?.copyWith(color: theme.colorScheme.outline)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Divider(color: theme.dividerColor, height: 1),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _urlController,
                    decoration: const InputDecoration(
                      labelText: '服务器地址',
                      hintText: '192.168.1.5:8080',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.dns_outlined),
                    ),
                    keyboardType: TextInputType.url,
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? '请输入服务器地址' : null,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _tokenController,
                    focusNode: _tokenFocus,
                    decoration: const InputDecoration(
                      labelText: '访问令牌',
                      hintText: '启动服务端时打印的那串字符',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.key_outlined),
                    ),
                    obscureText: true,
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? '请输入访问令牌' : null,
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _busy ? null : _connect,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('连接'),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    _Banner(
                      icon: Icons.error_outline,
                      color: theme.colorScheme.error,
                      text: _error!,
                    ),
                  ],
                  if (_probeResult != null) ...[
                    const SizedBox(height: 16),
                    _Banner(
                      icon: Icons.check_circle_outline,
                      color: theme.colorScheme.primary,
                      text: _probeResult!,
                    ),
                  ],
                  const SizedBox(height: 24),
                  Text(
                    '令牌可以在服务端启动日志中找到，'
                    '或查看数据目录下的 config.json。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 自动发现区块：搜索中 / 结果列表 / 空结果 / 失败，四态。
  Widget _buildDiscovery(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.04),
        border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.22)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (_scanning)
                const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(Icons.wifi_tethering,
                    size: 17, color: theme.colorScheme.primary),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  _scanning ? '正在搜索局域网…' : '局域网内的服务器',
                  style: theme.textTheme.labelLarge,
                ),
              ),
              if (!_scanning)
                IconButton(
                  onPressed: _scan,
                  icon: const Icon(Icons.refresh, size: 18),
                  tooltip: '重新搜索',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
            ],
          ),
          if (_scanError != null) ...[
            const SizedBox(height: 6),
            Text(_scanError!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error, height: 1.5)),
          ] else if (!_scanning && _servers.isEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '没有发现服务器。若服务端在另一网段、或本机开了 VPN，'
              '自动发现会失效，请用下面的手动输入。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
                height: 1.5,
              ),
            ),
          ],
          for (final s in _servers) ...[
            const SizedBox(height: 8),
            _ServerTile(
              server: s,
              selected: _urlController.text.trim() == _displayAddress(s),
              onTap: () => _pick(s),
            ),
          ],
        ],
      ),
    );
  }
}

/// 一台可选的服务器。
class _ServerTile extends StatelessWidget {
  const _ServerTile({
    required this.server,
    required this.selected,
    required this.onTap,
  });

  final DiscoveredServer server;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reachable = server.address != null;

    return Material(
      color: selected
          ? theme.colorScheme.primary.withValues(alpha: 0.10)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        // 没有地址的实例点不了：填进去也连不上，不如不给这个假入口。
        onTap: reachable ? onTap : null,
        borderRadius: BorderRadius.circular(9),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(
            children: [
              Icon(
                selected ? Icons.check_circle : Icons.dns_outlined,
                size: 18,
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outline,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(server.name,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      reachable
                          ? '${server.address}:${server.port}'
                              '${server.version == null ? '' : ' · v${server.version}'}'
                          : '未解析到地址',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 13, height: 1.5, color: color)),
          ),
        ],
      ),
    );
  }
}
