#!/bin/bash
#
# configure-kernel.sh -- config synthesis and the three Kleaf gates.
#
# This used to live inline in the "Configure kernel" step of
# .github/workflows/build-onyx.yml. It was moved out because GitHub
# treats an entire `run:` block as a single expression to expand and
# caps it at 21000 characters; the inline version had reached 22092 and
# the workflow was rejected with "Exceeded max expression length 21000".
# The previous inline version was already at 20803, i.e. 197 characters
# under the cap, so any further comment would have broken it again.
#
# Having it here also means it can be run directly:
#
#   ENABLE_SUSFS=true ENABLE_VENDOR_MODULES=true \
#   ENABLE_AUTOFDO=false ENABLE_THINLTO=false ENABLE_BTF=true \
#   GITHUB_ENV=/tmp/gh_env ./.github/actions/configure-kernel.sh
#
# which is how it is tested.
#
# Inputs (all supplied as environment variables by the workflow step):
#   ENABLE_SUSFS, ENABLE_VENDOR_MODULES, ENABLE_AUTOFDO, ENABLE_THINLTO,
#   ENABLE_BTF            booleans, as "true"/"false"
# From the workflow-level env: CLANG_VERSION, VENDOR_FRAGMENT,
# KERNEL_CODENAME, SUSFS_BRANCH. From an earlier step: BTF_UNAVAILABLE.
#
# Outputs are appended to $GITHUB_ENV and echoed as a status line.
#
# `set -e` matters and is not decorative: the inline version ran under
# GitHub's default `bash -e`, and dropping it would let a failed
# olddefconfig sail through. There is no `set -u` because BTF_UNAVAILABLE
# is legitimately unset on the common path.
#
# DO NOT add an option that turns a symbol off. This script used to carry a
# debug-reduction input that did exactly that, and it bricked the device:
# the kernel hung on the logo until the reduction was removed. The cost had
# been measured as "20 symbols, all debug-only" and all three gates stayed
# green, because diffing .config files shows what disappeared but not
# whether the kernel still behaves the same. CLEANCACHE is the Qualcomm
# tmem victim cache consulted during page reclaim, so it changes a
# runtime decision, not just diagnostics. Fragments are additive for a
# reason that is now backed by a real boot.
#
set -e

export ARCH=arm64 SUBARCH=arm64

# ==================================================================
# Config synthesis, mirroring build.config.msm.perf +
# build.config.msm.common from the stock Kleaf mixed-build:
#
#   gki_defconfig                    stock GKI base
#     + onyx_gki.fragment            Capybara tuning
#     + vendor/onyx_perf.config      device bits (=y only, see below)
#     + onyx_susfs.fragment          only when enable_susfs
#   --merge_config.sh -m -r -y-->  merged defconfig
#   --make-->                       .config
#
# followed by the same three gates the vendor build uses, so a
# fragment that does not take effect is a build failure rather than
# a silently missing feature.
# ==================================================================

BASE_DEFCONFIG=arch/arm64/configs/gki_defconfig
TUNING_FRAGMENT=arch/arm64/configs/onyx_gki.fragment
SUSFS_FRAGMENT=arch/arm64/configs/onyx_susfs.fragment
MERGED_DEFCONFIG=onyx_gki_defconfig
MERGED_PATH="out/arch/arm64/configs/$MERGED_DEFCONFIG"

# ---- assemble the fragment list ----------------------------------
FRAGMENTS="$BASE_DEFCONFIG $TUNING_FRAGMENT"
echo "Fragments:"
for f in $FRAGMENTS; do echo "  - $f"; done

if [ "$ENABLE_SUSFS" = "true" ]; then
  FRAGMENTS="$FRAGMENTS $SUSFS_FRAGMENT"
  echo "           $SUSFS_FRAGMENT (enable_susfs)"
fi

# ---- Xiaomi OEM bits, built-in entries only -----------------------
# The 33 "=m" entries in vendor/onyx_perf.config are OEM modules that
# link against symbols exported by the vendor (msm-kernel) image,
# which does not exist in a single-tree GKI build. The driver sources
# for most of them ARE in this tree (drivers/power/supply/mca,
# drivers/input/misc/si_haptic, ...) -- they are simply built as part
# of the vendor image, not vmlinux. Merging them anyway makes modpost
# fail with:
#   ERROR: modpost: "qcom_smem_alloc" [...mca_qcom_smem.ko] undefined!
#   ERROR: modpost: "pwrkey_irq_notifier_list" [...mtdoops.ko] undefined!
# (qcom_smem_alloc lives in drivers/soc/qcom/qcom_smem.c, a vendor
# module; pwrkey_irq_notifier_list needs CONFIG_INPUT_PM8941_PKEY.)
#
# They are never packaged anyway -- the device loads the stock ones
# from vendor_dlkm -- so only the "=y" entries are merged. The filter
# is derived from the fragment so it stays correct if Xiaomi adds
# entries.
#
# Known limitation: the filter is coarse. Of the four "=y" entries,
# JOYSTICK_XPAD_FF and JOYSTICK_XPAD_LEDS are real (JOYSTICK_XPAD is
# a stock in-tree driver, built in), but INPUT_FINGERPRINT and
# FOD_FINGERPRINT are inert shells: the driver that uses them is
# CONFIG_FINGERPRINT_MI_FP=m, which this filter drops. That driver
# does link on its own (verified on the 6.6.82 tree, exit 0), so it
# could be allow-listed here -- but each allow-listed module must be
# checked to link, since one that does not fails the whole build at
# modpost.
VENDOR_BUILTIN=""
if [ "$ENABLE_VENDOR_MODULES" = "true" ]; then
  VENDOR_BUILTIN="vendor_builtin.fragment"
  echo "  filtering $VENDOR_FRAGMENT: keeping =y, dropping $(grep -cE '^CONFIG_[A-Za-z0-9_]+=m$' "$VENDOR_FRAGMENT") OEM =m modules"
  grep -E '^CONFIG_[A-Za-z0-9_]+=y$' "$VENDOR_FRAGMENT" > "$VENDOR_BUILTIN" || true
  sed 's/^/    /' "$VENDOR_BUILTIN"
  FRAGMENTS="$FRAGMENTS $VENDOR_BUILTIN"
fi

# ---- BTF ---------------------------------------------------------
# The stock GKI base ships CONFIG_DEBUG_INFO_BTF=y, so nothing has to
# add it. Do not be tempted to set CONFIG_DEBUG_INFO_REDUCED=y: that
# blocks BTF outright (lib/Kconfig.debug:376: DEBUG_INFO_BTF depends on
# !DEBUG_INFO_SPLIT && !DEBUG_INFO_REDUCED) and olddefconfig drops BTF
# with no warning at all.
#
# Turning BTF *off* is a deliberate override, not a fragment: the base
# has it as =y, so a fragment saying =n would trip gate 1. It is
# therefore applied below with the debug reduction, before make.
BTF_OFF=0
if [ "$ENABLE_BTF" != "true" ] || [ "${BTF_UNAVAILABLE:-}" = "1" ]; then
  echo "  BTF disabled (input off, or pahole older than v1.21)"
  BTF_OFF=1
else
  echo "  BTF requested (stock GKI base provides CONFIG_DEBUG_INFO_BTF)"
fi

# ---- AutoFDO (probed BEFORE the merge so it becomes a fragment) --
# This tree ships its own profile at android/gki/aarch64/afdo/
# kernel.afdo, collected on 6.6.129 (13 patchlevels from this tree)
# on a Pixel 10. Using it is strictly better than the previous
# pipeline's download: android.googlesource.com/kernel/common only
# still publishes the android15-6.6 GKI profile, and 6.6.82-era
# samples are a much larger version gap.
#
# Non-fatal, and made a fragment rather than a post-merge
# scripts/config edit so that gate 3 stays honest: nothing may change
# the config after the merge.
AUTOFDO_FRAGMENT=""
IN_TREE_PROFILE=android/gki/aarch64/afdo/kernel.afdo
if [ "$ENABLE_AUTOFDO" = "true" ]; then
  if [ -s "$IN_TREE_PROFILE" ]; then
    AUTOFDO_FRAGMENT=onyx_autofdo.fragment
    echo "CONFIG_AUTOFDO_CLANG=y" > "$AUTOFDO_FRAGMENT"
    FRAGMENTS="$FRAGMENTS $AUTOFDO_FRAGMENT"
    # scripts/Makefile.autofdo keys off CLANG_AUTOFDO_PROFILE exactly.
    # Note arch/Kconfig:804 -- AUTOFDO_CLANG depends on
    # CC_IS_CLANG && CLANG_VERSION >= 170000, so gate 3 is what proves
    # the toolchain was new enough; a too-old clang silently loses
    # the symbol here.
    echo "CLANG_AUTOFDO_PROFILE=$PWD/$IN_TREE_PROFILE" >> $GITHUB_ENV
    AUTOFDO_STATUS="enabled (in-tree profile, $(du -h "$IN_TREE_PROFILE" | cut -f1))"
    echo "AUTOFDO_STATUS=$AUTOFDO_STATUS" >> $GITHUB_ENV
    echo "  - $AUTOFDO_FRAGMENT (in-tree profile)"
  else
    AUTOFDO_STATUS="skipped (profile unavailable)"
    echo "AUTOFDO_STATUS=$AUTOFDO_STATUS" >> $GITHUB_ENV
    echo "::warning::$IN_TREE_PROFILE missing or empty; AutoFDO disabled"
  fi
else
  AUTOFDO_STATUS="disabled by input"
  echo "AUTOFDO_STATUS=$AUTOFDO_STATUS" >> $GITHUB_ENV
  echo "  AutoFDO disabled by input"
fi

# ---- LTO (also a generated fragment, so it can be switched off) --
# ThinLTO, not FullLTO: CONFIG_CFI_CLANG=y (KCFI, gki_defconfig:98)
# and FullLTO's type-id reassignment conflict. See gki-clo commit
# 98763e396491 "Revert to ThinLTO: FullLTO conflicts with KCFI type
# IDs".
#
# This is the second of the two codegen switches, and both exist for
# the same reason. The stock device kernel -- the one whose config was
# extracted from the running system's own boot image, built from this
# same tree with this same clang r596125 -- uses LTO_NONE and has
# AUTOFDO_CLANG=n. Any of our tuning that the vendor does not use is
# a suspect when a build boots to the splash screen and stops, and
# these are the two.
#
# Generated as a fragment rather than left in onyx_gki.fragment so
# that turning it off does not cost HZ_300, SYSVIPC and the rest.
LTO_FRAGMENT=""
if [ "$ENABLE_THINLTO" = "true" ]; then
  LTO_FRAGMENT=onyx_lto.fragment
  echo "CONFIG_LTO_CLANG_THIN=y" > "$LTO_FRAGMENT"
  FRAGMENTS="$FRAGMENTS $LTO_FRAGMENT"
  LTO_STATUS="ThinLTO"
  echo "LTO_STATUS=$LTO_STATUS" >> $GITHUB_ENV
  echo "  - $LTO_FRAGMENT (ThinLTO)"
else
  # No fragment at all: LTO_NONE is the Kconfig default, which is
  # what the stock kernel uses. Asserted after the merge below.
  LTO_STATUS="none (matches stock device kernel)"
  echo "LTO_STATUS=$LTO_STATUS" >> $GITHUB_ENV
  echo "  LTO disabled by input (LTO_NONE, as on the stock kernel)"
fi

# One line so a log tells you which codegen this run used, without
# having to go hunting through the gate output. $LTO_STATUS and
# $AUTOFDO_STATUS are shell variables assigned just above; reading them
# through the workflow's env: context instead would give the value from
# the *previous* step, which on a fresh run is empty.
echo "CODEGEN: clang $CLANG_VERSION / LTO=$LTO_STATUS / AutoFDO=$AUTOFDO_STATUS"

# ---- GATE 1: no fragment may override an existing =y/m value -----
# (build.config.msm.common:97)
#
# The vendor build's fragments are strictly additive: anything that
# flips a value the base already sets is an accident (two fragments
# disagreeing) and must fail loudly.
mkdir -p out/arch/arm64/configs
MERGE_OUT=$(mktemp)
KCONFIG_CONFIG="$PWD/$MERGED_PATH" \
  ./scripts/kconfig/merge_config.sh -m -r -y $FRAGMENTS | tee "$MERGE_OUT"

if grep -qE -e "Previous value: [^=]+=[ym]" "$MERGE_OUT"; then
  echo "========================================================"
  echo "::error::Detected overridden config!"
  grep -C1 -E -e "Previous value: [^=]+=[ym]" "$MERGE_OUT"
  echo "A fragment tried to redefine a value the base already sets."
  echo "Fragments are additive-only -- see the rules in $TUNING_FRAGMENT."
  exit 1
fi
echo "  [gate 1/3] no overridden values"

# ---- deliberate overrides applied to the merged defconfig --------
# Fragments are additive-only, so anything that flips a value the
# base already sets has to happen here -- still BEFORE make, so that
# gate 3's diffconfig stays a real assertion.
#
# There is exactly one, and it is a drop rather than a setting: see
# the UAPI_HEADER_TEST comment below.
OVERRIDE_ARGS=""

OVERRIDE_ARGS=""

if [ "$BTF_OFF" = "1" ]; then
  # DEBUG_INFO_BTF_MODULES must go too, and so must the symbol that
  # merely depends on BTF modules -- otherwise gate 3 sees it as
  # "requested enabled but dropped" and fails the build.
  OVERRIDE_ARGS="$OVERRIDE_ARGS -d CONFIG_DEBUG_INFO_BTF \
                    -d CONFIG_DEBUG_INFO_BTF_MODULES \
                    -d CONFIG_MODULE_ALLOW_BTF_MISMATCH"
fi

# gki_defconfig line 1 is CONFIG_UAPI_HEADER_TEST=y, but that symbol
# is `depends on HEADERS_INSTALL && CC_CAN_LINK` and CC_CAN_LINK is a
# compile-probe result that no defconfig line can satisfy. It is a
# developer-only option -- "If you are a developer or tester and want
# to ensure the exported headers are self-contained" -- that
# recompiles every UAPI header standalone. There is nothing to gain
# from it in a shipping kernel and it costs build time, so drop the
# request rather than weakening the gate.
OVERRIDE_ARGS="$OVERRIDE_ARGS -d CONFIG_UAPI_HEADER_TEST"

if [ -n "$OVERRIDE_ARGS" ]; then
  # shellcheck disable=SC2086
  scripts/config --file "$MERGED_PATH" $OVERRIDE_ARGS
fi

# ---- build the merged defconfig, GATE 2: warnings are errors -----
# (build.config.msm.common:105-112)
#
# PIPESTATUS is not optional here. `make | tee | tail` takes its exit
# status from tail, which is always 0, so a failed defconfig would
# sail through `set -e` and leave out/.config missing. Downstream that
# used to be caught only because diffconfig prints a usage example
# containing a line starting with "-", which the gate 3 grep happened
# to match -- i.e. the build failed for an unrelated reason and
# printed a confusing message.
set +e
make O=out CC=clang LLVM=1 LLVM_IAS=1 "$MERGED_DEFCONFIG" 2>&1 | tee "$MERGE_OUT" | tail -5
MAKE_RC=${PIPESTATUS[0]}
set -e

if [ "$MAKE_RC" -ne 0 ]; then
  echo "========================================================"
  echo "::error::make $MERGED_DEFCONFIG failed (exit $MAKE_RC)"
  # `| tail -5` above hides the actual error, and the last five lines of a
  # kconfig failure are just the make exit chain -- "make[2]: *** ... Error 2"
  # -- which names nothing. Found this by breaking the tree on purpose and
  # being shown five lines that said only "Error 2". Grep the full log for
  # the lines that do name something, then fall back to the tail.
  echo "--- errors ---"
  grep -nE "error:|warning:|No rule to make|Stop\.|scripts/kconfig|\.c:[0-9]+" "$MERGE_OUT" | head -20 || true
  echo "--- tail of make output ---"
  tail -20 "$MERGE_OUT"
  exit 1
fi
if grep -q -e "warning:" "$MERGE_OUT"; then
  echo "========================================================"
  echo "::error::Treating config warnings as errors"
  grep -e "warning:" "$MERGE_OUT"
  exit 1
fi
# Belt and braces: a successful make must have produced a config.
if [ ! -s out/.config ]; then
  echo "========================================================"
  echo "::error::make reported success but out/.config is missing or empty"
  exit 1
fi
echo "  [gate 2/3] no kconfig warnings, out/.config produced"

# No scripts/config edits from here on. Everything the kernel is
# asked to do came from a fragment, which is what makes gate 3 below
# a meaningful assertion rather than a formality.

# ---- GATE 3: every fragment line must have survived --------------
# (build.config.msm.common:125)
#
# Deviation from the vendor gate, and why: upstream fails on ANY
# non-"+" line, because the vendor build never touches the config
# after the merge. We do one deliberate reduction (applied above),
# and turning CONFIG_UBSAN off makes its children invisible, so
# diffconfig reports "-UBSAN_BOOL n" for a symbol that was already
# unset and is merely no longer printed. That is not a dropped
# request.
#
# What must fail is a symbol that was requested ENABLED and did not
# survive: "-FOO y", "-FOO m" or "-FOO y -> m".
#
# No `|| true` here. Note that diffconfig exits 0 even when it cannot
# read a file, so this guard is NOT what protects the missing-config
# case -- the `-s out/.config` assertion in gate 2 is. It is here to
# catch genuine tool errors (unreadable/corrupt file, malformed
# input), which would otherwise be indistinguishable from "no drift"
# and turn the gate into a silent pass.
if ! scripts/diffconfig "$MERGED_PATH" out/.config > "$MERGE_OUT"; then
  echo "========================================================"
  echo "::error::scripts/diffconfig failed"
  cat "$MERGE_OUT"
  exit 1
fi
DRIFT=$(grep -E '^-' "$MERGE_OUT" | grep -vE '^-[A-Za-z0-9_]+ n$' || true)
if [ -n "$DRIFT" ]; then
  echo "========================================================"
  echo "::error::Defconfig fragment did not apply as expected"
  echo "$DRIFT"
  echo "A symbol was requested enabled but olddefconfig dropped it --"
  echo "almost always an unmet dependency or a conflicting choice."
  exit 1
fi
IGNORED=$(grep -cE '^-[A-Za-z0-9_]+ n$' "$MERGE_OUT" || true)
echo "  [gate 3/3] every requested symbol took effect ($IGNORED unset-but-invisible symbols ignored)"

# ---- codegen switches: assert the config ended up where the inputs
# ---- said it would -----------------------------------------------
# LTO is a choice group, so "no fragment" and "LTO_NONE" are the same
# thing in the config -- but it is worth asserting rather than
# assuming, because the whole point of the enable_thinlto switch is
# to reproduce the stock kernel's LTO_NONE exactly, and a silent
# reappearance of ThinLTO would make a boot-hang bisect meaningless.
if [ "$ENABLE_THINLTO" = "true" ]; then
  grep -q "^CONFIG_LTO_CLANG_THIN=y" out/.config \
    || { echo "::error::enable_thinlto=true but CONFIG_LTO_CLANG_THIN is not set"; exit 1; }
else
  grep -q "^CONFIG_LTO_NONE=y" out/.config \
    || { echo "::error::enable_thinlto=false but CONFIG_LTO_NONE is not set"; exit 1; }
  grep -q "^CONFIG_LTO_CLANG_THIN=y" out/.config \
    && { echo "::error::enable_thinlto=false but ThinLTO leaked in"; exit 1; }
fi
if [ "$ENABLE_AUTOFDO" != "true" ]; then
  # AUTOFDO_CLANG also has a `depends on CLANG_VERSION >= 170000`; if
  # the toolchain were old it would vanish silently. Since the point
  # of turning it off is a controlled bisect, its absence must be the
  # one we asked for.
  grep -q "^CONFIG_AUTOFDO_CLANG=y" out/.config \
    && { echo "::error::enable_autofdo=false but CONFIG_AUTOFDO_CLANG is set"; exit 1; }
  echo "  [codegen] AutoFDO off, as requested"
fi
echo "  [codegen] $(grep -E '^(CONFIG_LTO_NONE|CONFIG_LTO_CLANG_THIN|CONFIG_AUTOFDO_CLANG)=' out/.config | tr '\n' ' ')"

rm -f "$MERGE_OUT" "$VENDOR_BUILTIN" "$AUTOFDO_FRAGMENT" "$LTO_FRAGMENT"

# ---- feature status ----------------------------------------------
grep -q "^CONFIG_SYSVIPC=y" out/.config \
  && echo "DROIDSPACES_STATUS=applied (SYSVIPC=y, kABI-safe)" >> $GITHUB_ENV \
  || { echo "::error::CONFIG_SYSVIPC missing -- Droidspaces IPC unavailable"; exit 1; }

if [ "$ENABLE_SUSFS" = "true" ]; then
  grep -q "^CONFIG_KSU_SUSFS=y" out/.config \
    && echo "SUSFS_STATUS=applied (CONFIG_KSU_SUSFS=y)" >> $GITHUB_ENV \
    || { echo "::error::SUSFS symbols missing"; exit 1; }
fi

if [ "$BTF_OFF" = "0" ]; then
  # olddefconfig drops DEBUG_INFO_BTF silently if DEBUG_INFO_REDUCED
  # (or PAHOLE_VERSION < 121) creeps back in, so assert it explicitly.
  grep -q "^CONFIG_DEBUG_INFO_BTF=y" out/.config \
    || { echo "::error::CONFIG_DEBUG_INFO_BTF was dropped"; exit 1; }
  echo "BTF_STATUS=enabled (PAHOLE_VERSION=$(grep -m1 '^CONFIG_PAHOLE_VERSION=' out/.config | cut -d= -f2))" >> $GITHUB_ENV
else
  echo "BTF_STATUS=disabled" >> $GITHUB_ENV
fi

if grep -q "^CONFIG_BBG=y" out/.config; then
  echo "BBG_STATUS=applied (CONFIG_BBG=y)" >> $GITHUB_ENV
fi

echo "=== Key configs ==="
for cfg in CONFIG_KSU CONFIG_KSU_SUSFS CONFIG_HZ CONFIG_LTO_CLANG_THIN \
  CONFIG_CFI_CLANG CONFIG_ZRAM_DEF_COMP CONFIG_OVERLAY_FS CONFIG_SECCOMP \
  CONFIG_TCP_CONG_BBR3 CONFIG_DEFAULT_BBR3 CONFIG_DEFAULT_TCP_CONG CONFIG_NTSYNC \
  CONFIG_BBG CONFIG_LSM \
  CONFIG_NAMESPACES CONFIG_WIREGUARD CONFIG_AUTOFDO_CLANG CONFIG_MODVERSIONS \
  CONFIG_SYSVIPC CONFIG_POSIX_MQUEUE CONFIG_IPC_NS CONFIG_PID_NS \
  CONFIG_DEVTMPFS CONFIG_ANDROID_KABI_RESERVE \
  CONFIG_GKI_DYNAMIC_TASK_STRUCT_SIZE \
  CONFIG_DEBUG_INFO_BTF CONFIG_DEBUG_INFO_BTF_MODULES CONFIG_PAHOLE_VERSION \
  CONFIG_MODULE_SIG_HASH CONFIG_MODULE_SIG_PROTECT \
  CONFIG_MODULE_SIG_FORCE CONFIG_MODULE_SIG_KEY \
  CONFIG_MODULE_ALLOW_BTF_MISMATCH \
  CONFIG_MODULE_ALLOW_MISSING_NAMESPACE_IMPORTS \
  CONFIG_PROFILING CONFIG_PERF_EVENTS CONFIG_BPF_LSM CONFIG_UPROBES \
  CONFIG_LTO CONFIG_LTO_NONE CONFIG_LTO_CLANG CONFIG_LTO_CLANG_THIN \
  CONFIG_DEBUG_INFO_REDUCED CONFIG_UBSAN; do
  val=$(grep "^${cfg}=" out/.config 2>/dev/null | cut -d= -f2)
  if [ -z "$val" ] && grep -q "^# ${cfg} is not set" out/.config; then val="n"; fi
  [ -n "$val" ] && echo "  $cfg=$val" || echo "  $cfg=NOT SET"
done

