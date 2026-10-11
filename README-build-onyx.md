# build-onyx（seventeen @ 6.6.142）

本文记录本仓库 `.github/workflows/build-onyx.yml` 的实现。

- **树**：`seventeen` @ `6.6.142`，远端唯一分支就是 `seventeen`
- **设备**：Xiaomi SM8735（onyx），Oryon 平台，仅 aarch64
- **来源**：从 `kernel_xiaomi_sm8735`（`oss` @ `6.6.82`）整套迁移而来

`anykernel/AK3-NOTES.md` 记录 AnyKernel3 打包注意事项，**改 `tools/` 前必读**。

---

## 1. 迁移说明：和 6.6.82 那套有什么不同

流水线设计（官方 Kleaf 配置合成 + 三道闸门）**没有改动**。以下是真正需要改的部分，
每一条都做了验证。

### 1.1 两个补丁全部重新生成

代码本身逐字未变，变的只有行号。两个补丁都用「改文件 → `diff -u` → 写成 patch →
`patch --dry-run` 复验」的方式重新生成，**零 offset、零 fuzz**：

| 补丁 | 6.6.82 | 6.6.142 |
|---|---|---|
| `droidspaces_sysvipc.patch` | `sched.h` hunk @ 1075 / 1524 | hunk @ 1076 / 1530（+1 / +6） |
| `libbpf_strchr_const.patch` | `libbpf.c` @ 11241，`Makefile:89` | @ 11255，`Makefile:88`（+14 / −1） |

### 1.2 SUSFS：分支名对不上，但补丁能用；**不钉 commit**

susfs4ksu **没有 android17-6.6 分支**，它唯一的 6.6 分支是 `gki-android15-6.6`。
实测该分支的补丁套到 6.6.142 上：

```
19 hunks succeeded, 0 FAILED, exit 0
仅 fs/proc/base.c 的 hunk #4 落在 fuzz 1（offset 148）
```

**刻意不钉 commit**，始终跟踪分支头，这样上游修复不需要改本仓库就能生效。
代价是上游某次改动可能让补丁套不上 6.6.142——所以做了两件事保证"响而不静"：

- 实际用到的 commit 记进 `SUSFS_STATUS`（`applied (a0f9c59e)` 这种形式）；
- 套用失败时闸门 3 会因为 `CONFIG_KSU_SUSFS` 掉失而**硬失败**。

静默失效比构建失败更糟。

顺带：`fixup_susfs.sh` 在本树是**空操作**——`fs/proc/base.c:103` 本来就有
`<linux/dma-buf.h>`。脚本保留，因为它幂等且自检，而那个 fuzz 1 的 hunk 正好在同一个文件里。

### 1.3 AutoFDO：改用树内档案

本树**自带** `android/gki/aarch64/afdo/kernel.afdo`（4.1 MB，采集自 **6.6.129**，
Pixel 10）。这比旧流水线从 `android.googlesource.com` 下载好得多：

| | 旧（6.6.82） | 新（6.6.142） |
|---|---|---|
| 来源 | 上游下载 `android15-6.6` GKI 档案 | 树内 `android/gki/aarch64/afdo/` |
| 采集版本 | 6.6.x（差距大） | 6.6.129（**差 13 个 patchlevel**） |

探测过 `android16-6.6`(404) / `android16-6.12`(400) / `android17-6.6`(404)，
上游只剩 `android15-6.6` 一个 GKI 档案。仍然非致命，缺失则跳过。

注意 `arch/Kconfig:804`：`AUTOFDO_CLANG depends on CC_IS_CLANG && CLANG_VERSION >= 170000`。
工具链太旧会**静默**丢掉这个符号——正是闸门 3 存在的意义。

### 1.4 模块签名变成 SHA-256

```
6.6.82 的 gki_defconfig：不写 choice → 取 Kconfig 默认 → SHA-512
6.6.142 的 gki_defconfig：第 105 行 CONFIG_MODULE_SIG_SHA256=y → SHA-256
```

这是**基线自己的行为，不是本文件的决定**。不要用 fragment 去「修正」——
那会撞闸门 1。本地已验证 `CONFIG_MODULE_SIG_HASH="sha256"`。

### 1.5 `.gitignore` 吞掉 `.github/`（两次踩坑）

本树 `.gitignore` 有**两条**规则会吞掉 CI 目录：

| 行 | 规则 | 吞掉什么 |
|---|---|---|
| 13 | `.*` | `.github/` 本身 |
| 40 | `*.patch` | `.github/actions/*.patch` |

已在文件末尾补上对应反向规则（`!.github/`、`!/.github/`、`!.github/actions/*.patch`）。

**这两次失败都是静默的**：`git add -A` 跳过文件，`git status` 干干净净，
工作流本身还是进了仓库，CI 要跑到好几步之后才报
`No such file or directory` —— 而那个文件明明就在你刚提交的 diff 里。

改动 `.gitignore` 后必须跑这个检查，10 个关键文件全过才算完：

```bash
for f in .github/workflows/build-onyx.yml \
         .github/actions/droidspaces_sysvipc.patch \
         .github/actions/libbpf_strchr_const.patch \
         .github/actions/fixup_susfs.sh \
         arch/arm64/configs/onyx_gki.fragment \
         arch/arm64/configs/onyx_susfs.fragment \
         anykernel/tools/busybox anykernel/anykernel.sh \
         README-build-onyx.md; do
  git check-ignore -q "$f" && echo "✗ IGNORED: $f" || echo "✓ $f"
done
```

提交前再确认一次：

```bash
git ls-files --cached .github/actions/    # 三个文件都必须在
```

### 1.6 新树独有：`GKI_DYNAMIC_TASK_STRUCT_SIZE`

本树多了一套 kABI 机制，`gki_defconfig:190` 有
`CONFIG_GKI_TASK_STRUCT_VENDOR_SIZE_MAX=1024`。它和 Droidspaces 补丁**正交**，不会冲突：

- 动态 vendor 区在 `sizeof(struct task_struct)` **之后**
  （`include/linux/sched/task.h`，`android_task_vendor_data()` 返回 `p + 1`），
  所以不可能移动结构体内部的任何字段；
- `ANDROID_KABI_RESERVE` 操作的仍然是 `task_struct` 内部的槽位。

实测它确实开着（`GKI_DYNAMIC_TASK_STRUCT_SIZE=y`，由 base 提供），
且 `gki_defconfig` 基线在本地 `olddefconfig` 往返后**零漂移**（`diffconfig` 的 `^-` 行为 0）。

### 1.7 Droidspaces 配置跟上上游（2026-10-04）

对照 `ravindu644/Droidspaces-OSS` 的 `Documentation/Kernel-Configuration.md`
（commit `92cee27`）的 GKI 配置块，补齐了 9 个此前没有的符号：

| 组 | 符号 |
|---|---|
| NAT66 | `IP6_NF_NAT` `IP6_NF_TARGET_MASQUERADE` |
| UFW | `NETFILTER_XT_TARGET_LOG` `NETFILTER_XT_MATCH_RECENT` |
| fail2ban | `IP_SET` `IP_SET_HASH_IP` `IP_SET_HASH_NET` `NETFILTER_XT_SET` |
| NixOS | `TMPFS_XATTR` |

**两个符号刻意不加**，理由和上游一致：

- `CONFIG_CFS_BANDWIDTH` / `CONFIG_CGROUP_PIDS`（`--cpus` 和 `--pids-limit`）
  会改变调度器与 cgroup 结构体大小，数千个导出符号的 CRC 随之改变，原厂
  `vendor_dlkm` 模块拒绝加载，设备变砖。新字段塞不进 `ANDROID_KABI_RESERVE`
  预留位，所以 `droidspaces_sysvipc.patch` 救不了。上游自己也把它们注释掉了。
  `CONFIG_MEMCG` 基线本来就是 `=y`，所以 `--memory` 可用。
- `CONFIG_NETFILTER_XT_TARGET_REJECT` 在 6.6 已不存在。REJECT 目标现由
  `CONFIG_IP_NF_TARGET_REJECT` / `CONFIG_IP6_NF_TARGET_REJECT` 提供，
  两者在 `gki_defconfig` 里已经是 `=y`。照抄旧名字会被 `olddefconfig` 丢弃，
  然后闸门 3 判它为「请求开启却被丢弃」而**让构建失败**。

`CONFIG_CGROUP_DEVICE` 在上游的非 GKI 块里有、GKI 块里没有（虽然上游的
「缺少后果」表把它标为致命）。它在 6.6 无 Kconfig 依赖、也不在冻结 kABI
列表里，但 stock onyx 同样没开，且上游刻意不把它列入实测过的 kABI 安全集合，
所以不加。

这 9 个符号都不在 `android/abi_gki_aarch64.stg` 里。验证方式是真跑一遍
config 合成（闸门 1/2/3 全过），不是照着文档抄。

---

## 2. 配置合成

```
  gki_defconfig                     stock GKI 6.6.142 基线（796 行）
    + onyx_gki.fragment             Capybara 调优
    + vendor/onyx_perf.config 的 =y 行（构建时生成）
    + onyx_susfs.fragment           仅当 enable_susfs
    + onyx_autofdo.fragment         仅当树内 AutoFDO 档案可用
  ── merge_config.sh -m -r -y ──▶  onyx_gki_defconfig
  ── make onyx_gki_defconfig ────▶  out/.config
```

三道闸门抄自 `build.config.msm.common`（`:97` / `:105-112` / `:125`）：

1. **无覆盖**——`merge_config.sh` 不得报 `Previous value: …=[ym]`
2. **warning 即错误**——`make` 输出无 `warning:`，且 `out/.config` 非空
3. **fragment 全部生效**——`diffconfig` 不得有 `-SYM y` / `-SYM m` / `-SYM y -> m`

闸门 3 只过滤 `^-[A-Za-z0-9_]+ n$` 一种形态：`olddefconfig` 会把**本来就没设过**的
符号报成这个形态。请求了却被丢弃的 `y` / `m` 一个都不放过。

### 本地验证结果

用本机 clang 23.1.1 + pahole 1.32 完整跑了一遍 Configure（补丁按 CI 顺序应用）：

```
[gate 1/3] no overridden values
[gate 2/3] no kconfig warnings, out/.config produced
[gate 3/3] every requested symbol took effect (8 unset-but-invisible symbols ignored)
```

关键配置：

| 符号 | 值 |
|---|---|
| `CONFIG_HZ` | 300 |
| `CONFIG_LTO_CLANG_THIN` | y（`CONFIG_CFI_CLANG=y`，所以不能用 FullLTO） |
| `CONFIG_ZRAM_DEF_COMP` | `"lz4"` |
| `CONFIG_SYSVIPC` | y |
| `CONFIG_AUTOFDO_CLANG` | y |
| `CONFIG_DEBUG_INFO_BTF` | y（`CONFIG_DEBUG_INFO_REDUCED=n`） |
| `CONFIG_PAHOLE_VERSION` | 132 |
| `CONFIG_MODULE_SIG_HASH` | `"sha256"` |
| `CONFIG_MODULE_SIG_PROTECT` | y |
| `CONFIG_UAPI_HEADER_TEST` | n（刻意覆盖） |
| `CONFIG_PROFILING` / `CONFIG_BPF_LSM` | y |

---

## 3. BTF

| 前提 | 满足方式 |
|---|---|
| 不被 `DEBUG_INFO_REDUCED` 阻断 | 基线自带 `DEBUG_INFO_REDUCED=n`，闸门 2 的 `olddefconfig` 结果里断言 |
| pahole ≥ 1.21 | `:138` 装 `dwarves`；过旧则降级为无 BTF，不硬失败 |
| libbpf 能用现代宿主编译器编过 | `.github/actions/libbpf_strchr_const.patch`（本树已重新生成） |

- 依赖出处：`lib/Kconfig.debug:380`
  `depends on !DEBUG_INFO_DWARF5 || PAHOLE_VERSION >= 121`；本树实测 pahole **132**。
- `CONFIG_MODULE_ALLOW_BTF_MISMATCH` 是**必需项**：手机 `vendor_dlkm` 里那些原厂
  预编译模块的 BTF 必然和我们编出来的不一致，`kernel/bpf/btf.c:7373-7390` 会直接
  拒绝加载。
- `.BTF` 在 `scripts/link-vmlinux.sh` 里被标为 `alloc,readonly`，所以
  `objcopy -O binary` 之后仍在 `Image` 里。Build 步骤新增了 `readelf -S out/vmlinux`
  断言，不再只信配置。

---

## 4. Xiaomi vendor 片段

`vendor/onyx_perf.config` 有 33 个 `=m` 条目。**驱动源码大多就在本树里**
（`drivers/power/supply/mca/`、`drivers/input/misc/si_haptic/`……），
但它们是编进 **vendor (msm-kernel) 镜像**的，不在 GKI 的 vmlinux 里。
全量合并会让 modpost 炸掉：

```
ERROR: modpost: "qcom_smem_alloc" [...mca_qcom_smem.ko] undefined!
ERROR: modpost: "pwrkey_irq_notifier_list" [...mtdoops.ko] undefined!
```

（`qcom_smem_alloc` 在 `drivers/soc/qcom/qcom_smem.c`，是个 vendor 模块；
`pwrkey_irq_notifier_list` 需要 `CONFIG_INPUT_PM8941_PKEY`。）

而且它们**从来不会被打包**——设备从 `vendor_dlkm` 加载原厂的。所以只取 `=y`：

```bash
grep -E '^CONFIG_[A-Za-z0-9_]+=y$' "$VENDOR_FRAGMENT" > vendor_builtin.fragment
```

**过滤偏粗**：4 个 `=y` 里 `JOYSTICK_XPAD_FF` / `JOYSTICK_XPAD_LEDS` 是真的，
但 `INPUT_FINGERPRINT` / `FOD_FINGERPRINT` 是**空壳**——真正用它们的驱动是
`CONFIG_FINGERPRINT_MI_FP=m`，被过滤器丢了。该驱动本身能链接（6.6.82 树验证过，exit 0），
可以加白名单，但加之前必须逐个验证能链接，链接不过的会让整个构建在 modpost 阶段失败。

---

## 5. AnyKernel3

- 脚本来自上游 `020dfec`，**7 个二进制保持 aarch64**（复制后已逐个 `file` 复核）。
- `anykernel.sh`：变量全大写、`do.devicecheck=0`、`NO_MAGISK_CHECK=1`、
  `IS_SLOT_DEVICE=auto`、init_boot 自动分流。
- `kernel.string` 在打包时被 `sed` 注入真实版本串，不会变陈旧。
- 打包：`zip -r9 "../$ZIP_NAME" ./* -x '*.md' '*placeholder'`，**`LICENSE` 刻意保留**。
- ⚠️ **绝对不要**用上游 master 的 `tools/` 覆盖：它只提供 32 位 ARM，而 SM8735
  不执行 AArch32。详见 `anykernel/AK3-NOTES.md`。

**DTB 打包分支目前是死代码**：本树 `arch/arm64/boot/dts/qcom` 有 160 个 dtsi，
`*onyx*` / `*sm8735*` 匹配数为 **0**，设备树由 vendor 侧提供。保留是因为一旦换用
带 DTS 的树它立刻生效，删掉会让那天静默丢失 `dtb/`。

---

## 6. 已知未解决

| 项 | 说明 |
|---|---|
| **`Module.symvers` CRC 未比对** | 刷进去能开机 **≠** 原厂 `vendor_dlkm` 模块都能加载。需要从设备取基线。一条命令即可确认：`adb shell su -c 'dmesg \| grep -E "disagrees about version of symbol\|Unknown symbol\|version magic"'` |
| 内核版本串 | `CONFIG_LOCALVERSION_AUTO=y` + 工作流改源码 → 版本串带 `-dirty`。仅观感 |
| vendor `=m` 过滤 | 见 §5 |

## 7. 未移植

`BBRv3`、`NTSYNC`、`Baseband-guard` —— 6.6.142 里没有这些特性。

---

## 8. 维护提示

### 改 fragment 前先读 `onyx_gki.fragment` 顶部的两条规则

它们不是建议，是闸门 1 和闸门 3 的直接后果：

1. 绝不要设基线里已经是 `=y` 或 `=m` 的符号 → merge_config 报 override → 构建失败。
2. 绝不要设依赖无法满足的符号 → `olddefconfig` 静默丢弃 → 闸门 3 失败。

### 第三条：**绝不要关掉基线已有的符号**

这条是**真机刷出来**的，代价是一台变砖的设备。

本仓库一度有一个 `reduce_debug` 开关，关掉 14 个调试符号
（UBSAN、`CLEANCACHE`、`DEBUG_MEMORY_INIT` 等），内核随即卡在小米 logo
上不开机。单一变量法排除后确认是它，与 LTO、AutoFDO 无关。

麻烦的地方在于：**当时测出来的代价是"20 个符号，全是调试功能"，
而且三道闸门全程绿灯。** `.config` 文本对比只能看出什么消失了，
看不出内核行为是否还一样。`CLEANCACHE` 是 Qualcomm tmem 的受害者缓存，
PFRA 换页时会被查询——它改变的是运行时决策，不是诊断输出。

所以：想要"更干净"的配置之前，先想清楚它在真机上做什么。

### BTF 两条铁律

- `CONFIG_DEBUG_INFO_BTF` 必须保持开。
- `CONFIG_DEBUG_INFO_REDUCED` 必须保持关。

**改 `tools/` 前先读** `anykernel/AK3-NOTES.md`。

---

## 9. 与 6.6.82 那棵树的关系

| | `kernel_xiaomi_sm8735` | 本树 |
|---|---|---|
| 分支 / 版本 | `oss` @ 6.6.82 | `seventeen` @ **6.6.142** |
| 模块签名 | SHA-512（Kconfig 默认） | **SHA-256**（base 显式设置） |
| AutoFDO | 上游下载 android15-6.6 | **树内档案**（采集自 6.6.129） |
| kABI 机制 | `ANDROID_KABI_RESERVE` | 同上，**外加** `GKI_DYNAMIC_TASK_STRUCT_SIZE` |
| dtsi | 160（无 onyx） | 160（无 onyx） |
| 配置合成 | 官方 Kleaf + 三闸门 | **相同，未改动** |
| 调试裁剪 | 保留（`reduce_debug`） | **已删除**（它就是变砖元凶，见 §11） |
| Droidspaces 配置 | 旧版 GKI 块 | **跟上 2026-10-04 上游**，见 §1.7 |

6.6.82 那棵树仍在维护，两套并行。本树的裁剪删除**没有**同步过去，
所以那棵树上的 `reduce_debug` 仍然是默认开启的。

---

## 10. CI 实跑记录

| 运行 | 结果 | 停在哪 |
|---|---|---|
| `logs_101154931030` | ❌ | 第 6 步：`.github/actions/libbpf_strchr_const.patch: No such file or directory` |
| `logs_101161199225` | ❌ | 第 9 步：`clang: error: unknown argument: '-print-version-number'` |
| `logs_101178482014` | ❌ | 第 15 步 Build：`certs/extract-cert.c:152: error: use of undeclared identifier 'key_pass'` |
| `logs_101188129967` | ✅ | 19/19 步全过，产物 `Onyx-Kernel-v4-20261005.zip`（19M，97 个模块） |
| `logs_101213666886` | ✅ | 19/19 步全过，**刷入后设备正常开机**（LTO/AutoFDO/裁剪 三者全关） |
| 第五次（排除法） | ✅ | 只关裁剪、保留 LTO + AutoFDO，**设备正常开机、功能全正常** → 定位到裁剪 |

前三次分别对应本文 §1.5、§12（第二次）、§14（第三次）。第四次见 §15、§17；
第五次（开机成功）见 §11。

**第一次**：`.gitignore` 有两条规则吞掉 CI 目录（`.*` 和 `*.patch`），我只处理了
一条。补丁文件从未进仓库，但 `git status` 是干净的，工作流照常入库。详见 §1.5。

**第二次**：迁移时我加的一行版本检查用了 `-print-version-number`。这个参数
**任何 clang 都不支持**（它是 GCC 的写法），用本机 `/usr/bin/clang 23.1.1`
可以复现同样的错误。clang 本身没问题，CI 上跑出来是
`Android (... based on r596125) clang version 22.0.2`。现在改成从
`--version` 输出里 `sed` 解析，并保留「低于 17 就早失败」的原意
（`arch/Kconfig:804` 的 `AUTOFDO_CLANG depends on CLANG_VERSION >= 170000`）。

**第三次**：**上游回归**，见 §14。

### 第三次运行的配置结果（全部正确）

```
[gate 1/3] no overridden values
[gate 2/3] no kconfig warnings, out/.config produced
[gate 3/3] every requested symbol took effect (9 unset-but-invisible symbols ignored)
```

| 符号 | 值 | | 符号 | 值 |
|---|---|---|---|---|
| `CONFIG_KSU` | y | | `CONFIG_SYSVIPC` | y |
| `CONFIG_KSU_SUSFS` | y | | `CONFIG_POSIX_MQUEUE` | y |
| `CONFIG_HZ` | 300 | | `CONFIG_IPC_NS` | y |
| `CONFIG_LTO_CLANG_THIN` | y | | `CONFIG_PID_NS` | y |
| `CONFIG_CFI_CLANG` | y | | `CONFIG_DEVTMPFS` | y |
| `CONFIG_ZRAM_DEF_COMP` | `"lz4"` | | `CONFIG_ANDROID_KABI_RESERVE` | y |
| `CONFIG_AUTOFDO_CLANG` | y | | `CONFIG_GKI_DYNAMIC_TASK_STRUCT_SIZE` | y |
| `CONFIG_MODVERSIONS` | y | | `CONFIG_DEBUG_INFO_BTF` | y |
| `CONFIG_DEBUG_INFO_BTF_MODULES` | y | | `CONFIG_PAHOLE_VERSION` | 131 |
| `CONFIG_MODULE_SIG_HASH` | `"sha256"` | | `CONFIG_MODULE_SIG_PROTECT` | y |

BakaSU `applied (main)`、SUSFS `applied (CONFIG_KSU_SUSFS=y)`、
Droidspaces `applied`、AutoFDO `enabled (in-tree profile, 4.0M)`。

本地用 clang 23 预测的三项全部命中：BTF 保住、AutoFDO 保住、
模块签名是 SHA-256 而非 512。

---

## 11. 刷机后卡 logo：与官方配置的对比

用户把成功构建的 AK3 包刷进去后**卡在第一屏小米 logo**，系统进不去，
recovery 也进不去。怀疑是配置问题。

### 基准：直接从官方 boot 镜像里解出配置

用户提供了**正在运行的系统自己的 boot 镜像**（pixelOS 官方附加镜像）。
用内核自带的 `scripts/extract-ikconfig` 解出配置：

```
Linux/arm64 6.6.142
Android (15071444, +pgo, +bolt, +lto, +mlgo, based on r596125) clang version 22.0.2
8757 行
```

**同一棵源码树、同一个编译器**——这是能拿到的最干净的对照基准。
已存为 [`arch/arm64/configs/stock_onyx.config`](arch/arm64/configs/stock_onyx.config)。

boot 镜像的结构（手工解析 `ANDROID!` v4 头）：

```
offset 4096          内核（未压缩 arm64 Image，36 805 120 字节）
offset 36810752      vbmeta（AVB0，1536 字节）
offset 100663232     AVB footer（AVBf）
```

### 对比结果

总差异 936 行，但其中 **689 项是官方 `=m` 的 vendor 模块**
（`MMC_CQHCI`、`ARM_SMMU`、`COMMON_CLK_QCOM`…），它们由 `vendor_dlkm` 加载，
GKI-only 构建里没有是**正常形态**。另有 503 项是这些模块的子选项（`SENSORS` 157 个等），
同样属于结果而非原因。

**真正有意义的差异只有 8 组：**

| # | 项 | 我们 | 官方 | 风险 |
|---|---|---|---|---|
| 1 | `AUTOFDO_CLANG` | **y** | **n** | **高** |
| 2 | `LTO_CLANG_THIN` / `LTO_NONE` | **y** / n | n / **y** | **中高** |
| 3 | `SYSVIPC` `POSIX_MQUEUE` `IPC_NS` `USER_NS` `PID_NS` `TMPFS_POSIX_ACL` | **y** | **n** | 低 |
| 4 | `DEVTMPFS`（`DEVTMPFS_MOUNT=n`，不会自动挂载） | **y** | **n** | 低 |
| 5 | `MODULE_SIG_ALL`（`MODULE_SIG_FORCE=n`） | **y** | **n** | 低 |
| 6 | `HZ` | 300 | 250 | 无 |
| 7 | `ZRAM_DEF_COMP` | lz4 | lzo-rle | 无 |
| 8 | 调试裁剪（UBSAN 等） | ~~off~~ **已删除** | on | — |

> 第 8 行曾是唯一一处"我们比官方配置少开的东西"。它现在不是差异了：
> 裁剪整块移除后，UBSAN、debugfs、printk 时间戳等全部跟随 GKI 基线开启，
> 与官方配置一致。**这一行曾经让设备变砖**，详见第 11 节。

### 已确证排除的三个嫌疑

**① 模块 CRC 不匹配。** `MODVERSIONS`、`ANDROID_KABI_RESERVE`、
`GKI_DYNAMIC_TASK_STRUCT_SIZE`、`GKI_TASK_STRUCT_VENDOR_SIZE_MAX`、
`MODULE_SIG_*` **全部逐字相同**。且 `include/linux/android_kabi.h:59-61` 证实
`__GENKSYMS__` 下 `_ANDROID_KABI_REPLACE(_orig,_new)` 展开成 `_orig`，
genksyms 看到的仍是原布局——所以 Droidspaces 补丁改 `task_struct`
**不会改变 MODVERSIONS CRC**。

**② AVB 校验。** 解析出的 vbmeta：

```
algorithm_type   = 0   (AVB_ALGORITHM_NONE，未签名)
descriptors_size = 0   ← 没有任何 hash / hashtree descriptor
flags            = 0
```

这个 vbmeta **什么都不校验**，是刷机时已被
`--disable-verity --disable-verification` 改写过的。替换内核不影响它。

**③ DTB 缺失。** 官方 boot 镜像里 `dtb_size = 0`，设备树本来就在 vendor 侧。

### 结论与两个开关

无法从配置对比直接定案，但**官方唯一没做、而我们做了的两件事就是 ① 和 ②**，
两者都改变代码生成，且都会放大错误优化的后果：

- AutoFDO 档案采自 **6.6.129 + GKI 配置**，却用到了 **6.6.142 + 小米配置**上，
  隔了 13 个 patchlevel 和一整套完全不同的配置，函数内偏移对不上
- 官方用 `LTO_NONE`，我们用 ThinLTO

因此新增两个开关做受控 bisect：

| 输入 | 效果 | 与官方一致性 |
|---|---|---|
| `enable_thinlto: false` | 不生成 LTO fragment → Kconfig 默认 `LTO_NONE=y` | LTO 部分完全一致 |
| `enable_autofdo: false` | 不生成 AutoFDO fragment | AutoFDO 部分完全一致 |
| 两个都 false | 完整复刻官方的代码生成设置 | **两项均一致** |

`CONFIG_LTO_CLANG_THIN` 因此从静态的 `onyx_gki.fragment` 移到了**运行时生成的
`onyx_lto.fragment`**，和 AutoFDO 一样——否则关掉它就得整份 fragment 都不合并，
会连带丢掉 HZ、SYSVIPC 等所有调优。

闸门 3 之后新增断言，配置与输入不符直接失败：

- `enable_thinlto=true` 但没有 `CONFIG_LTO_CLANG_THIN=y` → 失败
- `enable_thinlto=false` 但没有 `CONFIG_LTO_NONE=y` → 失败
- `enable_thinlto=false` 但 ThinLTO 仍然出现 → 失败
- `enable_autofdo=false` 但 `CONFIG_AUTOFDO_CLANG=y` 仍然出现 → 失败

四种输入组合本地实测配置正确、闸门 1/3 通过、断言全过；
三种配置与输入不符的情形反向测试确认断言会触发。

日志里还会打一行 `CODEGEN: clang ... / LTO=... / AutoFDO=...`，
一眼能看出这次跑的是什么设置。

### 第四次运行：开机成功（三个变量同时变）

用户在 `enable_thinlto=false` + `enable_autofdo=false` + `reduce_debug=false`
下重跑，**设备正常开机**。截图确认：

```
内核版本   6.6.142-4k-g17a947583ae7-dirty
设备       Xiaomi Redmi 25053RT47C
Android    17
SUSFS      v2.3.0（9 项功能全部就位）
管理器     BakaSU v4.2.0-rc3，工作中（Built-in）
```

日志侧 `[gate 1/3]`～`[gate 3/3]` 全过，`CONFIG_LTO_NONE=y`，
`[codegen] AutoFDO off, as requested`。

这一轮同时动了三个变量，所以当时还不能定论，只能说"某个被关掉的东西是凶手"。

### 第五次运行：排除法定论

用户用单一变量法逐项恢复，先只关裁剪、保留 LTO + AutoFDO：

```
enable_thinlto   = true
enable_autofdo   = true
reduce_debug     = false      ← 唯一变量
```

**设备正常开机，所有功能正常。** 结论确定：

> **开机挂死的元凶是调试裁剪（`reduce_debug`），不是 LTO，也不是 AutoFDO。**

### 排查过程中被逐一排除的假设

| 假设 | 排除依据 |
|---|---|
| AVB 校验拦下自定义 boot | stock vbmeta `algorithm_type=0`、`descriptors_size=0`，不校验任何东西 |
| `MODVERSIONS` CRC 不匹配 | 所有 kABI 符号与官方一致。**genksyms 只消费预处理文本，从不调用编译器**（`scripts/Makefile.build:130`），所以 ThinLTO / AutoFDO 在原理上就不可能改变 CRC；实测 `SYSVIPC=y/n` 在裁剪开着时 CRC 不同、打上 Droidspaces 补丁后完全相同 |
| 缺少 DTB | stock 镜像同样 `dtb_size=0` |
| vermagic 的 `-dirty` 后缀 | `kernel/module/version.c:79-88` 的 `same_magic()` 在模块带 CRC 时直接跳过内核版本部分，只比 flag 差异 |
| ThinLTO / AutoFDO | 第五次运行两者都开着，正常开机 |
| **调试裁剪** | **第五次运行只关它，正常开机** |

### 为什么裁剪能让设备挂死在 logo

裁剪清单里有 14 个 `-d` 符号，代价是 20 个符号。按启动期行为影响分：

- `CLEANCACHE`（Qualcomm tmem 受害者缓存，PFRA 换页时走）——**唯一一个
  真正参与运行时内存回收路径的符号**；
- `DEBUG_MEMORY_INIT`（内存初始化健全性检查）——改变内存初始化时机；
- `UBSAN_TRAP` + `UBSAN_SANITIZE_ALL`——官方配置本来也是开的，所以
  **UBSAN 本身可存活**，之前"裁剪是凶手"的怀疑一度被这条证据反驳；
- `DEBUG_MISC` / `CMA_DEBUGFS` / `BT_DEBUGFS` / `PRINTK_*` / `RCU_TRACE`——
  诊断输出，不改变功能。

也就是说，真正有启动期行为影响的是 `CLEANCACHE` 和 `DEBUG_MEMORY_INIT`，
而 `CLEANCACHE` 恰好是唯一一个会**改变内存回收决策**的。静态阅读找不到
它会让启动挂死的机制，只能靠排除法定位。

### 处理：整块删除，不保留开关

裁剪能力已从仓库里**完全移除**——`onyx_debug_reduction.fragment` 删除，
`reduce_debug` / `reduce_debug_group` 两个输入删除，configure 脚本里的
裁剪解析和裁剪审计一并删除。它省下的那 20 个符号，在一台会因此变砖的
设备上不值得，换一个纯增量构建的收益也不值。

> 之前实测"裁剪代价只有 6~20 个符号、全部无害"这个结论**是错的**：
> 代价确实是 20 个符号，但其中至少一个改变了运行时行为。
> 那个实验只对比 `.config` 文本，**证明不了运行时等价**。

### 顺带修掉的一个 bug

`CODEGEN:` 那行日志打出来是 `LTO= / AutoFDO=`——两个变量都是空的。
原因是我只把状态写进了 `$GITHUB_ENV`，**从没赋给 shell 变量**。
现已改为先赋值再写入，摘要表格里的 LTO / AutoFDO 两行也一并修正。

### 仍然无法从镜像判断的

**内核到底有没有启动。** "卡第一屏 logo" 有两种完全不同的含义：
bootloader 刷屏（内核没跑起来 → 问题在打包/加载，不在配置），
或系统启动动画（内核跑了但起不来 → 配置嫌疑成立）。

**这是下一步最需要确认的事。** 建议 `fastboot boot` 带上串口/USB console，
只要 10 行 dmesg 就能定位得比现在快十倍。

---

## 12. Configure 逻辑搬出工作流

GitHub 拒绝了第六次提交：

```
Invalid workflow file: .github/workflows/build-onyx.yml#L1
(Line: 390, Col: 14): Exceeded max expression length 21000
```

**GitHub 把整个 `run:` 块当作一个待展开的表达式，上限 21000 字符。**

| 版本 | Configure 的 `run` 块 | 限制 |
|---|---|---|
| 第四次（可用） | 20,803 | 21,000 |
| 第六次（被拒） | **22,092** | 21,000 |

上一版**只差 197 个字符**就贴在天花板上了。也就是说这不是"某次改坏了"，
而是**任何一次加注释都会炸**——包括我给裁剪分组加的那些说明。
### 修法

把 Configure 的全部逻辑移到 [`.github/actions/configure-kernel.sh`](.github/actions/configure-kernel.sh)，
步骤只剩 17 行：

```yaml
- name: Configure kernel (official Kleaf-style synthesis)
  env:
    ENABLE_SUSFS: ${{ inputs.enable_susfs }}
    ...
  run: .github/actions/configure-kernel.sh
```

`inputs.*` 通过 `env:` 传入，脚本里用 `$ENABLE_SUSFS` 这样的普通 shell 变量。
最大的步骤现在只剩 Package 的 3075 字符。

### 副作用比预期好：现在能本地跑了

脚本化之后可以做之前一直没能做的验证——**在本地完整复现 Configure**：

```bash
# 1. 复现 CI 的补丁序列
patch -p1 < .github/actions/libbpf_strchr_const.patch
patch -p1 < .github/actions/droidspaces_sysvipc.patch
# 2. BakaSU：克隆 Baka-SU/BakaSU，软链到 drivers/kernelsu，接进 Makefile/Kconfig
git clone --depth 1 https://github.com/Baka-SU/BakaSU.git KernelSU
ln -sfn ../KernelSU/kernel drivers/kernelsu
# 3. SUSFS
patch -p1 < .../50_add_susfs_in_gki-android15-6.6.patch
# 4. 跑
ENABLE_SUSFS=true ... ./.github/actions/configure-kernel.sh
```

跑出来的结果与 CI 完全一致：`KSU_SUSFS=y`、`LTO_NONE=y`、三道闸门全过。

**这一跑就抓出了两个 bug，见下一节。**

---

## 13. 搬出工作流后立刻抓到的 bug

### ①（已随裁剪删除）裁剪审计会把 `UAPI_HEADER_TEST` 误判为越界

用默认的 `reduce_debug=true` 跑，审计直接失败：

```
::error::debug reduction removed symbols that are not debug features
 UAPI_HEADER_TEST y -> n
```

审计拿「应用**所有**覆盖之前的合并 defconfig」当参考，所以参考配置里
`CONFIG_UAPI_HEADER_TEST` 还是 `=y`，而实际配置是 `=n`——于是这个
**根本不属于裁剪**的符号被算成了裁剪的代价。

**这条路径从来没跑过**：前面所有运行要么早于审计的加入，要么
`reduce_debug=false` 跳过了它。而 `reduce_debug` 的默认值是 `true`，
**下一次默认构建就会炸**。

修法：参考配置也要应用同一批非裁剪覆盖。

> 裁剪与裁剪审计现已整体删除，本条仅作历史记录。
> 它也说明一件事：我加的这套审计**验证的是 `.config` 文本差异，
> 不是运行时等价性**，所以它当时判定"代价只有 20 个符号、无害"，
> 而真机上裁剪是致命的。

### make 失败时只显示 `tail -5`

闸门 2 里 `make ... | tee "$MERGE_OUT" | tail -5`，失败时只 `exit 1`。
而 kconfig 失败的最后五行永远是 make 的退出链：

```
make[2]: *** [../scripts/kconfig/Makefile:94：onyx_gki_defconfig] 错误 1
make[1]: *** [Makefile:252：__sub-make] 错误 2
```

**一个有用的信息都没有。** 我在本地复现时亲眼看到了这个现象。
现在失败时改为 grep 完整日志里的 `error:` / `warning:` / `No rule to make` 等行，
并附上 20 行 tail 兜底。

### 顺带纠正一处文档错误

`onyx_susfs.fragment` 一直写着"`CONFIG_KSU_SUSFS` 来自 susfs4ksu 的
`10_enable_susfs_for_ksu.patch`"。**这是错的，而且我们的工作流从来没应用过那个补丁。**

实际链路是：

```
BakaSU setup.sh → clone Baka-SU/BakaSU → kernel/ 软链到 drivers/kernelsu
  └─ Baka-SU/BakaSU 本身就是带 SUSFS 的 KernelSU fork
     它的 kernel/Kconfig 已经包含 config KSU_SUSFS + 9 个子选项（实测 10 处定义）
susfs4ksu 50_add_susfs → 只提供内核侧那一半
  └─ fs/、drivers/input/、security/selinux/、kernel/kallsyms.c、reboot.c、sys.c
     以及拷贝进来的 include/linux/susfs*.h 与 fs/susfs.c
```

在当前 Baka-SU/BakaSU main 上试打 `10_enable_susfs_for_ksu.patch`：
**一百多个 hunk 失败**——BakaSU 已经吸收/偏离了那个补丁要加的东西。
所以不应用它是对的，但文档归因错了。已改。

---

## 14. 上游回归：extract-cert 在 stock OpenSSL 下编不过

第三次运行前 14 步全过，Build 死在 `certs/extract-cert.c:152`：

```
error: use of undeclared identifier 'key_pass'
error: use of undeclared identifier 'key_pass'
```

**这不是流水线的问题，是 6.6.142 里一个真实的上游 bug。**

`extract-cert` 是宿主工具，`gki_defconfig` 设了
`CONFIG_MODULE_SIG_KEY="certs/signing_key.pem"`，所以一定会编。

### 怎么坏的

上游提交 `64282a745897 "extract-cert: Wrap key_pass with
'#ifdef USE_PKCS11_ENGINE'"` 为了消 clang 的 `-Wunused-but-set-global`
警告，把 `key_pass` 的**声明**和 `main()` 里的**赋值**都包进了
`#ifdef USE_PKCS11_ENGINE`。它的理由是"key_pass 只在 OpenSSL engine API
里用"。

但**用处留在了另一个分支**。`pkcs11:` 分支只被 `OPENSSL_IS_BORINGSSL` 包着：

```c
} else if (!strncmp(cert_src, "pkcs11:", 7)) {
#ifdef OPENSSL_IS_BORINGSSL
        ERR(1, "BoringSSL does not support extracting from PKCS#11");
#else
        ...
        if (key_pass)                 /* ← 声明已被条件编译掉 */
```

而**整个 kbuild 系统里没有任何地方定义 `USE_PKCS11_ENGINE`**
（grep 全部 Makefile 零命中）。所以只要宿主 OpenSSL 不是 BoringSSL，
声明被编掉、用法被编进来，这个文件根本编不出来。

`64282a745897` 在 6.6.142 里有、在 6.6.82 里没有——这就是 6.6.82 那棵树
能编而这棵不能的原因。

### 修法

`.github/actions/extract_cert_pkcs11_engine.patch`，把守卫改成三选一，
这正是上游提交本来的意图：

```c
#if defined(OPENSSL_IS_BORINGSSL)      行为不变
#elif defined(USE_PKCS11_ENGINE)       行为不变
#else                                  明确报错，而不是编译错误
```

新增的 `#else` 有意义：光删掉 engine 分支的话，`"pkcs11:"` 前缀会匹配上
`else if` 然后从 if/else 链里掉出去，**什么都不写**，`signing_key.x509`
变成空文件，要到很后面才炸。在提取阶段就报错能指名原因。

`drain_openssl_errors()` 也一并加了守卫——它只被同一个 engine 分支调用
（145、149 行），分支被编掉后它就成了未使用的 static 函数。当前宿主构建
没给 hostprogs 传 `-Wall`/`-Werror`（`KBUILD_HOSTCFLAGS` 只含
`$(KBUILD_USERHOSTCFLAGS) $(HOST_LFS_CFLAGS) $(HOSTCFLAGS)`，而
`HOSTCFLAGS` 未设置），所以今天只是个警告，但离致命只差一个编译选项。

本流水线用不到新的 `#else`：签名密钥是普通文件路径，`"pkcs11:"` 永远匹配不上。

### 验证

本机 OpenSSL 3.6.5，三种预处理组合全过：

| 组合 | 无标志 | `-Wall` | `-Wall -Wextra -Werror` |
|---|---|---|---|
| stock OpenSSL（我们的 CI） | ✅ | ✅ | ✅ |
| `USE_PKCS11_ENGINE` 已定义 | ✅ | ✅ | — |
| `OPENSSL_IS_BORINGSSL` 已定义 | ✅ | — | — |

未打补丁的文件用 `gcc -o /dev/null certs/extract-cert.c -lcrypto`
可复现同样的错误（exit 1，152 行）。

工作流里加了一步在**应用补丁后立刻编译验证**，不再等 1500 个 object
编到 `certs/` 才发现。该步幂等（grep 到已打补丁就跳过），本地在干净树
和已打补丁的树上各跑一遍都是 exit 0。

### 教训

前两次是我自己写的代码没在本地跑过。第三次是**上游 bug**——这类问题
只能靠"真去编译一次"发现，静态阅读发现不了。

---

## 15. 首次成功构建（logs_101188129967）

第四次运行，19 步全过。**这是本流水线在 6.6.142 上的第一次完整构建。**

| 指标 | 值 |
|---|---|
| 步骤 | 19/19，0 失败 |
| 闸门 | 3/3 通过 |
| 内核 | `6.6.142-4k-g29ca9ddd04f2-dirty` |
| 模块 | 97 |
| 产物 | `Onyx-Kernel-v4-20261005.zip`，19M |
| 编译耗时 | 1014 s（≈17 min） |
| checkout 耗时 | 355 s（当时为 `fetch-depth: 0`，126 万提交；**现已改为浅克隆**，见 §16） |
| ccache | 命中恢复，仅 ~72 MB（首次冷编译） |
| `.BTF` | `BTF_SECTIONS_IN_VMLINUX=ok` |
| modpost | 0 个 undefined，0 错误，0 objtool 警告 |

日志里唯一的警告是 GKI 树常见的 `overriding recipe for target 'dtbs'` 一类，
make 层面的，无害。

---

## 16. 构建耗时优化

一次 CI 运行的实测分解（总 24m19s）：

| 步骤 | 耗时 | 占比 |
|---|---|---|
| Checkout | 5m32s（其中 fetch 5m22s） | 22.7% |
| Fast cleanup + swap | 3m02s | 12.5% |
| **Build** | **14m28s** | **59.5%** |
| 其余 15 步 | 合计 ~1m | — |

Build 内部：并行编译 9m05s（ccache 命中 96.67%）→ ThinLTO 链接 4m00s（串行，
无日志）→ modpost/BTF/kallsyms/Image 58s → 97 个模块链接 25s。

### 已做：浅克隆

`fetch-depth: 0` → `1`。本仓库 126 万提交，完整 fetch 5m22s，占整体 23%，
而流水线里**没有任何地方消费 git 历史**：

- BakaSU `setup.sh` 的 `git checkout` / `git stash` 作用于**它自己 clone 的
  KernelSU 仓库**，不是内核树
- susfs4ksu 在 SUSFS 步骤单独 clone
- 版本串来自 `scripts/setlocalversion`，只需要 `git rev-parse HEAD`，以及
  `git rev-list --count <tag>...HEAD` 做 tag 查找

最后一条是唯一需要留意的地方，它安全**只因为本仓库一个 tag 都没有**：
`try_tag` 每次都失败，脚本直接落到 `printf '%s%.12s' -g "$head"`。
实测浅克隆与完整克隆产出**完全相同**的版本串：

```
浅克隆:   6.6.142-g40822f8fd38d
完整克隆: 6.6.142-g40822f8fd38d
```

> 如果将来给这个仓库打 tag，浅克隆下 `git rev-list` 对浅窗口之外的 tag
> 行为会变，届时要重新验证。

### 已做：清理步骤瘦身

`apt-get remove` + `autoremove` 实测 **2m08s**（dpkg 两次全库扫描 209,818 个
文件），而在这台 runner 上只回收了 `liblldb-20` 和 `liblldb-22` 两个小包。
`ubuntu-26.04` 镜像根盘 145G、可用约 107G，构建总需求约 45G，磁盘根本不紧张。
现在这步用 `df -k` 判断，低于 60G 才执行。

`rm -rf` 那几个目录（dotnet / swift / go / android / powershell / boost）
**保持无条件**——它们构建完全用不到，删掉是纯收益，不该为省几秒而条件化。

swap 从 20 GiB 降到 10 GiB，`dd` 改用 `status=none`（约省 25s）。
LTO 链接段是内存峰值，swap 只是兜底；若真出现 OOM，把 `count` 改回
`20480`，代价 25 秒。**必须用 `dd` 不能用 `fallocate`**——交换文件不允许有空洞，
ext4 上 fallocate 出来的文件 `swapon` 直接报 `Invalid argument`。

### 不做：合并四个小步骤

`Install deps`(9.4s) + `Install pahole`(2.4s) + 两个 patch 步骤合计 12 秒，
合并只省 10 秒。代价是这些步骤本来提供的**失败定位能力**——前三次 CI 失败
分别死在第 6、9、15 步，一眼就能看出是谁的问题。不划算。

### 不做：其它

- **Build 编译 9m05s**：ccache 命中 96.67%，117 个 miss 是真实变更，已近最优
- **ThinLTO 链接 4m00s**：4 vCPU 上只能靠换 runner 规格，是成本权衡
- **跳过模块构建**（`make Image.gz` 跳过 modpost）：可再省 30-60s，但会丢掉
  摘要里 `Modules built: 97` 这个配置健康信号

---

## 17. BBRv3 与 NTSync（2026-10-12 加入）

两个都来自 [WildKernels/kernel_patches](https://github.com/WildKernels/kernel_patches)，
都是 6.6.142 上原本缺失、靠回移补上的特性。

### BBRv3（拥塞控制，默认启用）

`.github/actions/bbrv3_backport.patch` = 上游 `android15-6.6` 那份回移，
**并设为默认**——不回移的话 stock BBRv1 仍然当值，这一整套就是死代码。

应用情况：15 个 hunk，**0 失败**，11 个 offset、2 个 fuzz 1，逐个人工核对过。

**kABI 需要证明而非假设。** 补丁给 `struct tcp_sock` 加了 3 个 bitfield，
而该结构体在冻结列表里。安全的原因是它们被包在 `#ifndef __GENKSYMS__` 内：

```c
#ifndef __GENKSYMS__
        fast_ack_mode:2,
        tlp_orig_data_app_limited:1,
        unused:2;
#else
        unused:5;        ← genksyms 只看这一支
#endif
```

genksyms 分支展开后与打补丁前**逐字节相同** → CRC 不变 → 原厂模块照常加载。
这依赖"genksyms 只消费预处理文本、从不调用编译器"（`scripts/Makefile.build:130`），
和 Droidspaces sysvipc 补丁是同一套机制。

唯一的 UAPI 改动：`rtnetlink.h` 的 `RTAX_FEATURE_MASK` 增加了两个**原本未使用**的位
（`TCP_USEC_TS` = 1<<4、`ECN_LOW` = 1<<5），已有位不变，旧 userspace 掩码仍有效。

**修正了上游一处笔误**：`android15-6.6` 那版有个 `-: ->` 把 `->` 写进了注释。
另外四版（5.10/5.15/6.1/6.12）都没有这个写法，全仓库也只出现这一次，
判定为孤立笔误而非有意标注。修正后该 hunk 变成空操作，`patch` 接受，
其余部分与上游逐字节相同。

验证：`net/ipv4/` 编译零错误，`tcp_bbr3.o` 337K，bbr3 全部函数符号就位。

### NTSync（Windows NT 同步原语模拟）

Wine 和 Windows 游戏需要它。**必须两个补丁、按顺序**：

| 补丁 | 作用 |
|---|---|
| `ntsync_base.patch` | 驱动本体 + UAPI 头（`drivers/misc/ntsync.c`、`include/uapi/linux/ntsync.h`） |
| `ntsync_compat_android15-6.6.patch` | Kconfig 条目 + Makefile 行 |

单独用任何一个都不行：base 只是加源码不编译，compat 引用一个不存在的 object。

**kABI 零风险**：只新增两个文件 + 在 `drivers/misc/{Kconfig,Makefile}` 各追加一行，
**不修改任何现有结构体**，冻结列表里的东西不可能移动。

设 `=y` 而非 Kconfig 默认的 `m`，这样不需要加载模块、不用附带 .ko 就能用。

验证：两个补丁 0 失败（仅 1 个 hunk offset 1），`drivers/misc/` 编译零错误，
`ntsync.o` 177K，5 个 ioctl 接口齐全。

### 都没有实机验证

BBRv3 和 NTSync 都是**编译通过**，没上设备。刷入后建议确认：

```bash
adb shell cat /proc/sys/net/ipv4/tcp_congestion_control       # bbr3
adb shell sysctl net.ipv4.tcp_available_congestion_control   # 含 bbr3
adb shell ls /dev/ntsync*                                    # NTSync
```

链路质量若反而变差，回退只需注释 fragment 里对应的行，补丁可以留着不启用。

---

## 18. 配置审计：我们相对纯基线改了什么

用 `diffconfig` 对比「`gki_defconfig` 单独生成的 `.config`」与「我们完整流水线
生成的 `.config`」。下面是**裁剪删除之后重新实测**的结果，共 **52 行差异**，
全部是 `n -> y` 或选择组切换，没有一项是关掉基线已有的东西。

### 性能调优

```
 AUTOFDO_CLANG n -> y
 HZ 250 -> 300          HZ_250 y -> n            HZ_300 n -> y
 LTO_CLANG_THIN n -> y  LTO_NONE y -> n          +LTO y   +LTO_CLANG y
 ZRAM_DEF_COMP "lzo-rle" -> "lz4"  ZRAM_DEF_COMP_LZ4 n -> y
 ZRAM_DEF_COMP_LZORLE y -> n
```

### 容器兼容（Droidspaces）

```
 DEVTMPFS n -> y        PID_NS n -> y            POSIX_MQUEUE n -> y
 SYSVIPC n -> y         USER_NS n -> y           TMPFS_POSIX_ACL n -> y
 TMPFS_XATTR n -> y     NETFILTER_XT_MATCH_ADDRTYPE n -> y
 +IPC_NS y  +POSIX_MQUEUE_SYSCTL y  +SYSVIPC_COMPAT y  +SYSVIPC_SYSCTL y
 +DEVTMPFS_MOUNT n  +DEVTMPFS_SAFE n
```

后四个 IPC 符号是 `default y` 的内部符号（`init/Kconfig:403/409/429`），
被 `SYSVIPC` / `POSIX_MQUEUE` 带出来。`TMPFS_XATTR` 最初是被
`TMPFS_POSIX_ACL` 的 `select`（`fs/Kconfig:191`）顺带带出的，现在已经是
`onyx_gki.fragment` 里显式请求的一项（Droidspaces 的 NixOS 支持）。

### NAT66 / UFW / fail2ban（Droidspaces，上游 GKI 块）

```
 IP6_NF_NAT n -> y       +IP6_NF_TARGET_MASQUERADE y
 NETFILTER_XT_TARGET_LOG n -> y  NETFILTER_XT_MATCH_RECENT n -> y
 IP_SET n -> y  +IP_SET_HASH_IP y  +IP_SET_HASH_NET y  +NETFILTER_XT_SET y
 +NF_LOG_SYSLOG y  +NF_LOG_IPV6 y  +IP6_NF_TARGET_NPT y
 +IP_SET_MAX 256  +NET_EMATCH_IPSET n
```

带 `+` 的都是被 `select` / `default` 带出来的内部符号。`IP_SET` 是
menuconfig，它下面 15 种 set 类型全部出现在 diff 里，只有我们请求的
`hash:ip` 和 `hash:net` 是 `y`，其余是 `n`——这是 kconfig 的正常展开。
`IP6_NF_TARGET_NPT` 是 `IP6_NF_NAT` 块内的默认子项（SNPT / DNPT 目标）。

这九个符号都不在 `android/abi_gki_aarch64.stg` 里，所以不触及冻结 kABI。

### 曾经过的调试裁剪（已删除）

裁剪还在时，这里还有第三组差异——20 个符号消失，包括 `CLEANCACHE`、
`DEBUG_MEMORY_INIT`、整个 `UBSAN` 家族。当时我写的是"除 UBSAN 及其依赖
外没有任何附带损失"，**这个判断是错的**，其中 `CLEANCACHE` 会改变内存
回收决策，真机直接变砖。原始 diff 不再列出，但把它记在这里作为反例：
`.config` 文本对比证明不了运行时等价。详见第 11 节。

### Xiaomi vendor 的 4 个 `=y`

```
 INPUT_FINGERPRINT n -> y   JOYSTICK_XPAD_FF n -> y   JOYSTICK_XPAD_LEDS n -> y
 +FOD_FINGERPRINT y
 +FINGERPRINT_MI_FP n  +FP_HAVE_MULTI_SCREEN n  +SIDE_FINGERPRINT n
```

**4 个里只有 2 个真的有用**，已从源码层面证实：

- `JOYSTICK_XPAD_FF` / `JOYSTICK_XPAD_LEDS` —— **有效**。`gki_defconfig:409`
  已有 `CONFIG_JOYSTICK_XPAD=y`，所以这两个开关有真实驱动可用。
- `INPUT_FINGERPRINT` / `FOD_FINGERPRINT` —— **空壳**。
  `drivers/input/fingerprint/mi_fp/Kconfig` 里 `FINGERPRINT_MI_FP` 是 tristate，
  厂商配置写的是 `=m`，被我们的 `=y` 过滤器丢掉，于是它 `n`，
  `mi_fp.ko` 根本不参与编译。而 `FOD_FINGERPRINT` 这个 bool **没有任何
  `depends on`**，kconfig 无条件接受 `=y`；全树只有
  `drivers/input/fingerprint/mi_fp/fp_driver.{c,h}` 引用它——那是不编译的文件。
  结论：`CONFIG_FOD_FINGERPRINT=y` 是一个**死配置**。

要修就得把 `FINGERPRINT_MI_FP` 加进 vendor 过滤器的白名单，但加之前必须确认
`mi_fp.ko` 能独立链接（旧树验过 exit 0，本树未验）。

### 一个必须记下来的结论：不会变砖

```
CONFIG_MODULE_SIG=y            CONFIG_MODULE_SIG_SHA256=y
CONFIG_MODULE_SIG_KEY="certs/signing_key.pem"
# CONFIG_MODULE_SIG_FORCE is not set      ← 关键
CONFIG_MODULE_SIG_PROTECT=y
```

`MODULE_SIG_FORCE` 没有 `default y`，所以是 `n`。这意味着手机上原厂
`vendor_dlkm` 里那些**用小米自己密钥签名**的模块**仍然能加载**，只是会 taint
内核。如果它是 `y`，那些模块会被直接拒绝 → 变砖。

现在 Key configs 转储会显式打印这一项和 `MODULE_SIG_KEY`，免得哪天有人
"顺手"打开强制签名。

`CONFIG_MODULE_ALLOW_BTF_MISMATCH=y` 也确认在位（BTF 必需项）。

---

### 顺带修掉的两个小问题

- `CLANG_MAJOR` 之前只 `echo` 到 stdout，没进 `$GITHUB_ENV`，导致摘要表格渲染成
  `LLVM )`。现在补上 `>> $GITHUB_ENV`。
- Key configs 转储此前把「显式 `n`」和「配置里根本没这个符号」都显示成
  `NOT SET`，无法区分。现在 `# CONFIG_X is not set` 渲染成 `n`。

---
