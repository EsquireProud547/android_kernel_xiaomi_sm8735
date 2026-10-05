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
         arch/arm64/configs/onyx_debug_reduction.fragment \
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

---

## 11. CI 实跑记录

| 运行 | 结果 | 停在哪 |
|---|---|---|
| `logs_101154931030` | ❌ | 第 6 步：`.github/actions/libbpf_strchr_const.patch: No such file or directory` |
| `logs_101161199225` | ❌ | 第 9 步：`clang: error: unknown argument: '-print-version-number'` |
| `logs_101178482014` | ❌ | 第 15 步 Build：`certs/extract-cert.c:152: error: use of undeclared identifier 'key_pass'` |
| `logs_101188129967` | ✅ | 19/19 步全过，产物 `Onyx-Kernel-v4-20261005.zip`（19M，97 个模块） |

前三次分别对应本文 §1.5、§11（第二次）、§12（第三次）。第四次见 §13、§14。

**第一次**：`.gitignore` 有两条规则吞掉 CI 目录（`.*` 和 `*.patch`），我只处理了
一条。补丁文件从未进仓库，但 `git status` 是干净的，工作流照常入库。详见 §1.5。

**第二次**：迁移时我加的一行版本检查用了 `-print-version-number`。这个参数
**任何 clang 都不支持**（它是 GCC 的写法），用本机 `/usr/bin/clang 23.1.1`
可以复现同样的错误。clang 本身没问题，CI 上跑出来是
`Android (... based on r596125) clang version 22.0.2`。现在改成从
`--version` 输出里 `sed` 解析，并保留「低于 17 就早失败」的原意
（`arch/Kconfig:804` 的 `AUTOFDO_CLANG depends on CLANG_VERSION >= 170000`）。

**第三次**：**上游回归**，见 §12。

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

ReSukiSU `applied (main)`、SUSFS `applied (CONFIG_KSU_SUSFS=y)`、
Droidspaces `applied`、AutoFDO `enabled (in-tree profile, 4.0M)`。

本地用 clang 23 预测的三项全部命中：BTF 保住、AutoFDO 保住、
模块签名是 SHA-256 而非 512。

---

## 12. 上游回归：extract-cert 在 stock OpenSSL 下编不过

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

## 13. 首次成功构建（logs_101188129967）

第四次运行，19 步全过。**这是本流水线在 6.6.142 上的第一次完整构建。**

| 指标 | 值 |
|---|---|
| 步骤 | 19/19，0 失败 |
| 闸门 | 3/3 通过 |
| **裁剪审计** | 通过（20 个符号，全在白名单内） |
| 内核 | `6.6.142-4k-g29ca9ddd04f2-dirty` |
| 模块 | 97 |
| 产物 | `Onyx-Kernel-v4-20261005.zip`，19M |
| 编译耗时 | 1014 s（≈17 min） |
| checkout 耗时 | 355 s（`fetch-depth: 0`，126 万提交） |
| ccache | 命中恢复，仅 ~72 MB（首次冷编译） |
| `.BTF` | `BTF_SECTIONS_IN_VMLINUX=ok` |
| modpost | 0 个 undefined，0 错误，0 objtool 警告 |

日志里唯一的警告是 GKI 树常见的 `overriding recipe for target 'dtbs'` 一类，
make 层面的，无害。

---

## 14. 配置审计：我们相对纯基线改了什么

这是最值得看的一节。用 `diffconfig` 对比「`gki_defconfig` 单独生成的 .config」
与「我们完整流水线生成的 .config」，**全部 52 行差异**：

### 调试裁剪（14 个请求，20 个符号消失）

```
 BT_DEBUGFS y -> n        CLEANCACHE y -> n       CMA_DEBUGFS y -> n
 DEBUG_MEMORY_INIT y -> n DEBUG_MISC y -> n       PRINTK_CALLER y -> n
 PRINTK_TIME y -> n      RCU_TRACE y -> n        UBSAN y -> n
-CC_HAS_UBSAN_ARRAY_BOUNDS y                      -TEST_UBSAN n
-UBSAN_ARRAY_BOUNDS y   -UBSAN_BOOL n   -UBSAN_BOUNDS y   -UBSAN_ENUM n
-UBSAN_LOCAL_BOUNDS y   -UBSAN_SANITIZE_ALL y     -UBSAN_SHIFT n
-UBSAN_TRAP y           -UBSAN_UNREACHABLE n
```

除 UBSAN 及其依赖外**没有任何附带损失**。

### 性能调优

```
 AUTOFDO_CLANG n -> y
 HZ 250 -> 300          HZ_250 y -> n            HZ_300 n -> y
 LTO_CLANG_THIN n -> y  LTO_NONE y -> n          +LTO y   +LTO_CLANG y
 ZRAM_DEF_COMP "lzo-rle" -> "lz4"  ZRAM_DEF_COMP_LZ4 n -> y
 ZRAM_DEF_COMP_LZORLE y -> n
```

### 容器兼容

```
 DEVTMPFS n -> y        PID_NS n -> y            POSIX_MQUEUE n -> y
 SYSVIPC n -> y         USER_NS n -> y           TMPFS_POSIX_ACL n -> y
 TMPFS_XATTR n -> y     NETFILTER_XT_MATCH_ADDRTYPE n -> y
 +IPC_NS y  +POSIX_MQUEUE_SYSCTL y  +SYSVIPC_COMPAT y  +SYSVIPC_SYSCTL y
```

后四个新出现的符号都是 `default y` / `def_bool y` 的内部符号
（`init/Kconfig:403/409/429`），被 `SYSVIPC` / `POSIX_MQUEUE` 带出来。
`TMPFS_XATTR` 是 `TMPFS_POSIX_ACL` 的 `select`（`fs/Kconfig:191`）——我们没请求它，
但 POSIX ACL 本来就需要 xattr 支持。

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

## 15. 新增：裁剪审计（把注释变成强制检查）

闸门 1–3 只检查**我们要求的东西有没有生效**，没有一个能看见「没要求却悄悄丢掉」
的符号——`olddefconfig` 会安静地丢弃它，然后内核照样编译成功。

这正是 `CONFIG_PROFILING` 的失效模式：加进裁剪清单会让本树掉 10 个符号
（`ARM_PMU` `ARM_PMUV3` `HAVE_HW_BREAKPOINT` `HW_PERF_EVENTS` `BPF_EVENTS`
`BPF_LSM` `UPROBES` `UPROBE_EVENTS` `GUEST_PERF_EVENTS` `UID_SYS_STATS`），
即所有硬件性能计数器、所有 uprobe 支持、**BPF LSM**——**make 仍然 exit 0**。
一边发 BTF 给 eBPF 一边把 `BPF_LSM` 关掉，自相矛盾，而流水线里没有任何东西会报警。

所以现在多了一步审计：把配置生成两遍（一遍带裁剪、一遍不带），
`diffconfig` 之后要求每一处差异都在白名单内：

- 任何 `UBSAN*`
- 8 个调试开关：`BT_DEBUGFS` `CLEANCACHE` `CMA_DEBUGFS` `DEBUG_MEMORY_INIT`
  `DEBUG_MISC` `PRINTK_CALLER` `PRINTK_TIME` `RCU_TRACE`
- `CC_HAS_UBSAN_ARRAY_BOUNDS`、`TEST_UBSAN`

不在名单里的任何一行 → **构建失败**并打印越界符号。

本地双向验证过：

| 场景 | 结果 |
|---|---|
| 真实裁剪清单（20 个符号） | ✅ 通过 |
| 模拟加入 `CONFIG_PROFILING`（多出 `ARM_PMU`/`BPF_LSM`/`UPROBES`） | ❌ 失败并列出越界符号 |

成本是一次额外的 `olddefconfig`（几秒）。这一步让 fragment 里那段
「DO NOT ADD CONFIG_PROFILING」从注释变成了可执行约束。

### 顺带修掉的两个小问题

- `CLANG_MAJOR` 之前只 `echo` 到 stdout，没进 `$GITHUB_ENV`，导致摘要表格渲染成
  `LLVM )`。现在补上 `>> $GITHUB_ENV`。
- Key configs 转储此前把「显式 `n`」和「配置里根本没这个符号」都显示成
  `NOT SET`，无法区分。现在 `# CONFIG_X is not set` 渲染成 `n`。

---