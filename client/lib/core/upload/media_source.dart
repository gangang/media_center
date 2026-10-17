/// 相册这一侧的抽象：权限、列表、取原文件。
///
/// 为什么要这一层：上传队列（[UploadQueue]）只认"本地路径 + 名字 + 大小"，
/// 它不该知道照片是从手机相册读来的、还是从文件系统里挑的。相册读取则完全是
/// 平台的事 —— 要用 `photo_manager`、要申请 `READ_MEDIA_IMAGES`、要在
/// Android 上把 `content://` 换成真实文件。
///
/// 把两者隔开之后，上传界面可以用一个假的 [MediaSource] 在 `flutter test` 里
/// 跑完整流程（选片 → 排队 → 传完 → 刷新），而不必有一台手机。
library;

import 'dart:typed_data';

import 'upload_models.dart';

/// 用户对相册访问权的选择结果。
///
/// 三种而不是两种：`denied` 还能再弹一次系统对话框，`blocked` 不能 ——
/// 后者只能把用户引到系统设置里改，两种情况的引导文案完全不同。
enum MediaAccess {
  granted,
  denied,
  blocked,
}

/// 相册里的一条记录。
///
/// 刻意只有 id、名字、时间和类型：没有 `AssetEntity`，没有 `Uri`，
/// 也不带文件大小 —— 相册 API 不直接给大小，为了列表上显示它就得把每个
/// 文件复制出来，代价远大于收益。真正的大小在 [MediaSource.materialize]
/// 拿到文件之后才知道。
class MediaCandidate {
  const MediaCandidate({
    required this.id,
    required this.fileName,
    required this.isVideo,
    this.createdAt,
  });

  /// 平台侧的稳定标识（Android 是 MediaStore id，iOS 是 localIdentifier）。
  final String id;

  final String fileName;
  final bool isVideo;
  final DateTime? createdAt;

  String get kindLabel => isVideo ? '视频' : '照片';
}

/// 相册来源。
abstract class MediaSource {
  /// 这个平台上有没有"备份手机相册"这回事。
  ///
  /// 桌面端返回 false。桌面上的文件本来就在磁盘里，用户直接把它放进扫描目录
  /// 就行；再做一个"选文件上传"的界面只是把同一件事换个地方做，还多一条
  /// 需要维护的代码路径。
  bool get supported;

  /// 现在有没有访问权。**不弹窗**，用于进入页面时判断要不要显示引导。
  Future<MediaAccess> currentAccess();

  /// 申请访问权。已经授权时直接返回 granted，不弹窗。
  Future<MediaAccess> requestAccess();

  /// 读最近的照片和视频，新的在前。
  Future<List<MediaCandidate>> recent({int limit = 300});

  /// 把候选解成本地可读文件的路径。
  ///
  /// 返回 null 表示这条读不出来（典型情况：照片只存在 iCloud，本地没有副本）。
  /// 一条读不出来不该让整批备份失败，跳过它继续。
  Future<PendingUpload?> materialize(MediaCandidate candidate);

  /// 缩略图字节，用于选择界面。拿不到时返回 null，界面显示占位图。
  Future<Uint8List?> thumbnail(MediaCandidate candidate, {int size = 200});

  /// 把用户送到系统设置页（[MediaAccess.blocked] 之后唯一的出路）。
  Future<void> openSettings();
}
