# Plan — X11 Display via guest Xvnc + native RFB/Metal client (Option B)

Status: PLANNED · Owner: agent + isteeb · Prereq: none
Related: `docs/LIMITATIONS.md` (GUI gap), `docs/SECURITY.md`, `fs/sock.c` (host-passthrough sockets)

## 1. Goal

`ssh -X` from the guest terminal to any remote host; remote X11 clients render
inside a native iOS display surface in the app, driven by touch, pointer
(trackpad/mouse) and keyboard, at usable frame rates.

**Non-goals for B** (must not preclude): per-X-window surfaces on a future
visionOS target; GPU acceleration; Wayland; App Store distribution.

## 2. Architecture

```
┌─ iOS app ────────────────────────────────────────────────┐
│ DisplayViewController (full-screen surface)              │
│   ├─ DisplayMetalRenderer  (MTKView, BGRA8 texture)      │
│   ├─ Input: gestures / UIPointerInteraction / GCMouse /  │
│   │        presses(with:) → RFBKeyEvent (keysyms)        │
│   └─ DisplaySession  (probe, connect, reconnect, inject) │
│         └─ RFBClient (pure C: RFB 3.8, no UIKit)         │
└──────────────────────┬───────────────────────────────────┘
                       │ TCP 127.0.0.1:5901-5910 (host-passthrough, fs/sock.c)
┌─ guest (Alpine aarch64, asbestos-interpreted) ───────────┐
│ Xvnc :1 (TigerVNC) — RFB server, depth 24, loopback only │
│   + twm (title bars) + xauth cookie                      │
│ startx-vnc (shipped via RootfsPatch.bundle v6)           │
│ ssh -X remote  → remote xclock appears on :1             │
└──────────────────────────────────────────────────────────┘
```

Why this shape:
- Guest sockets are **host-passthrough** (`fs/sock.c:449+` supports AF_UNIX path
  + abstract, TCP): a stock Alpine `Xvnc` works without any kernel changes.
- The RFB hop decouples us from X internals now, and on a later visionOS
  target a session-per-X-window variant can reuse the same client stack.

## 3. Design decisions

| # | Decision | Rationale / alternative rejected |
|---|---|---|
| D1 | **Xvnc (TigerVNC)** as guest X server | single binary, built-in RFB + Tight, no MIT-SHM needed; vs Xvfb+x11vnc (two processes, more SHM/IPC surface) |
| D2 | **Write our own RFB client** (~2 kloc C) | repo style is "no vendored code"; GPLv3/GPLv2 status is fine either way (LICENSE.md), but own client keeps the protocol layer portable to visionOS and free of GPL ambiguity; libvncclient (GPLv2) is the fallback if protocol work stalls |
| D3 | **Encoding preference: CopyRect > Raw > Hextile > Tight** | the interpreted guest is the bottleneck, not loopback bandwidth; Raw costs the server a memcpy while Tight costs interpreted zlib. Verify with Phase 0 matrix; invert if data disagrees |
| D4 | Launch UX = toolbar button; app probes 5901-5910; if closed, injects `startx-vnc` via `Terminal sendInput:`; polls for RFB banner | avoids any new host↔guest IPC; `sendInput:` and RootfsPatch already exist |
| D5 | Packages via runtime `apk add` (repositories.txt already shipped into the app bundle), apk cache in app container for warm start; script + twm rc via **RootfsPatch.bundle v6** | keeps rootfs bundle deterministic and avoids build-machine apk tooling; bake-time is the fallback if first-run latency is bad |
| D6 | Geometry = device main screen in points (not pixels), depth 24, BGRA → zero conversion into Metal | caps interpreted blit cost; ExtendedDesktopSize pseudo-encoding later for rotation |
| D7 | Strict layering: `RFBClient`/`RFBFramebuffer`/`RFBKeyEvent` are pure C, no UIKit; renderer and input are swappable behind protocols | visionOS: `DisplaySession` per surface; per-window future = x11vnc `-id` scraping or a small X extension (spike in Phase 7, not scheduled) |
| D8 | Security: Xvnc `-localhost yes`, cookie auth guest-side, RFB auth None (loopback stays inside the app sandbox); never bind 0.0.0.0; document in SECURITY.md | consistent with existing sandbox threat model |

## 4. File-level change list

New:
- `app/Display/RFBClient.{h,c}` — RFB 3.8: handshake, security (None + DES VNC-AUTH), pixel format, Raw/CopyRect/Hextile/Tight(zlib)/CoRRE, pseudo-encodings Cursor / DesktopSize / ExtendedDesktopSize / LastRect, incremental update loop, Bell, ServerCutText, fuzz-resistant parsing.
- `app/Display/RFBFramebuffer.{h,c}` — pixel store, dirty-rect merge, generation counter, PPM dump hook for tests.
- `app/Display/RFBKeyEvent.{h,c}` — HID/keycode → X11 keysym tables, modifier/AltGr state machine.
- `app/Display/DisplaySession.{h,m}` — port probe, connect/backoff/reconnect, foreground-transition handling, `sendInput:` orchestration, session state KVO.
- `app/Display/DisplayMetalRenderer.{h,m}` — MTKView subclass; dirty-rect texture streaming; fit/1:1/zoom scale modes; vsync.
- `app/Display/DisplayViewController.{h,m}` — gestures (tap=L, 2-finger=R, long-press-drag, pan-scroll), `UIPointerInteraction` + `GCMouse` absolute pointer, keyboard capture (`presses(with:)` + hidden `UIKeyInput`), clipboard ↔ ClientCutText, on-screen extra-keys bar (reuse ExtraKeysBarView pattern).
- `app/RootfsPatch.bundle/files/usr/local/bin/startx-vnc` + `files/etc/X11/twm/system.twmrc` + manifest v6.
- `tests/host/rfb_*.c` — protocol unit tests against an in-tree mock RFB server; optional live-Xvnc mode.
- `tests/e2e/display_*.sh` — Linux-host: guest Xvnc + xterm, client dumps, screenshot compare.
- `docs/DISPLAY.md` — user guide (`ssh -X` walkthrough).

Modified:
- `app/TerminalViewController.m` — Display toolbar button + presentation + live state.
- `app/UserPreferences.{h,m}` — encoding choice, scale mode, touchpad-vs-direct, geometry override.
- `iSH.xcodeproj/project.pbxproj` — manual registration (CONTINUITY lesson: known-good pattern).
- `docs/LIMITATIONS.md` — retire the "no X11" line when Phase 5 lands.
- `SECURITY.md` — display-session section.
- `CONTINUITY.md` — progress as phases complete.

## 5. Phases, acceptance criteria, estimates

### Phase 0 — Spike & perf gate (de-risk, ~1 session) — HARD GATE
On aarch64 Linux host build (and/or iPoke): `apk add tigervnc twm xterm xauth`;
run `Xvnc :1 -localhost yes -geometry <screen-points> -depth 24`; launch
xterm/xeyes; connect from a desktop VNC viewer. Record boot time, syscall gaps
(interpreter log), and an encoding matrix (Raw/Hextile/Tight fps for text
scroll + xeyes).
**Acceptance**: Xvnc reaches a usable session with no unimplemented-syscall
blockers; ≥5 fps fullscreen text scroll server-side. Findings written to
`docs/reports/audits/XVNC_SPIKE_<date>.md`. **If the gate fails** → re-scope
(smaller geometry, depth 16, AOT training task) before any client code.

### Phase 1 — Guest session management (~1-2 sessions)
`startx-vnc` (free-display pick, xauth cookie, first-free rfbport 5901-5910,
geometry from injected env, exec twm), RootfsPatch v6, `DisplaySession` probe +
inject + poll.
**Acceptance**: on iPoke, tapping Display brings a live session up <60 s cold
(incl. apk), <10 s warm; button reflects state; second tap focuses existing.

### Phase 2 — RFB protocol core (~2-4 sessions, parallelizable with Phase 1)
`RFBClient` + `RFBFramebuffer` + mock-server unit tests + live-Xvnc tests
(Linux CI / local rig). Bit-exact PPM dumps across two runs; malformed-rect
fuzzing; clean teardown.
**Acceptance**: all unit tests green in `make` target following repo
conventions; headless client renders xterm session to PPM.

### Phase 3 — Metal renderer + touch/pointer input (~2-3 sessions)
Renderer with dirty rects and scale modes; gesture set; absolute pointer via
`UIPointerInteraction`/`GCMouse`; local cursor from Cursor pseudo-encoding.
**Acceptance**: on-device xterm/xeyes interaction; pointer-move → photon ≤1
frame on CopyRect path; no tearing; rotation handled (refit, no resize proto yet).

### Phase 4 — Keyboard (~2-3 sessions)
Hardware `presses(with:)` → keysym via `RFBKeyEvent` (keycode-based, not
characters), modifier state incl. AltGr, no stuck modifiers on app switch;
software keyboard via hidden input + extra-keys bar.
**Acceptance**: full xterm typing test (symbols, arrows, Home/End/PgUp, Ctrl/
Alt combos); modifier release verified after every interruption path.

### Phase 5 — Integration, ssh -X e2e, polish (~2-3 sessions)
Full story on iPoke: Display → `ssh -X host` → xclock/xterm interactive;
suspend/resume reconnect with full (non-incremental) refresh; clipboard both
ways; settings screen; memory/jetsam instrumentation (fb ≈ 12 MB + textures).
**Acceptance**: user story demo recorded; `docs/DISPLAY.md` written;
LIMITATIONS.md updated.

### Phase 6 — Hardening, security, CI (~1-2 sessions)
SECURITY.md section (loopback-only assertion in DisplaySession + guest script);
error surfaces (server death, port stolen, apk offline); CI wiring for rfb
tests; optional AOT profile training entry for Xvnc.
**Acceptance**: adversarial review pass; CI green.

### Phase 7 — visionOS per-window (future, unscheduled)
Spike per-window options (x11vnc `-id` scraping vs small X extension exposing
window rects), WindowGroup session model, renderer protocol reuse. B's layering
(D7) exists precisely to keep this door open.

## 6. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Missing syscalls in Xvnc path (memfd_create, epoll_pwait2, …) | medium | Phase 0 gate; kernel gaps are small, well-patterned fixes in `kernel/` |
| Interpreter CPU starves encoding | medium | D3 Raw-first; geometry in points; depth 16 fallback; AOT training |
| Keyboard layout edge cases (dead keys, non-US) | medium | keycode-based hardware path first; ship US-ANSI table; document |
| iOS suspension mid-session | certain | reconnect + full refresh state machine |
| Jetsam pressure | low | instrument; cap depth; reuse single fb texture |
| Port collision with user services | low | 5901-5910 scan + status in `/tmp` |
| RootfsPatch regressions | low | version bump, idempotent apply already proven (CurrentRoot.m) |

## 7. Test matrix

Linux host CI (guest Xvnc in fakefs, client headless) · macOS rig (desktop
Xvnc for protocol tests) · iPhone Air "iPoke" (device acceptance) · iOS
simulator (interaction smoke).

## 8. Estimate

Critical path Phases 0→2; total ~3-5 weeks agent-paced interleaved with other
work. Phase 0 is cheap and must run first — it can invalidate D3/D6 cheaply.
