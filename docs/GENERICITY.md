# Genericity contract

This document codifies how performance work and "baked-in" behavior coexist
with the project's goal: **the truest possible generic Alpine Linux**, where
users install whatever they want (`apk add ...`, mise, language runtimes) and
it runs as well as the hardware and a no-JIT emulator allow. No user should
be required to run a specific version of anything from a specific source.

## The tier model

Everything the app does for performance or compatibility falls into exactly
one of four tiers. New work must identify its tier, and tier boundaries are
enforced:

| Tier | What it is | Rule |
|---|---|---|
| 0 | Universal engine/kernel performance: block cache, TLB, prechain, syscall fast paths, fakefs pragmas, native crypto-instruction gadgets (AESE, SHA\*, EOR3, PMULL, TBL/TBX) | Benefits every guest binary, every version. Always allowed in the default app. |
| 1 | Behavior-keyed coercion at `execve`: env vars (`PYTHONMALLOC`, `GODEBUG` merge, `GOMAXPROCS`, `JSC_*`/`BUN_JSC_*`), Node argv flags (`--jitless` …), existence-gated polyfills | Must be keyed on runtime *family/behavior*, never a version; must have an escape hatch; must tolerate bystanders (a non-matching program ignores it). |
| 2 | Version-pinned payload: AOT pre-translated images (musl/BusyBox/Bun/Go) recorded from checksum-pinned upstream artifacts | **Never in the default app.** Lives only in the opt-in `iSH-ARM64-AOT-Bootstrap` target (separate bundle id). Runtime matching degrades gracefully (exact → family/content-hash → interpreter); package upgrades simply fall back to the interpreter ("unmatched code uses the interpreter; do not overwrite user files to force a match"). |
| 3 | Native offload by exec name (ffmpeg/ffprobe) | Exact system paths only ("do not replace arbitrary user binaries by basename"), shebang scripts fall through, `NO_OFFLOAD=1`/`MINIS_NO_FFMPEG_OFFLOAD=1` opt-out, no production cooperative handler without a bounded-cancellation contract (see `docs/NATIVE_OFFLOAD.md`). |

The bundled minirootfs pin (`app/GuestARM64.xcconfig`) is installer
determinism, not a runtime lock: after first boot the guest manages itself
with unrestricted `apk`.

## Tier-1 rules in detail

1. **Inject only what is behavior-keyed.** `PYTHONMALLOC=malloc` works on any
   CPython; `JSC_*` and `BUN_JSC_*` are both set because Bun renamed them;
   Node's `--jitless` flags are stable V8 flags. Nothing may depend on a
   specific upstream release.
2. **Escape hatches are mandatory.** `ISH_NODE_NO_ARG_INJECTION=1` (Node argv
   flags) and `ISH_NO_ENV_INJECTION=1` (the whole env table, including the
   startup copies in `xX_main_Xx.h` and `main.c`) let any environment get a
   pristine guest. `ISH_HOST_SHA512=0` / `ISH_HOST_SHA3=0` force the C crypto
   fallbacks for A/B testing.
3. **Fill gaps, never clobber user values** — with one forced exception:
   `GODEBUG` *merges* `asyncpreemptoff=1` into a user-provided value (its
   absence is a correctness cliff, not a preference), and `PYTHONMALLOC` is
   force-replaced (pymalloc arenas misbehave under emulation). Both are
   documented here as deliberate exceptions.
4. **The kernel does not have UX opinions.** `NO_COLOR=1` used to be injected
   into every process; it was removed — users who want it can export it.
5. **Existence-gated guest files only.** `/lib/wasm-polyfill.js`,
   `/lib/fetch-polyfill.js` and `/lib/zero_free.so` are injected only if
   present in the guest, and the polyfills self-disable when the guest no
   longer needs them (`WebAssembly` defined).

## Decisions with measurements

- **`PYTHONDONTWRITEBYTECODE=1` stays.** Measured on the fakefs guest root
  (the iPhone configuration): 8× stdlib import storm with forced recompile
  ≈ 16.7 s wall vs ≈ 17.2 s with a *warm* `.pyc` cache (154 files present).
  Reading + unmarshaling pyc through the sqlite-backed fakefs costs more
  than recompiling in-memory. Revisit only if the fakefs read path gets
  significantly faster.
- **AOT stays a lane, not the product.** See `docs/reports/` — no break-even
  at ≤64 work units, Python regresses ~14 %, and the on-device bash/ble spike
  was 30 % *slower* with 75 % image hit rate (2026-11-22).

## When adding baked-in behavior

Ask, in order: (1) Is it Tier 0? Then it's fine everywhere. (2) Is it
behavior-keyed with an escape hatch and a bystander-tolerant default? Tier 1,
document it in `kernel/exec.c` next to the table. (3) Does it pin a version?
It belongs in the AOT bootstrap lane only. (4) Does it replace a user binary?
It needs the offload policy contract. Anything else — don't bake it in.
