import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// 上传期间把进程钉在前台。
///
/// 为什么需要：安卓会在应用退到后台之后限制甚至冻结进程，一次几百张的相册备份
/// 恰好是个长任务 —— 用户切去回个消息，上传就停了。前台服务是安卓上唯一被官方
/// 认可的长任务存活方式：它带一条常驻通知，系统因此不会回收进程。
///
/// 抽成接口有两个原因：
/// 1. 桌面端没有这回事，测试里也不该真的去起一个服务；
/// 2. 前台服务起不来（没给通知权限、厂商 ROM 限制）时**绝不能让上传跟着失败**。
///    保活是"更好"，不是"前提"。
abstract class UploadKeepAlive {
  /// 开始保活。失败不抛异常 —— 调用方不该为此写 try/catch。
  Future<void> acquire({String title, String text});

  /// 更新通知上的文字（进度）。
  Future<void> update({String title, String text});

  /// 结束保活。多次调用是安全的。
  Future<void> release();
}

/// 桌面端与测试用的空实现。
class NoopUploadKeepAlive implements UploadKeepAlive {
  const NoopUploadKeepAlive();

  @override
  Future<void> acquire({String title = '', String text = ''}) async {}

  @override
  Future<void> update({String title = '', String text = ''}) async {}

  @override
  Future<void> release() async {}
}

/// 安卓前台服务实现。
///
/// 只在安卓上真的做事；其他平台静默退化 —— 这个类会被无条件构造，让调用方
/// 自己判断平台会把"哪些平台支持"这件事散落到各处。
class ForegroundServiceKeepAlive implements UploadKeepAlive {
  ForegroundServiceKeepAlive();

  static const _channelId = 'mediacenter_upload';
  static const _serviceId = 7311;

  bool _initialized = false;
  bool _running = false;

  bool get _applicable => Platform.isAndroid || Platform.isIOS;

  @override
  Future<void> acquire({String title = '正在备份相册', String text = ''}) async {
    if (!_applicable || _running) return;
    try {
      await _init();
      await _ensureNotificationPermission();

      if (await FlutterForegroundTask.isRunningService) {
        _running = true;
        return;
      }
      final result = await FlutterForegroundTask.startService(
        serviceId: _serviceId,
        serviceTypes: const [ForegroundServiceTypes.dataSync],
        notificationTitle: title,
        notificationText: text.isEmpty ? '正在上传到媒体中心' : text,
        callback: _startCallback,
      );
      _running = result is ServiceRequestSuccess;
    } catch (_) {
      // 厂商 ROM、权限被拒、系统限制……都走这里。上传继续，只是不再受保护。
      _running = false;
    }
  }

  @override
  Future<void> update({String title = '正在备份相册', String text = ''}) async {
    if (!_running) return;
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: text.isEmpty ? '正在上传到媒体中心' : text,
      );
    } catch (_) {
      // 通知更新失败不影响上传。
    }
  }

  @override
  Future<void> release() async {
    if (!_running) return;
    _running = false;
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {
      // 服务已经不在（被系统杀了）时 stopService 会抛，忽略即可。
    }
  }

  Future<void> _init() async {
    if (_initialized) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: _channelId,
        channelName: '相册备份',
        channelDescription: '备份进行时显示进度，结束后自动消失。',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        // 我们不需要周期回调：上传跑在 UI isolate 里，服务只负责让进程活着。
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        // 两者都开着才有意义：WiFi 锁防止系统为了省电关掉 WiFi 射频，
        // 唤醒锁防止 CPU 睡下去把分片传到一半停住。
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    _initialized = true;
  }

  Future<void> _ensureNotificationPermission() async {
    if (!Platform.isAndroid) return;
    final p = await FlutterForegroundTask.checkNotificationPermission();
    if (p != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
  }
}

/// 服务的入口。必须是顶层函数，且带 `vm:entry-point` —— 它会在另一个
/// isolate 里被调用，release 构建的 tree-shaking 不认这个注解就会把它删掉，
/// 表现为"服务启动了但立刻退出"。
@pragma('vm:entry-point')
void _startCallback() {
  FlutterForegroundTask.setTaskHandler(_IdleTaskHandler());
}

/// 什么都不做的任务处理器。
///
/// 这个服务的唯一职责是"存在"：它让系统认为进程在做用户可见的工作，从而不回收。
/// 真正的上传跑在主 isolate，不在这里 —— 把队列搬进后台 isolate 会引出
/// 跨 isolate 的状态同步问题，收益却只是省一点主 isolate 的 CPU。
class _IdleTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}
