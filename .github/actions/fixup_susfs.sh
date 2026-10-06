#!/bin/bash
# Make sure <linux/dma-buf.h> is included in fs/proc/base.c, which the SUSFS
# context hooks expect.
#
# On this tree (seventeen @ 6.6.142) the include is already there at line 103,
# so this is a no-op that just confirms it. It is kept because it is idempotent
# and self-checking, and because the SUSFS patch's one fuzzy hunk lands in this
# same file: if that hunk ever has to be regenerated, the include has to be
# right first. The original comment claimed CLO kernels lack this header; that
# was true of the old tree, not this one.
set -e

KERNEL_ROOT="${1:-.}"
cd "$KERNEL_ROOT"

BASE_C="fs/proc/base.c"
if grep -q '#include <linux/dma-buf.h>' "$BASE_C" 2>/dev/null; then
  echo "  [✓] fs/proc/base.c: <linux/dma-buf.h> already present"
else
  echo "  [*] fs/proc/base.c: adding <linux/dma-buf.h> for SUSFS context..."
  sed -i '/#include <linux\/cpufreq_times.h>/a #include <linux/dma-buf.h>' "$BASE_C"
  grep -q '#include <linux/dma-buf.h>' "$BASE_C" && echo "  [✓] Done" || exit 1
fi
