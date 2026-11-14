# dsh-go iOS Linux 沙箱（iSH）集成说明

> 阶段 4（构建链与 AOT）的实测记录。本文只写实测值；测不到的写“未测”，不编数字。
> 设计依据：`~/workspace/dsh-go-ipa/linux-sandbox-design.md`（§2.8、§3 阶段 4、§5）。
> 分支：`feat/ish-linux-sandbox`。AOT 槽位与录制流程见 `third_party/ish/build-aot.sh` /
> `third_party/ish/record-aot.sh` 与 `~/workspace/dsh-go-stage4/STAGE4-NOTES.md`。

## 1. 架构（一句话）

DSH 留在 NodeMobile 里；iSH 是并行的执行后端（Alpine userland，进程内模拟的
ARM64 Linux 内核，Asbestos 翻译层 AOT-only：`-Djit=true -Djit_emit=false`，
运行时不映射可执行内存，不需要 `dynamic-codesigning` entitlement）。
终端页走 Guest PTY（`/bin/sh`），agent `bash` 走 DSH 补丁 + Node 转发层
（`ish-bridge.mjs`）→ 回环 HTTP/WS 服务（`/ish/exec`、`/ish/pty`）。

## 2. 构建链（4.1 / 4.2，阶段 2 已做，阶段 4 核实）

| 件 | 位置 | 状态 |
|---|---|---|
| iSH 静态库构建 | `third_party/ish/build-ish.sh`（Meson 交叉编译，arm64 device only，min iOS 15.0） | ✅ 构建 19–23 均产出 |
| rootfs 制作 | `third_party/ish/prepare-rootfs.sh`（Alpine 3.21.0 minirootfs → fakefs → 确定性 zip，固定 2020-01-01 时间戳） | ✅ 构建 23 的 zip：523 条记录全是 2020-01-01，哈希 `3392680bd78e` |
| 源码钉选 | `third_party/ish/source.json`（OpenMinis/ish-arm64 @ `0fd17a13`） | ✅ |
| Xcode 工程 | `app/ios/Runner.xcodeproj/project.pbxproj`（IShArtifacts 组：libish.a / libish_emu.a / libfakefs.a + alpine-rootfs.zip；`OTHER_LDFLAGS` 有 `-lish_emu -lish -lfakefs -lsqlite3 -lz -lresolv`） | ✅ |
| Codemagic | `codemagic.yaml` 工作流 `ios-stage2-verify`（Build iSH libs + Stage iSH artifacts 两步；`max_build_duration: 120`） | ✅ 构建 19–23 均产出含 iSH 的未签名 IPA |
| AOT 槽位 | `third_party/ish/build-aot.sh`（产 `libish_aot.a`：本地 .S 组装 / 下载 SHA256 钉死 / 空 stub 三档）；pbxproj 三处 `OTHER_LDFLAGS` 均已加 `-force_load $(SRCROOT)/IShArtifacts/lib/libish_aot.a` | ✅ 阶段 4 接线；当前是空 stub（纯 gadget 解释器） |

## 3. AOT 镜像（4.3）

- **v1 出货状态：无镜像（纯 gadget 解释器）。**构建 23 真机已验证 shell 可用
  （`root@dsh-go`，`ls /` 全套目录，`/home/workspace` 挂载正常）。
- **ABI 门禁在引擎里，不在构建脚本里**（`asbestos/guest-arm64/jit.c`
  `aot_init()`）：镜像的 `abi` / `prologue_words` / `entry_off` /
  `n_pinned` 与当前 iSH 不符时，镜像进 `rejected` 列表，不装、不崩。
  本分支钉选的 iSH（`0fd17a13`）的 `JIT_CODE_VERSION` 是 8；OpenMinis
  在同一版本上录制的 abi 是 `1f3bb5a0`。真机验证方法（无需改代码）：
  在终端里跑 `cat /proc/ish/jit`，看 `images: N in use, M rejected
  (abi XXXXXXXX)` 一行与每模块的命中数。
- **最小 AOT 集（待录制）**：musl、busybox、zlib、libcrypto、libssl、pcre2。
  录制流程在 `third_party/ish/record-aot.sh`（macOS arm64 专用，Codemagic
  工作流 `ios-aot-record` 一键触发）；镜像不进 git，走 GitHub release
  下载、SHA256 钉死（`third_party/ish/aot-manifest.json`）。完整 25 张
  镜像集是后续迭代。
- **AOT 开关**：引擎默认开（`aot_off` 初始为 false；`/proc/ish/jit` 写
  `off` 可关）。dsh-go 没有单独的开关 UI；有镜像时自动用，无镜像时
  自动退回 gadget 解释器。
- **命中率与提速：未测。** 录制完成后按设计里的方法测（grep/find 这类
  命令的前后耗时对比；ripgrep 这类瓶颈在文件系统调用的场景如实记录，
  不硬凑数字）。OpenMinis 的参考数（iPhone 实测，供对照，不是 dsh-go
  的实测）：AOT 命中率 85–100%（libjpeg 55.7% 例外）；grep 134.3s →
  99.7s、find 6.7s → 5.8s；ripgrep 只快 3–6% 所以没收录。

## 4. 包体与构建时间实测（4.4）

### 4.1 IPA 大小（实测，2026-11-14/15）

| 构建 | IPA 大小（字节） | 说明 |
|---|---|---|
| 原始 dsh-go（无 iSH，2026-11-14 ~15:56） | 152,615,225 | 基线 |
| 构建 20（阶段 2，2026-11-14 23:16） | 156,993,482 | 含 iSH |
| 构建 21（阶段 3，2026-11-15 00:03） | 157,007,988 | 含 iSH + bridge |
| 构建 22（阶段 3 修复，2026-11-15 00:51） | 157,020,346 | 含 iSH + bridge |
| **构建 23（阶段 3 根因修复，2026-11-15 01:20）** | **156,982,023** | **含 iSH + bridge + 确定性 rootfs** |

- **iSH 增量（构建 23 − 基线）：4,366,798 字节（约 4.2 MiB，压缩后）。**
- 构建 23 包内实测（未压缩大小）：
  - `Payload/Runner.app/Runner`：4,103,512 字节（基线 3,008,672；差值
    1,094,840，约 1.0 MiB——链接进来的三个静态库经链接器裁剪后的增量）
  - `Payload/Runner.app/alpine-rootfs.zip`：3,956,916 字节
  - `Payload/Runner.app/NativeNode/ish-bridge.mjs`：41,907 字节
  - （注：IPA 是 zip 压缩包，各件未压缩大小之和 ≠ IPA 总大小，不要直接相加。）
- AOT 镜像对包体的影响：**未测**（当前是空 stub，增量约 0）。完整 25 张
  镜像集的 .S 合计约 1 GB（OpenMinis 的数字），装配后的 .a 会显著增大
  IPA；最小集（6 张）的影响待录制后实测。

### 4.2 构建耗时（实测，Codemagic mac_mini_m2，2026-11-15）

| 构建 | 开始 → 结束（UTC） | 总耗时 | 其中 iSH 两步 |
|---|---|---|---|
| 构建 23 | 17:09:23 → 17:20:07 | **10 分 44 秒** | Build iSH libs 1 分 36 秒；Stage iSH artifacts 6 秒 |
| 构建 22 | 00:38:45 → 00:51:17 | 12 分 32 秒 | （未分段） |
| 构建 21 | ~23:53 → 00:03:58 | 约 11 分 | （未分段） |
| 原始 dsh-go（无 iSH） | — | 约 8 分 | — |

- 构建 23 分段耗时（API 实测）：Flutter pub get and analyze 76 秒；
  Install DSH engine 32 秒；iSH bridge 单测 33 秒；Stage iOS engine 10 秒；
  Assemble NativeNodeArtifacts 17 秒；Build iSH libs 96 秒；Stage iSH
  artifacts 6 秒；Pod install and build iOS 3 分 49 秒；Package IPA 22 秒。
- **iSH 两步合计约 1 分 42 秒**；相对无 iSH 的构建（约 8 分），总耗时
  增加约 3 分钟。`max_build_duration: 120` 有充足余量。
- 首次构建（冷缓存）耗时：**未测**（构建 19–23 都是 Codemagic 新机，
  无缓存，上述即冷构建耗时；本地首次构建参考 OpenMinis 的 30–60 分钟，
  未在 dsh-go 上实测）。

### 4.3 rootfs 解压耗时（首次安装）

- **精确分段计时：未测。** App 目前没有记录解压耗时的日志；精确数字
  需在真机上分段计时（解压开始 → `.ready` 标记写入）或在代码里加时间戳。
- **实测上界：< 60 秒。** 2026-11-15 01:27 真机：用户点终端失败页的
  “重置并重装”后，同分钟内 shell 已可用（`root@dsh-go` 提示符）。这是
  重置 + 解压 + boot 的全程上界，不是纯解压耗时。
- rootfs zip 大小：3,956,916 字节（构建 23），内含 523 条记录（data/ +
  meta.db）。解压是首次使用时一次性完成，之后冷启动不再解压。

### 4.4 内存（未测）

- Guest 内存上限取可用内存 ×0.5（2 GB 硬顶），阶段 1 的实测定稿值；
  单 shell 内存占用与 DSH 全量启动 + Guest 跑编译时的 footprint 采样
  尚未在 dsh-go 真机上做。见设计 §1.11 / §3 阶段 5.5。

## 5. 已知不支持项（v1）

- 后台执行：App 切后台后 Guest 同样被挂起/节流（设计 §2.7）。
- App Store 上架：v1 只走侧载；合规动作在阶段 6（源码提供、第三方声明）。
- Native offload（28 个假命令）：不做。
- Android：不做。
- AOT 完整 25 张镜像集：后续迭代；当前最小集（6 张）待录制。

## 6. 回归注意

- 模拟器：iSH 库只产 arm64 device 切片，模拟器构建会链接报错；
  Codemagic 只产 device IPA，不受影响。
- 下个构建不再要求重置的验证：构建 23 与构建 24 的
  `rootfs-manifest.json` 里的 `rootfs_zip_sha256` 必须相同（确定性 zip；
  构建 23 的值是 `3392680bd78e`）。
