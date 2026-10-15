# 本地私有化媒体中心

相册 + 影院的本地私有化部署方案。数据全部留在你自己的主机上，客户端通过局域网直连，
不经过任何云端服务。

**当前进度：阶段一（后端核心）、阶段二（照片浏览）、阶段三（影院播放）已完成并通过验证。**

---

## 架构

```
┌─────────────────────────────────────────────────────┐
│                  你的主机（本地）                     │
│                                                       │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────┐ │
│  │ 媒体文件夹    │─▶│  后端服务     │─▶│  SQLite    │ │
│  │ 原始照片/视频 │  │  Go · :8080  │  │  元数据索引 │ │
│  └──────────────┘  └──────┬───────┘  └────────────┘ │
│                            │                          │
│                     ┌──────▼───────┐                  │
│                     │  缩略图缓存   │                  │
│                     │  thumbs/     │                  │
│                     └──────────────┘                  │
└──────────────────────────┬───────────────────────────┘
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
- **原文件**：永远留在原位置，后端只读。删掉索引可以随时重建。
- **媒体处理**：调用 `ffprobe` / `ffmpeg` 子进程，不链接 libav*。
- **客户端**：Flutter，桌面端与 Android 共用一套代码。视频播放用 `media_kit`（底层 libmpv），
  照片缩放用 Flutter 内置的 `InteractiveViewer`，网络层只用官方 `http`。

技术选型的完整理由见 [DECISIONS.md](DECISIONS.md)。

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
│       ├── store/               # SQLite 索引：建表、查询、相册数据层
│       ├── scanner/             # 目录扫描、增量索引、失效清理
│       ├── meta/                # EXIF 解析、ffprobe 元数据提取
│       ├── imageutil/           # 缩略图缩放（box 滤波）
│       ├── discovery/           # mDNS 服务广播（含网卡筛选与发送可达性预检）
│       └── api/                 # HTTP 路由、鉴权、中间件
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
└── scripts/
    ├── make-test-media.sh       # 生成测试素材（含真实 EXIF 的 JPEG）
    ├── verify-api.sh            # 后端 API 回归验证
    └── verify-albums.sh         # 相册功能回归验证（含级联清理）
```

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

覆盖 35 项断言：鉴权三种传参方式、EXIF 大小端、缩略图与缓存头、HTTP Range 四种形态
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

## 路线图

| 阶段 | 内容 | 状态 |
|:---|:---|:---|
| 一 | 后端核心：扫描、索引、缩略图、Range、鉴权 | 已完成 |
| 二 | 客户端照片浏览：网格、缩放查看、服务器管理 | 已完成 |
| 三 | 影院功能：`media_kit` 视频播放、音轨/字幕切换 | 已完成 |
| 四 | 相册管理 | 已完成：后端 API + 级联清理（43 项断言）、客户端界面（端到端测试通过） |
| 四 | mDNS 自动发现 | 已完成：后端广播（`dns-sd` / `cmd/mdnsprobe` 可发现）+ 客户端连接页自动发现（应用包内端到端验证通过） |
| 五 | 手机照片备份上传 | 待开始 |
| 六 | Android 打包、跨平台二进制、开机自启 | 待开始 |
