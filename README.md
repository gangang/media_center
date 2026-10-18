# 本地私有化媒体中心

相册与影院的本地私有化部署方案。后端以单个静态二进制运行，客户端通过局域网直连，
数据与索引全部保存在自己的主机上，不依赖任何云端服务。

- **后端**：Go，编译为单文件静态二进制，零运行时依赖。
- **索引**：SQLite（纯 Go 驱动，无 CGO），只存元数据，不存图片二进制。
- **原文件**：留在原位置，后端只读；删除索引后可随时重建。
- **手机备份**：写入数据目录下的 `library/`，不触碰用户自己的媒体目录。
- **媒体处理**：调用 `ffprobe` / `ffmpeg` 子进程，不链接 libav*。
- **客户端**：Flutter，桌面端与 Android 共用一套代码。视频播放基于 `media_kit`（libmpv），
  照片缩放使用内置 `InteractiveViewer`，网络层仅使用官方 `http`。

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

## 目录结构

```
backend/            Go 后端：HTTP API、扫描器、SQLite、mDNS 广播
  cmd/mdnsprobe/    mDNS 诊断工具
  cmd/mcastcheck/   组播可达性诊断工具
client/             Flutter 客户端：桌面端与 Android
  lib/core/         API 客户端、上传引擎、发现逻辑
  lib/features/     相册、影院、连接页
  integration_test/ 端到端测试
packaging/          安装说明与三平台开机自启脚本
scripts/            发布构建、冒烟测试、回归验证
```

## 快速开始

不想编译的，直接下载预编译版本（5 个平台的服务端 + Android 包）：
[Releases](https://github.com/gangang/media_center/releases)。解压后读里面的 `INSTALL.md`。

以下是从源码构建的方式。

### 1. 编译并启动后端

```bash
cd backend
go build -o mediacenter-server .
./mediacenter-server
```

首次启动在 `~/.mediacenter` 下生成 `config.json`（含随机访问令牌），终端打印可直接访问的地址：

```
MediaCenter-YourMac v0.1.0
  数据目录 : /Users/you/.mediacenter
  本机访问 : http://localhost:8080/?token=xxxxxxxx...
  局域网   : http://192.168.1.5:8080/?token=xxxxxxxx...
  访问令牌 : xxxxxxxx...
```

浏览器打开该地址显示状态页，可确认服务是否正常与已索引数量。

### 2. 添加媒体目录

```bash
TOKEN=<令牌>

# 添加目录，自动触发扫描
curl -X POST http://localhost:8080/api/folders \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"path":"/Users/you/Pictures"}'

# 查看扫描进度
curl -H "Authorization: Bearer $TOKEN" http://localhost:8080/api/scan/status
```

数据目录下的 `library/` 在服务端启动时自动注册为扫描目录，无需手动添加，且不能被移除
（`DELETE /api/folders/{id}` 返回 409）。

### 3. 运行客户端

```bash
cd client
flutter run -d macos              # 或 flutter run -d <android-device>
```

在连接页填入服务器地址（如 `192.168.1.5:8080`）与访问令牌。

## API 参考

除 `GET /` 与 `GET /api/ping` 外，所有接口都需要令牌。令牌支持三种传递方式：

| 方式 | 示例 |
|:---|:---|
| 标准请求头（推荐） | `Authorization: Bearer <token>` |
| 自定义请求头 | `X-Token: <token>` |
| 查询参数 | `?token=<token>`（供 `<img src>` 等无法设置请求头的场景） |

令牌有两种：

- **主令牌**：`config.json` 里的那个，首次启动时随机生成。它能做所有事，包括签发和吊销设备令牌。
- **设备令牌**：为每台设备单独签发。丢了手机只需要吊销那一个，其他设备不受影响。

设备令牌只存 SHA-256 摘要，明文只在签发的那一刻返回一次，之后无法再取回。

| 方法 | 路径 | 说明 |
|:---|:---|:---|
| GET | `/api/tokens` | 已签发的设备令牌（不含明文），**仅主令牌可用** |
| POST | `/api/tokens` | 签发一个，`{"name": "我的手机"}`，响应里的 `token` 只出现这一次 |
| DELETE | `/api/tokens/{id}` | 吊销，立即生效；重复吊销同样返回 204 |

```bash
# 给手机签一个
curl -X POST http://localhost:8080/api/tokens \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"name":"我的手机"}'
```

### 服务器信息

| 方法 | 路径 | 说明 |
|:---|:---|:---|
| GET | `/api/ping` | 服务器名称与版本，无需令牌，用于连接探测 |
| GET | `/api/stats` | 索引统计、扫描状态、ffmpeg 可用性、HEIC 缩略图能力 |

### 媒体

| 方法 | 路径 | 说明 |
|:---|:---|:---|
| GET | `/api/media` | 分页媒体列表 |
| GET | `/api/media/{id}` | 单个媒体的完整元数据 |
| GET | `/api/media/{id}/thumbnail` | 缩略图（JPEG，最长边 320px，永久缓存） |
| GET | `/api/media/{id}/original` | 原文件，支持 HTTP Range |
| PATCH | `/api/media/{id}` | 改名或移动，**仅主令牌**，见下 |
| DELETE | `/api/media/{id}` | 删除文件（索引 + 磁盘 + 缩略图），**仅主令牌**，见下 |
| POST | `/api/media/move` | 批量移动，**仅主令牌** |
| POST | `/api/media/delete` | 批量删除，**仅主令牌** |

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

列表项含 `file_path`（文件在服务端的绝对路径），对任何已认证设备可见——
那些设备本来就能拉原图，目录结构是两者中较小的暴露面。列目录的
`GET /api/fs/browse` 则仍然只给主令牌。

#### 文件管理（改名 / 移动 / 删除）

三者都要求**两层授权**：令牌是主令牌，且文件位于已注册的扫描目录之内。
取消注册目录即收回其授权，文件仍在磁盘上、索引也还在。

| 方法 | 路径 | 请求体 | 说明 |
|:---|:---|:---|:---|
| PATCH | `/api/media/{id}` | `{"name": "新名字.jpg"}` | 改名，扩展名不可改 |
| PATCH | `/api/media/{id}` | `{"folder_id": 2}` | 移动到另一个已注册目录 |
| POST | `/api/media/move` | `{"ids": [1,2], "folder_id": 2}` | 批量移动，单次上限 200 |
| DELETE | `/api/media/{id}` | — | 删除单个文件 |
| POST | `/api/media/delete` | `{"ids": [1,2,3]}` | 批量删除，单次上限 200 |

几个必须知道的行为：

- **改名是原地更新那一行索引**，媒体 `id` 不变，因此相册成员关系不会丢。
  缩略图按内容哈希寻址，内容没变就不重制。
- 目标目录已有同名文件时，服务端按 ` (1)`、` (2)` 自动追加序号，
  响应里的 `applied_name` 是最终采用的名字，界面应以它为准。
- 跨卷移动（内置盘 ↔ 外接盘）自动退回复制 + 校验 + 删源。
- **删除是删磁盘文件**，不是只删索引——只删索引会被下次扫描当新文件复活。
  文件已经不在时仍然删行，响应带 `file_existed: false`。
  文件存在但删不掉（只读盘、权限）时返回 400，索引行保留。
- 批量操作返回逐项明细，不整批回滚：
  `{"deleted": 2, "failed": 1, "results": [{"id": 1, "ok": true}, {"id": 5, "ok": false, "error": "..."}]}`

### 目录与扫描

| 方法 | 路径 | 说明 |
|:---|:---|:---|
| GET | `/api/folders` | 已配置的目录列表 |
| POST | `/api/folders` | 添加目录，自动触发扫描 |
| DELETE | `/api/folders/{id}` | 移除目录及其索引条目，不删除磁盘文件 |
| POST | `/api/scan/start` | 手动触发扫描，可传 `{"folder_id": 1}` 限定目录 |
| GET | `/api/scan/status` | 扫描进度 |
| GET | `/api/fs/browse?path=` | 列服务端目录，**仅主令牌**，见下 |

`GET /api/fs/browse` 供客户端做目录挑选器（手机不可能知道 Mac 的绝对路径）。
只列直接子目录，不提供文件内容访问；它唯一天职是「注册为扫描目录」，
浏览本身不构成授权。

| 字段 | 说明 |
|:---|:---|
| `entries` | 子目录，按名称排序、隐藏目录排最后并置灰；不含符号链接目录 |
| `parent` | 父目录（根目录时为 null） |
| `home` | 服务端用户主目录 |
| `shortcuts` | 服务端按平台算好的一键入口：主目录、图片目录、`/Volumes`、`/media`、Windows 盘符 |
| `truncated` | 子目录超过 500 条时为 true，客户端应提示改用手动输入 |

### 相册

| 方法 | 路径 | 说明 |
|:---|:---|:---|
| GET | `/api/albums` | 相册列表（含 `item_count` 与 `cover_url`） |
| POST | `/api/albums` | 创建相册，`{"name": "...", "description": "..."}` |
| GET | `/api/albums/{id}` | 单个相册 |
| PATCH | `/api/albums/{id}` | 部分更新，只改传入的字段 |
| DELETE | `/api/albums/{id}` | 删除相册，不影响媒体文件本身 |
| GET | `/api/albums/{id}/media` | 相册内媒体，分页参数同 `/api/media` |
| POST | `/api/albums/{id}/media` | 加入成员，`{"media_ids": [1,2,3]}` |
| DELETE | `/api/albums/{id}/media` | 移出成员，可传 JSON body 或 `?media_ids=1,2,3` |
| GET | `/api/media/{id}/albums` | 反查媒体所属相册 |

相册名唯一性大小写不敏感（`COLLATE NOCASE`）。重复加入同一媒体是幂等的，单次请求最多 500 个 id。

### 手机备份上传

分片上传 + 断点续传 + 内容去重。文件落在 `<数据目录>/library/<年>/<月>/`，以 `origin='upload'` 入库。

客户端侧的上传引擎（哈希、分片、续传、重试、秒传、取消）已完成并有单元测试覆盖。
Android 客户端的「备份」页已经接入：申请相册权限 → 选片 → 排队上传，上传期间用前台服务保活，
断网或切到后台都不会让任务半途而废。桌面端不显示这个入口——桌面上的文件本来就在磁盘里，
直接放进扫描目录即可。

接口本身也可直接调用：

| 方法 | 路径 | 说明 |
|:---|:---|:---|
| POST | `/api/uploads` | 开会话；命中已有内容时直接秒传 |
| PUT | `/api/uploads/{id}/chunks/{index}` | 上传一片（body 为原始字节） |
| POST | `/api/uploads/{id}/complete` | 校验并落库，返回 `media` 对象 |
| GET | `/api/uploads/{id}` | 查询进度，返回已收分片序号数组 |
| DELETE | `/api/uploads/{id}` | 取消并清理临时文件 |

`POST /api/uploads` 请求体：

```json
{
  "file_name": "IMG_0001.JPG",
  "file_size": 21723,
  "content_hash": "c53c76da...",
  "chunk_size": 4194304
}
```

`content_hash` 与 `chunk_size` 可选。命中已有内容时返回 `200 {"dedup": true, "media": {...}}`；
否则返回 `201 {"upload_id": "...", "chunk_size": 4194304, "chunk_count": 1, "received": []}`。

第 `i` 片写入偏移 `i * chunk_size`，最后一片长度为 `total_size - (chunk_count-1) * chunk_size`，
大小不符返回 400。`GET /api/uploads/{id}` 返回 `received: [0,2,5]`，客户端据此只补缺失分片；
重复发送同一分片是幂等的。

内容哈希算法（秒传与完整性校验共用）：

```
sha256( 小端 uint64 文件大小 || 文件前 256 KiB || 文件后 256 KiB )
```

最后一段仅当文件大于 256 KiB 时计入。`scripts/verify-upload.sh` 中的 `mc_hash()` 是参考实现。

| 状态码 | 含义 |
|:---|:---|
| 400 | 参数非法（文件名含路径分隔符、分片大小不符、`file_size` < 1024 等） |
| 409 | 分片不齐时调用 `complete`（响应含 `missing` 列表），或会话已结束 |
| 413 | `file_size` 超过 64 GiB 上限 |
| 415 | 扩展名不是支持的媒体类型 |
| 422 | 哈希不符，文件不进入媒体库 |

同名文件不互相覆盖：目标名被占用时追加序号（`IMG_0001 (1).JPG`），以 `O_CREAT|O_EXCL` 原子认领。

### HEIC（iPhone 照片）

HEIC 会正常入库、正常下载，但缩略图能不能生成取决于 `ffmpeg` 有没有 HEVC 解码器——
Go 标准库读不了 HEIC，这一条路完全靠外部工具。用 `GET /api/stats` 的 `heic_thumbnails`
可以直接看出来：

```json
{ "ffmpeg_available": true, "heic_thumbnails": true }
```

`false` 时照片仍在库里、原图仍可下载，只是列表里显示占位图。换成带 HEVC 支持的 ffmpeg 即可，
不需要改动服务端。

## 开发

### 后端

```bash
cd backend
go vet ./...              # 静态检查
go build -o mediacenter-server .
go test ./...             # 单元测试
```

跨平台编译（`CGO_ENABLED=0`，无需目标平台工具链）：

```bash
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -o mediacenter.exe .
CGO_ENABLED=0 GOOS=linux   GOARCH=amd64 go build -o mediacenter-linux .
CGO_ENABLED=0 GOOS=darwin  GOARCH=arm64 go build -o mediacenter-mac .
```

### 客户端

```bash
cd client
flutter analyze
flutter test
flutter run -d macos
```

`flutter test` 需要先摘掉代理环境变量，否则测试会在加载阶段报
`Unable to connect to flutter_tester process: Invalid WebSocket upgrade request`：

```bash
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY flutter test
```

端到端验证（真实启动窗口、真实发 HTTP、真实用 libmpv 解码）：

```bash
# 需先启动后端，且后端索引里已有媒体
flutter test integration_test/playback_test.dart -d macos \
  --dart-define=MC_BASE_URL=http://127.0.0.1:18080 \
  --dart-define=MC_TOKEN=<令牌>

flutter test integration_test/album_test.dart -d macos \
  --dart-define=MC_BASE_URL=http://127.0.0.1:18080 \
  --dart-define=MC_TOKEN=<令牌>

# 上传链路：客户端队列 + 真实 HTTP + 真实后端（不需要窗口）
flutter test integration_test/upload_test.dart -d macos \
  --dart-define=MC_BASE_URL=http://127.0.0.1:18080 \
  --dart-define=MC_TOKEN=<令牌>

flutter test integration_test/discovery_test.dart -d macos
```

macOS 首次编译需要 `media_kit` 的两个 GitHub 原生产物（约 16 MB），由 `pod install` 时的
`make` 下载；网络无法直连 GitHub 时需先按 SHA256 预置到各包的 `.cache/`。

### Android 正式打包

release 包由 `client/android/app/upload-keystore.jks` 签名，密码与别名在同目录的
`key.properties` 中。两个文件均被 `.gitignore` 排除，需自行生成并离线备份。

```bash
cd client
flutter build apk --release --split-per-abi
# build/app/outputs/flutter-apk/app-arm64-v8a-release.apk   约 32 MB
# build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk 约 29 MB
# build/app/outputs/flutter-apk/app-x86_64-release.apk      约 37 MB
```

验证签名：

```bash
$ANDROID_HOME/build-tools/<ver>/apksigner verify --print-certs \
  build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

缺少 `key.properties` 时 release 构建直接失败，不会静默使用 debug 密钥。仅需确认代码可编译时用
`flutter build apk --debug`；确实需要 debug 签名的 release 包时，在 `android/gradle.properties`
中加入 `mc.allowDebugSigning=true`。

图标与启动图由脚本生成（依赖 Pillow，改配色需同时修改脚本常量与
`drawable/ic_launcher_background.xml`）：

```bash
python3 scripts/gen-android-icons.py
```

### 发布包与验证

```bash
./scripts/build-release.sh              # 版本号取 git describe --tags --always --dirty
./scripts/build-release.sh -v 0.2.0     # 或显式指定
```

产出 5 个平台的归档（darwin/arm64、darwin/amd64、linux/amd64、linux/arm64、windows/amd64）
及 Android 包，附 `SHA256SUMS`。每个包内含二进制、`INSTALL.md` 与 `service/` 自启脚本。

```bash
# 发布二进制冒烟测试（仅依赖 bash + curl）
./scripts/smoke-test.sh ./dist/mediacenter-<v>-darwin-arm64/mediacenter "<v>"

# 接口回归：默认 http://127.0.0.1:18080，令牌取 MC_TOKEN 或数据目录下的 config.json
./scripts/verify-api.sh
./scripts/verify-albums.sh

# 上传接口回归：自带服务端与独立数据目录，跑完自动清理（默认端口 18091）
./scripts/verify-upload.sh

# 生成测试素材
./scripts/make-test-media.sh <输出目录>
```

## 许可证

本项目以 Apache License 2.0 发布，完整条款见 [LICENSE](LICENSE)。

```
Copyright 2026 ganggang

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

第三方依赖各自遵循其原有许可证：Go 模块见 `backend/go.mod`，Flutter 包见 `client/pubspec.yaml`，
macOS 端的 libmpv 原生库见 `client/macos`。本项目不附带 ffmpeg，仅做检测与提示。
