const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const scan = @import("scan.zig");
const fuzzy = @import("fuzzy.zig");
const uni = @import("unicode.zig");

extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

/// Allocation failure while building a frame is unrecoverable; crash loudly
/// rather than silently rendering a corrupt screen. (Terminal-cleanup paths
/// keep best-effort `catch {}` since they run during teardown/signals.)
fn oom() noreturn {
    @panic("out of memory");
}

// Saved terminal state for restoration from a signal handler (which cannot
// take arguments). Set while the TUI owns the terminal.
var g_orig: posix.termios = undefined;
var g_active: bool = false;

fn restoreTerminal() void {
    if (!g_active) return;
    g_active = false;
    const seq = "\x1b[?25h\x1b[?1049l"; // show cursor, leave alt-screen
    _ = std.c.write(1, seq.ptr, seq.len);
    posix.tcsetattr(0, .FLUSH, g_orig) catch {};
}

fn onSignal(sig: posix.SIG) callconv(.c) void {
    restoreTerminal();
    // restore default disposition and re-raise so exit status reflects signal
    const act = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(sig, &act, null);
    _ = posix.raise(sig) catch {};
}

fn installSignalHandlers() void {
    const act = posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    for ([_]posix.SIG{ .INT, .TERM, .HUP, .QUIT }) |s| {
        posix.sigaction(s, &act, null);
    }
}

const Hit = struct {
    idx: u32,
    score: i32,
    m: fuzzy.Match,
};

// Official brand colors as 24-bit truecolor.
fn agentColor(a: scan.Agent) []const u8 {
    return switch (a) {
        .claude => "\x1b[38;2;218;119;86m", // #DA7756 Anthropic terra cotta
        .codex => "\x1b[38;2;16;163;127m", // #10A37F OpenAI green
        .opencode => "\x1b[38;2;207;206;205m", // #CFCECD opencode logo gray
        .pi => "\x1b[38;2;136;192;208m", // #88C0D0 pi Nord frost
    };
}

pub const Tui = struct {
    a: std.mem.Allocator,
    io: Io,
    records: []const scan.Record,
    query: std.ArrayList(u8) = .empty,
    hits: std.ArrayList(Hit) = .empty,
    sel: usize = 0,
    top: usize = 0,
    rows: u16 = 24,
    cols: u16 = 80,
    orig: posix.termios = undefined,
    matcher: fuzzy.Matcher,

    pub fn init(a: std.mem.Allocator, io: Io, records: []const scan.Record) Tui {
        return .{ .a = a, .io = io, .records = records, .matcher = fuzzy.Matcher.init(a) };
    }

    fn winsize(self: *Tui) void {
        var ws: posix.winsize = undefined;
        // CDXC:AgentHistorySearch 2026-05-29-12:49:
        // zehn runs inside Ghostex on macOS as well as ordinary Linux terminals.
        // Terminal sizing must use libc ioctl instead of Linux syscall numbers;
        // macOS rejects those with SIGSYS after the alternate screen is entered,
        // leaving users with a blank terminal.
        const rc = ioctl(0, @intCast(posix.T.IOCGWINSZ), &ws);
        if (rc == 0 and ws.row > 0 and ws.col > 0) {
            self.rows = ws.row;
            self.cols = ws.col;
        }
    }

    fn enterRaw(self: *Tui) !void {
        self.orig = try posix.tcgetattr(0);
        g_orig = self.orig;
        var t = self.orig;
        t.lflag.ICANON = false;
        t.lflag.ECHO = false;
        t.lflag.ISIG = false;
        t.lflag.IEXTEN = false;
        t.iflag.IXON = false;
        t.iflag.ICRNL = false;
        try posix.tcsetattr(0, .FLUSH, t);
        g_active = true;
    }

    fn leaveRaw(self: *Tui) void {
        g_active = false;
        posix.tcsetattr(0, .FLUSH, self.orig) catch {};
    }

    fn recompute(self: *Tui) void {
        self.hits.clearRetainingCapacity();
        const q = self.query.items;
        for (self.records, 0..) |rec, i| {
            if (self.matcher.match(q, rec.text)) |m| {
                self.hits.append(self.a, .{ .idx = @intCast(i), .score = m.score, .m = m }) catch oom();
            }
        }
        std.mem.sort(Hit, self.hits.items, self.records, struct {
            fn lt(recs: []const scan.Record, x: Hit, y: Hit) bool {
                if (x.score != y.score) return x.score > y.score;
                const tx = recs[x.idx].ts;
                const ty = recs[y.idx].ts;
                if (tx != ty) return tx > ty; // newer first
                return x.idx < y.idx;
            }
        }.lt);
        self.sel = 0;
        self.top = 0;
    }

    fn listHeight(self: *Tui) usize {
        // 1 prompt line + 1 separator + preview(5)
        const reserved: usize = 1 + 1 + 5;
        if (self.rows <= reserved + 1) return 1;
        return self.rows - reserved;
    }

    fn clampScroll(self: *Tui) void {
        const h = self.listHeight();
        if (self.sel < self.top) self.top = self.sel;
        if (self.sel >= self.top + h) self.top = self.sel + 1 - h;
    }

    // Render `text` on a single line: UTF-8 aware, truncated to `max` display
    // columns, with matched bytes highlighted. Highlight positions are byte
    // offsets (matches are byte-wise); a codepoint is highlighted if its first
    // byte is a match position.
    fn writeHighlighted(self: *Tui, buf: *std.ArrayList(u8), text: []const u8, m: fuzzy.Match, max: usize, selected: bool) void {
        var pi: usize = 0;
        var i: usize = 0;
        var used: usize = 0;
        while (i < text.len) {
            const d = uni.decode(text[i..]);
            // sanitize control chars (incl. newlines/tabs) to a space
            const is_ctrl = d.cp < 0x20 or (d.cp >= 0x7f and d.cp < 0xa0);
            const cw: usize = if (is_ctrl) 1 else uni.charWidth(d.cp);
            if (used + cw > max) {
                buf.appendSlice(self.a, "…") catch oom();
                return;
            }
            // advance highlight cursor past any positions before i
            while (pi < m.pos_len and m.positions[pi] < i) pi += 1;
            const hl = pi < m.pos_len and m.positions[pi] == i;
            if (hl) {
                pi += 1;
                buf.appendSlice(self.a, "\x1b[1;33m") catch oom(); // bold yellow
            }
            if (is_ctrl) {
                buf.append(self.a, ' ') catch oom();
            } else {
                buf.appendSlice(self.a, text[i .. i + d.len]) catch oom();
            }
            if (hl) {
                buf.appendSlice(self.a, "\x1b[0m") catch oom();
                if (selected) buf.appendSlice(self.a, "\x1b[7m") catch oom();
            }
            used += cw;
            i += d.len;
        }
    }

    fn render(self: *Tui, w: *Io.Writer) !void {
        self.winsize(); // pick up live terminal resizes
        self.clampScroll();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.a);
        const b = &buf;

        b.appendSlice(self.a, "\x1b[2J\x1b[H") catch oom(); // clear + home

        // prompt line
        b.appendSlice(self.a, "\x1b[1;36m❯ \x1b[0m") catch oom();
        b.appendSlice(self.a, self.query.items) catch oom();
        var cnt: [64]u8 = undefined;
        const cs = std.fmt.bufPrint(&cnt, "  \x1b[90m{d}/{d}\x1b[0m\r\n", .{ self.hits.items.len, self.records.len }) catch "\r\n";
        b.appendSlice(self.a, cs) catch oom();

        const h = self.listHeight();
        const text_max: usize = if (self.cols > 14) self.cols - 14 else 20;
        var row: usize = 0;
        while (row < h) : (row += 1) {
            const hi = self.top + row;
            if (hi >= self.hits.items.len) {
                b.appendSlice(self.a, "\r\n") catch oom();
                continue;
            }
            const hit = self.hits.items[hi];
            const rec = self.records[hit.idx];
            const selected = hi == self.sel;
            if (selected) b.appendSlice(self.a, "\x1b[7m") catch oom();
            b.appendSlice(self.a, if (selected) "▌ " else "  ") catch oom();
            // agent tag
            b.appendSlice(self.a, agentColor(rec.agent)) catch oom();
            var tag: [16]u8 = undefined;
            const ts = std.fmt.bufPrint(&tag, "{s: <7}", .{rec.agent.label()}) catch rec.agent.label();
            b.appendSlice(self.a, ts) catch oom();
            b.appendSlice(self.a, "\x1b[0m") catch oom();
            if (selected) b.appendSlice(self.a, "\x1b[7m") catch oom();
            b.append(self.a, ' ') catch oom();
            self.writeHighlighted(b, rec.text, hit.m, text_max, selected);
            b.appendSlice(self.a, "\x1b[0m\r\n") catch oom();
        }

        // separator
        b.appendSlice(self.a, "\x1b[90m") catch oom();
        var k: usize = 0;
        while (k < self.cols) : (k += 1) b.append(self.a, '-') catch oom();
        b.appendSlice(self.a, "\x1b[0m\r\n") catch oom();

        // preview of selected
        if (self.sel < self.hits.items.len) {
            const rec = self.records[self.hits.items[self.sel].idx];
            var pv: [256]u8 = undefined;
            const head = std.fmt.bufPrint(&pv, "\x1b[90magent:\x1b[0m {s}  \x1b[90mproject:\x1b[0m {s}\r\n", .{ rec.agent.label(), if (rec.project.len > 0) rec.project else "-" }) catch "";
            b.appendSlice(self.a, head) catch oom();
            // up to 4 lines, wrapped at display width, UTF-8 aware
            var i: usize = 0;
            var line_lines: usize = 0;
            while (i < rec.text.len and line_lines < 4) {
                var used: usize = 0;
                const line_start = i;
                while (i < rec.text.len) {
                    if (rec.text[i] == '\n') break;
                    const d = uni.decode(rec.text[i..]);
                    const is_ctrl = d.cp < 0x20 or (d.cp >= 0x7f and d.cp < 0xa0);
                    const cw: usize = if (is_ctrl) 1 else uni.charWidth(d.cp);
                    if (used + cw > self.cols) break;
                    if (is_ctrl) b.append(self.a, ' ') catch oom() else b.appendSlice(self.a, rec.text[i .. i + d.len]) catch oom();
                    used += cw;
                    i += d.len;
                }
                b.appendSlice(self.a, "\r\n") catch oom();
                // if we stopped on a newline, skip it
                if (i < rec.text.len and rec.text[i] == '\n') i += 1;
                line_lines += 1;
                if (i == line_start and used == 0) i += 1; // guarantee progress
            }
        }

        try w.writeAll(b.items);
        try w.flush();
    }

    /// Returns the selected record index, or null if cancelled.
    pub fn run(self: *Tui, w: *Io.Writer) !?usize {
        self.winsize();
        installSignalHandlers();
        try self.enterRaw();
        defer self.leaveRaw();
        try w.writeAll("\x1b[?1049h\x1b[?25l"); // alt screen, hide cursor
        try w.flush();
        defer {
            w.writeAll("\x1b[?25h\x1b[?1049l") catch {}; // show cursor, leave alt screen
            w.flush() catch {};
        }

        self.recompute();

        var ibuf: [256]u8 = undefined;
        while (true) {
            try self.render(w);
            const n = posix.read(0, &ibuf) catch break;
            if (n == 0) break;
            var i: usize = 0;
            while (i < n) {
                const c = ibuf[i];
                if (c == 27) {
                    // escape sequence (arrows) or bare ESC
                    if (i + 2 < n and ibuf[i + 1] == '[') {
                        switch (ibuf[i + 2]) {
                            'A' => self.moveUp(),
                            'B' => self.moveDown(),
                            else => {},
                        }
                        i += 3;
                        continue;
                    }
                    return null; // bare ESC quits
                }
                switch (c) {
                    3 => return null, // ctrl-c
                    13, 10 => {
                        if (self.sel < self.hits.items.len)
                            return self.hits.items[self.sel].idx;
                        return null;
                    },
                    127, 8 => {
                        if (self.query.items.len > 0) {
                            // pop a full UTF-8 codepoint
                            _ = self.query.pop();
                            while (self.query.items.len > 0 and
                                (self.query.items[self.query.items.len - 1] & 0xC0) == 0x80)
                            {
                                _ = self.query.pop();
                            }
                            self.recompute();
                        }
                    },
                    14 => self.moveDown(), // ctrl-n
                    16 => self.moveUp(), // ctrl-p
                    else => {
                        // accept printable ASCII and any UTF-8 continuation/lead
                        // bytes (>=128), but not DEL
                        if ((c >= 32 and c < 127) or c >= 128) {
                            self.query.append(self.a, c) catch oom();
                            self.recompute();
                        }
                    },
                }
                i += 1;
            }
        }
        return null;
    }

    fn moveDown(self: *Tui) void {
        if (self.hits.items.len == 0) return;
        if (self.sel + 1 < self.hits.items.len) self.sel += 1;
    }
    fn moveUp(self: *Tui) void {
        if (self.sel > 0) self.sel -= 1;
    }
};
