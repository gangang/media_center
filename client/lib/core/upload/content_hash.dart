import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 指纹覆盖的字节数：头尾各 256 KiB。
///
/// 与后端 `scanner.quickHash` 里的 `chunk` 常量一致，改一处必须改另一处。
const fingerprintChunk = 256 * 1024;

/// 计算文件的内容指纹，结果与后端 `scanner.quickHash` **逐字节一致**。
///
/// 算法：`sha256(小端 uint64(文件大小) ‖ 头 256 KiB ‖ 尾 256 KiB)`，小写十六进制。
/// 文件不超过 256 KiB 时只有头（也就是整个文件），没有尾。
///
/// **为什么客户端要算**：后端支持秒传 —— `POST /api/uploads` 带上
/// `content_hash`，服务端若已有这份内容就直接返回，一个字节都不用传。
/// 手机反复备份同一个相册时，这会把"每张照片传一次"变成"每张照片一个小请求"。
///
/// **为什么必须和后端一模一样**：哈希不一致**不会报任何错**。服务端只是找不到
/// 已有内容，于是老老实实把整份文件收下 —— 用户看到的是"备份有点慢"，
/// 而不是"功能坏了"。所以两边各有一份用同一组常量做的断言测试
/// （`internal/scanner/hash_test.go` 与 `test/content_hash_test.dart`）。
///
/// 内存上限约 512 KiB/文件：只读头尾，不读整个文件，所以 4 GB 视频和 4 KB
/// 照片的代价一样。这也是后端不用全文件哈希的原因（D4）。
Future<String> contentHashOfFile(File file, {int? size}) async {
  final total = size ?? await file.length();
  final raf = await file.open();
  try {
    // 大小参与身份计算：内容相同但长度不同的两个文件应当被当作不同文件。
    // 后端是 binary.LittleEndian.PutUint64，这里必须同样是小端 8 字节。
    final sizeBytes = ByteData(8)..setUint64(0, total, Endian.little);

    final buf = BytesBuilder(copy: false);
    buf.add(sizeBytes.buffer.asUint8List());

    final headLen = total < fingerprintChunk ? total : fingerprintChunk;
    if (headLen > 0) {
      buf.add(await _readExactly(raf, 0, headLen));
    }

    // 尾段只在文件大于一个块时才有，并且可能和头段**重叠**（256 KiB ~ 512 KiB
    // 之间时就是如此）。后端也是这么做的（`if size > chunk` 才 seek 到末尾），
    // 重叠是刻意保留的：宁可多读一遍，也不让边界附近的字节逃出指纹。
    if (total > fingerprintChunk) {
      buf.add(
        await _readExactly(raf, total - fingerprintChunk, fingerprintChunk),
      );
    }

    return sha256.convert(buf.takeBytes()).toString();
  } finally {
    await raf.close();
  }
}

/// 从 [start] 处精确读取 [length] 字节。
///
/// 读不满就报错，而不是拿一段短数据去算哈希：那会得到一个"看起来正常"的
/// 错误指纹，而它的唯一症状是秒传永远不命中 —— 又是一个不会报错的故障。
Future<Uint8List> _readExactly(
  RandomAccessFile raf,
  int start,
  int length,
) async {
  await raf.setPosition(start);
  final bytes = await raf.read(length);
  if (bytes.length != length) {
    throw FileSystemException(
      '读取文件时长度不足：需要 $length 字节，实际 ${bytes.length} 字节',
      raf.path,
    );
  }
  return bytes;
}
