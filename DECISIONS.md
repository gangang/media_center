# 技术决策记录

本文件记录**已经定下来的**决策与理由。后续如要推翻，请在这里追加一条新记录，而不是直接改旧条目——保留决策演进的痕迹。

---

## D1. 第一场景是"浏览已有媒体库"，手机备份后置

**决策**：MVP 只做只读浏览——扫描主机上的现有文件夹，客户端浏览、查看、播放。手机照片上传备份放到后续阶段单独设计。

**理由**：用户明确回答。备份功能会引入上传通道、断点续传、内容去重、冲突处理、后台同步、iOS 后台限制等一系列问题，工作量翻倍，且与"浏览"的架构正交。先把只读链路做扎实。

**影响**：`/api/media` 系列接口全部是只读的；`media_files` 表不需要 `source`（上传/扫描）字段。后续加上传时，需要新增 `uploads` 表与分片上传接口，`media_files` 增加 `origin` 字段区分来源。

---

## D2. 后端语言用 Go，而不是 Rust

**决策**：后端使用 Go。

**理由**：用户的硬性指标是"方便快捷的安装"。在这一条上 Go 明显占优：

| 维度 | Go | Rust |
|:---|:---|:---|
| 单文件分发 | `CGO_ENABLED=0 go build` 直接产出静态二进制 | 默认动态链接 glibc，静态链接需额外配置 |
| 交叉编译 | `GOOS=windows GOARCH=amd64 go build` 一条命令 | 需要 cross / cargo-zigbuild 等额外工具链 |
| SQLite 驱动 | `modernc.org/sqlite` 纯 Go，无需 CGO | `rusqlite` 需链接 C 库 |
| 媒体库调用 | `os/exec` 调 ffmpeg 子进程，天然简单 | `ffmpeg-next` 是绑定 crate，编译与静态链接都痛苦 |
| 开发速度 | 快 | 慢（所有权/生命周期心智负担） |

原方案中"Rust 的编译产物更干净，用户不需要装运行时"这一论据，对 Go 同样成立。Rust 真正的优势（内存安全、极限性能、无 GC）在一个家庭规模的 I/O 密集型媒体服务器上并不构成实际收益。

**如果将来要推翻**：只有在需要把转码、AI 推理等 CPU 密集任务内联进主进程、且对延迟有极致要求时，才值得重新评估。

---

## D3. 用 ffprobe / ffmpeg 子进程，不链接 libav*

**决策**：元数据提取调用 `ffprobe`，缩略图兜底调用 `ffmpeg`，通过 `os/exec` 启动子进程。

**理由**：
1. 不引入 C 依赖，保持 `CGO_ENABLED=0` 的纯静态编译能力（见 D2）。
2. 升级媒体支持只需替换 ffmpeg 二进制，无需重新编译后端。
3. 子进程崩溃不会带崩主进程。
4. Jellyfin、Plex、PhotoPrism 均采用此方案，是成熟做法。

**代价**：用户需要自行安装 ffmpeg。启动时会检测并在横幅与 `/api/stats` 中提示。后续可考虑在发布包中附带各平台 ffmpeg 二进制。

---

## D4. 用内容哈希做稳定身份，而不是只用文件路径

**决策**：`media_files` 同时保存 `file_path`（UNIQUE，用于幂等 upsert）和 `content_hash`（用于稳定身份、去重、缩略图寻址）。

**哈希算法**：`sha256(文件大小 + 前 256 KiB + 后 256 KiB)`。不是全文件哈希。

**理由**：用户整理目录（移动、重命名文件夹）时，纯路径方案会导致整库重新索引。内容哈希让"同一个文件换了位置"仍然可识别。全文件哈希一个 4 GB 的视频会显著拖慢扫描，而头尾指纹已足够稳定地标识文件身份。

**已知取舍**：极低概率的哈希碰撞；两个内容不同但大小、头尾 256 KiB 都相同的文件会被视为同一身份。对家庭媒体库可接受。若将来需要严格去重，可增加"全文件哈希"作为二次校验。

---

## D5. 缩略图存文件系统，不进数据库

**决策**：缩略图以 `<数据目录>/thumbs/<哈希前2位>/<哈希>.jpg` 存放，数据库只存路径。

**理由**：保持 SQLite 索引轻量（可随时删除重建），缩略图按哈希分片避免单目录文件过多。

**连带效果**：因为路径由内容哈希决定，缩略图 URL 是不可变的，可以设置 `Cache-Control: immutable`，客户端可以永久缓存。

---

## D6. 鉴权从第一天就有

**决策**：所有接口（除 `GET /` 和 `GET /api/ping`）都要求 Token。Token 在首次启动时随机生成，写入 `config.json`（权限 0600），启动横幅中打印。

**理由**：整个产品卖点是隐私。局域网不等于可信网络——合租、宿舍、公司 WiFi、访客网络都会把其他人放在同一网段。没有鉴权意味着任何能访问端口的人都能下载全部原图，这与产品目标直接冲突。事后补鉴权比一开始就做贵得多。

**实现细节**：支持 `Authorization: Bearer`、`X-Token` 头，以及 `?token=` 查询参数。查询参数不是最优做法，但 `<img src>` / `<video src>` 无法附加请求头，内建状态页依赖这一点。使用 `subtle.ConstantTimeCompare` 防止时序攻击。

**后续**：应演进为一次性配对码 + 每个客户端独立 Token，支持吊销单个设备。当前是全局共享 Token，MVP 够用。

---

## D7. 视频只做直连播放，不做服务端转码

**决策**：原文件通过 HTTP Range 直接下发，由客户端解码。后端只是一个带 Range 支持的静态文件服务器。

**理由**：现代设备（`media_kit` 基于 libmpv）对 H.264/H.265/VP9/AV1 支持已经很好。不做转码让后端实现极简，且 `http.ServeContent` 已经免费提供 Range / If-Range / Last-Modified 处理。

**已知限制**：10-bit HEVC 在老款 Android 设备上可能无法解码；内封字幕需要客户端支持。后续低成本兜底是 **remux**（换容器不重编码，几乎零 CPU），而不是全量转码。

---

## D8. 数据库写入串行化

**决策**：扫描器使用 worker pool 并行处理文件（哈希、元数据、缩略图），但所有数据库写入经过**单个 writer goroutine**。

**理由**：SQLite 在 WAL 模式下支持多读单写，但并发写会触发 `SQLITE_BUSY`。与其依赖重试，不如从结构上保证只有一个写入者。

**连接配置**：`busy_timeout=5000`、`journal_mode=WAL`、`foreign_keys=ON`、`synchronous=NORMAL`、连接池上限 8。

---

## D9. 客户端技术栈

**决策**：Flutter，使用 `http` + `shared_preferences` 起步，照片查看用 Flutter 内置的 `InteractiveViewer` + `PageView`。

**理由**：垂直切片阶段尽量少引依赖，降低构建失败概率。`photo_view`、`dio`、`Riverpod` 等可在功能铺开后再引入——它们解决的是规模化问题，不是"能不能跑通"的问题。

**视频播放**：后续引入 `media_kit`（桌面端 `video_player` 支持很差，`media_kit` 是正确选择）。

---

## D10. MVP 平台范围：桌面端 + Android

**决策**：iOS 推迟到后续阶段。

**理由**：iOS 需要声明本地网络权限、为明文 HTTP 配置 ATS 例外，真机分发还需要 Mac + 开发者账号（签名、描述文件、过期续签）。Android 侧载 APK 与桌面端分发的成本低得多。先把两端跑顺，再评估 iOS 的投入产出。

---

## D11. 视频播放用 media_kit（libmpv），不用 video_player

**决策**：客户端视频播放选 `media_kit` + `media_kit_video` + `media_kit_libs_video`，底层是 libmpv。

**理由**：

| 候选 | 结论 |
|---|---|
| `video_player` | 桌面端支持很差，格式覆盖窄，MKV/多音轨/内封字幕基本不可用 |
| `media_kit`（libmpv） | 格式覆盖等同 mpv；原生支持多音轨、内封字幕、硬件解码；桌面/移动同一套 API |
| 自己写 FFI 绑 libmpv | 等于把 media_kit 重写一遍，没有收益 |

**关键实现点**：

- `MediaKit.ensureInitialized()` 必须在创建任何 `Player` **之前**调用，否则原生库不会加载。
- 原文件接口需要令牌，因此必须走 `Media(url, httpHeaders: {...})` 把 `Authorization` 头透传给 mpv —— 让 mpv 自己发起的 Range 请求也带上令牌。这是"客户端直连 + 服务端鉴权"能同时成立的前提。
- 播放页只订阅 `tracks / track / buffering / playing / error` 五条流，把播放失败的原因如实显示出来，而不是静默卡住。

---

## D12. 构建须知：libmpv 原生产物必须离线预置

**背景**：`media_kit` 的两个 pod 在 `pod install` 时会各自跑一次 `make`，从 GitHub 下载原生产物：

| 包 | 产物 | 用途 | 上游地址 |
|---|---|---|---|
| `media_kit_libs_macos_video` | `libmpv-xcframeworks_v0.6.0_macos-universal-video-default.tar.gz` | 提供 `Mpv.xcframework` 等 18 个框架，用于**链接** | GitHub **Releases** |
| `media_kit_video` | `mpv-0.36.0.tar.gz` | 提供 `client.h` 等 4 个头文件，用于**编译** | GitHub **archive** |

**问题**：在受限网络下 GitHub Releases 直连返回 502，`make` 静默失败——`pod install` 本身仍然"成功"，直到 Swift 编译阶段才报 `cannot find type 'mpv_node_list' in scope`，排查成本很高。

**解决**：产物按 SHA256 校验后预置到各包的 `.cache/`，`make` 会直接判定"无需重建"。镜像用 `https://ghfast.top/<原始 URL>` 前缀。两个 SHA256 都已在 `make` 的 Makefile 里固定，预置时必须校验通过。

**另一个坑**：`media_kit_video` 的 podspec 用 `s.source_files = 'Classes/plugin/**/*.swift', 'Headers/**/*.h'` 把这些头文件纳入 pod。CocoaPods 是在 `pod install` 时**一次性 glob** `source_files` 的——所以如果头文件是在 `pod install` **之后**才补齐的，Pods 工程里根本不会有它们（umbrella header 不会 `#import "client.h"`），编译照样失败。补齐头文件后**必须重跑 `pod install`**。

---

## D13. 端到端验证用 integration_test，而不是人工点界面

**决策**：把"点开视频能不能播"做成可重复执行的 `integration_test`。

**理由**：播放链路的每一环（HTTP Range、令牌透传、libmpv 解码、轨道解析）都可能单独正确而组合失败。集成测试会真的启动 macOS 窗口、真的发 HTTP、真的让 libmpv 解码，是唯一能证明"这条链路通了"的手段。判定依据取播放页自身的可见状态（缓冲转圈 / 已暂停提示 / 错误浮层三者都不出现即视为播放中），不依赖脆弱的内部状态读取。

**环境注意**：沙箱化的 macOS App **不能直接执行二进制启动**（会崩在 `_libsecinit_appsandbox`），必须经由 LaunchServices；用 `flutter run -d macos` 或 `flutter test integration_test -d macos` 启动即可。

---

## D14. mDNS 服务广播：选型、网卡筛选、以及一个必须自己补的可达性检查

**选型**：`github.com/grandcat/zeroconf`。唯一的硬指标是纯 Go——它决定了后端能保持
`CGO_ENABLED=0` 单文件静态编译，这是"方便快捷的安装"这条需求的地基。更常见的
`hashicorp/mdns` 依赖 `miekg/dns` + `golang.org/x/net/ipv4` 的裸套接字路径，在受限环境
下会直接 `operation not permitted`，不可用。

**代价**：`zeroconf` 会钉住 2020 年的 `golang.org/x/net`，那个版本的
`internal/socket` 在现代 Go 上链接失败（`invalid reference to syscall.recvmsg`）。
所以 `go get` 之后**必须**再 `go get golang.org/x/net@latest golang.org/x/sys@latest
golang.org/x/crypto@latest github.com/miekg/dns@latest`，否则 `go build` 报错且信息指不到
真正原因。另外 `go mod tidy` 在代码还没引用该库时会把它删掉——顺序是先加依赖、再写引用代码。

### 只广播真实局域网网卡（这不是洁癖，是正确性问题）

`zeroconf.Register` 会把**传入的每个网卡的地址合并成一份 A 记录**，而 `appendAddrs`
会把这份合集放进**每一个**响应里，无论查询来自哪条链路（`ifIndex` 只在地址集为空时才被
当作兜底使用）。

于是"顺手把网桥也传进去"的后果不是多一条冗余广播，而是：一台同时有 Wi-Fi 和虚拟机网桥的
机器，会向**真实 Wi-Fi 上的手机**宣告多个地址，其中若干是不可达的网桥地址。客户端选中哪
一个是不确定的，选错就连不上，而且没有任何有用的报错。

实测：本机 `en0` 是 `192.168.1.49`，另有 `bridge100/101/102` 分别持有
`192.168.139.3`、`192.168.107.0`、`192.168.97.0`（后两个甚至是被当作主机地址使用的
**网络地址**）。筛选前 `dns-sd -G v4` 会返回 4 条 A 记录，筛选后只剩 1 条。

筛选规则：必须 `UP` + 非 `LOOPBACK` + `MULTICAST` + **非 `POINTOPOINT`**（这条是跨平台可用的
真实标志位，能挡住 `utun*`/`tun*`/`gif*`），再排除一组已知虚拟网卡名前缀
（`bridge`/`vmenet`/`vmnet`/`utun`/`gif`/`stf`/`anpi`/`awdl`/`llw`/`docker`/`veth`/`virbr`/`br`/`tun`/`tap`），
最后要求持有可路由的 IPv4（排除回环、链路本地 `169.254.*`、未指定地址）。

内核没有提供能区分"网桥"和"以太网口"的可移植标志位——两者都是 UP/BROADCAST/MULTICAST/RUNNING——
所以名字前缀是唯一可用的信号。`cmd/mdnsprobe` 与 `internal/discovery` 的单元测试把这个
前缀表锁住，避免将来某次改动悄悄把不可达地址放回来。

**顺带修掉的重复**：`main.go` 里原本有一份平行的 `lanIPs()`，注释里写着"与 discovery 保持一致"，
结果改了一边没改另一边——横幅打印的地址和实际广播的地址立刻就不一致了。现在两者都走
`discovery.LANIPv4()`，结构上无法再分叉。

### 令牌不放进 TXT 记录

mDNS TXT 记录对同网段任何设备可读，包括访客 Wi-Fi。发现只负责回答"服务器在哪"，
授权仍由令牌独立完成。TXT 只带 `name` / `version` / `api` / `path`。

### 必须自己补一个"能不能发出去"的检查

`zeroconf` 的 `multicastResponse` **丢弃每一个 `WriteTo` 的返回值**并始终返回 `nil`。
也就是说：一台组播被 VPN 或网络策略拦截的机器，日志上照样打印"广播成功"，
而实际上一个包都没发出去。从外部看，这和正常工作完全无法区分——用户唯一的症状是
"手机找不到服务器"，且毫无线索。

因此 `discovery.Start` 在注册之后会真的试发一个包（`checkMulticastSend`），失败则在横幅里
打印明确警告，并附上具体错误。预检发往 224.0.0.251 的 **9 号端口**而不是 5353：
路由只由目的地址决定，所以这样走的是同一条路径，同时保证探针包绝不会被网络上的
其他 mDNS 实现误认成真实流量。

### 踩坑记录：macOS 上必须先 join 组播组，才能发送

排查过程中我自己写的诊断工具 `cmd/mcastcheck` 一度给出**假阴性**——所有发送策略都返回
`sendmsg: no route to host`，而路由表里明明有 `224.0.0/4 -> en0` 的正确路由。

真正的原因是：该工具在发送前没有调用 `JoinGroup`。**在 macOS 上，`IP_ADD_MEMBERSHIP`
不只是为了接收，它同时是内核为该套接字建立可用组播路由的前提**。补上 `JoinGroup` 之后，
三种发送方式全部成功。`cmd/mcastcheck` 里已把这个步骤和结论写进注释，防止下次再被误导。

**客户端侧**：这里的估计后来被实测推翻了——不需要走系统 Bonjour，纯 Dart 组播就能发现。
见 **D16**。Android 侧仍受各厂商后台策略影响，需要单独验证。

---

## D15. 相册成员关系：用 media_id + 外键级联

**决策**：`album_items(album_id, media_id)` 以 `media_id` 指向 `media_files(id)`，
并声明 `ON DELETE CASCADE`。

**为什么不用 `content_hash`**：`content_hash` 是跨扫描稳定的内容身份（见 D4），看起来更适合
做长期引用。但它不是主键，且允许多行持有同一哈希（同一文件出现在两个目录时）。以它建关系
就要处理"一对多"，级联语义也会变得含混。相册是索引之上的视图，指向索引行的主键是更诚实
的建模。

**级联的实际行为**（`scripts/verify-albums.sh` G 段逐条验证）：

1. 文件从磁盘消失 → 重扫 → `media_files` 行被清理 → 成员关系随外键消失，`item_count` 归零。
   不会留下指向空气的孤儿行。
2. 文件放回去 → 重扫 → 媒体以**新的 id** 重新入库（实测 8 → 9），但**成员关系不会自动恢复**。

第 2 点是刻意接受的取舍：关系的生命周期跟着索引行走。要让它自动恢复，就得引入一张
独立于索引的"用户意图"表，并把 `content_hash` 作为跨扫描的稳定键——那是平台化阶段的事，
现在做只会增加一层无人使用的复杂度。**当前语义对用户是安全的**：相册里能看到的每一项
都一定能打开，这是数据库层面保证的，而不是靠应用层记得清理。

**一个重要的安全前提**：扫描器在目录不可读时会**直接返回而不执行 prune**（见
`scanner.go` 中对 `os.Stat` 失败的处理）。所以拔掉外置硬盘、或网络盘暂时掉线，
不会导致整个库被判定为"文件全部消失"从而清空索引——相册数据因此也不会被误删。
这个行为是级联方案能成立的前提，改动扫描器时不能破坏它。

---

## D16. 客户端发现：纯 Dart 组播，不用平台通道，也不用 Bonjour API

**决策**：客户端用 `multicast_dns`（Dart 官方包，内部是 `RawDatagramSocket`）直接收发组播，
完成 PTR → SRV → A → TXT 四步解析。**不引入平台通道，不调 `NSNetServiceBrowser` /
`NsdManager`，也不需要 `NSBonjourServices`。**

**这推翻了 D14 里"客户端侧待做"那条的判断。** 当时的估计是：macOS / iOS 上要走系统
Bonjour，需要额外声明本地网络权限。实际先做了一个**不依赖任何包**的裸 Dart 探测
（`RawDatagramSocket.bind(anyIPv4, 5353, reuseAddress: true, reusePort: true)` +
`joinMulticast(224.0.0.251)` + 手工拼一个 PTR 查询包），结果在 macOS 上直接收到了完整的
344 字节响应，含 `_mediacenter._tcp.local`、实例名、`bogon.local` 与四条 TXT。**结论：纯
Dart 可行，不需要平台通道。** 这一步先做探测再引依赖，省掉了整条平台通道的实现量。

**踩坑记录（这个坑值得单独写下来）**：`lookup()` 返回的是 `Stream`，而**不能**写成
`stream.toList().timeout(1.5s, onTimeout: () => [])`。`toList()` 要等流**关闭**才完成，
而这个库内部要 5 秒才关流；于是 1.5 秒的超时先触发，返回那个空兜底值，把**已经收到**的
记录一起丢掉。实测记录在 **15ms** 就到达了，代码却报"未发现任何服务"——看起来完全像是
网络问题。因为 `Future.timeout` 的 `onTimeout` 签名是 `FutureOr<T> Function()`，这段代码
类型检查还是通过的，静态分析发现不了。

现在 `ServerDiscovery._collect()` 自己收：收到一条就把 settle 计时器重置，连续 400ms 没有
新记录就返回，最长不超过 1.8 秒。既不会丢数据，也不会每次干等满窗口。

**另一个假线索**：一开始怀疑"带显式网卡的 `joinMulticast` 会改变 socket 的默认组播发送
网卡，导致查询从 lo0 或 bridge 出去"。实测**不成立**——不指定网卡与逐网卡 join 都能收到
响应（分别 3 条和 4 条）。真正的原因就是上面那个 `toList().timeout()`。记在这里是因为它
很像真的：macOS 上 `IP_ADD_MEMBERSHIP` 确实会影响发送路径（见 D14 的 JoinGroup 那条），
但在这件事上不是原因。

**可测性**：抽出 `ServerDiscoverer` 接口，`ConnectPage` 与 `MediaCenterApp` 都接受一个
可选的实现。理由很实际——真实发现要开 socket、等网络，而搜索期间的转圈动画会让
`pumpAndSettle` **永远等不到静止**，widget 测试必然超时。注入假实现后，发现卡片的四种
状态（搜索中／有结果／空结果／失败）以及"只发现一台时自动填充"这类分支才测得了。

**权限配置**（两处，都是 Release 下会静默失效的）：

1. `Info.plist` 加 `NSLocalNetworkUsageDescription`。macOS 15 起访问本地网络必须声明用途，
   否则系统不弹授权框、访问被直接拒绝，界面只会显示"没有发现服务器"，看起来像局域网里
   真的没有服务端。
2. `Release.entitlements` 加 `com.apple.security.network.server`。原先只有 `network.client`，
   而发现要 bind 5353 收数据报，沙箱里"接收"属于监听行为。**Debug 因为刻意关了沙箱
   （见 D13 的说明）看不出这个问题**，只有 Release 会踩到。

**令牌仍然要手动填**：发现只负责填地址。令牌不放 TXT 是 D14 的决定，这里保持一致。
更顺手的做法是后端启动时在终端打印一个带令牌的二维码让客户端扫，留到打包阶段做。

**已知限制**：只解析 IPv4（A 记录）。后端广播的地址已经过滤掉虚拟网卡，所以拿到的就是
对方在真实局域网上的地址；但纯 IPv6 网络下会发现不到。

---

## D17. 上传落地目录纳入扫描范围，而不是隔离在外

**决策**：上传的文件写入 `<数据目录>/library/`，并且**该目录在启动时自动注册为扫描目录**。
`media_files.origin` 用 `'scan'` / `'upload'` 区分来源。

**这与阶段五计划里写的相反**。计划当时写的是"默认不要放在已扫描的目录里"，理由是
"会出现同一份文件既被上传又被扫描索引到的重复行"。这个理由在**路径不同**时才成立
（比如用户又把同一张照片手工拷进另一个扫描目录）。上传的场景不是这样：

上传与扫描写的是**同一个 `file_path`**，而 `UpsertMedia` 的冲突目标是 `file_path`，
所以只会有一行。真正会产出两行的是"同一份内容存在两个路径"，那属于用户自己拷来拷去，
靠 `content_hash` 去重能兜住"不重复占空间"，但两行 `file_path` 本身是**正确的**描述。

把上传目录排除在扫描之外，反而要付三笔代价：

1. **两套索引路径**。上传接口得自己提取 EXIF、自己调 ffprobe、自己生成缩略图，
   于是哈希算法、元数据规则、缩略图命名就有了第二份实现，迟早和扫描器不一致。
   现在两者共用 `scanner.buildMediaFile`，`IndexFile` 只是它的一个入口。
2. **删除不会被清理**。用户在文件系统里删掉一张上传的照片，扫描器不认这个目录，
   索引行就永远留着，前端点开是 404。纳入扫描后 `prune` 自然处理。
3. **"上传的算不算媒体"会分裂**。统计、时间线、相册都要额外区分两套来源。

**换来的代价与对策**：`origin` 必须**只在插入时写**（`UpsertMedia` 的 `ON CONFLICT`
里刻意不更新 `origin`）。否则扫描器下次走到同一个文件，会把它从 `'upload'` 改回
`'scan'`，来源信息就悄悄没了。这条由 `TestUpsertPreservesOrigin` 钉住。

**另一个必须堵的坑**：媒体库目录既然是扫描目录，用户就可能通过 `DELETE /api/folders/{id}`
把它删掉——不会丢文件，但之后所有上传都不再进索引，表现上非常像数据丢失。
`handleDeleteFolder` 因此显式拒绝删除媒体库目录（409）。

**临时区放在库外**：`<数据目录>/uploads/` 存未完成的分片。放在库内的话，半个文件会被
扫描器当成媒体走一遍完整流程（哈希、ffprobe、缩略图），既浪费又会短暂出现在库里。

---

## D18. 分片直落目标偏移，进度以分片表为准

**决策**：`init` 时按声明大小创建一个临时文件；每个分片用 `WriteAt` 写到
`index * chunk_size` 的偏移；`upload_chunks(upload_id, chunk_index)` 逐条记录到达的分片，
`received_chunks` 由 `COUNT(*)` 重算而不是自增。

**为什么不留分片文件再合并**：合并要额外读一遍、写一遍整个文件。4 GB 的视频就是多 8 GB
的磁盘 I/O，而且合并期间要额外占一份空间。直落偏移让"上传完成"退化成一次 `rename`，
在同一文件系统内是原子的、零拷贝的。

**为什么进度不靠自增**：客户端重发一个已经发过的分片是很正常的事（超时后没收到响应、
或 App 重启后续传）。自增计数会被灌水，进而让 `complete` 在分片其实不齐时误判为已完成。
重算则天然幂等。`TestUploadChunkCountsAreIdempotent` 覆盖了这条。

**为什么记录每一条分片而不是只记计数**：断点续传要回答的是"**还缺哪几片**"，不是"收了几片"。
只存计数的话，客户端重连后只能整文件重传。`GET /api/uploads/{id}` 返回的是分片序号数组。

**内存**：`io.Copy` 配 `io.LimitReader`，整个流程没有任何一处把文件读进内存，
也没有任何一处按文件大小分配缓冲。这条是阶段五计划里点名的风险，现在由实现方式直接排除，
而不是靠评审时记得检查。

---

## D19. 内容哈希一物两用：去重键 + 完整性校验

**决策**：`content_hash` 既是秒传的判定依据，也是 `complete` 阶段校验"收到的字节就是
客户端声称的那份文件"的依据。算法与扫描器完全相同（`sha256(size || 前 256 KiB || 后 256 KiB)`，
见 D4），并通过 `scanner.ContentHash` 单一导出，避免两边各写一份而悄悄漂移。

**两条去重路径，因为客户端不一定算得出哈希**：

1. `init` 带 `content_hash` 且命中已有媒体 → 直接返回 `dedup: true` 和已有媒体对象，
   **一个字节都不用传**。这是手机重跑备份时的主路径。
2. `init` 没带哈希 → 正常传完，在 `complete` 阶段算出哈希后仍然发现重复 →
   丢弃刚收到的临时文件，返回已有媒体。传输白做了，但**存储不会翻倍**，
   而且用户看到的结果和秒传一致。

第 2 条是刻意的冗余：只做第 1 条的话，一个算不出哈希的客户端（或哈希算法版本不一致的旧客户端）
就会把整个相册重新存一遍。

**哈希不符时返回 422，并把会话标记为 `failed`**，而不是静默接受。分片传输中间被截断、
被代理改写、或客户端读文件时文件正在变化，都会走到这里。一条"大小对得上、哈希对不上"的记录
如果被放行入库，用户会得到一张打不开的照片，而错误现场已经消失。

**校验失败的顺序很重要**：先校验、再 `rename` 进媒体库。校验不过的文件根本没进库，
也不会有索引行——`verify-upload.sh` 专门断言了"校验失败的文件未进入媒体库"。

**客户端必须用同一套算法**。这一点写在接口说明里，因为它是"秒传能不能生效"的唯一前提，
而且不一致时的表现是"静默变慢"，不会报任何错。

---

## D20. 迁移用幂等 ALTER，不引入迁移框架

**决策**：`migrate()` 分三步——先跑建表脚本（全部 `IF NOT EXISTS`），再用
`PRAGMA table_info` 判断后 `ALTER TABLE ADD COLUMN` 补列，最后跑依赖新列的索引。
不引入版本号表，不引入迁移库。

**为什么**：整个数据库只有 6 张表，唯一的演进动作是加列。一个迁移框架带来的
"版本号 + up/down 脚本 + 状态表"比它解决的问题还多。幂等 ALTER 的语义很直白：
再跑一次就是空操作。

**注意点**：`CREATE TABLE IF NOT EXISTS` 对**已存在**的表什么都不做，所以给老库加列
只能靠 `ALTER`。而且新加的列**不能带** `NOT NULL` 却没有默认值——`origin` 声明为
`TEXT NOT NULL DEFAULT 'scan'`，老库升级后所有历史行自动获得 `'scan'`，
既不用回填也不用重建。`TestMigrateAddsOriginToExistingDatabase` 用第一版建表语句
造一个老库来验证这条路。

**踩坑记录（一个自己写注释把自己坑了的例子）**：原先 `migrate()` 是把整个脚本按 `";"`
切开逐条执行。这次给 `uploads` 表写注释时顺手写了一句英文
"A row exists only for the duration of the transfer; once the file is assembled…"——
那个分号把语句从中间切断了，服务端启动直接失败。

问题不在于那一句注释，而在于**按 `;` 切分本身就是错的**：只要有人写一句带分号的注释，
或者将来加一条含字符串字面量的语句，就会重演，而且是在别人的机器上重演。
所以修的是切分逻辑本身——`splitStatements` 先剥掉 `--` 行注释再切分。

---

## D21. Android 用正式 keystore 签名；缺密钥时构建失败，而不是静默用 debug 签名

**决策**：release 构建从 `android/key.properties` 读取签名材料（keystore 路径、密码、别名）；
该文件与 `app/upload-keystore.jks` 都在 `.gitignore` 里。**找不到 `key.properties` 时
release 构建直接失败**，报错里说明原因并给出三种处理办法。显式退出开关是
`android/gradle.properties` 里的 `mc.allowDebugSigning=true`（默认关闭）。

**为什么不静默回退到 debug 密钥**：debug 签名的包与正式包签名不同，安装器会拒绝覆盖安装
（`INSTALL_FAILED_UPDATE_INCOMPATIBLE`）。静默回退产出的就是一个"看起来是正式包、实际
升不了级"的东西——正好是这个阶段要消灭的那个问题。**构建失败至少是响的，静默降级是哑的。**

**这条决策中途改过一次，过程比结论更值得记。** 第一版实现的是"回退 + `logger.warn` 告警"，
理由是"别人 clone 下来不配密钥也能编译"。实测发现这个机制根本不成立：

1. **`flutter build apk` 会过滤 Gradle 的日志输出。** 脚本里的 `logger.warn` 看不到。
   为排除"只是日志级别不够"这种可能，我临时加了一句 `println` 当探针——同样看不到。
2. **Gradle 9 默认开启配置缓存。** 脚本体（包括那条 `warn`）只在配置阶段执行一次，
   第二次构建起就不再重新执行。所以它连"每次都会跑"都保证不了。

也就是说"打一条警告"既不一定显示、也不一定执行。反过来，**构建失败是 Flutter 一定会
透传给用户的**（`Gradle task assembleRelease failed with exit code 1` 加上完整报错）。

代价是"没配密钥的人编不出 release 包"。这个代价可以接受，因为那两种真实需求都有更好的出口：
只想确认代码能编过就用 `--debug`；确实要一个 debug 签名的 release 包就显式开开关。

**验证**（四种组合都实测过，不是推断）：

| 构建 | `key.properties` | `mc.allowDebugSigning` | 结果 |
|:---|:---|:---|:---|
| `--release` | 存在 | 未设置 | 成功，签名 = `433783c2…`（正式密钥） |
| `--release` | 不存在 | 未设置 | **失败**，报错含完整指引 |
| `--release` | 不存在 | `true` | 成功，签名 = `7f8919af…`（debug 密钥） |
| `--debug` | 不存在 | 未设置 | 成功（不受影响，见下） |

**第二个坑：fail-closed 不能写在 `buildTypes.release` 里。** 那段配置在**配置阶段**
对所有构建都会执行一次，所以写在那里的 `require` 会让 `flutter build apk --debug`
一起失败——而我的报错信息里恰好推荐用户"改用 `--debug`"。也就是说第一版给出的指引
本身就是错的，只是当时没测 `--debug` 才没暴露。

正确落点是 `tasks.matching { it.name == "assembleRelease" }.configureEach { doFirst { ... } }`：
放在执行期，只命中 release。这同时避开了配置缓存——配置期的判断会被缓存，执行期的不会。

**核对方法**（应该成为发版前的固定动作）：

```bash
apksigner verify --print-certs build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
# 期望 SHA-256:
# 43:37:83:C2:7E:5B:6F:D0:02:27:4B:FD:44:57:64:BB:74:E9:2E:D0:82:CF:98:00:59:2E:A0:78:9B:F7:50:EA
```

**几个容易踩的点**：

1. **`storeFile` 的相对路径基准。** Flutter 官方文档里的
   `file(keystoreProperties['storeFile'])` 写在 `app/build.gradle.kts` 里，实际是相对
   **app/** 解析的；但 `key.properties` 放在 `android/` 下，读的人很容易以为相对
   `android/`。这里统一用 `rootProject.file(...)` 显式锚定到 `android/`，
   `key.properties` 里写 `storeFile=app/upload-keystore.jks`，把歧义消掉。

2. **PKCS12 而不是 JKS。** Java 9 起 PKCS12 是默认密钥库格式，JKS 是遗留格式。
   这里 `keytool -storetype PKCS12` 并在 gradle 里显式声明 `storeType`，不依赖 JDK 默认值，
   否则换个 JDK 版本可能读不出同一个文件。PKCS12 的约束是 key password 必须等于
   store password，所以 `key.properties` 里两个字段值相同。

3. **`minSdk = 24`，所以只有 v2 签名、没有 v1（JAR）签名是正确的。**
   `apksigner verify --verbose` 会打印 `Verified using v1 scheme (JAR signing): false`，
   这不是缺陷——v1 只在 API < 24 的设备上才需要。看到这行不用去开 `enableV1Signing`。

4. **签名与升级是两件独立的事。** 能不能**装上**取决于包名 + 签名证书是否一致；
   能不能**升到新版本**取决于 versionCode 是否递增。签名对了但 versionCode 没涨，
   安装器会拒绝（`INSTALL_FAILED_VERSION_DOWNGRADE`）。

5. **已有的测试包必须卸载一次。** 之前那个 91 MB 的包是 debug 密钥签的，与正式包签名不同，
   安装器会直接拒绝覆盖（`INSTALL_FAILED_UPDATE_INCOMPATIBLE`）。这是一次性的：
   卸掉重装之后，后续所有正式包都能平滑升级。

**为什么版本号只在 `pubspec.yaml` 写一份**：Flutter Gradle 插件会把
`version: 1.0.0+1` 拆成 versionName / versionCode 注入，在 `build.gradle.kts` 里再写一遍
就多了一个会漂移的副本。客户端版本（`1.0.0`）与后端 `api.Version`（`0.1.0`）不必相同——
它们各自独立发布；真正约束兼容性的是后端的 `api_version`（整数，当前为 `1`），
客户端已经读了它（`models.dart` 的 `apiVersion`）。

**遗留**：debug keystore 在 macOS 上是 `~/.android/debug.keystore`，本机固定，
但它不是"我的"密钥，换机器就变——这正是原先"测试包无法升级"的根因。



