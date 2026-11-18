# iOS 工程

本目录为 iOS 应用入口，打开 `Runner.xcworkspace` 并选择 `Runner` scheme。本机工具链是 Flutter 3.47.7 / Dart 3.13.5、Xcode 27.2；上游历史 CI 使用 Xcode 26.6，最低 iOS 15。插件走 Swift Package Manager，这个工程没有 CocoaPods 的 `Podfile`。本源码目录已移除其他平台的应用宿主；`runtime/ohos/` 中仍被 iOS 使用的共享构建输入保留。

## 本次模拟器验证

2026-11-17，使用 Xcode 27.2 完成本机 Debug 模拟器的下载模式引擎 smoke，退出码为 0。应用包没有 `runtime.zip`，通过本机 HTTP 回环服务完成初次安装、再次安装和重置后的重新安装，共收到 3 次成功下载请求。安装、引擎启动、登录、3 轮真实 read 工具调用、前后台恢复、停止与原地重启、新旧 token 隔离、保留选项的重置和重装均通过。

该测试使用本机假模型，验证的是实际引擎与工具流程。普通主程序也已通过模拟器 Debug 编译、启动后 30 秒存活检查，并已截图确认进入对话界面；停止下载服务后重新启动，仍成功连接已安装的本机引擎。没有验证付费模型账号、真实 iPhone 签名或安装，也没有部署公开 HTTPS 下载地址。

同为普通主程序的模拟器 Debug 构建，App 目录从清理前 567,165,084 字节降至 461,956,525 字节，减少约 100.3 MiB（18.6%）。这不是签名 IPA 的大小。约 44 MiB 的运行时 ZIP 已独立导出；必要原生 frameworks 仍随 App 交付。

## 在 Mac 上编译

以下命令均从仓库根目录开始。需要 Python 3.11+ 和网络；本机引擎原生构建还需下文的 LLVM、lld、Meson 和 Ninja。先准备 NodeMobile、运行时 ZIP 和原生构建输入：

```sh
bash tooling/ios/prepare-engine.sh
```

产物位于 `app/ios/Engine/`，不进 git。引擎原生 frameworks 由 Xcode 编译并随应用签名，不能在安装运行时 ZIP 时下载替换。未准备 Engine 的构建只能连接远程主机。

接着配置运行时下载源，缩小应用安装包：

```sh
python3 tooling/ios/configure-runtime-download.py --url https://your-host/path/
```

将 `your-host` 换成自己可控制的 HTTPS 文件服务。脚本写入 `app/ios/runtime-download.json`，并导出 `dist/ios-runtime/runtime-<SHA256>.zip`；将该 ZIP 上传到配置 URL 对应的目录。也可以传入完整 `.zip` URL，此时导出文件名与 URL 末尾相同。配置中的 SHA-256、大小和版本绑定本次准备的 ZIP；每次重新准备引擎后都要重新配置并上传文件。

配置下载源后，Xcode 只嵌入下载元数据、必要原生 frameworks 及少量 iOS 工具资源。App 内点击安装时才下载 JavaScript 运行时，验证 SHA-256、大小和版本后解压，成功后删除下载的 ZIP；后续启动使用已安装文件。没有可用下载服务器时，示例 URL 无法安装引擎。

准备 Flutter 依赖并打开工程：

```sh
cd app
flutter pub get
open ios/Runner.xcworkspace
```

在 Xcode 里选择 `Runner` scheme 和模拟器，执行 Build / Run。可先做不签名编译检查，在 `app/` 下运行：

```sh
flutter build ios --simulator --debug
flutter build ios --release --no-codesign
```

### 真机签名与启动

在 `Signing & Capabilities` 中给 `Runner`、`ShareExtension` 和 `CompanionWidget` 选择同一 Apple Team，配置各自可用的 Bundle ID。Runner 与 ShareExtension 的 App Group 必须相同；Runner 与 CompanionWidget 的专用共享 Keychain access group 必须相同。扩展的 Bundle ID 必须以主应用的 Bundle ID 开头。

更换 Bundle ID 时同步修改 target 的 `PRODUCT_BUNDLE_IDENTIFIER`、相应 `.entitlements` 和 `ShareExtension/ShareInbox.swift` 的 App Group，以及 `Runner/Info.plist` 和 `CompanionWidget/Info.plist` 中的 `DSHCompanionAccessGroup`。保留相同的 Team 前缀。账号是否支持这些 capabilities 由 Xcode 和 Apple 的实际签名结果决定；本次修改没有完成你的真机签名或安装验证。

免费 Apple 账号（Personal Team）可以先用：每次签名 7 天有效，最多 3 台设备，不能用推送。它能不能注册 App Group 还没实测；不能的话，先在 Xcode 里去掉 `ShareExtension` target 和两份 `.entitlements`，只是少了分享入口。

插上已信任并启用开发者模式的手机后，在 Xcode 选择该设备 Run，或执行：

```sh
flutter run --release -d <设备>
```

应用启动后到设置的本机引擎页面安装运行时，启动引擎，再配置模型凭据并发起对话。运行时安装、引擎启动和模型登录是不同步骤，编译通过不能替代这些验证。只连远程主机可以跳过本机引擎安装。

### iOS 灵动岛

灵动岛使用 Apple 的 `ActivityKit + WidgetKit`，对应扩展 target 是
`PetLiveActivity`。主 App 通过 `dsh/pet_live_activity` 把本机任务的思考、运行、等待确认、完成和失败状态推给扩展；扩展同时提供锁屏卡片、展开态、紧凑态和最小态。需要 iOS/iPadOS 16.2 或更高版本，并在系统的“实时活动”设置中允许 DSH Go；只有带 Dynamic Island 的 iPhone 才会显示岛，其他设备仍可显示锁屏实时活动。

灵动岛不会把整套 `assets/pets` 复制进扩展。选中的宠物会优先通过 App Group 暂存；侧载环境没有可用 App Group 时，App 将当前姿态压缩成小 PNG 放进 ActivityKit 状态，扩展只携带这张静帧。因此 `PetLiveActivity.appex` 不应随着宠物资源增长；构建后可检查 `Runner.app/PlugIns/PetLiveActivity.appex` 的体积。

这条链路不依赖 APNs，状态更新由正在运行的 App 发起；系统暂停 App 后，岛上的内容按 `staleDate` 变为“等待恢复”。点击岛上的会话链接会回到对应对话。真机上需要给 Runner、PetLiveActivity、ShareExtension 和 CompanionWidget 使用同一个 Team，并为扩展使用以主 Bundle ID 开头的 Bundle ID。

手机操控的原生 CoreDevice/XCTest 组件可先运行 `bash tooling/ios/build-phone-self-runner.sh` 准备，需 rustup/cargo 与脚本指定的 Rust 工具链；它不等于安装或签名 XCTest PhoneRunner，也不负责启动本机引擎。

### 模拟器下载联调

没有 HTTPS 服务时，可从根目录配置本机回环地址并启动静态服务器：

```sh
python3 tooling/ios/configure-runtime-download.py --allow-local-debug --url http://127.0.0.1:8787/
python3 -m http.server 8787 --bind 127.0.0.1 --directory dist/ios-runtime
```

保持服务器运行，再在另一个终端或 Xcode 运行 Debug 模拟器构建，进入 App 点击安装。HTTP 回环地址只用于 Debug 模拟器联调，真机的 `127.0.0.1` 指向手机本身；Release 构建拒绝 HTTP，必须重新配置 HTTPS 地址后编译。离线测试如需把 ZIP 放回 App，可使用构建环境变量 `DSH_IOS_BUNDLE_RUNTIME=YES`；这会增加安装包体积。

上游 `iOS compile` 工作流使用 `tooling/ios/build.sh` 输出编译错误（失败时不用登录也能看原因：Xcode 的报错会列在运行页的 Annotations 里），并在模拟器中执行引擎工具回合和停止、重启检查（`tooling/ios/engine-smoke/`）。工作流定义和历史记录不表示当前这台 Mac、签名账号或 iPhone 已通过测试。

## 引擎 addon 的 framework 布局

两份 addon 由 `build-engine-native.sh` 输出为 `DshFlock.framework/DshFlock` 和 `DshRequireBuiltin.framework/DshRequireBuiltin`，与 `DshNodeHost.framework` 一起嵌入 App 的 `Frameworks/`。iOS 宿主校验与生成 runtime 的 loader 必须使用同一布局；addon 源码、N-API 版本和注册名不因包装改名。升级必须重新准备 runtime，不能把旧 loader 与新 framework 混用。 嵌入脚本会在编译和复制前检查已准备 ZIP 的唯一 loader 成员及两项新路径；旧布局、缺失或损坏时明确失败并要求重跑 `tooling/ios/prepare-engine.sh`，不会自动下载。

`embed-engine.sh` 清除增量构建遗留的两个裸 `.so`，启用签名时逐个签 framework；`CODE_SIGNING_ALLOWED=NO` 仍产出未签名代码，安装前必须由 Xcode 或重签工具签妥全部嵌套 framework。包装改变不是签名验证成功的替代，第三方重签与真机启动须实际复核。模拟器 engine-smoke 会要求新 executable 路径存在，再进入原真实工具回合。

## iSH 的构建产物

`tooling/ios/build-ish.sh iphoneos OUTPUT_DIR`（或 `iphonesimulator`）从固定的
`OpenMinis/ish-arm64` 提交下载源码，核对 SHA256 后打 `tooling/ios/ish/build.patch`，
生成未签名的 `DshGuest.framework`。上游源码和工具链缓存不进仓库。
上游历史记录曾使用 Xcode 26.2 编译设备和模拟器 framework；模拟器真实内核的 Python 与文件系统回归见下文。该记录不是本次本机 Xcode 27.2 验证结果，编译通过也不代表所有 iPhone 操作都已验证。

Mac 首次构建还需 LLVM（生成 ARM64 Linux VDSO）、独立 lld、Meson 和 Ninja；CI 使用
Meson 1.7.2、Ninja 1.11.1.4。可运行 `brew install llvm lld meson ninja`，并将
`$(brew --prefix llvm)/bin`、`$(brew --prefix lld)/bin` 以及 Meson/Ninja 放进 `PATH`。
iSH 构建脚本兼容 Python 3.9+；固定源码包使用先验证全部路径的解压器，仅接受目录和
普通文件，不依赖 `tarfile.data_filter`，不会退回未过滤的 `extractall`。
已准备本机引擎时，Xcode 嵌入阶段会调用该脚本；未准备引擎的远程专用包仍跳过。
缓存分别在 `Engine/build/iphoneos/guest` 和 `Engine/build/iphonesimulator/guest`，
命中前核对构建输入、Xcode/SDK/实际 Apple clang 和全部产物 SHA256；命中后不再探测
构建工具、下载或解压，因此 Xcode 阶段的 Python 版本及 PATH 顺序变化不会使有效缓存失效。
缓存未命中才检查 Meson/Ninja/LLVM/lld 并给出安装命令；固定源码压缩包在 `Engine/ish-cache`。

`DshGuest.framework` 与其他引擎 framework 一起复制和签名，不在 App 启动时链接。
它携带上游许可、固定源码地址和本地修改补丁；Archive 继续拒绝 framework 外的原生代码。
可选 Linux 安装入口和 guest owner 已接入；安装后重启本机引擎才启用 Linux 路由。工作区准入、权限与路由的本轮修复仍需 iPhone 真机复验，模拟器或 Linux 上的测试不代替真机结果。

### 可选 Linux 的 shell 契约

- 没安装 Linux 时，保留 just-bash 和引擎 Node Worker；不把它们描述成真正的 Linux。
- 已安装且由可信原生 owner 接入时，普通脚本整段交给 Linux。`cat /etc/os-release`、`ls /`、`command -v apk` 和管道不再按虚拟命令清单决定环境；guest 不可用或缺包时明确失败，不回退虚拟后端重跑。
- guest 使用 `/bin/sh`（Alpine ash），不是完整 Bash。需要 Bash 时在 guest 安装后显式调用；`git`、`rg`、`jq` 等也需要 guest 自己安装，不能借用虚拟桩。只有工作区 `/workspace` 和私有 `/tmp` 是宿主挂载，`danger-full-access` 也不能突破 iOS 沙箱或扩大挂载；执行仍需工具策略生成的一次性票据。
- 静态明确的 `node script.mjs` 等仍用引擎 Node Worker，可配合简单的虚拟管道命令；含 guest 命令、动态或不透明执行的 Node 混合脚本先拒绝，不执行前半段。脚本文件、stdin 及未选择 Worker 的动态命令或 `source`/`eval` 都只在 Linux 内执行，其中的 `node` 是 guest 程序，不会切回引擎 Worker。

本机可运行的回归检查（不启动 iSH）：

```sh
npm ci --ignore-scripts --prefix runtime/ohos/process
python3 runtime/ohos/process/build-just-bash.py
node --test tooling/ios/guest-tests/route.test.mjs runtime/tests/ios-guest-policy.test.mjs
python3 tooling/ios/tests/guest-admission.test.py -v
```

票据与真实 worker 集成测试另需从 `runtime/locks/dsh-0.2.2-rc.1/` 安装的独立 npm 前缀；先安装 `runtime/ohos/node/build-tools` 的锁定依赖并运行 `node runtime/ohos/process/build-rg-regex.mjs`，再按 [runtime.test.mjs](../../tooling/ios/guest-tests/runtime.test.mjs) 的启动说明运行。该测试使用真实工具、审批、Worker 和生成的 override，但 native 通道只记录请求，不运行 iSH；JIT 与 `--jitless` 分别验证。真机还应分别在只读、工作区可写和完全权限会话里测试独立环境探测、包管理、普通管道、Node Worker 及混合脚本拒绝。

Python 的原生文件系统回归见 [guest-mmap.md](../../tooling/ios/engine-smoke/guest-mmap.md)。2026-11-11 已在 iOS 模拟器的真实 DshGuest 内核、独立 Alpine 3.24.4 根目录验证 Python 3.14.10 和 pip 26.1.2：普通安装、从 `/workspace` 加载 libpython/扩展模块、文件与目录复制、权限/时间戳、跨挂载移动、临时目录清理，以及离线 pip 安装并导入 six 1.17.0。修复涵盖 musl 的超出文件长度预留映射、guest EOF 页面 SIGBUS，以及这些文件系统操作；仍保留只读挂载、硬链接和特殊权限位限制。模拟器结果不等于上述操作已在 iPhone 真机全部复验。

## 能力与上游验证历史

以下包含上游已有实现和验证记录。历史设备、CI 和模拟器结果不表示本次裁剪或下载模式已完成你的真机验收；当前设备仍需按末尾清单实际验证。

- CI 会在 iOS 模拟器上真跑：真 NodeMobile 的工具回合、取消、停止和恢复会话；停止时不误关别人的 fd；真 App 里的安装、启动、登录、停止、重启和重置；真 App 启动后 30 秒还活着；在 App 进程里真调用提醒、联系人、定位、OCR 和网页操作，只有点确认框是测试代点的（`RunnerTests`，选图除外）。上述 CI 运行门是 Debug 构建。2026-11-06 一台 iPad Air 5（iPadOS 18.7.7）装了自签的 Release 包：App 三次冷启动都正常，本机引擎在加载没签名的 addon 时失败，addon 因此改成了 framework。此后本分支已在 iPhone 13 / iOS 26.0 覆盖安装并运行本机对话；这不代表 TestFlight 白屏或下表全部项目已经验证。
- 本机引擎使用保留的共享基础层（历史路径为 `runtime/ohos/`）和同进程的 Node（NodeMobile 24.22.1，`--jitless`）。未安装可选 Linux 时，命令由 just-bash 模拟，没有 Linux 或 Python；安装并启用后按上面的 guest 契约运行，软件包以 guest 实际安装情况为准，仍不能任意启动 iOS 宿主进程。基础引擎首次安装需下载和解压空间，可选 Linux 另占空间。引擎第一次启动时才加载，只连远程的人不占这份内存。
- 停止后能原地再启动，不用重开应用（`runtime/ios/host/node_runner.cc`）。
- 本机引擎能处理图片。sharp 在这里装不了，所以 `runtime/ios/image/ios-sharp.cjs` 替代它，像素走系统的 ImageIO（`runtime/ios/host/image_binding.cc`），附件库自己的规则不变。ImageIO 写不了 WebP，所以带透明的图存 PNG，比目标大时压不下去（只影响透明图）。校验和缩放都走缩略图路径，大图的像素不用全部放进内存，但实际峰值还没在设备上量过。
- App 切到后台后，系统很快会暂停引擎；后台的本地监听被回收时，回到前台会自动重启引擎。iOS 26 以上，本机正在跑的一轮会向系统申请继续运行（`BGContinuedProcessingTask`），系统同意就接着跑并显示进度，也可能随时收回，收回后和暂停一样。这部分只编过、没在设备上跑过。
- 引擎的堆上限是 `--max-old-space-size=256 --max-semi-space-size=4`，还没在设备上定过。它和 App 同进程，所以快撞上限时 runner 会停掉这次运行（退出码 70），App 留着，可以重新启动。这一轮不会接着跑。Buffer 和原生内存、系统的 jetsam 不在保护范围内。
- NodeMobile 24.22.1-0 记录 fd 时增删用的哈希不一样，Environment 结束时会按旧号关掉别人的文件和 socket，所以主线程和 Worker 都关了 fd 跟踪。代价：一次运行留下没关的原始 fd，要到 App 退出才释放。
- iOS 的 App 外宠物使用系统画中画，默认关闭且不作为手机操控前置条件；伙伴小屋另有小号/中号桌面小组件，展示名字、状态、亲密度和最近一句话，点按进入小屋。小组件使用专用共享 Keychain 展示快照，不共享模型凭据或配对记录；Runner 与 CompanionWidget 的签名必须包含相同的专用 access group。系统安排刷新，不是实时 Live2D 动画。Android 式悬浮窗、无限后台常驻和应用内 APK 更新不适用于 iOS。
- 手机系统动作（日历、分享、拨号草稿等）给本机引擎提供 13 个 `mcp__phone__*` 工具，和安卓同一份目录。每个动作都要在 App 里批准一次，通知点击不算批准。系统动作本身还没在设备上跑过。
- Siri 和快捷指令（iOS 16 以上）：问 DSH Go、语音输入、新建对话。都只是打开 App 停在输入框，不会自动发送。CI 只查过元数据，没实际喊过。
- 内置浏览器：`mcp__browser__*`，App 内一个独立的 WKWebView，脚本跑在单独的 content world 里。每次运行里，每个站点第一次要用户批准。密码和支付字段不让填，弹页面交给用户。不能访问本机和内网地址，但只查写死的 IP，解析到内网的域名拦不住。iOS 17 以上登录状态和 App 其他网页分开存。
- 系统工具：`mcp__system__*`，读写提醒事项和联系人、选图片、读一次位置、识别图片里的文字。只在用户看着 App 时才跑，每次都弹确认并写明要读写什么。选图片用系统选择器，它本身就算同意；文字识别只能用这个对话选过的图片，图片 30 分钟或本次运行结束后失效。这部分只编过、没在设备上跑过。
- 控制其他 App：默认使用本机 CoreDevice 开发者连接查询/打开应用和 OCR 读屏，实际输入能力取决于系统服务；XCTest 是单独启用的增强，需匹配并签名安装的 PhoneRunner。本次引擎和对话的手机任务首次由用户原生授权，最长 30 分钟；普通后续动作不再逐次拉回确认，敏感输入交还用户。开启完成后返回时，CoreDevice 与 XCTest 各自复用本任务仍有效的连接打开 DSH Go，不重建连接、不跨路线重试，是否进入前台以 UIKit 为准。Mac runner 仍是可选路径。参见[手机操控](../../docs/guide/zh/04-phone-control.md)和[设备验证记录](../../tooling/ios/phone-self-runner/DEVICE_TEST_PROGRESS.md)；模拟器通过不代表当前组合版本已经完成真机验收。
- `dsh/native-media` 的语音不提供：回声消除管不到扬声器。`dsh/usage` 只读不上报：Worker 只收安卓的值。`dsh/dynamic_color`、`dsh/picture_shortcut` iOS 没有公开接口，入口隐藏。
- 设备档位：内存低于 3.5 GiB 算低档，其余中档，不用 `high`。
- 通知只在应用运行时发得出去。锁屏和离开应用后的提醒要 APNs，还没做，所以离开应用后等你确认的请求不会提醒你，回到应用才看得到。
- 凭据存在 Keychain，只留在本机，不随备份迁移。全新安装时会先清掉上一次安装留下的 Keychain（`AppDelegate.forgetPreviousInstall`）。
- 包里还带着 `assets/engine/`，隐藏入口不等于移除。发行前要决定去留，并生成 iOS 的第三方许可清单（见 `app/lib/ui/common/third_party_licenses.dart`）。
- 发行前需检查安装包内容及 iOS 的第三方许可清单；运行时下载不免除原有许可证和署名要求。
- 分享扩展靠响应链唤起主应用，这是非公开用法，上架时要重新评估。唤起失败时，内容留在收件箱，下次回到应用时送达。

## 真机验收

装好后逐项过一遍，失败的记下系统版本和现象：

| 项 | 怎么测 | 应该看到 |
|---|---|---|
| 首次引导 | 全新安装 | 只出现通知和语音两项权限，没有存储、电池、无障碍；通知和麦克风各弹一次系统对话框 |
| 远程连接 | 配对一台主机，发一轮消息 | 回复流式出现；局域网直连时系统问一次本地网络权限 |
| 系统识别 | 输入框点语音，说中文和英文 | 边说边出字；结束后文字留在输入框；飞行模式下，支持本机识别的语言仍可用 |
| 语音被打断 | 听写时来电或定闹钟 | 听写结束并提示，之后应用里的声音正常 |
| 通知 | 应用在前台，后台跑完一轮 | 收到提醒，点开进入对应对话 |
| 通知被拒 | 系统对话框选不允许，再到后台运行页点通知 | 跳到系统设置的通知页 |
| 快捷操作 | 长按桌面图标 | 有新对话、语音输入和最近的对话，点开各自进入 |
| 冷启动快捷操作 | 划掉应用后再用快捷操作 | 同样能进入，不丢 |
| 分享文字和链接 | Safari 分享一个网页 | 应用被唤起，新对话输入框里有链接和标题 |
| 分享照片 | 相册选 3 张（含一张 HEIC），分享 | 都在附件里，HEIC 变成 JPEG，长边不超过 2560 |
| 分享过多 | 一次分享超过 9 项 | 系统不提供 DSH Go，或多出的提示被跳过 |
| 唤起失败 | 分享后没有回到应用时，手动打开应用 | 内容仍然送达，只送一次 |
| 分享时被杀 | 分享后立刻划掉应用，再打开 | 内容还在，可能重复一次，不会自动发送 |
| 重装 | 登录后卸载，再装回来 | 不会带着旧凭据自动连上 |
| `.dshgo` | 文件 App 里打开或分享一个 `.dshgo` | 进入分享码导入，不会变成聊天附件 |
| 链接 | Safari 打开 `dshgo://` 链接 | 进入对应页面 |
| 文件 | 打开和保存对话产生的文件、PDF 预览 | 预览正常，保存后在文件 App 的 DSH Go 目录里 |
| 相册 | 保存生成的图片 | 系统只要求“添加照片”权限，图片进相册 |
| WebView | 打开网页模式，切后台久一点再回来 | 被系统回收时显示“网页已关闭 · 重新打开”，点开后恢复 |
| 本机引擎安装 | 配好可访问的运行时 URL，在设置里安装，中途杀掉应用后重试 | 显示下载和安装进度，核验通过才安装；成功后删除下载 ZIP |
| 本机引擎一轮 | 配好模型，新对话让它写文件、搜索、跑 bash | 回复流式出现，审批是真弹的，文件在产出目录 |
| 本机引擎重启 | 停止，再启动 | 不用重开应用，新对话正常 |
| 本机引擎切后台 | 跑一轮时切走几分钟，再回来 | 接着跑或明确报结果未知，不重复执行工具 |
| 结果未知 | 工具跑到一半时划掉应用，再打开那个对话 | 横幅说有调用没等到结果；确认之前工具被拒绝；确认后对话能继续，那个调用不会重跑 |
| 本机产出 | 让引擎往产出目录写文件，再打开、分享、保存 | 产出列表里有它，三个操作都正常 |
| 本机图片 | 配一个支持图片的模型，发一张 4800 万像素照片和一张透明 PNG，再让内置浏览器截图 | 模型看得到图内容；照片方向正确；发送时内存不至于把 App 杀掉；对话里有缩略图 |
| 重置和卸载 | 引擎页重置（保留技能），再装回来；再卸载 | 选了保留的还在，其余没了；卸载后存储空间回来，远程连接不受影响 |
| 只连远程不加载引擎 | 不启动本机引擎时看内存（Xcode 调试栏） | 没有多出约 90 MB 的 Node |
| 后台继续（iOS 26） | 本机跑一轮时切走 | 系统显示进度，这一轮接着跑；系统收回后回来能看到结果或结果未知，不重复执行工具 |
| Siri | 喊“问 DSH Go”，快捷指令 App 里也找一下 | 打开 App，内容在输入框里，没有自动发送；中文系统用中文短语 |
| 内置浏览器 | 让引擎打开一个网站、读内容、点链接、填搜索框 | 第一次弹站点批准；换站点再弹；密码框被拒绝并弹页面给你；关掉后没有留下进程问题 |
| 浏览器和 App 分开 | 在内置浏览器登录一个网站，再看 App 的网页模式 | 登录状态不互通（iOS 17 以上） |
| 提醒事项 | 让引擎列提醒、新建一条、标记完成 | 每次弹确认写明内容；系统权限只问一次；提醒 App 里能看到改动 |
| 改过的提醒 | 引擎列完后手动改那条提醒，再让它标记完成 | 引擎收到“已经改过了”，没有覆盖你的改动 |
| 联系人 | 让引擎查一个人的电话、新建一个联系人 | 确认里写明查什么；只返回问到的字段；不动已有联系人；iOS 18 受限授权时只查得到允许的 |
| 选图片和识别 | 让引擎选一张带中文的图并读文字 | 弹系统选择器；读出中文；换个对话用这张图被拒绝 |
| 位置 | 让引擎读当前位置，再在设置里改成大致位置 | 确认后弹一次系统权限；大致位置时返回 `reduced` |
| 控制其他 App | 配好本机开发者连接，让引擎打开设置并连续读屏；点按另测 XCTest 增强 | 不选宠物、不开画中画也可发起手机任务；首次任务授权后连续读屏无需回 App 重复确认；任务完成后按设置返回原对话；连接缺输入能力时不伪造点击成功 |
| 换主题的网页小窗 | 系统和应用的深色设置不一致时打开插件小窗 | 跟随应用的深色，文字缩放跟随 |
| 深色模式 | 系统切深色后启动 | 启动屏不闪白 |
| 中文 | 系统语言切中文和英文 | 权限说明和快捷操作跟随系统语言 |
| 图标 | 桌面、设置页 | 显示品牌图标，不是 Flutter 默认图标 |
| 换图标 | 外观页依次选四款图标 | 系统提示后桌面图标跟着变，重开应用仍选中当前这款 |
