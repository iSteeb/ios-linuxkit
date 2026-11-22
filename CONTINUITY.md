# CONTINUITY.md — ios-linuxkit bring-up on iPhone (iPoke)

## PLAN
- Goal: build ios-linuxkit (iSH ARM64 fork) from iSteeb's fork, install on iPhone "iPoke" via devicectl, run Alpine aarch64 shell.
- Acceptance: app launches on device, terminal boots to Linux shell. ← DONE 2026-11-21 (verify visually on device)
- Next: on-device smoke test (boot shell, apk update), then pi agent + ssh setup inside guest.
- Active plan: X11 display via guest Xvnc + native RFB/Metal client (Option B) — docs/plans/X11_RFB_DISPLAY_PLAN.md; phases tracked in todo tool; Phase 0 spike is the hard gate.

## DECISIONS
- [2026-11-19] Adopt rcarmo/ios-linuxkit (fork: iSteeb/ios-linuxkit @ d23ae89 = 2.6.1 build 828) instead of building from scratch. [USER]
- [2026-11-19] Use repo-local mise for build tools (meson pypi:meson, ninja aqua:ninja-build/ninja). [USER]
- [2026-11-19] Use team 7997G399U7 (paid Individual, the Xcode-signed-in Apple ID), NOT keychain cert team VZAY7UW5SX. Bundle dev.isteeb.linuxkit + group.dev.isteeb.linuxkit. [CODE]
- [2026-11-19] Build scheme iSH-ARM64, config Debug-ApplePleaseFixFB19282108, IPHONEOS_DEPLOYMENT_TARGET=15.0 (Xcode 27.2 requirement). [CODE]
- [2026-11-21] X11 display = Option B: guest Xvnc (TigerVNC) on 127.0.0.1:5901-5910 + own native RFB client (no vendored code) + Metal renderer; guest sockets are host-passthrough (fs/sock.c) so no kernel changes needed. Chosen over noVNC webview (B) and native Xorg DDX (D) for input quality + effort; visionOS per-window future shapes layering (pure-C protocol layer). [USER]

## PROGRESS
- [2026-11-21] FULL-APP COHESION PASS (BUILT, holding for approval):
  P1 touch truth: touchstart preventDefault REMOVED (it was killing native pan — root cause of finger-scroll death); CSS touch-action:none + capture stopPropagation neutralizes xterm touch; tap→focus, tap-dismiss; xterm-6 vscode-style DOM scrollbar hidden (the "left scrollbar"); system UIScrollView indicator hidden.
  P1 loupe: region snapshot (60pt@2x = loupe), anchor-slide between 120ms snapshots, fixed centering math; handles 44pt hit areas.
  P2 lazy webviews: ROOT CAUSE was setTty→syncWindowSize→webView getter materializing a webview PER GUEST TTY (7 WebProcesses!). Guards in syncWindowSize + setEnableVoiceOverAnnounce; getter was already lazy. One WebProcess now.
  P2 FileProvider: extension-presence check before NSFileProviderManager work (boot error spam gone). SIGWINCH debounce 150ms after last fit.
  P3: ScrollbarView frame-write guard; edit-menu interaction removed; pre-15 inset math removed; keyboardDidSomething trimmed.
- KNOWN DEFERRED: link taps (WebLinks modifier-click oriented; needs tap-owner design), PasteboardDevice paste-banner behavior, focus adapter monkeypatch stays.
- [2026-11-21] Scroll/UX batch (BUILT, awaiting user approval to install):
  1. Scroll hardening: coalesced newScrollTop (one in-flight evaluateJavaScript, newest offset wins) — kills flick latency pileup. Native momentum untouched.
  2. Keyboard-follow: fitTerminal preserves anchor — at bottom → scrollToBottom, else keep top line (fixes content-under-keyboard on toggle).
  3. Edge auto-scroll: CADisplayLink ramps 0→2400px/s within 56pt of viewport edge, active during finger-drag AND handle-drag (adjustStart respected); re-extends selection at same screen point; loupe follows.
  4. Pinch zoom: UIPinchGestureRecognizer → fontSize 6–28 in 0.5 steps, live via existing KVO→updateStyle→fit path.
  5. Output pill: bridge maybeReportNewOutput (scrolled-up + write, 250ms throttle) → native pill bottom-center, tap → scrollToBottom, hides when offset reaches bottom.
  6. Copy toast: "Copied N chars" fades 0.8s after auto-copy.
- LESSON: ObjC property named copyToast violates ARC copy-naming rule → renamed clipboardToast. CGRectIsEmpty (no Get). drawViewHierarchyInRect blank on WKWebView → takeSnapshotWithConfiguration. [TOOL]
- [2026-11-21] DEBUG SESSION (3 regressions → 3 root causes, all fixed):
  1. Long-press "dead" = app CRASH: UIKit probes updateFloatingCursorAtPoint: with nil terminal → appendString:nil → NSInvalidArgumentException (symbolicated via slide 0x960000 + nm). Fixed with nil guard. Crashes explained osc52+settings reports too.
  2. OSC52 dead = parser format bug: xterm hands registerOscHandler(52) "c;<b64>" (strips empty selection param), my parser expected ";c;<b64>" → silently consumed. Fixed (accepts both). VERIFIED on sim: "[setClipboard] wrote 15 chars".
  3. Extra Keys row inaccessible = storyboard cell inserted into External-Keyboard SCENE (VbH-40-Znm) not main About scene → cross-scene outlet dropped. Moved under "External Keyboard" row in main scene. VERIFIED via scene-scan script.
- Debug techniques that worked: devicectl launch --console (bridges app stdout+crash to terminal!), sim launch with defaults args (-Key Value repeated = array), screenshot+describe_image, baked-in probe launchCommand, nm+slide symbolication. [TOOL]
- Remaining breadcrumb logs: [setClipboard], [selection] in NSLog — keep for now.
- Bridge quirk: xterm-term-bridge.js IIFE runs ~7× per webview load (pre-existing "frontend loaded" ×6) — harmless but suspicious; investigate someday. [DISCOVERY]
- Build+deployed to iPoke after fixes. [CODE]
- [2026-11-21] Clipboard pass: OSC52 (bridge registerOscHandler(52) → native setClipboard → UIPasteboard, 256KB cap); selection upgraded (word-select on long-press, adjustSelectionStart JS, selectionRect geometry msg, native drag handles + auto-copy+haptic on settle); buttons restyled (radius 8 continuous, symbol configs via imageByApplyingSymbolConfiguration — old API REMOVED in iOS 27 SDK); gear → showAbout; Extra Keys row in About.storyboard keyboard section (outlet exk-K1-cell). Files: xterm-term-bridge.js, Terminal.m, TerminalView.m, ExtraKeysBarView.m, About.storyboard, AboutViewController.m, TerminalViewController.m. Built+deployed iPoke. [CODE]
- LESSON: iOS 27 SDK removed UIImage.imageWithSymbolConfiguration: — use imageByApplyingSymbolConfiguration:. plutil can't lint storyboards — xmllint. [TOOL]
- [2026-11-21] Keyboard bar redesign (rootshell-inspired, no vendored code): new in-code ExtraKeysBarView [ESC][TAB][CTRL] + scrollable editable center + [ARROWS][PASTE][hide-kbd iPhone-only]. New files app/ExtraKeysBarView.{h,m}, app/ExtraKeysEditorViewController.{h,m}. UserPreferences.extraKeys (defaults / ~ - | \ $ :settings, KVO live-reload). TerminalViewController: bar swap, controlKey outlet reassign, resizeBar gutted, inset math → inputAccessoryView. pbxproj: manual file registration (IDs 5EE1…A1/A2/B1–B4). Built + installed + launched on iPoke. [CODE]
- Gear button opens the Extra Keys editor (decision; About screen still via old infoButton flow). [ASSUMPTION] user wanted edit-in-settings; confirm UX.
- LESSON: never pipe xcodebuild through `| head` — SIGPIPE kills the build silently mid-flight. [TOOL]
- BUILD SUCCEEDED (config Debug-ApplePleaseFixFB19282108, IPHONEOS_DEPLOYMENT_TARGET=15.0, -allowProvisioningUpdates). [CODE]
- Installed LinuxKit.app on iPoke (bundle dev.isteeb.linuxkit) + launched via devicectl. [TOOL]
- Rebuild cmd: eval "$(mise activate bash)" && xcodebuild -project iSH.xcodeproj -scheme iSH-ARM64 -configuration Debug-ApplePleaseFixFB19282108 -destination 'id=00008150-000243C63408401C' -derivedDataPath build/xcode-dd IPHONEOS_DEPLOYMENT_TARGET=15.0 CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates build
- Fork carries rcarmo's team K8Q74NT2BG in pbxproj (now replaced); beware upstream merges re-introducing it.
- User accepted updated PLA in developer account (was blocking app-group provisioning). [USER]
- Local changes not yet committed: .mise.toml, CONTINUITY.md, app/iSH.xcconfig, iSH.xcodeproj/project.pbxproj. [CODE]
- Cloned with submodules to ~/work/ios-linuxkit. deps/linux intentionally skipped (`update = none` in .gitmodules). [CODE]
- Build path: checked-in iSH.xcodeproj (NO xcodegen needed). Makefile is Linux-host only. [CODE]
- iSH-ARM64 does NOT embed FileProvider extension (empty Embed phase); only the old x86 target does. [CODE]
- Signing wrinkle: app/iSH.entitlements requires app group group.$(ROOT_BUNDLE_IDENTIFIER). AppGroup.m ContainerURL() has AOT-bootstrap fallback pattern if group unavailable → patch path exists if personal team can't register groups. [CODE]

## DISCOVERIES
- Target device iPoke = iPhone Air (iPhone18,4), UDID 00008150-000243C63408401C, paired/available. [TOOL]
- Build downloads Alpine 3.24.2 aarch64 minirootfs during build (ROOTFS_URL in app/GuestARM64.xcconfig, pinned SHA). [CODE]
- "bwrap: command not found" sandbox errors from bash tool are environmental; user opened sandbox on request. [TOOL]

## OUTCOMES
- [2026-11-21] LinuxKit.app 2.6.1 (build 828) built from iSteeb/ios-linuxkit@d23ae89, installed + launched on iPhone Air iPoke. First boot extracts bundled Alpine 3.24.2 aarch64 rootfs.

## OUTCOMES (session 1, 2026-11-22)
- Interaction model finalized (all-manual): double-tap = keyboard toggle, long-press-hold = paste popup, long-press-drag = selection w/ loupe+handles+autoscroll, single tap = dismiss selection only, pan = scroll, pinch = font. Keyboard focus: webview permanently barred (canBecomeFirstResponder NO + textarea pointer-events none).
- OSC52 + touch selection + toast/pill/pinch shipped. Copy on every selection settle.
- Known remaining: Terminal.storyboard still carries the old (unused) bar scene + outlets — removal needs storyboard surgery; do not delete IBOutlet properties in code alone (nib decode crash). [DISCOVERY]
