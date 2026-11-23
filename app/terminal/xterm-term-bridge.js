/**
 * xterm-term-bridge.js — xterm.js terminal bridge for ios-linuxkit.
 *
 * Drop-in alternative to term.js (Ghostty). Uses the same native bridge API
 * (window.exports / webkit.messageHandlers) so the Obj-C host code doesn't
 * need changes — only the HTML entry point differs (xterm-term.html vs term.html).
 *
 * Build switch: in Terminal.m, load xterm-term.html instead of term.html to use
 * the xterm.js renderer instead of Ghostty WebGL/Canvas2D.
 */

(async () => {
    'use strict';

    window.exports = {
        write() {},
        getSize: () => [0, 0],
        copy: () => false,
        setFocused() {},
        scrollToBottom() {},
        newScrollTop() {},
        updateStyle() {},
        getCharacterSize: () => [0, 0],
        clearScrollback() {},
        setUserGesture() {},
        setAccessibilityEnabled() {},
    };

    const terminalElement = document.getElementById('terminal');
    const { Terminal, FitAddon, WebLinksAddon, LigaturesAddon } = window.xtermModules || {};
    const { CanvasAddon } = window.CanvasAddon || {};
    if (!Terminal || !FitAddon || !WebLinksAddon || !LigaturesAddon) {
        window.__terminalBootstrapLog?.('terminal xterm modules were not loaded');
        return;
    }
    if (!CanvasAddon) {
        window.__terminalBootstrapLog?.('terminal xterm canvas addon was not loaded');
        return;
    }

    const ansiColorNames = [
        'black',
        'red',
        'green',
        'yellow',
        'blue',
        'magenta',
        'cyan',
        'white',
        'brightBlack',
        'brightRed',
        'brightGreen',
        'brightYellow',
        'brightBlue',
        'brightMagenta',
        'brightCyan',
        'brightWhite',
    ];

    // ── Native bridge (same as term.js) ──────────────────────────────────────
    const native = new Proxy({}, {
        get(_, prop) {
            return (...args) => {
                if (!window.webkit?.messageHandlers?.[prop])
                    return;
                let body = null;
                if (args.length == 1)
                    body = args[0];
                else if (args.length > 1)
                    body = args;
                window.webkit.messageHandlers[prop].postMessage(body);
            };
        }
    });

    // ── Style state ──────────────────────────────────────────────────────────
    let styleState = {
        foregroundColor: '#d4d4d4',
        backgroundColor: '#1e1e1e',
        cursorColor: undefined,
        fontSize: 12,
        fontFamily: '"JetBrainsMono Nerd Font Mono", "FiraCode Nerd Font Mono", ui-monospace, "SFMono-Regular", Menlo, Monaco, monospace',
        colorPaletteOverrides: undefined,
        blinkCursor: false,
        cursorShape: 'BLOCK',
    };
    styleState = {...styleState, ...normalizeStyleUpdate(window.__terminalInitialStyle)};
    applyDocumentStyle(styleState);
    await loadConfiguredFont(styleState);

    let resizeFrame = null;
    let pendingScrollSync = false;
    let lastNativeScrollHeight;
    let lastNativeScrollTop;
    let nativeScrollRequest = null;
    let oldProps = {};
    let xtermAppActive = null;
    let selectionAnchor = null;
    let selectionEnd = null;
    let lastNewOutputReport = 0;

    // ── Terminal setup ────────────────────────────────────────────────────────
    const term = new Terminal({
        cols: 80,
        rows: 24,
        fontSize: styleState.fontSize,
        fontFamily: styleState.fontFamily,
        theme: {
            foreground: styleState.foregroundColor,
            background: styleState.backgroundColor,
            cursor: styleState.cursorColor || styleState.foregroundColor,
            cursorAccent: styleState.backgroundColor,
        },
        cursorBlink: styleState.blinkCursor,
        cursorStyle: cursorStyleForXterm(styleState.cursorShape),
        allowTransparency: true,
        scrollback: 10000,
        // Guest tools occasionally die leaving the tty at -opost (bare-LF output);
        // convertEol makes the terminal CR-on-LF so output degrades gracefully
        // instead of staircase-rendering. Verified harmless for proper \r\n output.
        convertEol: true,
        disableStdin: true,  // iOS handles text input natively
        allowProposedApi: true,
        overviewRuler: {width: 0},
        smoothScrollDuration: 0,
        windowsMode: false,
    });

    const fitAddon = new FitAddon();
    term.loadAddon(new CanvasAddon());
    term.loadAddon(fitAddon);
    term.loadAddon(new WebLinksAddon());

    term.onData((data) => {
        native.sendInput(data);
        syncApplicationCursor();
    });
    term.onResize(() => {
        native.resize();
        scheduleScrollSync();
    });
    term.onScroll(() => {
        scheduleScrollSync();
        reportSelectionGeometry();
    });
    term.onCursorMove(syncApplicationCursor);
    term.onSelectionChange(() => {
        reportSelectionGeometry();
    });

    // OSC 52: programs (local or over SSH, e.g. vim/tmux) yank to the clipboard
    // with ESC ] 52 ; c ; <base64> ST. Decode and forward to the system clipboard.
    const OSC52_MAX_BASE64 = 262144;
    try {
        term.parser.registerOscHandler(52, (data) => {
            try {
                // xterm delivers "c;<base64>" (strips the empty selection param);
                // be liberal and also accept ";c;<base64>".
                const parts = data.split(';');
                const clipboard = parts[0] === '' ? parts[1] : parts[0];
                const encoded = parts.slice(parts[0] === '' ? 2 : 1).join(';');
                if (clipboard !== 'c' || !encoded || encoded === '?')
                    return true;
                if (encoded.length > OSC52_MAX_BASE64)
                    return true;
                const binary = atob(encoded);
                const bytes = new Uint8Array(binary.length);
                for (let i = 0; i < binary.length; i++)
                    bytes[i] = binary.charCodeAt(i);
                native.setClipboard(new TextDecoder().decode(bytes));
            } catch (error) {
                native.log(`osc52 failed: ${error?.stack || error}`);
            }
            return true;
        });
    } catch (error) {
        native.log(`osc52 registration failed: ${error?.stack || error}`);
    }

    term.open(terminalElement);
    installNativeFocusAdapter();
    installLigatures();
    disableWebTextInput();
    installFocusBridge();
    fitAddon.fit();
    syncApplicationCursor();
    scheduleScrollSync();

    // ── Resize handling ──────────────────────────────────────────────────────
    let resizeDebounce = null;

    function fitTerminal() {
        if (resizeFrame !== null)
            return;
        resizeFrame = requestAnimationFrame(() => {
            resizeFrame = null;
            const buffer = term.buffer.active;
            // Preserve what the user is looking at across reflows (keyboard
            // show/hide, font size changes, rotation): follow the newest line
            // if we were at the bottom, otherwise keep the same top line.
            const wasFollowing = buffer.viewportY >= buffer.baseY;
            const previousTopLine = buffer.viewportY;
            fitAddon.fit();
            const newBuffer = term.buffer.active;
            if (wasFollowing) {
                term.scrollToBottom();
            } else if (previousTopLine > 0) {
                term.scrollToLine(Math.min(previousTopLine, newBuffer.baseY));
            }
            // Keyboard animations refit every frame; notify the guest of its
            // new window size only once things settle (one SIGWINCH, not 60).
            if (resizeDebounce !== null)
                clearTimeout(resizeDebounce);
            resizeDebounce = setTimeout(() => {
                resizeDebounce = null;
                native.resize();
            }, 150);
            scheduleScrollSync();
        });
    }

    const ro = new ResizeObserver(() => fitTerminal());
    ro.observe(terminalElement);

    // ── Exports (native → JS) ────────────────────────────────────────────────
    function latin1StringToBytes(str) {
        const bytes = new Uint8Array(str.length);
        for (let i = 0; i < str.length; i++) {
            bytes[i] = str.charCodeAt(i) & 0xff;
        }
        return bytes;
    }

    window.exports = {
        write(data) {
            const bytes = typeof data === 'string' ? latin1StringToBytes(data) : new Uint8Array(data);
            term.write(bytes, scheduleScrollSync);
            if (bytes.includes(0x1b))
                syncApplicationCursor();
            maybeReportNewOutput();
        },
        getSize() {
            return [term.cols, term.rows];
        },
        copy() {
            return term.getSelection();
        },
        beginSelection(x, y) {
            selectionAnchor = selectionCell(x, y);
            if (!selectionAnchor)
                return;
            // Long-press selects the word under the finger, like iOS text fields.
            const word = wordRangeAt(selectionAnchor);
            if (word) {
                selectionAnchor = word.start;
                selectionEnd = word.end;
                selectRange(selectionAnchor, selectionEnd);
            } else {
                // Blank area: keep the anchor for drag-extend, but never create
                // an empty selection (a zero-length selection is sticky and
                // used to wedge the tap-to-focus handler).
                selectionEnd = selectionAnchor;
            }
        },
        extendSelection(x, y) {
            const end = selectionCell(x, y);
            if (!selectionAnchor || !end)
                return;
            selectionEnd = end;
            selectRange(selectionAnchor, selectionEnd);
        },
        moveSelectionEndpoint(which, x, y) {
            // Move the VISUAL start or end endpoint, whichever side the anchor
            // currently is. Handles may cross: dragging the start handle past
            // the end naturally swaps their roles (native iOS behavior).
            const cell = selectionCell(x, y);
            if (!cell || !selectionAnchor || !selectionEnd)
                return;
            const anchorIsVisualStart = cellLess(selectionAnchor, selectionEnd);
            if (which === 'start') {
                if (anchorIsVisualStart)
                    selectionAnchor = cell;
                else
                    selectionEnd = cell;
            } else {
                if (anchorIsVisualStart)
                    selectionEnd = cell;
                else
                    selectionAnchor = cell;
            }
            selectRange(selectionAnchor, selectionEnd);
        },
        selectAll() {
            selectionAnchor = {row: 0, col: 0};
            selectionEnd = {row: term.buffer.active.length - 1, col: term.cols - 1};
            term.selectAll();
        },
        clearSelection() {
            selectionAnchor = null;
            selectionEnd = null;
            term.clearSelection();
        },
        setFocused(focused) {
            terminalElement.classList.toggle('terminal-focused', !!focused);
            setXtermAppActive(!!focused);
        },
        scrollToBottom() {
            term.scrollToBottom();
            scheduleScrollSync();
        },
        newScrollTop(top) {
            if (!Number.isFinite(top))
                return;
            const cellHeight = getCellSize().height;
            if (!cellHeight)
                return;
            const buffer = term.buffer.active;
            const line = Math.max(0, Math.min(buffer.baseY, Math.round(top / cellHeight)));
            // UIKit owns fractional offsets and momentum. Do not snap its
            // offset back to the rounded row when acknowledging this request.
            nativeScrollRequest = {buffer, line, cellHeight};
            term.scrollToLine(line);
            scheduleScrollSync();
        },
        async updateStyle(newStyle) {
            styleState = {...styleState, ...normalizeStyleUpdate(newStyle)};
            applyDocumentStyle(styleState);
            await loadConfiguredFont(styleState);

            if (term.options.fontSize !== styleState.fontSize)
                term.options.fontSize = styleState.fontSize;
            if (term.options.fontFamily !== styleState.fontFamily)
                term.options.fontFamily = styleState.fontFamily;
            term.options.cursorBlink = !!styleState.blinkCursor;
            term.options.cursorStyle = cursorStyleForXterm(styleState.cursorShape);
            term.options.theme = themeForXterm(styleState);

            fitTerminal();
            term.refresh(0, term.rows - 1);
            scheduleScrollSync();
        },
        getCharacterSize() {
            const size = getCellSize();
            return [size.width || 0, size.height || 0];
        },
        clearScrollback() {
            term.clear();
            term.scrollToBottom();
            scheduleScrollSync();
        },
        setUserGesture() {},
        setAccessibilityEnabled() {},
        updateLoupe(x, y) {
            updateLoupe(x, y);
        },
        hideLoupe() {
            hideLoupe();
        },
    };

    // ── Signal ready ─────────────────────────────────────────────────────────
    setXtermAppActive(true);
    fitTerminal();
    native.load();
    native.syncFocus();

    function disableWebTextInput() {
        if (!term.textarea)
            return;
        term.textarea.readOnly = true;
        term.textarea.tabIndex = -1;
        term.textarea.autocapitalize = 'off';
        term.textarea.autocomplete = 'off';
        term.textarea.autocorrect = 'off';
        term.textarea.spellcheck = false;
        // Never let taps reach the hidden textarea: it used to steal first
        // responder from the native terminal view, closing the keyboard on a
        // single tap and breaking the double-tap toggle.
        term.textarea.style.pointerEvents = 'none';
        term.textarea.setAttribute('aria-hidden', 'true');
    }

    function selectionCell(x, y) {
        const screen = terminalElement.querySelector('.xterm-screen');
        const cell = getCellSize();
        if (!screen || !cell.width || !cell.height || !Number.isFinite(x) || !Number.isFinite(y))
            return null;
        const rect = screen.getBoundingClientRect();
        return {
            col: Math.max(0, Math.min(term.cols - 1, Math.floor((x - rect.left) / cell.width))),
            row: term.buffer.active.viewportY + Math.max(0, Math.min(term.rows - 1, Math.floor((y - rect.top) / cell.height))),
        };
    }

    function cellLess(a, b) {
        return a.row * term.cols + a.col < b.row * term.cols + b.col;
    }

    function selectRange(a, b) {
        const start = cellLess(a, b) ? a : b;
        const end = cellLess(a, b) ? b : a;
        const distance = (end.row * term.cols + end.col) - (start.row * term.cols + start.col);
        term.select(start.col, start.row, distance + 1);
    }

    function wordRangeAt(cell) {
        const buffer = term.buffer.active;
        const row = Math.max(0, Math.min(cell.row, buffer.length - 1));
        const line = buffer.getLine(row);
        if (!line)
            return null;
        const text = line.translateToString(false);
        const isWord = (ch) => ch !== undefined && /\S/.test(ch);
        if (!isWord(text[cell.col]))
            return null;
        let startCol = cell.col;
        let endCol = cell.col;
        while (startCol > 0 && isWord(text[startCol - 1]))
            startCol--;
        while (isWord(text[endCol + 1]))
            endCol++;
        return {start: {row: cell.row, col: startCol}, end: {row: cell.row, col: endCol}};
    }

    function reportSelectionGeometry() {
        if (!selectionAnchor || !selectionEnd || !term.hasSelection()) {
            native.selectionRect(null);
            return;
        }
        const screen = terminalElement.querySelector('.xterm-screen');
        const cell = getCellSize();
        if (!screen || !cell.width || !cell.height)
            return;
        const rect = screen.getBoundingClientRect();
        const viewportY = term.buffer.active.viewportY;
        const pointFor = (c) => ({
            x: rect.left + c.col * cell.width,
            y: rect.top + (c.row - viewportY) * cell.height,
        });
        const start = cellLess(selectionAnchor, selectionEnd) ? selectionAnchor : selectionEnd;
        const end = cellLess(selectionAnchor, selectionEnd) ? selectionEnd : selectionAnchor;
        const startPoint = pointFor(start);
        const endPoint = pointFor(end);
        native.selectionRect({
            sx: startPoint.x,
            sy: startPoint.y,
            ex: endPoint.x + cell.width,
            ey: endPoint.y,
            cellHeight: cell.height,
        });
    }

    function maybeReportNewOutput() {
        const buffer = term.buffer.active;
        if (buffer.viewportY >= buffer.baseY)
            return; // following the latest line: nothing to surface
        const now = performance.now();
        if (now - lastNewOutputReport < 250)
            return;
        lastNewOutputReport = now;
        native.newOutput(true);
    }

    // ── In-page selection loupe ─────────────────────────────────────────────
    // Magnifies the terminal's own canvases synchronously (canvas-to-canvas).
    // Native snapshot APIs deliver too late during gesture tracking; the page
    // provably renders live during drags (the selection highlight does).
    let loupeRoot = null;
    let loupeCanvas = null;

    function updateLoupe(x, y) {
        if (!loupeRoot) {
            loupeRoot = document.createElement('div');
            const d = 120;
            loupeRoot.style.cssText = `position:fixed;left:0;top:0;width:${d}px;height:${d}px;` +
                'border-radius:60px;border:3px solid rgba(25,25,25,0.8);box-shadow:0 4px 12px rgba(0,0,0,0.35);' +
                'overflow:hidden;pointer-events:none;z-index:9999;display:none;';
            const dpr = window.devicePixelRatio || 1;
            loupeCanvas = document.createElement('canvas');
            loupeCanvas.width = d * dpr;
            loupeCanvas.height = d * dpr;
            loupeCanvas.style.cssText = 'width:120px;height:120px;display:block;';
            loupeRoot.appendChild(loupeCanvas);
            document.body.appendChild(loupeRoot);
        }
        const dpr = window.devicePixelRatio || 1;
        const diameter = 120;
        const magnification = 2;
        const region = diameter / magnification; // 60 CSS px of terminal
        const sourceX = Math.max(0, Math.min(window.innerWidth - region, x - region / 2));
        const sourceY = Math.max(0, Math.min(window.innerHeight - region, y - region / 2));
        const context = loupeCanvas.getContext('2d');
        context.setTransform(dpr, 0, 0, dpr, 0, 0);
        context.clearRect(0, 0, diameter, diameter);
        const canvases = terminalElement.querySelectorAll('canvas');
        for (const canvas of canvases) {
            const rect = canvas.getBoundingClientRect();
            if (rect.width === 0 || rect.height === 0)
                continue;
            // Source rect in the canvas's internal pixel space.
            const kx = canvas.width / rect.width;
            const ky = canvas.height / rect.height;
            const sx = (sourceX - rect.left) * kx;
            const sy = (sourceY - rect.top) * ky;
            try {
                context.drawImage(canvas, sx, sy, region * kx, region * ky, 0, 0, diameter, diameter);
            } catch (error) {
                // tainted or missing layer; skip
            }
        }
        loupeRoot.style.display = 'block';
        let left = x - diameter / 2;
        let top = y - diameter - 46;
        left = Math.max(4, Math.min(window.innerWidth - diameter - 4, left));
        top = Math.max(4, top);
        loupeRoot.style.left = `${left}px`;
        loupeRoot.style.top = `${top}px`;
    }

    function hideLoupe() {
        if (loupeRoot)
            loupeRoot.style.display = 'none';
    }

    function installFocusBridge() {
        // Native owns every touch: pan scrolls, double tap toggles the
        // keyboard, long-press selects or pastes. The page opts out of web
        // touch handling entirely: `touch-action: none` stops default web
        // scrolling, and a capture-phase stopPropagation keeps xterm's own
        // viewport touch handlers from seeing drags. Nothing here ever calls
        // preventDefault (that kills native ancestor recognizers) or focuses.
        terminalElement.style.touchAction = 'none';
        terminalElement.addEventListener('touchmove', (event) => {
            event.stopPropagation();
        }, {capture: true});
        terminalElement.addEventListener('focus', () => native.syncFocus());
        terminalElement.addEventListener('blur', () => native.syncFocus());
    }

    function installLigatures() {
        try {
            term.loadAddon(new LigaturesAddon());
        } catch (error) {
            native.log(`terminal ligatures addon failed: ${error?.stack || error}`);
        }
    }

    function installNativeFocusAdapter() {
        const browserService = term._core?._coreBrowserService;
        if (!browserService)
            return;
        try {
            Object.defineProperty(browserService, 'isFocused', {
                configurable: true,
                get: () => !!xtermAppActive,
            });
        } catch (error) {
            native.log(`terminal focus adapter failed: ${error?.stack || error}`);
        }
    }

    function setXtermAppActive(active) {
        if (xtermAppActive === active) {
            if (active)
                ensureCursorVisible();
            return;
        }
        xtermAppActive = active;

        const core = term._core;
        try {
            if (core?.element)
                core.element.classList.toggle('focus', active);
            if (active) {
                core?._renderService?.handleFocus?.();
                ensureCursorVisible();
            } else {
                core?._renderService?.handleBlur?.();
            }
        } catch (error) {
            native.log(`terminal focus sync failed: ${error?.stack || error}`);
        }
    }

    function ensureCursorVisible() {
        const coreService = term._core?.coreService;
        if (coreService)
            coreService.isCursorInitialized = true;
        term.refresh(term.buffer.active.cursorY, term.buffer.active.cursorY);
    }

    function scheduleScrollSync() {
        if (pendingScrollSync)
            return;
        pendingScrollSync = true;
        requestAnimationFrame(() => {
            pendingScrollSync = false;
            syncScroll();
        });
    }

    function syncScroll() {
        const cellHeight = getCellSize().height;
        if (!cellHeight)
            return;
        const buffer = term.buffer.active;
        // Fit rounds rows down; the unused fraction still belongs to UIKit's
        // viewport. Its maximum offset must equal baseY * cellHeight exactly.
        const scrollHeight = buffer.baseY * cellHeight + terminalElement.clientHeight;
        const scrollTop = buffer.viewportY * cellHeight;

        if (scrollHeight !== lastNativeScrollHeight) {
            native.newScrollHeight(scrollHeight);
            lastNativeScrollHeight = scrollHeight;
        }
        const acknowledgesNativeScroll = nativeScrollRequest?.buffer === buffer &&
            nativeScrollRequest.line === buffer.viewportY &&
            nativeScrollRequest.cellHeight === cellHeight;
        nativeScrollRequest = null;
        if (!acknowledgesNativeScroll && scrollTop !== lastNativeScrollTop) {
            native.newScrollTop(scrollTop);
        }
        lastNativeScrollTop = scrollTop;
    }

    function syncApplicationCursor() {
        syncProp('applicationCursor', !!term.modes?.applicationCursorKeysMode);
    }

    function syncProp(name, value) {
        if (oldProps[name] !== value)
            native.propUpdate(name, value);
        oldProps[name] = value;
    }

    function getCellSize() {
        const dims = term._core?._renderService?.dimensions;
        return {
            width: dims?.css?.cell?.width || 0,
            height: dims?.css?.cell?.height || 0,
        };
    }

    function normalizeStyleUpdate(nextStyle) {
        const style = {...(nextStyle || {})};
        if (!Array.isArray(style.colorPaletteOverrides))
            style.colorPaletteOverrides = undefined;
        return style;
    }

    function applyDocumentStyle(style) {
        if (style.backgroundColor)
            document.documentElement.style.setProperty('--terminal-background', style.backgroundColor);
        if (style.foregroundColor)
            document.documentElement.style.setProperty('--terminal-foreground', style.foregroundColor);
    }

    async function loadConfiguredFont(style) {
        if (!document.fonts?.load)
            return;
        const family = firstFontFamily(style.fontFamily);
        if (!family)
            return;
        try {
            await Promise.all([
                document.fonts.load(`${style.fontSize}px ${quoteCssFontFamily(family)}`),
                document.fonts.load(`700 ${style.fontSize}px ${quoteCssFontFamily(family)}`),
            ]);
            await document.fonts.ready;
        } catch (error) {
            native.log(`terminal font load failed: ${error}`);
        }
    }

    function firstFontFamily(familyList) {
        const trimmed = String(familyList || '').trim();
        if (!trimmed)
            return '';
        const match = trimmed.match(/^(['"])(.*?)\1/);
        if (match)
            return match[2];
        return trimmed.split(',')[0].trim();
    }

    function quoteCssFontFamily(family) {
        const trimmed = String(family || '').trim();
        if (!trimmed || trimmed.startsWith('"') || trimmed.startsWith("'"))
            return trimmed;
        if (/^[a-zA-Z_-][a-zA-Z0-9_-]*$/.test(trimmed))
            return trimmed;
        return `"${trimmed.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
    }

    function cursorStyleForXterm(cursorShape) {
        switch (cursorShape) {
            case 'BEAM':
            case 'bar':
                return 'bar';
            case 'UNDERLINE':
            case 'underline':
                return 'underline';
            case 'BLOCK':
            case 'block':
            default:
                return 'block';
        }
    }

    function themeForXterm(style) {
        const theme = {
            foreground: style.foregroundColor,
            background: style.backgroundColor,
            cursor: style.cursorColor || style.foregroundColor,
            cursorAccent: style.backgroundColor,
            // Translucent tint keeps the underlying text visible while selected.
            selectionBackground: 'rgba(120, 170, 255, 0.35)',
        };
        if (Array.isArray(style.colorPaletteOverrides)) {
            for (let i = 0; i < Math.min(ansiColorNames.length, style.colorPaletteOverrides.length); i++)
                theme[ansiColorNames[i]] = style.colorPaletteOverrides[i];
        }
        return theme;
    }

})();
