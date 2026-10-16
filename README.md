# 本地私有化媒体中心

相册 + 影院的本地私有化部署方案。数据全部留在你自己的主机上，客户端通过局域网直连，
不经过任何云端服务。

**当前进度：阶段一～四已完成；阶段五（手机备份上传）后端已完成并通过 82 项断言验证；
阶段六 4.1（Android 正式签名 + 按 ABI 拆分 + 图标与启动图）已完成，release 包可覆盖安装升级。**

---

## 架构

```
┌─────────────────────────────────────────────────────────────┐
│                     你的主机（本地）                          │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────┐ │
│  │ 媒体文件夹    │─▶│  后端服务     │─▶│  SQLite            │ │
│  │ 原始照片/视频 │  │  Go · :8080  │  │  元数据索引         │ │
│  └──────────────┘  └──────┬───────┘  └────────────────────┘ │
│                            │                                 │
│              ┌─────────────┼─────────────┐                   │
│              ▼             ▼             ▼                   │
│      ┌──────────────┐ ┌──────────┐ ┌──────────────┐         │
│      │  缩略图缓存   │ │ library/ │ │ ffprobe/     │         │
│      │  thumbs/     │ │ 备份落盘  │ │ ffmpeg       │         │
│      └──────────────┘ └──────────┘ └──────────────┘         │
└──────────────────────────┬───────────────────────────────────┘
                           │ 内网 HTTP（带 Token）
        ┌──────────────────┼──────────────────┐
        ▼                  ▼                  ▼
   ┌─────────┐        ┌─────────┐        ┌─────────┐
   │桌面端    │        │Android  │        │iOS      │
   │(已完成)  │        │(已完成)  │        │(后续)    │
   └─────────┘        └─────────┘        └─────────┘
```

- **后端**：Go，编译为单个静态二进制，零运行时依赖。
- **索引**：SQLite（纯 Go 驱动，无 CGO），只存元数据，不存图片二进制。
- **你的原文件**：永远留在原位置，后端只读。删掉索引可以随时重建。
- **手机备份**：写入服务端自己拥有的 `library/` 目录，不会碰你自己的媒体文件夹。
- **媒体处理**：调用 `ffprobe` / `ffmpeg` 子进程，不链接 libav*。
- **客户端**：Flutter，桌面端与 Android 共用一套代码。视频播放用 `media_kit`（底层 libmpv），
  照片缩放用 Flutter 内置的 `InteractiveViewer`，网络层只用官方 `http`。

技术选型的完整理由见 [DECISIONS.md](DECISIONS.md)。

### 文档导航

| 文档 | 内容 |
|:---|:---|
| [技术文档.md](技术文档.md) | 前后端技术栈全清单、架构分层、目录结构逐项解析、关键数据流 |
| [开发计划.md](开发计划.md) | 阶段规划、阶段五/六的任务分解与风险、技术债、推进顺序建议 |
| [DECISIONS.md](DECISIONS.md) | 技术决策记录 D1–D26，含取舍理由与踩坑记录 |
| [packaging/INSTALL.md](packaging/INSTALL.md) | **面向使用者**的安装说明（随发布包分发），区别于本文档的开发者视角 |
| 本文档 | 快速开始、API 参考、开发与验证命令 |

---

## 快速开始

### 1. 编译并启动后端

```bash
cd backend
go build -o mediacenter-server .

# 首次启动会在 ~/.mediacenter 下生成 config.json（含随机访问令牌）
./mediacenter-server
```

启动后终端会打印可直接访问的地址与令牌：

```
MediaCenter-YourMac v0.1.0
  数据目录 : /Users/you/.mediacenter
  本机访问 : http://localhost:8080/?token=xxxxxxxx...
  局域网   : http://192.168.1.5:8080/?token=xxxxxxxx...
  访问令牌 : xxxxxxxx...
```

用浏览器打开那个地址，会看到一个状态页，可以确认服务是否正常、已索引多少内容。

### 2. 添加媒体目录

```bash
TOKEN=<你的令牌>

# 添加目录（会自动触发扫描）
curl -X POST http://localhost:8080/api/folders \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"path":"/Users/you/Pictures"}'

# 查看扫描进度
curl -H "Authorization: Bearer $TOKEN" http://localhost:8080/api/scan/status
```

> 数据目录下的 `library/`（手机备份的落盘位置）会在服务端启动时**自动注册**为扫描目录，
> 不需要也不应该手动添加。它同样**不能被移除**：`DELETE /api/folders/{id}` 会返回 409，
> 因为删掉它不会丢文件，但之后所有上传都不再进索引。

### 3. 运行客户端

```bash
cd client
flutter run -d macos     # 或 flutter run -d <android-device>
```

在连接页填入服务器地址（如 `192.168.1.5:8080`）与访问令牌即可。

---

## API 参考

除 `GET /` 与 `GET /api/ping` 外，**所有接口都需要令牌**。令牌可通过三种方式传递：

| 方式 | 示例 |
|:---|:---|
| 标准请求头（推荐） | `Authorization: Bearer <token>` |
| 自定义请求头 | `X-Token: <token>` |
| 查询参数 | `?token=<token>`（供 `<img src>` 等无法设置请求头的场景使用） |

### 服务器信息

| 方法 | 路径 | 说明 |
|:---|:---|:---|
| GET | `/api/ping` | 服务器名称与版本。**无需令牌**，用于连接探测 |
| GET | `/api/stats` | 索引统计、扫描状态、ffmpeg 可用性 |

### 媒体

| 方法 | 路径 | 说明 |
|:---|:---|:---|
| GET | `/api/media` | 分页媒体列表 |
| GET | `/api/media/{id}` | 单个媒体的完整元数据 |
| GET | `/api/media/{id}/thumbnail` | 缩略图（JPEG，最长边 320px，永久缓存） |
| GET | `/api/media/{id}/original` | 原文件，**支持 HTTP Range**，视频拖动依赖它 |

`/api/media` 查询参数：

| 参数 | 默认值 | 说明 |
|:---|:---|:---|
| `type` | 全部 | `photo` 或 `video` |
| `page` | 1 | 页码 |
| `page_size` | 60 | 每页数量（上限 500） |
| `sort` | `taken_at_desc` | `taken_at_asc` / `name_asc` / `size_desc` / `size_asc` / `indexed_desc` |
| `q` | — | 按文件名模糊搜索 |
| `from` / `to` | — | 拍摄时间范围（RFC3339） |
| `origin` | 全部 | `scan`（扫描入库）或 `upload`（手机备份上传） |

返回的每个媒体项都带 `origin` 字段，客户端可以据此区分"我传上去的"和"本来就有的"。

### 目录与扫描

| 方法 | 路径 | 说明 |
|:---|:---|:---|
| GET | `/api/folders` | 已配置的目录列表 |
| POST | `/api/folders` | 添加目录（自动触发扫描） |
| DELETE | `/api/folders/{id}` | 移除目录及其索引条目（**不删除磁盘文件**） |
| POST | `/api/scan/start` | 手动触发扫描，可传 `{"folder_id": 1}` 限定目录 |
| GET | `/api/scan/status` | 扫描进度 |

### 相册

| 方法 | 路径 | 说明 |
|:---|:---|:---|
| GET | `/api/albums` | 相册列表（含 `item_count` 与 `cover_url`） |
| POST | `/api/albums` | 创建相册，`{"name": "...", "description": "..."}` |
| GET | `/api/albums/{id}` | 单个相册 |
| PATCH | `/api/albums/{id}` | 部分更新；只传需要改的字段，未传的保持不变 |
| DELETE | `/api/albums/{id}` | 删除相册（**不影响媒体文件本身**） |
| GET | `/api/albums/{id}/media` | 相册内媒体，分页参数同 `/api/media` |
| POST | `/api/albums/{id}/media` | 加入成员，`{"media_ids": [1,2,3]}` |
| DELETE | `/api/albums/{id}/media` | 移出成员，可传 JSON body 或 `?media_ids=1,2,3` |
| GET | `/api/media/{id}/albums` | 反查某个媒体属于哪些相册 |

相册名的唯一性**大小写不敏感**（`COLLATE NOCASE`）。重复加入同一媒体是幂等的
（`added` 返回 0），单次请求最多 500 个 id。

### 手机备份上传

分片上传 + 断点续传 + 内容去重。文件最终落在 `<数据目录>/library/<年>/<月>/`，
并以 `origin='upload'` 入库，上传完成即可在 `/api/media` 里看到。

| 方法 | 路径 | 说明 |
|:---|:---|:---|
| POST | `/api/uploads` | 开会话；命中已有内容时直接秒传 |
| PUT | `/api/uploads/{id}/chunks/{index}` | 上传一片（body 为原始字节） |
| POST | `/api/uploads/{id}/complete` | 校验并落库，返回 `media` 对象 |
| GET | `/api/uploads/{id}` | 查询进度，返回**已收分片序号数组**（续传依据） |
| DELETE | `/api/uploads/{id}` | 取消并清理临时文件 |

`POST /api/uploads` 请求体：

```json
{
  "file_name": "IMG_0001.JPG",
  "file_size": 21723,
  "content_hash": "c53c76da...",   // 可选；提供则可秒传
  "chunk_size": 4194304             // 可选；服务端会夹到 256 KiB ~ 64 MiB
}
```

响应：命中已有内容时返回 `200 {"dedup": true, "media": {...}}`（**零字节传输**）；
否则返回 `201 {"upload_id": "...", "chunk_size": 4194304, "chunk_count": 1, "received": []}`。

**分片大小**：第 `i` 片写入偏移 `i * chunk_size`，最后一片为
`total_size - (chunk_count-1) * chunk_size`。大小不符会被拒绝（400）。

**断点续传**：`GET /api/uploads/{id}` 返回 `received: [0,2,5]` 这样的序号数组，
客户端只补缺失的分片即可。重复发送同一分片是幂等的，不会把进度灌水。

**内容哈希**（秒传与完整性校验共用，必须与服务端一致）：

```
sha256( 小端 uint64 文件大小 || 文件前 256 KiB || 文件后 256 KiB )
```

最后一段仅当文件大于 256 KiB 时计入。算法与扫描器共用一份实现；
`scripts/verify-upload.sh` 里的 `mc_hash()` 是一份可直接照抄的参考实现。

**错误语义**：

| 状态码 | 含义 |
|:---|:---|
| 400 | 参数非法（文件名含路径分隔符、分片大小不符、`file_size` < 1024 等） |
| 409 | 分片不齐时调用 `complete`（响应含 `missing` 列表），或会话已结束 |
| 415 | 扩展名不是支持的媒体类型 |
| 422 | **哈希不符**——收到的字节与声明不一致，文件不会进入媒体库 |
| 413 | `file_size` 超过 64 GiB 上限 |

**同名文件**不会互相覆盖：目标名已被占用时追加序号（`IMG_0001 (1).JPG`），
用 `O_CREAT|O_EXCL` 原子认领，两台手机同时备份同名文件也不会丢。

---

## 目录结构

```
media_center/
├── DECISIONS.md                 # 技术决策记录（含取舍理由）
├── README.md
├── backend/                     # Go 后端
│   ├── main.go                  # 入口：启动 HTTP 服务、mDNS 广播、打印横幅、优雅退出
│   ├── cmd/
│   │   ├── mdnsprobe/           # 诊断：从本机能否发现本服务
│   │   └── mcastcheck/          # 诊断：组播收发链路逐环节检查
│   └── internal/
│       ├── config/              # 配置加载与令牌生成
│       ├── store/               # SQLite 索引：建表与原地迁移、媒体/相册/上传会话
│       ├── scanner/             # 目录扫描、增量索引、失效清理；上传落库也走这里
│       ├── meta/                # EXIF 解析、ffprobe 元数据提取
│       ├── imageutil/           # 缩略图缩放（box 滤波）
│       ├── discovery/           # mDNS 服务广播（含网卡筛选与发送可达性预检）
│       └── api/                 # HTTP 路由、鉴权、中间件、分片上传
├── client/                      # Flutter 客户端
│   ├── lib/
│   │   ├── core/                # API 客户端、数据模型、分页、配置持久化、mDNS 发现
│   │   ├── widgets/             # 共享控件（媒体缩略图网格）
│   │   └── features/
│   │       ├── connect/         # 连接服务器：自动发现 + 手动输入兜底
│   │       ├── home/            # 主壳：图库 / 相册 / 影院 切换（响应式导航）
│   │       ├── gallery/         # 图库网格、全屏查看、服务器管理
│   │       ├── albums/          # 相册列表、详情、加入相册弹层
│   │       └── cinema/          # 影院列表、视频播放器
│   ├── tool/
│   │   └── mdns_probe.dart      # 诊断：从本机能否发现本服务（复用 core 里的同一份逻辑）
│   └── integration_test/        # 端到端验证（播放、相册、自动发现）
├── packaging/                   # 发布用的静态素材
│   ├── INSTALL.md               # 面向非开发者的安装说明（随每个发布包一起发）
│   └── service/                 # 各平台开机自启脚本
│       ├── darwin/              # LaunchAgent：install.sh / uninstall.sh
│       ├── linux/               # systemd user unit：install.sh / uninstall.sh
│       └── windows/             # 计划任务：install.cmd / uninstall.cmd / run.cmd
└── scripts/
    ├── make-test-media.sh       # 生成测试素材（含真实 EXIF 的 JPEG）
    ├── verify-api.sh            # 后端 API 回归验证
    ├── verify-albums.sh         # 相册功能回归验证（含级联清理）
    ├── verify-upload.sh         # 上传备份回归验证（自带服务端与独立数据目录）
    ├── build-release.sh         # 一次产出全部平台的发布包 + SHA256SUMS
    ├── smoke-test.sh            # 跨平台冒烟测试（可在容器里跑交叉编译产物）
    └── gen-android-icons.py     # 生成 Android 图标与启动图（15 个文件，见下）
```

> `dist/` 是 `build-release.sh` 的输出目录（6 个平台包合计约 130 MB），
> 已在 `.gitignore` 中排除——全部可以从源码重新产出。

---

## 开发

### 后端

```bash
cd backend
go vet ./...              # 静态检查
go build -o mediacenter-server .
go test ./...             # 单元测试（EXIF 解析、网卡筛选）
```

跨平台编译：

```bash
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -o mediacenter.exe .
CGO_ENABLED=0 GOOS=linux   GOARCH=amd64 go build -o mediacenter-linux .
CGO_ENABLED=0 GOOS=darwin  GOARCH=arm64 go build -o mediacenter-mac .
```

### 客户端

```bash
cd client
flutter analyze
flutter test               # 单元测试 + widget 测试
flutter run -d macos
```

端到端验证（会真实启动窗口、真实发 HTTP、真实用 libmpv 解码）：

```bash
# 需先启动后端，并确保后端索引里已有媒体
flutter test integration_test/playback_test.dart -d macos \
  --dart-define=MC_BASE_URL=http://127.0.0.1:18080 \
  --dart-define=MC_TOKEN=<令牌>

# 相册：新建 → 从图库长按加入 → 相册内可见 → 移出 → 删除
flutter test integration_test/album_test.dart -d macos \
  --dart-define=MC_BASE_URL=http://127.0.0.1:18080 \
  --dart-define=MC_TOKEN=<令牌>

# 自动发现：连接页能否在应用包内发现服务端（不预置服务器信息）
flutter test integration_test/discovery_test.dart -d macos
```

> 这三个测试能抓出 `flutter analyze` 和单元测试都看不见的缺陷。实际例子：在
> `showDialog` 外面 `await` 返回后立刻 `controller.dispose()`，会抛
> `A TextEditingController was used after being disposed`（`showDialog` 的 future 在
> `pop` 那一刻就完成了，而退场动画还没播完），并级联出几条看起来毫不相干的框架报错。
> 分析器对这类问题完全沉默。
>
> `discovery_test.dart` 单独说明一下：**`dart run tool/mdns_probe.dart` 能发现服务，
> 不等于应用里的客户端也能。** 应用有 bundle、有沙箱、有 macOS 15 起的本地网络隐私授权，
> 任何一条都能让组播静默失效，而界面只会显示"没有发现服务器"，看起来像局域网里真的没有
> 服务端。所以这条用例必须在真实应用包里跑，不能用命令行探测代替。

> **macOS 首次编译前置**：`media_kit` 依赖两个来自 GitHub 的原生产物，在
> `pod install` 时由各自的 `make` 下载。若网络无法直连 GitHub，需要先按
> SHA256 校验预置到各包的 `.cache/`（详见 `DECISIONS.md` D12）。另外，Debug
> 构建关闭了 App Sandbox —— 否则 `flutter test integration_test` 无法启动应用
> （详见 `macos/Runner/DebugProfile.entitlements` 内的说明）。

### Android 正式打包（签名）

release 包由 `client/android/app/upload-keystore.jks` 签名，密码与别名在同目录的
`key.properties` 里。**这两个文件都被 `.gitignore` 排除，不在版本库中。**

```bash
cd client
flutter build apk --release --split-per-abi
# → build/app/outputs/flutter-apk/app-arm64-v8a-release.apk    约 32 MB
#   build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk  约 29 MB
#   build/app/outputs/flutter-apk/app-x86_64-release.apk       约 37 MB
```

按 ABI 拆分后每个包只含一个 ABI；不加 `--split-per-abi` 的 universal 包会把三个 ABI
都装进去，95.6 MB。现代手机装 `arm64-v8a` 那一个就够。

验证签名（应打印出与 keystore 一致的 SHA-256，而不是 debug 证书）：

```bash
$ANDROID_HOME/build-tools/37.0.0/apksigner verify --print-certs \
  build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

当前签名证书指纹（换 keystore 时这里要同步更新）：

```
SHA-256  43:37:83:C2:7E:5B:6F:D0:02:27:4B:FD:44:57:64:BB:74:E9:2E:D0:82:CF:98:00:59:2E:A0:78:9B:F7:50:EA
SHA-1    80:81:AD:AA:79:16:00:E9:9F:5C:D9:25:7A:69:B2:CB:67:84:8D:45
```

> **`upload-keystore.jks` 和 `key.properties` 必须一起离线备份。**
> Android 靠签名证书识别"这是同一个应用"：keystore 丢了就再也签不出能覆盖安装的包，
> 只能换包名从头来（用户数据全丢）。缺 `key.properties` 同样打不开这个 keystore。

**找不到 `key.properties` 时 release 构建会直接失败**（而不是静默用 debug 密钥签出来），
报错里会说明原因和三种处理办法。这是刻意的：debug 签名的包与正式包签名不同，安装器会拒绝
覆盖安装，而"构建成功但升不了级"比"构建失败"更难发现。

- 只想确认代码能编过 → `flutter build apk --debug`
- 确实需要一个 debug 签名的 release 包 → 在 `android/gradle.properties` 里加
  `mc.allowDebugSigning=true`

> 为什么不做成"打一条警告然后继续"：实测 `flutter build apk` 会过滤掉 Gradle 的日志，
> 脚本里的 `logger.warn` 和 `println` 都看不到；而且 Gradle 9 默认开启配置缓存，
> 脚本体从第二次构建起就不再重新执行。**"打警告"这个机制既不一定显示、也不一定执行**，
> 只有构建失败是 Flutter 一定会透传给用户的。

> 版本号的唯一来源是 `pubspec.yaml` 的 `version: 1.0.0+1`（`+` 前是 versionName，
> 后是 versionCode），由 Flutter Gradle 插件注入，不要在 `build.gradle.kts` 里再写一份。
> **能不能覆盖升级由 versionCode 是否递增决定；签名决定的是"能不能装上"。**

#### 图标与启动图

图标不手绘，由脚本生成（改配色只改脚本里两个常量）：

```bash
/Users/zhangbaobao/.workbuddy-ai/binaries/python/envs/default/bin/python \
  scripts/gen-android-icons.py
```

一次产出 15 个文件：

| 用途 | 目录 | 尺寸 | 说明 |
|:---|:---|:---|:---|
| 传统图标 | `mipmap-{m,h,xh,xxh,xxxh}dpi/ic_launcher.png` | 48–192 | API 24-25 用，自带圆角方底（launcher 不裁切） |
| adaptive 前景 | `mipmap-*/ic_launcher_foreground.png` | 108–432 | API 26+ 用，只有白色图形；底色由 `drawable/ic_launcher_background.xml` 提供 |
| 启动图 logo | `drawable-*/launch_image.png` | 112–448 | 浅色底上用**渐变**图形（白色 logo 在浅底上看不见） |

> **改配色要同时改两处**：脚本里的 `BRAND_START` / `BRAND_END`，
> 以及 `drawable/ic_launcher_background.xml` 的渐变（adaptive 底色不走脚本）。
> 两边的注释互相指向对方。

> adaptive 前景的图形占比必须小于 0.667（108dp 画布只有中心 72dp 保证可见），
> 脚本里是 `ADAPTIVE_MARK_FRAC`，实测值 0.583。

### 跨平台发布与自启

一条命令产出全部平台的发布包：

```bash
./scripts/build-release.sh              # 版本号取 git describe --tags --always --dirty
./scripts/build-release.sh -v 0.2.0     # 或显式指定
```

产出 6 个归档 + `SHA256SUMS`：

| 目标 | 归档 | 二进制 |
|:---|:---|:---|
| `darwin/arm64` | `.tar.gz` | 11 MB |
| `darwin/amd64` | `.tar.gz` | 12 MB |
| `linux/amd64` | `.tar.gz` | 12 MB |
| `linux/arm64` | `.tar.gz` | 11 MB |
| `windows/amd64` | `.zip` | 12 MB |
| `android/arm64` | `.zip`（含 APK） | 31 MB |

每个包是一个自洽目录：二进制 + `INSTALL.md` + `service/`（自启脚本）。

**为什么一次就能出全部平台**：`CGO_ENABLED=0`。`modernc.org/sqlite` 是纯 Go 实现、
不含 cgo，所以交叉编译不需要任何目标平台的工具链或 sysroot。这是当初选
`modernc.org/sqlite` 而不是 `mattn/go-sqlite3` 换来的直接好处。

**版本号是注入进去的**，不是写死在源码里：

```bash
go build -ldflags "-s -w -X mediacenter/internal/api.Version=$VERSION"
```

`api.Version` 因此必须是 `var` 而不是 `const`（`-X` 改不了常量）。
`build-release.sh` 会在 host 平台真的执行一次 `mediacenter -version` 并断言版本号对得上——
注入失败是**静默的**（没有报错，只是版本号不对），只有自检能抓到。详见 `DECISIONS.md` D23。

#### 冒烟测试

`scripts/smoke-test.sh` 只依赖 `bash` + `curl`，自己造素材、自己起服务、跑完清理：

```bash
./scripts/smoke-test.sh ./dist/mediacenter-<v>-darwin-arm64/mediacenter "<v>"

# 交叉编译出来的 Linux 产物用容器跑（容器里现装 curl/bash）
docker run --rm --platform linux/amd64 -v "$PWD:/w" -w /w alpine:latest \
  sh -c 'apk add --no-cache curl bash >/dev/null && \
         bash ./scripts/smoke-test.sh ./dist/mediacenter-<v>-linux-amd64/mediacenter "<v>"'
```

17 项断言覆盖：`-version` 自报 + 版本注入生效 → 建库 → 加目录 → 扫描 → 索引 → 查库，
外加鉴权（无令牌 401 / 带令牌 200）与 SIGTERM 干净退出。

实测结果：

| 目标 | 执行方式 | 结果 |
|:---|:---|:---|
| `darwin/arm64` | 本机原生 | 17/17 |
| `darwin/amd64` | 本机 Rosetta 2 | 17/17 |
| `linux/arm64` | alpine 容器，原生 | 17/17 |
| `linux/amd64` | alpine 容器，QEMU 模拟 | 17/17 |
| `windows/amd64` | **未执行** | 仅结构校验 |

> Windows 只做了结构校验（`PE32+`、仅依赖 `kernel32.dll`、版本串已内嵌、`.cmd` 纯 ASCII），
> **没有在真机上运行过**。真要发 Windows 包之前应该先补上这一步。

> 脚本里变量后紧跟中文标点必须写成 `${VAR}`：UTF-8 locale 下 bash 会把多字节字符
> 吞进变量名，导致 `unbound variable`，而 `LC_ALL=C` 下却正常——是个环境相关的坑。
> 详见 `DECISIONS.md` D26。跑这些脚本时建议也顺手在 `LC_ALL=en_US.UTF-8` 下过一遍。

#### 开机自启

三个平台的 install / uninstall 脚本都在发布包的 `service/` 下：

| 平台 | 机制 | 安装 |
|:---|:---|:---|
| macOS | LaunchAgent（用户级，不需要 root） | `service/install.sh` |
| Linux | systemd user unit（不需要 root） | `service/install.sh` |
| Windows | 计划任务 `/SC ONLOGON /RL LIMITED`（不需要提权） | `service\install.cmd` |

三个平台都以 `-scan` 启动：扫描是增量的（size+mtime 未变则跳过），所以开机跑一遍
代价很低，换来"关机期间放进来的照片开机就能看到"。

端口被占用时**明确报错并以退出码 1 结束，不静默换端口**（用户已经拿到具体 URL 了），
报错里直接给出换端口写法和查占用者的命令。详见 `DECISIONS.md` D24。

### 生成测试素材

```bash
./scripts/make-test-media.sh /tmp/mc-test-media
```

会生成带真实 EXIF 拍摄时间的 JPEG（大端与小端 TIFF 各一份）、PNG、以及带
`creation_time` 元数据的 MP4，用于验证元数据解析与缩略图。

### 后端 API 回归验证

```bash
MC_DATA_DIR=/tmp/mc-data ./scripts/verify-api.sh          # 令牌自动从 config.json 读取
MC_TOKEN=<令牌> ./scripts/verify-api.sh http://host:port  # 或显式指定
```

覆盖 32 项断言：鉴权三种传参方式、EXIF 大小端、缩略图与缓存头、HTTP Range 四种形态
（含**分段拼接后 SHA256 与整体文件一致**，可抓出 Range 边界错位）、多音轨 MKV 元数据、
以及 404/400/416 等错误边界。

### 相册功能回归验证

```bash
MC_DATA_DIR=/tmp/mc-data ./scripts/verify-albums.sh
```

覆盖 43 项断言：相册 CRUD、大小写不敏感的唯一性、PATCH 部分更新语义、成员增删幂等、
封面推导与反向查询、删除相册不影响媒体本身，以及 G 段——把文件移出扫描目录后重扫，
确认成员关系被外键级联清理。G 段需要 `scripts/make-test-media.sh` 生成的素材，
找不到时会跳过而不是报失败。

### 上传备份回归验证

```bash
./scripts/verify-upload.sh              # 默认端口 18091
MC_PORT=19000 ./scripts/verify-upload.sh
```

**这个脚本与上面两个不同：它自带服务端。** 自己编译、自己起服务、自己建独立数据目录、
跑完清理，不依赖也不需要先跑起来的后端，也不会污染 `~/.mediacenter`。

覆盖 82 项断言：分片上传、**断点续传（只补缺失分片）**、秒传（`init` 阶段命中内容）、
`complete` 阶段的二次去重、哈希不符返回 422 且文件不入库、同名文件自动改名、
分片大小与序号越界、路径穿越文件名、取消后清理临时文件、媒体库目录不可删除，
以及**触发一次真实扫描后 `origin` 仍为 `upload`、不产生重复行**。

后端单元测试另外覆盖了数据库迁移：

```bash
cd backend && go test ./...
```

其中 `store` 包用第一版建表语句造一个"老库"，验证升级后历史行不丢、`origin` 自动获得
`'scan'`；并锁住"重扫不得覆盖 `origin`""重发分片不得灌水进度"这两条约定。

### mDNS 自动发现诊断

发现功能要么在用户的网络上真的可用，要么毫无价值，而失败时通常是**静默**的。
两个诊断工具用来把"到底哪一环断了"变成可回答的问题：

```bash
cd backend
go run ./cmd/mdnsprobe              # 从本机能发现本服务吗？（标准 mDNS 浏览器视角）
go run ./cmd/mcastcheck -iface en0  # 组播收发链路逐环节检查（bind / join / send）

cd ../client
dart run tool/mdns_probe.dart       # 客户端那份逻辑能否发现本服务（复用 lib/core 的同一实现）
```

`mdnsprobe` 期望在 1～2 秒内看到服务，并打印出客户端实际会拿到的地址。若服务器横幅里
的地址与它打印的地址不一致，就是问题所在。

客户端那份诊断**刻意复用 `lib/core/server_discovery.dart`**，而不是另写一套：两边各写一份
的话，改了实现却忘了改诊断工具，就会拿旧逻辑去证明新代码没问题。

---

## 已实现的细节

- **增量扫描**：按 `(文件大小, 修改时间)` 判断是否跳过，重复扫描是幂等的。
- **失效清理**：文件从磁盘消失后，重新扫描会移除对应索引条目与孤儿缩略图。
- **稳定身份**：`content_hash = sha256(大小 + 前 256 KiB + 后 256 KiB)`，文件移动或重命名后仍可识别。
- **时间线兜底**：优先取 EXIF `DateTimeOriginal`，其次视频 `creation_time`，最后降级为文件修改时间，保证时间线不缺失。
- **并发模型**：worker pool 并行做哈希/元数据/缩略图，数据库写入经单个 goroutine 串行化。
- **缩略图按内容哈希寻址**：因此 URL 不可变，可设置 `Cache-Control: immutable` 让客户端永久缓存。
- **按需生成缩略图**：缓存被清空后，访问接口会重新生成。
- **视频原文件直连播放**：后端不转码，`media_kit`（libmpv）通过 HTTP Range 按需拉取，拖动进度不产生额外服务端开销。
- **音轨与字幕轨切换**：MKV 内封的多音轨、内封字幕由 libmpv 直接解析，客户端提供轨道选择面板。
- **相册成员关系靠外键级联**：`album_items` 对 `media_files` 声明 `ON DELETE CASCADE`，
  媒体条目被清理时成员关系自动消失，不会留下指向空气的孤儿行。索引里没有的 id 一律拒绝，
  因此"相册里的每一项都能打开"是数据库层面保证的，而不是靠应用层记得去清理。
- **mDNS 自动发现**：后端启动时广播 `_mediacenter._tcp`，TXT 记录带服务器名、版本、API 版本。
  **访问令牌刻意不放进 TXT**——同网段任何设备（包括访客 Wi-Fi）都能读到它，发现只负责
  "告诉客户端服务器在哪"，客户端仍须自己证明有权访问。
- **只广播真实局域网网卡**：见下方"已知限制"里关于虚拟机网桥的说明，这不是洁癖而是正确性问题。
- **组播发送可达性预检**：启动时会真的试发一个包，因为所用的 mDNS 库会**丢弃**发送错误，
  导致"广播成功"和"一个包都没发出去"在日志上完全一样。
- **客户端自动发现走纯 Dart 组播**：客户端自己发 PTR 查询、解析 SRV/A/TXT，不引入平台通道，
  也不依赖 Bonjour API。连接页进页面就开始搜，只发现到一台时顺手填好地址；手动输入始终保留，
  因为跨网段和被 VPN 拦截的场景本来就发现不到。
- **发现只填地址，不填令牌**：令牌不在 TXT 里（见上），客户端仍须自己输入。发现只解决
  "服务器在哪"，不解决"我有没有权限"。
- **备份上传用分片直落目标偏移**：每片用 `WriteAt` 写到最终位置，`complete` 只是一次
  `rename`，4 GB 视频不会多读写一遍，也不会在合并期间额外占一份空间。全程 `io.Copy`，
  没有任何一处按文件大小分配内存。
- **上传进度以分片表为准**：`received_chunks` 由 `COUNT(*)` 重算而非自增，因此重发一个
  已到达的分片不会把进度灌水。`GET /api/uploads/{id}` 返回的是**已收分片序号数组**，
  断线重连只需补缺失的那几片。
- **内容去重（秒传）**：`init` 阶段若客户端给出 `content_hash` 且服务端已有该内容，
  直接返回已有媒体对象，**零字节传输**；`complete` 阶段会再算一次哈希，即使客户端
  没声明哈希也能识别出重复，此时丢弃刚收到的临时文件。
- **哈希既是去重键也是完整性证据**：`complete` 阶段重算哈希并与声明比对，不符返回 422
  且文件**根本不进媒体库**。顺序是"先校验、再入库、最后索引"——颠倒的话会先留下一个
  用户看不见却占着空间的残留。
- **同名文件原子认领**：用 `O_CREAT|O_EXCL` 一步完成"检查并占位"，冲突时追加序号
  （`IMG_0001 (1).JPG`）。两台手机同时备份同名文件是常态，不是边界情况。
- **媒体库目录由服务端拥有并自动注册为扫描目录**：上传与扫描因此共用一条索引管线，
  哈希、EXIF、缩略图规则只有一份实现；同时 `DELETE /api/folders/{id}` 会拒绝删除它，
  避免"之后所有上传都不再进索引"这种看起来像数据丢失的状态。
- **上传临时文件不放在媒体库里**：未完成的分片在 `<数据目录>/uploads/`，避免半个文件
  被扫描器当成媒体走一遍完整流程。启动时回收超过 24 小时的未完成会话，且只删除该目录内的路径。
- **数据库原地迁移**：`CREATE TABLE IF NOT EXISTS` 对已存在的表不生效，所以新增列走
  `PRAGMA table_info` 判断 + `ALTER TABLE ADD COLUMN`，老库直接升级、历史数据不丢、无需重建。

## 已知限制

- **HEIC 支持依赖 ffmpeg**：标准库读不了 HEIC，缩略图走 ffmpeg 兜底。未安装 ffmpeg 时 iPhone 照片的缩略图会缺失。
- **iOS 未适配**：需要声明本地网络权限、为明文 HTTP 配置 ATS 例外，且真机分发成本高。
- **mDNS 只在真实局域网网卡上广播**：虚拟机网桥（macOS 的 `bridge*` / `vmenet*`）、VPN 隧道
  （`utun*`）一律不广播。原因是所用的 mDNS 库会把传入网卡的地址**合并成一份 A 记录放进每个
  响应**，一旦把网桥也传进去，同一台机器就会向真实 Wi-Fi 上的手机宣告多个不可达地址，
  客户端选错就连不上且没有任何有用的报错。代价是虚拟机里的客户端无法自动发现本机，
  需要手动输入地址（横幅里会打印）。
- **组播被 VPN 或网络策略拦截时无法自动发现**：部分 VPN 客户端会把组播流量也路由走隧道，
  此时服务器会在横幅里打印一条明确的警告，而不是假装广播成功。客户端需手动输入地址。
- **客户端发现只解析 IPv4**：只查 A 记录。后端广播的地址已过滤掉虚拟网卡，拿到的就是对方
  在真实局域网上的地址；但纯 IPv6 网络下会发现不到，需手动输入。
- **发现失败时是静默降级**：连接页只会显示"没有发现服务器"，不区分"局域网里确实没有"和
  "被系统拦了"。macOS 15 起需要 `NSLocalNetworkUsageDescription`（已加），Release 沙箱还需
  `com.apple.security.network.server`（已加）——**这两项在 Debug 下都看不出来，因为 Debug
  刻意关了沙箱**。改动这两处配置后必须跑一次 `integration_test/discovery_test.dart`。
- **全局共享令牌**：尚未支持按设备发放与吊销。
- **老设备上的 10-bit HEVC**：不转码意味着解码能力完全取决于客户端。桌面端 libmpv 没问题，老款 Android 设备可能放不了。低成本兜底是 remux（换容器不重编码），尚未实现。
- **视频播放依赖 libmpv 原生库**：首次编译需要下载约 16 MB 的 macOS 原生框架包与 mpv 头文件。网络受限环境下需离线预置（见 `DECISIONS.md` D12），否则会在 Swift 编译阶段报 `cannot find type 'mpv_node_list' in scope`，而这个错误信息完全指不到真正的原因。
- **Debug 构建未启用 App Sandbox**：为让端到端集成测试能启动应用而做的取舍，Release 构建仍然开启沙箱。
- **备份上传暂无客户端**：后端接口已完整可用并经过 82 项断言验证，但手机端尚未接入。
- **上传会话 24 小时后被回收**：跨天中断的传输需要重新开始。客户端侧应把上传状态持久化到本地，
  重启后主动续传（属于阶段五客户端任务）。
- **上传最小 1 KiB**：与扫描器的下限保持一致——扫描器会跳过小于 1 KiB 的文件，接受更小的上传
  会产生一条下次扫描立刻被清理的索引行。
- **秒传依赖客户端算出哈希**：算法不一致时不会报错，只是每次都退化为全量传输。算法已写成
  可照抄的参考实现（见上文与 `scripts/verify-upload.sh` 的 `mc_hash()`）。

## 路线图

| 阶段 | 内容 | 状态 |
|:---|:---|:---|
| 一 | 后端核心：扫描、索引、缩略图、Range、鉴权 | 已完成 |
| 二 | 客户端照片浏览：网格、缩放查看、服务器管理 | 已完成 |
| 三 | 影院功能：`media_kit` 视频播放、音轨/字幕切换 | 已完成 |
| 四 | 相册管理 | 已完成：后端 API + 级联清理（43 项断言）、客户端界面（端到端测试通过） |
| 四 | mDNS 自动发现 | 已完成：后端广播（`dns-sd` / `cmd/mdnsprobe` 可发现）+ 客户端连接页自动发现（应用包内端到端验证通过） |
| 五 | 手机照片备份上传 · **后端** | 已完成：5 个接口 + 分片续传 + 去重秒传 + 原地迁移（82 项断言 + 6 项单元测试） |
| 五 | 手机照片备份上传 · **客户端** | 待开始（Android 权限、媒体选择器、上传队列、前台服务保活） |
| 六 | Android 打包、跨平台二进制、开机自启 | 进行中：正式签名 + split-per-abi + 图标与启动图已完成；三平台交叉编译、自启、发布包待做 |
