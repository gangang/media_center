import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_center_client/core/upload/content_hash.dart';

/// 与后端 `internal/scanner/hash_test.go` 里的 `vectorFill` 完全一致。
///
/// 用算术而不是随机：两边必须能各自重建出同样的字节，而不必附带二进制夹具。
Uint8List vectorFill(int n) {
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = (i * 37 + 11) % 256;
  }
  return b;
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mc-hashvec');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  Future<File> write(String name, Uint8List bytes) async {
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(bytes);
    return f;
  }

  test('内容指纹与后端实现逐字节一致（跨语言契约）', () async {
    // 这组常量与 Go 侧完全相同。秒传只有在两边算出同一个哈希时才会命中，
    // 而不一致时**不会报错**——只会让每次备份都重传服务端已有的文件。
    // 所以把向量冻在这里，两边任何一侧漂移都会有测试失败。
    const vectors = <int, String>{
      0: 'af5570f5a1810b7af78caf4bc70a660f0df51e42baf91d4de5b2328de0e83dfc',
      1: '62e7e02ebe7b1ee4cd2120090bc09b8baf24b40c2bb5ef15aa3ad054b1b57412',
      1023: '9e20c018bdc8331d1f488eacd97f58f795359518bc6040d054c583ea4f738c18',
      1024: '14fac5fe7015bcbf8d0af8d27c2c637e1f59633c49fc41c7daf4acb5c088c04e',
      262143: 'b90fbed02d9e51a1bc7b0c9617660fb4a958731a606ac229a3cfafff6cf9cafb',
      262144: 'b681453aedfd522f2b202a4718254c8425a85df37626088a0a79dd6814503b95',
      262145: '12c8c9e0a2b54df9a743c21b20ccb3ead735b47dda8fdb9e9c2a67c2530c2383',
      524288: '532137cd71fbb1c59f03ddeb059e498116928183567b37fc9411422cfacf5614',
      1048576: 'c12e90efb667b07ff4d8fdab0cdc31a9490c6e41f056c8db8c020cd03079bab4',
      3000000: '7d266d141a819b0e1a42df3f9f94e7ab570529502b76a1fb561d4ea46cacd2e5',
    };

    for (final entry in vectors.entries) {
      final f = await write('f${entry.key}.bin', vectorFill(entry.key));
      expect(
        await contentHashOfFile(f),
        entry.value,
        reason: 'size=${entry.key} 的指纹与后端不一致',
      );
    }
  });

  test('头尾指纹忽略中间字节（这是刻意的取舍，不是缺陷）', () async {
    // 指纹 = 大小 + 头 256 KiB + 尾 256 KiB（D4）。中间改一个字节，哈希不变。
    // 这个测试存在的意义是让该性质成为"可读到的决定"，而不是日后被当成 bug 撞见。
    const size = 1024 * 1024;
    final a = vectorFill(size);
    final b = Uint8List.fromList(a);
    b[size ~/ 2] ^= 0xFF;

    final fa = await write('a.bin', a);
    final fb = await write('b.bin', b);

    expect(await contentHashOfFile(fa), await contentHashOfFile(fb));

    // 大小参与身份计算，所以传入不同的 size 必须得到不同的哈希。
    expect(
      await contentHashOfFile(fa, size: size - 1),
      isNot(await contentHashOfFile(fa)),
    );
  });

  test('读取不完整时报错，而不是算出一个错的指纹', () async {
    // 声明 4096 字节但文件只有 100 字节：宁可抛错，也不要拿一段短数据去算哈希 ——
    // 那会得到一个看起来正常的错误指纹，症状只是"秒传永远不命中"。
    final f = await write('short.bin', vectorFill(100));
    expect(
      () => contentHashOfFile(f, size: 4096),
      throwsA(isA<FileSystemException>()),
    );
  });
}
