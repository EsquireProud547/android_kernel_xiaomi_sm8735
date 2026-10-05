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

### 1.2 SUSFS：分支名对不上，但补丁能用

susfs4ksu **没有 android17-6.6 分支**，它唯一的 6.6 分支是 `gki-android15-6.6`。
实测该分支的补丁套到 6.6.142 上：

```
19 hunks succeeded, 0 FAILED, exit 0
仅 fs/proc/base.c 的 hunk #4 落在 fuzz 1（offset 148）
```

因为流水线现在**依赖**这个补丁还能套上，所以做了两件事：

- `SUSFS_COMMIT` 把 `a0f9c59e2243f8a5db955f4ad1686d5e0ad26e1a` 钉死，
  免得「能不能套上」随上游移动；
- 套用结果写进 `SUSFS_STATUS`，失败时闸门 3 会因为 `CONFIG_KSU_SUSFS` 掉失而报错。
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

### 1.5 `.gitignore` 会吞掉 `.github/`

本树 `.gitignore:13` 是裸 `.*`，和 6.6.82 那棵树一模一样。已追加反向规则：

```
!.github/
!/.github/
```

验证：`git check-ignore -v .github/workflows/build-onyx.yml` 现在退出码为 1（未被忽略）。
不加这两行，工作流永远进不了仓库。

### 1.6 新树独有：`GKI_DYNAMIC_TASK_STRUCT_SIZE`

本树多了一套 kABI 机制，`gki_defconfig:190` 有
`CONFIG_GKI_TASK_STRUCT_VENDOR_SIZE_MAX=1024`。它和 Droidspaces 补丁**正交**，不会冲突：

- 动态 vendor 区在 `sizeof(struct task_struct)` **之后**
  （`include/linux/sched/task.h`，`android_task_vendor_data()` 返回 `p + 1`），
  所以不可能移动结构体内部的任何字段；
- `ANDROID_KABI_RESERVE` 操作的仍然是 `task_struct` 内部的槽位。

实测它确实开着（`GKI_DYNAMIC_TASK_STRUCT_SIZE=y`，由 base 提供），
且 `gki_defconfig` 基线在本地 `olddefconfig` 往返后**零漂移**（`diffconfig` 的 `^-` 行为 0）。

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

闸门 3 只过滤 `^-[A-Za-z0-9_]+ n$` 一种形态：调试裁剪关掉 `CONFIG_UBSAN`
后，其子选项在 `.config` 里不再显示，`diffconfig` 会把**本来就没设过**的符号
报成 `-UBSAN_BOOL n`。请求了却被丢弃的 `y` / `m` 一个都不放过。

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
| `CONFIG_PROFILING` / `CONFIG_BPF_LSM` | y（没被裁剪误伤） |

---

## 3. 调试裁剪的实测代价

`onyx_debug_reduction.fragment` 有 14 个 `-d` 符号。代价是**在 6.6.142 上实测的**，
方法：合并 defconfig 后分别用「不裁剪 / 只裁剪 / 裁剪 + `-d CONFIG_PROFILING`」
生成三份 `.config`，再互相 `diffconfig`。三次 `make` **全部 exit 0**——
这正是问题所在，没有任何编译期信号。

**本裁剪清单的代价：恰好 6 个符号**

```
CC_HAS_UBSAN_ARRAY_BOUNDS
UBSAN_ARRAY_BOUNDS  UBSAN_BOUNDS  UBSAN_LOCAL_BOUNDS
UBSAN_SANITIZE_ALL  UBSAN_TRAP
```

**如果再加上 `CONFIG_PROFILING`：再损失 10 个**

```
ARM_PMU  ARM_PMUV3  HAVE_HW_BREAKPOINT  HW_PERF_EVENTS
BPF_EVENTS  BPF_LSM  UPROBES  UPROBE_EVENTS
GUEST_PERF_EVENTS  UID_SYS_STATS
```

即：所有硬件性能计数器、全部 uprobe 支持、**BPF LSM** 全部消失，而内核照样编译成功。
`CONFIG_BPF_LSM` 正是 eBPF LSM 程序挂载的地方——发 BTF 给 eBPF 的意义直接被抵消。

> 6.6.82 那棵树测同样的实验是 27 个符号。数字随内核变，结论没变。
> 改这个清单时务必重新测。

---

## 4. BTF

| 前提 | 满足方式 |
|---|---|
| 不被 `DEBUG_INFO_REDUCED` 阻断 | 裁剪清单顶部明令禁止加这两项 |
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

## 5. Xiaomi vendor 片段

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

## 6. AnyKernel3

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

## 7. 已知未解决

| 项 | 说明 |
|---|---|
| **`Module.symvers` CRC 未比对** | 刷进去能开机 **≠** 原厂 `vendor_dlkm` 模块都能加载。需要从设备取基线 |
| **AK3 未实机验证** | CI 只能证明包能生成。这套流程**没有实机跑过**——迁移刚完成，第一次 CI 才是第一次构建 |
| 内核版本串 | `CONFIG_LOCALVERSION_AUTO=y` + 工作流改源码 → 版本串带 `-dirty`。仅观感 |
| `fetch-depth: 0` | checkout 慢。ReSukiSU `setup.sh` 的前置要求，未测浅克隆 |
| vendor `=m` 过滤 | 见 §5 |

## 8. 未移植

`BBRv3`、`NTSYNC`、`Baseband-guard` —— 6.6.142 里没有这些特性。

---

## 9. 维护提示

改 fragment 前先读 `arch/arm64/configs/onyx_gki.fragment` 顶部的两条规则——
它们不是建议，是闸门 1 和闸门 3 的直接后果：

1. 绝不要设基线里已经是 `=y` 或 `=m` 的符号 → merge_config 报 override → 构建失败。
2. 绝不要设依赖无法满足的符号 → `olddefconfig` 静默丢弃 → 闸门 3 失败。

**BTF 两条铁律**（写进裁剪清单顶部了）：

- `CONFIG_DEBUG_INFO_BTF` 必须保持开。
- `CONFIG_DEBUG_INFO_REDUCED` 必须保持关。

**改 `tools/` 前先读** `anykernel/AK3-NOTES.md`。

---

## 10. 与 6.6.82 那棵树的关系

| | `kernel_xiaomi_sm8735` | 本树 |
|---|---|---|
| 分支 / 版本 | `oss` @ 6.6.82 | `seventeen` @ **6.6.142** |
| 模块签名 | SHA-512（Kconfig 默认） | **SHA-256**（base 显式设置） |
| AutoFDO | 上游下载 android15-6.6 | **树内档案**（采集自 6.6.129） |
| kABI 机制 | `ANDROID_KABI_RESERVE` | 同上，**外加** `GKI_DYNAMIC_TASK_STRUCT_SIZE` |
| dtsi | 160（无 onyx） | 160（无 onyx） |
| 配置合成 | 官方 Kleaf + 三闸门 | **相同，未改动** |

6.6.82 那棵树仍在维护，两套并行。
