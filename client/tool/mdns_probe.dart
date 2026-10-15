// mDNS 发现诊断工具（纯 Dart，不依赖 Flutter）。
//
// 用途：在改动客户端发现逻辑之前，先确认「这台机器上能不能看到后端广播的服务」。
// UI 里的失败很难定位——是没收到响应、是解析错了字段、还是界面没刷新？这里把
// 每一步的原始结果都打出来，一次看清。
//
// 复用 lib/core/server_discovery.dart 的同一份逻辑，不另写一套：两边各写一份
// 的话，改了实现却忘了改诊断工具，就会拿旧逻辑去证明新代码没问题。
//
// 运行（在 client 目录下）：
//   /opt/homebrew/share/flutter/bin/cache/dart-sdk/bin/dart run tool/mdns_probe.dart
//
// 退出码：发现到服务为 0，否则为 1，便于放进脚本。

import 'dart:io';

import 'package:media_center_client/core/server_discovery.dart';

Future<void> main(List<String> args) async {
  stdout.writeln('查询 $kServiceType.local ...');

  final discovery = ServerDiscovery();
  try {
    final servers = await discovery.discover();

    if (servers.isEmpty) {
      stdout.writeln('未发现任何服务。');
      stdout.writeln('排查方向：');
      stdout.writeln('  1. 后端是否在跑——启动日志里会有一行 mDNS，');
      stdout.writeln('     并列出它在哪些网卡上广播（只会是真网卡，不含虚拟网卡）。');
      stdout.writeln('  2. 若日志提示「组播发送不通」，说明本机的组播被拦了');
      stdout.writeln('     （常见于 VPN），此时只能手动输入地址。');
      stdout.writeln('  3. 确认客户端与后端在同一网段。');
      exitCode = 1;
      return;
    }

    stdout.writeln('发现 ${servers.length} 个服务：');
    for (final s in servers) {
      stdout.writeln('  - ${s.name}');
      stdout.writeln('      地址 : ${s.baseUrl ?? '<无地址，无法连接>'}');
      stdout.writeln('      主机 : ${s.host}');
      stdout.writeln('      实例 : ${s.instance}');
      stdout.writeln('      版本 : ${s.version ?? '?'}  API: ${s.apiVersion ?? '?'}');
      stdout.writeln('      TXT  : ${s.txt}');
    }
    exitCode = servers.any((s) => s.baseUrl != null) ? 0 : 1;
  } on ServerDiscoveryException catch (e) {
    stderr.writeln('发现失败：$e');
    exitCode = 2;
  } finally {
    discovery.dispose();
  }
}
