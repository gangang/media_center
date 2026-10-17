import 'dart:io';
import 'dart:typed_data';

import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:photo_manager/photo_manager.dart';

import '../../core/upload/media_source.dart';
import '../../core/upload/upload_models.dart';

/// 用系统相册（Android MediaStore / iOS Photos）实现的 [MediaSource]。
///
/// 只做三件事：要权限、列最近的条目、把条目变成可读的本地文件。分片、重试、
/// 续传一律不在这里 —— 那是 [UploadQueue] 的事。
class PhotoLibrarySource implements MediaSource {
  /// 只取「全部」这一个相册。
  ///
  /// 系统相册里同一张照片会同时出现在「相机」「截图」「全部」里，
  /// 不去重就会把同一个文件传三遍 —— 秒传能挡住重复落盘，但白算三次哈希、
  /// 白排三次队。`onlyAll: true` 直接绕开这个问题。
  static const _requestOption = PermissionRequestOption(
    androidPermission: AndroidPermission(
      type: RequestType.common,
      mediaLocation: false,
    ),
    iosAccessLevel: IosAccessLevel.readWrite,
  );

  @override
  bool get supported => Platform.isAndroid || Platform.isIOS;

  @override
  Future<MediaAccess> currentAccess() async {
    final state = await PhotoManager.getPermissionState(
      requestOption: _requestOption,
    );
    return _toAccess(state);
  }

  @override
  Future<MediaAccess> requestAccess() async {
    final state = await PhotoManager.requestPermissionExtend(
      requestOption: _requestOption,
    );
    if (state.hasAccess) return MediaAccess.granted;
    // 系统只告诉了我们"没给"，没告诉我们"还能不能再问"。再问一次会不会
    // 弹窗，取决于用户上次点的是"拒绝"还是"拒绝且不再询问" —— 这个区别
    // 只有 permission_handler 能读到。
    return await _isBlocked() ? MediaAccess.blocked : MediaAccess.denied;
  }

  MediaAccess _toAccess(PermissionState state) {
    if (state.hasAccess) return MediaAccess.granted;
    // restricted 是家长控制之类的限制，用户自己改不了，只能引导去设置看。
    if (state == PermissionState.restricted) return MediaAccess.blocked;
    return MediaAccess.denied;
  }

  Future<bool> _isBlocked() async {
    if (Platform.isAndroid) {
      final photos = await ph.Permission.photos.status;
      final storage = await ph.Permission.storage.status;
      return photos.isPermanentlyDenied || storage.isPermanentlyDenied;
    }
    final photos = await ph.Permission.photos.status;
    return photos.isPermanentlyDenied;
  }

  @override
  Future<List<MediaCandidate>> recent({int limit = 300}) async {
    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: true,
      filterOption: FilterOptionGroup(
        orders: [
          const OrderOption(type: OrderOptionType.createDate, asc: false),
        ],
      ),
    );
    if (albums.isEmpty) return const [];

    final assets = await albums.first.getAssetListPaged(page: 0, size: limit);
    return assets.map(_toCandidate).toList(growable: false);
  }

  MediaCandidate _toCandidate(AssetEntity asset) => MediaCandidate(
    id: asset.id,
    fileName: _displayName(asset),
    isVideo: asset.type == AssetType.video,
    createdAt: asset.createDateTime,
  );

  /// 相册条目的文件名经常是空的（尤其视频），但上传要靠它决定服务端落盘的名字。
  /// 兜底成一个带时间戳的名字，至少不会互相覆盖。
  String _displayName(AssetEntity asset) {
    final title = asset.title?.trim();
    if (title != null && title.isNotEmpty) return title;
    final ext = asset.type == AssetType.video ? 'mp4' : 'jpg';
    final t = asset.createDateTime;
    final stamp =
        '${t.year}${_two(t.month)}${_two(t.day)}_'
        '${_two(t.hour)}${_two(t.minute)}${_two(t.second)}';
    return 'asset_${stamp}_${asset.id.hashCode.toRadixString(16)}.$ext';
  }

  static String _two(int v) => v < 10 ? '0$v' : '$v';

  @override
  Future<PendingUpload?> materialize(MediaCandidate candidate) async {
    final asset = await AssetEntity.fromId(candidate.id);
    if (asset == null) return null;

    // originFile 要原图/原视频：缩略图或转码副本会让服务端存下一份降质的
    // 东西，而备份的意义就是留住原件。
    final file = await asset.originFile ?? await asset.file;
    if (file == null) return null;

    final size = await file.length();
    if (size <= 0) return null;

    return PendingUpload(
      localPath: file.path,
      fileName: candidate.fileName,
      fileSize: size,
    );
  }

  @override
  Future<Uint8List?> thumbnail(MediaCandidate candidate, {int size = 200}) async {
    final asset = await AssetEntity.fromId(candidate.id);
    if (asset == null) return null;
    return asset.thumbnailDataWithSize(ThumbnailSize.square(size));
  }

  @override
  Future<void> openSettings() => PhotoManager.openSetting();
}
