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

- **v1 出货状态：最小 AOT 集（6 张镜像）已装上。**构建 51（2026-11-16 01:32，
  ios-stage2-verify，commit b379fcd8）07c 步骤确认走 downloaded 模式：从
  GitHub release `aot-minimal-1f3bb5a0` 下载 `libish_aot.a`（46,947,640 字节），
  SHA256 `950fe2c46be1…` 核对通过，**images=6**。真机验证（2026-11-16 01:42，
  用户确认 "aot正常"）：App 启动不崩、终端可用，`cat /proc/ish/jit` 显示
  6 张镜像在用。Runner 二进制 43,085,432 字节（内含 `__ish_aot` 与
  `_ish_aot_module_libcrypto_3_3_2_r4` 等符号）。AOT 崩溃处理已按 OpenMinis
  补回 park 分支（`ISHCrashHandler.m`：guest 线程 fault 时记日志 + 阻塞全部
  信号 + `select()` 挂起，不再转发给 Node/V8 的 handler）。
- **ABI 门禁在引擎里，不在构建脚本里**（`asbestos/guest-arm64/jit.c`
  `aot_init()`）：镜像的 `abi` / `prologue_words` / `entry_off` /
  `n_pinned` 与当前 iSH 不符时，镜像进 `rejected` 列表，不装、不崩。
  本分支钉选的 iSH（`0fd17a13`）的 `JIT_CODE_VERSION` 是 8；OpenMinis
  在同一版本上录制的 abi 是 `1f3bb5a0`。真机验证方法（无需改代码）：
  在终端里跑 `cat /proc/ish/jit`，看 `images: N in use, M rejected
  (abi XXXXXXXX)` 一行与每模块的命中数。
- **最小 AOT 集（已录制、在用）**：musl、busybox、zlib、libcrypto、libssl、pcre2。
  录制在 Codemagic `ios-aot-record` 工作流上完成（attempt 14，2026-11-15 11:59，
  6 个模块全部超过翻译数门禁：musl 3830/3800、busybox 6556/5200、zlib 954/200、
  libcrypto 19039/15000、libssl 7326/5800、pcre2 4689/4100；manifest abi
  `1f3bb5a0`）。镜像不进 git，走 GitHub release 下载、SHA256 钉死
  （`third_party/ish/aot-manifest.json`）。完整 25 张镜像集是后续迭代。
- **AOT 开关**：引擎默认开（`aot_off` 初始为 false；`/proc/ish/jit` 写
  `off` 可关）。dsh-go 没有单独的开关 UI；有镜像时自动用，无镜像时
  自动退回 gadget 解释器。
- **命中率与提速：未测。** 录制完成后按设计里的方法测（grep/find 这类
  命令的前后耗时对比；ripgrep 这类瓶颈在文件系统调用的场景如实记录，
  不硬凑数字）。OpenMinis 的参考数（iPhone 实测，供对照，不是 dsh-go
  的实测）：AOT 命中率 85–100%（libjpeg 55.7% 例外）；grep 134.3s →
  99.7s、find 6.7s → 5.8s；ripgrep 只快 3–6% 所以没收录。dsh-go 的
  AOT 提速对照待阶段 5.5 实测（构建 47 无 AOT vs 构建 51 有 AOT，同一
  workload `time` 对比）。

### 3.1 agent bash（阶段 5.2，2026-11-16）

- agent `bash` 走 DSH 补丁（第 137 个，`ish-sandbox-backend.diff`）+
  bridge `spawnIshExec` → POST `/ish/exec` → `ISHShellExecutor` → Guest
  `/bin/sh`，输出 NDJSON 流回。bridge 单测 18/18 本地通过。
- **执行超时 600s**：bridge 的 `DEFAULT_EXEC_TIMEOUT_MS` = 600_000（=
  bash-local `maxTimeoutMs`；DSH deadline 是 operative timeout，服务端
  超时只是 backstop）。`sleep 70` 不再在 60s 被切断。
- **Stop/超时能杀到 Guest**：补丁把 `signal: spec.signal` 传给 Node
  spawn；bridge 接 `options.signal`，abort 即断开 HTTP 回环请求，Swift
  侧取消执行、杀 Guest 进程组；Node 24 signal-abort 只发 req `error`
  （AbortError）不发 `abort`，bridge 已按取消处理（不走 exit 1）。
  实测（mock /ish/exec）：abort 200ms → 207ms 以 SIGTERM settle，partial
  输出保留；无补丁对照：abort 后 5s 仍不 settle。
- stdin：spawn 后立刻写、25ms 收集窗口（bash executor 的非交互约定）；
  env 白名单；cwd 只认 workspace/tmp；未启动时 fail-closed
  （503 `ish_not_booted` → `SANDBOX_UNAVAILABLE`）。

## 4. 包体与构建时间实测（4.4）

### 4.1 IPA 大小（实测，2026-11-14/15）

| 构建 | IPA 大小（字节） | 说明 |
|---|---|---|
| 原始 dsh-go（无 iSH，2026-11-14 ~15:56） | 152,615,225 | 基线 |
| 构建 20（阶段 2，2026-11-14 23:16） | 156,993,482 | 含 iSH |
| 构建 21（阶段 3，2026-11-15 00:03） | 157,007,988 | 含 iSH + bridge |
| 构建 22（阶段 3 修复，2026-11-15 00:51） | 157,020,346 | 含 iSH + bridge |
| **构建 23（阶段 3 根因修复，2026-11-15 01:20）** | **156,982,023** | **含 iSH + bridge + 确定性 rootfs** |
| 构建 47（阶段 4 终端修复，2026-11-16 00:30） | 157,561,737 | 含 iSH + bridge + workspace 确保 |
| **构建 51（阶段 4 AOT，2026-11-16 01:32）** | **164,876,716** | **含 iSH + bridge + AOT 6 张镜像** |

- **iSH 增量（构建 23 − 基线）：4,366,798 字节（约 4.2 MiB，压缩后）。**
- **AOT 增量（构建 51 − 构建 47）：7,314,979 字节（约 7.0 MiB，压缩后）。**
  构建 51 包内实测：`Payload/Runner.app/Runner` 43,085,432 字节（构建 47
  仅 4,120,432；差值即链入的 `libish_aot.a`）；`alpine-rootfs.zip` 哈希
  `3392680bd78e`，与构建 23/24 相同（确定性 zip）。
- 构建 23 包内实测（未压缩大小）：
  - `Payload/Runner.app/Runner`：4,103,512 字节（基线 3,008,672；差值
    1,094,840，约 1.0 MiB——链接进来的三个静态库经链接器裁剪后的增量）
  - `Payload/Runner.app/alpine-rootfs.zip`：3,956,916 字节
  - `Payload/Runner.app/NativeNode/ish-bridge.mjs`：41,907 字节
  - （注：IPA 是 zip 压缩包，各件未压缩大小之和 ≠ IPA 总大小，不要直接相加。）
- AOT 镜像对包体的影响：**已测（最小集 6 张）**。构建 51 比构建 47 大
  7,314,979 字节（约 7.0 MiB，压缩后）；Runner 从 4,120,432 字节涨到
  43,085,432 字节。完整 25 张镜像集的 .S 合计约 1 GB（OpenMinis 的数字），
  装配后的 .a 会显著增大 IPA；最小集（6 张）的影响如上。

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
- Native offload（28 个假命令）：不做。Android：不做。
- AOT 完整 25 张镜像集：后续迭代；当前最小集（6 张）已录制、在用。
- **一次只能开一个交互终端**：ISHKernel 的交互路径是单条共享 `_consoleTTY`
  （全局 `g_ptyOutput` + 单个 outputCallback，`ish_proto_tty_write` 忽略
  tty 参数）；第二个终端会被回环服务以 close 1008 拒绝，终端页显示
  "another terminal session is already active"。真多终端需内核级
  per-session PTY 路由，是阶段 5.3 的独立大项（用户已定"一个终端够用"）。
- agent `bash` 单次执行上限 600s；stdin 只在 spawn 后 25ms 内收集，之后
  写入的丢弃（非交互约定）；Guest 内网络策略未强制执行。

## 6. 回归注意

- 模拟器：iSH 库只产 arm64 device 切片，模拟器构建会链接报错；
  Codemagic 只产 device IPA，不受影响。
- 下个构建不再要求重置的验证：构建 23 与构建 24 的
  `rootfs-manifest.json` 里的 `rootfs_zip_sha256` 必须相同（确定性 zip；
  构建 23 的值是 `3392680bd78e`）。
