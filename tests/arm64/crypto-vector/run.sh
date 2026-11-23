#!/usr/bin/env bash
# Crypto vector gate: native oracle vs emulated guest, plus the EOR3 C
# fallback path (ISH_HOST_SHA3=0). Validates TBL/TBX/PMULL/PMULL2/EOR3
# gadgets against the same instructions executing natively.
#
# The guest binary is a freestanding static ELF built with zig cc (bundles
# an lld capable of ELF linking; macOS clang cannot). Falls back to clang
# --target + lld on hosts where that works (Linux).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$(cd "$HERE/../../.." && pwd)"
CC="${CC:-clang}"
ZIG="${ZIG:-}"
ISH_BIN="${ISH_BIN:-$PROJECT/build-arm64-linux/ish}"
ROOTFS="${ROOTFS:-$PROJECT/alpine-arm64-fakefs}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

case "$(uname -m)" in aarch64|arm64) ;; *) echo 'requires an arm64 host' >&2; exit 1;; esac
test -x "$ISH_BIN"; test -d "$ROOTFS"

if [ -z "$ZIG" ]; then
    if command -v zig >/dev/null 2>&1 && zig version >/dev/null 2>&1; then
        ZIG="zig"
    elif command -v mise >/dev/null 2>&1 && mise x zig@0.14.1 -- zig version >/dev/null 2>&1; then
        ZIG="mise x zig@0.14.1 -- zig"
    fi
fi

# Native oracle: hosted build, runs on the host CPU.
"$CC" -O2 -Wall -Wextra -Werror "$HERE/driver.c" "$HERE/crypto_ops.S" -o "$TMP/cryptovec"
"$TMP/cryptovec" > "$TMP/native.log"
grep -Fxq 'crypto-vector-ok cases=60 failures=0' "$TMP/native.log"

# Guest build: freestanding static Linux ELF (no libc).
if [ -n "$ZIG" ]; then
    # shellcheck disable=SC2086
    $ZIG cc -target aarch64-linux-musl -ffreestanding -nostdlib -O2 \
        -Wall -Wextra -Werror "$HERE/driver.c" "$HERE/crypto_ops.S" \
        -o "$TMP/cryptovec-elf"
else
    "$CC" --target=aarch64-linux-musl -ffreestanding -nostdlib -fuse-ld=lld \
        -O2 -Wall -Wextra -Werror "$HERE/driver.c" "$HERE/crypto_ops.S" \
        -o "$TMP/cryptovec-elf"
fi

tar -C "$TMP" -cf - cryptovec-elf | "$ISH_BIN" -f "$ROOTFS" /bin/sh -ec \
    'mkdir -p /tmp/cryptovec && tar -xf - -C /tmp/cryptovec'

# Emulated, native gadgets (incl. EOR3 when the host has FEAT_SHA3).
"$ISH_BIN" -f "$ROOTFS" /tmp/cryptovec/cryptovec-elf > "$TMP/guest.log"
diff -u "$TMP/native.log" "$TMP/guest.log"

# Emulated, EOR3 forced through the C fallback.
ISH_HOST_SHA3=0 "$ISH_BIN" -f "$ROOTFS" /tmp/cryptovec/cryptovec-elf > "$TMP/guest_soft.log"
diff -u "$TMP/native.log" "$TMP/guest_soft.log"

echo 'crypto-vector-gate-ok: tbl/tbx/pmull/eor3/aese, native vs guest vs soft-fallback'
