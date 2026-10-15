import 'dart:async';
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';

/// mDNS 服务类型。必须与后端 `internal/discovery.ServiceType` 保持一致，
/// 否则两边各说各话，谁也不会报错，只是永远发现不到对方。
const String kServiceType = '_mediacenter._tcp';

/// 一台通过 mDNS 发现的 MediaCenter 服务器。
class DiscoveredServer {
  const DiscoveredServer({
    required this.instance,
    required this.name,
    required this.host,
    required this.port,
    required this.addresses,
    required this.txt,
  });

  /// 服务实例全名，形如 `MediaCenter-bogon._mediacenter._tcp.local`。
  ///
  /// 它是这个实例在网络上的唯一标识，也是后续查 SRV/TXT 的键。
  final String instance;

  /// 展示名称，取自 TXT 的 `name`。
  final String name;

  /// SRV 记录里的目标主机，形如 `bogon.local`。
  final String host;

  final int port;

  /// A 记录解析出的 IPv4 地址。
  final List<String> addresses;

  /// TXT 记录里的原始键值。
  ///
  /// 注意这里**没有**访问令牌——后端刻意不广播它，因为同一网段上任何设备
  /// 都能读到 TXT。令牌仍需用户从服务端启动日志里取。
  final Map<String, String> txt;

  /// 可用的首选地址；没有任何地址时为 null。
  String? get address => addresses.isEmpty ? null : addresses.first;

  /// 可直接交给 [ApiClient] 的地址；没有地址时为 null。
  ///
  /// 后端当前广播的 `path` 恒为 `/`，但这里仍然按它拼接：将来若服务端挂在
  /// 反向代理的子路径下，客户端不用改代码就能跟上。
  String? get baseUrl {
    final a = address;
    if (a == null) return null;
    final p = txt['path'];
    final suffix = (p == null || p.isEmpty || p == '/') ? '' : p;
    return 'http://$a:$port$suffix';
  }

  /// 服务端版本，来自 TXT。
  String? get version => txt['version'];

  /// 服务端 API 版本，来自 TXT。
  String? get apiVersion => txt['api'];

  @override
  String toString() =>
      '$name ${address ?? '<无地址>'}:$port'
      '${version == null ? '' : ' v$version'}';
}

/// 服务器发现能力的抽象。
///
/// 单独抽出接口，是为了让连接页可测：真实实现要开组播 socket、要等网络响应，
/// 放进 widget 测试既慢又不稳定（而且界面上的转圈动画会让 `pumpAndSettle`
/// 永远等不到静止）。测试注入一个立刻返回固定结果的实现即可。
abstract class ServerDiscoverer {
  /// 发现局域网内的服务器。失败时抛 [ServerDiscoveryException]。
  Future<List<DiscoveredServer>> discover();

  /// 释放底层资源。
  void dispose();
}

/// 通过 mDNS 发现局域网内的 MediaCenter 服务器。
///
/// 只在同一广播域内有效：跨网段、以及会拦截组播的 VPN 场景都发现不到，
/// 所以调用方必须保留手动输入地址的入口，不能把发现当作唯一路径。
class ServerDiscovery implements ServerDiscoverer {
  MDnsClient? _client;

  /// 启动一次 mDNS 查询所需的等待窗口。
  ///
  /// 之所以要自己定一个窗口，而不是用库的 `stream.toList()`：`toList` 会一直
  /// 等到流**关闭**才完成，而库内部要 5 秒才关流；如果给它套一个更短的
  /// `Future.timeout`，超时会返回兜底值，把已经收到的记录一起丢掉——表现
  /// 为「网络抓包明明有响应，代码里却什么都拿不到」。所以这里自己收，
  /// 收满窗口就返回，收到多少算多少。
  static const Duration _browseWindow = Duration(milliseconds: 1800);

  /// 连续这么久没有新记录就认为收完了，提前返回。
  ///
  /// 常见情况是响应在几十毫秒内到齐，有它就不必每次干等满 1.8 秒。
  static const Duration _settle = Duration(milliseconds: 400);

  /// 后续 SRV/TXT/A 查询的窗口。这些记录通常已经随 PTR 的响应包一起到达并
  /// 进了库的缓存，命中缓存时流会立刻关闭，所以窗口给得很短也不会漏。
  static const Duration _resolveWindow = Duration(milliseconds: 700);

  /// 发现局域网内的服务器。
  ///
  /// 返回的列表已排序：能拿到地址的排在前面，其余按名称排序，保证同一批
  /// 结果顺序稳定（否则每次刷新列表都在跳）。
  @override
  Future<List<DiscoveredServer>> discover() async {
    final client = await _ensureStarted();

    // 第一步：问「谁提供这个服务」。PTR 记录的 owner name 是服务类型本身，
    // domainName 才是具体的实例名。
    final ptrs = await _collect<PtrResourceRecord>(
      client.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer('$kServiceType.local'),
      ),
      window: _browseWindow,
      settle: _settle,
    );

    // 一台服务器可能被多条 PTR 记录重复指向（多网卡时很常见），去重。
    final instances = <String>{for (final p in ptrs) p.domainName};

    final out = <DiscoveredServer>[];
    for (final instance in instances) {
      final server = await _resolve(client, instance);
      if (server != null) out.add(server);
    }

    out.sort((a, b) {
      final aOk = a.address != null ? 0 : 1;
      final bOk = b.address != null ? 0 : 1;
      if (aOk != bOk) return aOk - bOk;
      final byName = a.name.compareTo(b.name);
      return byName != 0 ? byName : a.instance.compareTo(b.instance);
    });
    return out;
  }

  /// 把单个实例名解析成完整信息。解析不出 SRV 或地址时返回 null。
  Future<DiscoveredServer?> _resolve(MDnsClient client, String instance) async {
    final srvs = await _collect<SrvResourceRecord>(
      client.lookup<SrvResourceRecord>(ResourceRecordQuery.service(instance)),
      window: _resolveWindow,
      settle: _settle,
    );
    if (srvs.isEmpty) {
      // 只有实例名没有 SRV，属于半残状态：界面上会表现为「看得到名字却连不上」。
      // 直接丢掉，让调用方只看到能连的，而不是把问题推给用户去猜。
      return null;
    }
    final srv = srvs.first;

    // SRV 的 target 带结尾的点（`bogon.local.`），而查询名不带，去掉更稳妥。
    final host = srv.target.endsWith('.')
        ? srv.target.substring(0, srv.target.length - 1)
        : srv.target;

    // 只查 A（IPv4）。地址来自后端广播的网卡地址，已经过滤掉虚拟网卡，
    // 所以这里拿到的就是对方在真实局域网上的地址。
    final addrs = await _collect<IPAddressResourceRecord>(
      client.lookup<IPAddressResourceRecord>(
        ResourceRecordQuery.addressIPv4(host),
      ),
      window: _resolveWindow,
      settle: _settle,
    );

    final txts = await _collect<TxtResourceRecord>(
      client.lookup<TxtResourceRecord>(ResourceRecordQuery.text(instance)),
      window: _resolveWindow,
      settle: _settle,
    );

    final txt = txts.isEmpty ? const <String, String>{} : parseTxt(txts.first.text);

    return DiscoveredServer(
      instance: instance,
      // TXT 的 name 是后端自己填的显示名；没有就退回实例名首段。
      name: txt['name'] ?? instance.split('.').first,
      host: host,
      port: srv.port,
      addresses: <String>{
        for (final a in addrs) a.address.address,
      }.toList(),
      txt: txt,
    );
  }

  /// 释放 socket。页面销毁时必须调用，否则 5353 上的监听会一直留着。
  @override
  void dispose() {
    _client?.stop();
    _client = null;
  }

  Future<MDnsClient> _ensureStarted() async {
    final existing = _client;
    if (existing != null) return existing;

    final client = MDnsClient();
    try {
      await client.start();
    } on SocketException catch (e) {
      // 5353 被独占且对方没开端口复用时会走到这里。多数系统上不会发生，
      // 但发生时要给出可行动的提示，而不是一句「发现失败」。
      throw ServerDiscoveryException('无法监听 mDNS 端口 5353：$e');
    } catch (e) {
      throw ServerDiscoveryException('mDNS 初始化失败：$e');
    }
    _client = client;
    return client;
  }

  /// 收集一段时间内的记录；连续 [settle] 没有新记录则提前结束。
  Future<List<T>> _collect<T extends ResourceRecord>(
    Stream<T> stream, {
    required Duration window,
    required Duration settle,
  }) async {
    final out = <T>[];
    final done = Completer<void>();

    Timer? settleTimer;
    final hardTimer = Timer(window, () {
      if (!done.isCompleted) done.complete();
    });

    void finish() {
      if (!done.isCompleted) done.complete();
    }

    final sub = stream.listen(
      (record) {
        out.add(record);
        settleTimer?.cancel();
        settleTimer = Timer(settle, finish);
      },
      onError: (Object _) => finish(),
      onDone: finish,
    );

    try {
      await done.future;
    } finally {
      hardTimer.cancel();
      settleTimer?.cancel();
      await sub.cancel();
    }
    return out;
  }
}

/// 发现过程中的可预期失败。
class ServerDiscoveryException implements Exception {
  const ServerDiscoveryException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 解析 TXT 记录文本。
///
/// multicast_dns 把多个 length-prefixed 字符串用换行拼成一条，所以这里按行拆。
/// 值里可能自带 `=`（比如带查询串的 URL），因此只按**第一个** `=` 切。
Map<String, String> parseTxt(String text) {
  final out = <String, String>{};
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final idx = trimmed.indexOf('=');
    if (idx <= 0) continue;
    out[trimmed.substring(0, idx)] = trimmed.substring(idx + 1);
  }
  return out;
}
