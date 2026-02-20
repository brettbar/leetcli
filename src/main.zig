const std = @import("std");
const vaxis = @import("vaxis");

const Problem = struct {
    title: []const u8,
    url: []const u8,
    path: []const u8,
    markdown: []const u8,
};

const AppState = struct {
    problems: []const Problem,
    selected: usize = 0,
    selected_language: usize = 0,
    focus: PaneFocus = .problems,
    status_message: []const u8 = "",
    answer_preview: []const u8 = "",
    answer_preview_path: []const u8 = "",
    answer_open: bool = false,
    run_output: []const u8 = "",
    problem_scroll: usize = 0,
    code_scroll: usize = 0,
    run_scroll: usize = 0,
};

const AppEvent = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

const language_options = [_][]const u8{
    "Python",
    "Golang",
    "C++",
};

const pane_header_style_focused: vaxis.Style = .{
    .bg = .{ .index = 153 }, // light blue
    .fg = .{ .index = 16 },
    .bold = true,
};

const pane_header_style_unfocused: vaxis.Style = .{
    .bold = true,
};

const cursor_highlight_style: vaxis.Style = .{
    .bg = .{ .index = 216 }, // soft orange
    .fg = .{ .index = 16 },
};

const PaneFocus = enum {
    problems,
    problem_view,
    language_menu,
    run_panel,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len > 1 and std.mem.eql(u8, args[1], "--hydrate-problems")) {
        const problems = try loadProblems(allocator);
        try hydrateProblems(allocator, problems);
        std.debug.print("Hydrated {d} problem file(s)\n", .{problems.len});
        return;
    }

    const problems = try loadProblems(allocator);
    var state = AppState{
        .problems = problems,
    };

    var tty = try vaxis.Tty.init();
    defer tty.deinit();

    var vx = try vaxis.init(allocator, .{});
    defer vx.deinit(allocator, tty.anyWriter());

    try vx.enterAltScreen(tty.anyWriter());
    try vx.queryTerminal(tty.anyWriter(), 1 * std.time.ns_per_s);

    var loop: vaxis.Loop(AppEvent) = .{
        .tty = &tty,
        .vaxis = &vx,
    };
    try loop.init();
    defer loop.stop();
    try loop.start();

    const initial_size = try vaxis.Tty.getWinsize(tty.fd);
    try vx.resize(allocator, tty.anyWriter(), initial_size);
    try render(&vx, tty.anyWriter(), &state);

    while (true) {
        switch (loop.nextEvent()) {
            .winsize => |ws| {
                try vx.resize(allocator, tty.anyWriter(), ws);
                try render(&vx, tty.anyWriter(), &state);
            },
            .key_press => |key| {
                if (key.matches('q', .{}) or
                    key.matches(vaxis.Key.escape, .{}) or
                    key.matches('c', .{ .ctrl = true }))
                {
                    break;
                }

                var redraw = false;

                if (key.matches(vaxis.Key.tab, .{ .ctrl = true }) or key.matches('n', .{ .ctrl = true }))
                {
                    state.focus = switch (state.focus) {
                        .problems => .problem_view,
                        .problem_view => .language_menu,
                        .language_menu => .run_panel,
                        .run_panel => .problems,
                    };
                    redraw = true;
                } else if (key.matches(vaxis.Key.tab, .{ .ctrl = true, .shift = true }) or key.matches('p', .{ .ctrl = true })) {
                    state.focus = switch (state.focus) {
                        .problems => .run_panel,
                        .problem_view => .problems,
                        .language_menu => .problem_view,
                        .run_panel => .language_menu,
                    };
                    redraw = true;
                } else if (key.matches(vaxis.Key.left, .{ .ctrl = true }) or
                    key.matches('h', .{ .ctrl = true }) or
                    key.matches(8, .{}) or // ctrl-h (BS)
                    key.matches(127, .{}))
                {
                    const next_focus: PaneFocus = switch (state.focus) {
                        .run_panel => .language_menu,
                        .language_menu => .problems,
                        .problem_view => .problems,
                        .problems => .problems,
                    };
                    if (next_focus != state.focus) {
                        state.focus = next_focus;
                        redraw = true;
                    }
                } else if (key.matches(vaxis.Key.right, .{ .ctrl = true }) or
                    key.matches('l', .{ .ctrl = true }) or
                    key.matches(12, .{}))
                {
                    const next_focus: PaneFocus = switch (state.focus) {
                        .problems => .problem_view,
                        .language_menu => .run_panel,
                        .problem_view => .problem_view,
                        .run_panel => .run_panel,
                    };
                    if (next_focus != state.focus) {
                        state.focus = next_focus;
                        redraw = true;
                    }
                } else if (state.focus == .problem_view and
                    (key.matches(vaxis.Key.down, .{ .ctrl = true }) or
                    key.matches('j', .{ .ctrl = true }) or
                    key.matches(vaxis.Key.enter, .{ .ctrl = true }) or
                    key.matches(10, .{}) or
                    key.matches(13, .{})))
                {
                    state.focus = .language_menu;
                    redraw = true;
                } else if (key.matches(vaxis.Key.up, .{ .ctrl = true }) or
                    key.matches('k', .{ .ctrl = true }) or
                    key.matches(11, .{}))
                {
                    if (state.focus == .language_menu or state.focus == .run_panel) {
                        state.focus = .problem_view;
                        redraw = true;
                    }
                } else if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
                    switch (state.focus) {
                        .problems => {
                            if (state.selected + 1 < state.problems.len) {
                                state.selected += 1;
                                state.problem_scroll = 0;
                                clearAnswerPreview(&state);
                                redraw = true;
                            }
                        },
                        .problem_view => {
                            const max_scroll = maxLineScroll(state.problems[state.selected].markdown);
                            if (state.problem_scroll < max_scroll) {
                                state.problem_scroll += 1;
                                redraw = true;
                            }
                        },
                        .language_menu => {
                            if (state.answer_preview.len > 0) {
                                const max_code_scroll = maxLineScroll(state.answer_preview);
                                if (state.code_scroll < max_code_scroll) {
                                    state.code_scroll += 1;
                                    redraw = true;
                                }
                            } else if (state.selected_language + 1 < language_options.len) {
                                state.selected_language += 1;
                                clearAnswerPreview(&state);
                                redraw = true;
                            }
                        },
                        .run_panel => {
                            if (state.run_output.len > 0) {
                                const max_run_scroll = maxLineScroll(state.run_output);
                                if (state.run_scroll < max_run_scroll) {
                                    state.run_scroll += 1;
                                    redraw = true;
                                }
                            }
                        },
                    }
                } else if (state.focus == .problems and key.matches(vaxis.Key.enter, .{})) {
                    state.focus = .problem_view;
                    redraw = true;
                } else if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
                    switch (state.focus) {
                        .problems => {
                            if (state.selected > 0) {
                                state.selected -= 1;
                                try refreshAnswerPreview(allocator, &state);
                                redraw = true;
                            }
                        },
                        .problem_view => {
                            if (state.problem_scroll > 0) {
                                state.problem_scroll -= 1;
                                redraw = true;
                            }
                        },
                        .language_menu => {
                            if (state.answer_preview.len > 0) {
                                if (state.code_scroll > 0) {
                                    state.code_scroll -= 1;
                                    redraw = true;
                                }
                            } else if (state.selected_language > 0) {
                                state.selected_language -= 1;
                                clearAnswerPreview(&state);
                                redraw = true;
                            }
                        },
                        .run_panel => {
                            if (state.run_output.len > 0 and state.run_scroll > 0) {
                                state.run_scroll -= 1;
                                redraw = true;
                            }
                        },
                    }
                } else if (key.matches(vaxis.Key.page_down, .{})) {
                    switch (state.focus) {
                        .problem_view => {
                            const max_scroll = maxLineScroll(state.problems[state.selected].markdown);
                            state.problem_scroll = @min(state.problem_scroll + 10, max_scroll);
                            redraw = true;
                        },
                        .language_menu => {
                            if (state.answer_preview.len > 0) {
                                const max_code_scroll = maxLineScroll(state.answer_preview);
                                state.code_scroll = @min(state.code_scroll + 10, max_code_scroll);
                                redraw = true;
                            }
                        },
                        .run_panel => {
                            if (state.run_output.len > 0) {
                                const max_run_scroll = maxLineScroll(state.run_output);
                                state.run_scroll = @min(state.run_scroll + 10, max_run_scroll);
                                redraw = true;
                            }
                        },
                        else => {},
                    }
                } else if (key.matches(vaxis.Key.page_up, .{})) {
                    switch (state.focus) {
                        .problem_view => {
                            state.problem_scroll = state.problem_scroll -| 10;
                            redraw = true;
                        },
                        .language_menu => {
                            if (state.answer_preview.len > 0) {
                                state.code_scroll = state.code_scroll -| 10;
                                redraw = true;
                            }
                        },
                        .run_panel => {
                            if (state.run_output.len > 0) {
                                state.run_scroll = state.run_scroll -| 10;
                                redraw = true;
                            }
                        },
                        else => {},
                    }
                } else if (state.focus == .language_menu and key.matches('1', .{})) {
                    state.selected_language = 0;
                    clearAnswerPreview(&state);
                    redraw = true;
                } else if (state.focus == .language_menu and key.matches('2', .{})) {
                    state.selected_language = 1;
                    clearAnswerPreview(&state);
                    redraw = true;
                } else if (state.focus == .language_menu and key.matches('3', .{})) {
                    state.selected_language = 2;
                    clearAnswerPreview(&state);
                    redraw = true;
                } else if (state.focus == .language_menu and key.matches(vaxis.Key.enter, .{})) {
                    if (state.answer_preview.len == 0) {
                        state.status_message = createAnswerFile(allocator, &state) catch |err| try std.fmt.allocPrint(
                            allocator,
                            "Failed: {s}",
                            .{@errorName(err)},
                        );
                        try refreshAnswerPreview(allocator, &state);
                    }
                    state.answer_open = true;
                    redraw = true;
                } else if (state.focus == .run_panel and key.matches(vaxis.Key.enter, .{})) {
                    if (state.answer_preview.len > 0) {
                        state.run_output = runSelectedInput(allocator, &state) catch |err| try std.fmt.allocPrint(
                            allocator,
                            "Run failed: {s}",
                            .{@errorName(err)},
                        );
                        state.status_message = "";
                    }
                    redraw = true;
                }

                if (redraw) {
                    try render(&vx, tty.anyWriter(), &state);
                }
            },
        }
    }
}

fn render(vx: *vaxis.Vaxis, writer: std.io.AnyWriter, state: *const AppState) !void {
    var window = vx.window();
    window.clear();

    if (window.width == 0 or window.height == 0) {
        try vx.render(writer);
        return;
    }

    const left_width = @max(@as(usize, 10), window.width / 6);
    const divider_col = if (left_width < window.width) left_width else window.width - 1;

    for (0..window.height) |row| {
        window.writeCell(divider_col, row, .{
            .char = .{ .grapheme = "│", .width = 1 },
        });
    }

    const left = window.child(.{
        .width = .{ .limit = divider_col },
        .height = .expand,
    });
    const right = window.child(.{
        .x_off = @min(divider_col + 1, window.width),
        .width = .expand,
        .height = .expand,
    });

    const problems_header_style: vaxis.Style = if (state.focus == .problems) pane_header_style_focused else pane_header_style_unfocused;
    _ = try left.print(&.{.{ .text = "Problems", .style = problems_header_style }}, .{
        .row_offset = 0,
        .col_offset = 1,
        .wrap = .none,
    });

    if (left.height > 1) {
        const visible_rows = left.height - 1;
        const start = scrollStart(state.selected, visible_rows);
        var row: usize = 1;
        var i: usize = start;
        while (i < state.problems.len and row < left.height) : ({
            i += 1;
            row += 1;
        }) {
            const style: vaxis.Style = if (i == state.selected and state.focus == .problems) cursor_highlight_style else .{};
            _ = try left.print(&.{.{ .text = state.problems[i].title, .style = style }}, .{
                .row_offset = row,
                .col_offset = 1,
                .wrap = .none,
            });
        }
    }

    if (right.width > 0 and right.height > 0) {
        const split_row = if (right.height > 1) right.height / 2 else 0;
        if (split_row < right.height) {
            for (0..right.width) |col| {
                right.writeCell(col, split_row, .{
                    .char = .{ .grapheme = "─", .width = 1 },
                });
            }
        }
    }

    const right_top = right.child(.{
        .width = .expand,
        .height = .{ .limit = if (right.height > 1) right.height / 2 else right.height },
    });
    const right_bottom = right.child(.{
        .y_off = if (right.height > 1) right.height / 2 + 1 else right.height,
        .width = .expand,
        .height = .expand,
    });

    const problem_header_style: vaxis.Style = if (state.focus == .problem_view) pane_header_style_focused else pane_header_style_unfocused;
    _ = try right_top.print(&.{.{ .text = "Problem", .style = problem_header_style }}, .{
        .row_offset = 0,
        .col_offset = 1,
        .wrap = .none,
    });
    _ = try right_top.print(&.{.{ .text = "PgUp/PgDn or j/k to scroll", .style = .{ .dim = true } }}, .{
        .row_offset = 1,
        .col_offset = 1,
        .wrap = .none,
    });
    _ = try right_top.print(&.{.{ .text = sliceFromLine(state.problems[state.selected].markdown, state.problem_scroll) }}, .{
        .row_offset = 2,
        .col_offset = 1,
        .wrap = .word,
    });
    const language_header_style: vaxis.Style = if (state.focus == .language_menu) pane_header_style_focused else pane_header_style_unfocused;
    const run_button_style: vaxis.Style = if (state.focus == .run_panel) pane_header_style_focused else pane_header_style_unfocused;
    const bottom_left_width = if (right_bottom.width > 2) right_bottom.width / 2 else right_bottom.width;
    const bottom_divider_col = if (bottom_left_width < right_bottom.width) bottom_left_width else right_bottom.width -| 1;
    if (right_bottom.width > 0 and right_bottom.height > 0 and bottom_divider_col < right_bottom.width) {
        for (0..right_bottom.height) |row| {
            right_bottom.writeCell(bottom_divider_col, row, .{
                .char = .{ .grapheme = "│", .width = 1 },
            });
        }
    }
    const bottom_left = right_bottom.child(.{
        .width = .{ .limit = bottom_divider_col },
        .height = .expand,
    });
    const bottom_right = right_bottom.child(.{
        .x_off = @min(bottom_divider_col + 1, right_bottom.width),
        .width = .expand,
        .height = .expand,
    });

    _ = try bottom_left.print(&.{.{ .text = "Code", .style = language_header_style }}, .{
        .row_offset = 0,
        .col_offset = 1,
        .wrap = .none,
    });

    if (state.answer_open and state.answer_preview.len > 0) {
        try printCodeWithHighlight(bottom_left, state.answer_preview, state.selected_language, state.code_scroll);
    } else {
        _ = try bottom_left.print(&.{.{ .text = "Answer Language", .style = .{ .bold = true } }}, .{
            .row_offset = 2,
            .col_offset = 1,
            .wrap = .none,
        });
        var lang_row: usize = 4;
        for (language_options, 0..) |_, idx| {
            if (lang_row >= bottom_left.height) break;
            const line = switch (idx) {
                0 => "1. Python",
                1 => "2. Golang",
                else => "3. C++",
            };
            const style: vaxis.Style = if (state.selected_language == idx and state.focus == .language_menu) cursor_highlight_style else .{};
            _ = try bottom_left.print(&.{.{ .text = line, .style = style }}, .{
                .row_offset = lang_row,
                .col_offset = 1,
                .wrap = .none,
            });
            lang_row += 1;
        }
        if (bottom_left.height > lang_row + 1) {
            _ = try bottom_left.print(&.{.{ .text = "Select language, then Enter to create file.", .style = .{ .dim = true } }}, .{
                .row_offset = lang_row + 1,
                .col_offset = 1,
                .wrap = .none,
            });
        }
    }
    _ = try bottom_right.print(&.{.{ .text = "Run [Enter]", .style = run_button_style }}, .{
        .row_offset = 0,
        .col_offset = 1,
        .wrap = .none,
    });
    _ = try bottom_right.print(&.{.{ .text = "PgUp/PgDn or j/k to scroll", .style = .{ .dim = true } }}, .{
        .row_offset = 1,
        .col_offset = 1,
        .wrap = .none,
    });
    if (state.run_output.len > 0 and bottom_right.height > 2) {
        try printRunOutput(bottom_right, state.run_output, 2, 1, state.run_scroll);
    } else if (state.status_message.len > 0 and bottom_right.height > 2) {
        _ = try bottom_right.print(&.{.{ .text = state.status_message }}, .{
            .row_offset = 2,
            .col_offset = 1,
            .wrap = .word,
        });
    }

    try vx.render(writer);
}

fn scrollStart(selected: usize, visible_rows: usize) usize {
    if (visible_rows == 0) return selected;
    const half = visible_rows / 2;
    if (selected <= half) return 0;
    return selected - half;
}

fn printCodeWithHighlight(window: vaxis.Window, code: []const u8, language: usize, scroll: usize) !void {
    var row: usize = 2;
    var lines = std.mem.splitScalar(u8, code, '\n');
    var skipped: usize = 0;
    while (lines.next()) |line| {
        if (skipped < scroll) {
            skipped += 1;
            continue;
        }
        if (row >= window.height) break;
        try printHighlightedLine(window, row, 1, line, language);
        row += 1;
    }
}

fn printHighlightedLine(window: vaxis.Window, row: usize, start_col: usize, line: []const u8, language: usize) !void {
    var col = start_col;
    var i: usize = 0;
    while (i < line.len and col < window.width) {
        // Comment tokens consume the rest of the line.
        if (isLineCommentStart(line[i..], language)) {
            const res = try window.print(&.{.{ .text = line[i..], .style = .{ .fg = .{ .index = 2 } } }}, .{
                .row_offset = row,
                .col_offset = col,
                .wrap = .none,
            });
            _ = res;
            break;
        }

        if (line[i] == '"' or line[i] == '\'') {
            const end = scanString(line, i);
            const token = line[i..end];
            const res = try window.print(&.{.{ .text = token, .style = .{ .fg = .{ .index = 3 } } }}, .{
                .row_offset = row,
                .col_offset = col,
                .wrap = .none,
            });
            col = res.col;
            if (res.overflow) break;
            i = end;
            continue;
        }

        if (isIdentStart(line[i])) {
            const end = scanIdent(line, i);
            const token = line[i..end];
            const style: vaxis.Style = if (isKeyword(language, token))
                .{ .fg = .{ .index = 6 }, .bold = true }
            else
                .{};
            const res = try window.print(&.{.{ .text = token, .style = style }}, .{
                .row_offset = row,
                .col_offset = col,
                .wrap = .none,
            });
            col = res.col;
            if (res.overflow) break;
            i = end;
            continue;
        }

        if (line[i] == '\t') {
            const res = try window.print(&.{.{ .text = "    " }}, .{
                .row_offset = row,
                .col_offset = col,
                .wrap = .none,
            });
            col = res.col;
            if (res.overflow) break;
            i += 1;
            continue;
        }

        const end = i + 1;
        const res = try window.print(&.{.{ .text = line[i..end] }}, .{
            .row_offset = row,
            .col_offset = col,
            .wrap = .none,
        });
        col = res.col;
        if (res.overflow) break;
        i = end;
    }
}

fn isLineCommentStart(s: []const u8, language: usize) bool {
    if (s.len == 0) return false;
    if (language == 0) return s[0] == '#'; // Python
    return s.len >= 2 and s[0] == '/' and s[1] == '/'; // Go/C++
}

fn scanString(line: []const u8, start: usize) usize {
    const quote = line[start];
    var i = start + 1;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            i += 1;
            continue;
        }
        if (line[i] == quote) return i + 1;
    }
    return line.len;
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

fn scanIdent(line: []const u8, start: usize) usize {
    var i = start;
    while (i < line.len and isIdentChar(line[i])) : (i += 1) {}
    return i;
}

fn isKeyword(language: usize, ident: []const u8) bool {
    const keywords = switch (language) {
        0 => &[_][]const u8{ "def", "class", "return", "if", "elif", "else", "for", "while", "in", "import", "from", "pass", "None", "True", "False" },
        1 => &[_][]const u8{ "func", "package", "import", "return", "if", "else", "for", "range", "switch", "case", "type", "struct", "var", "const", "nil" },
        else => &[_][]const u8{ "class", "public", "private", "protected", "return", "if", "else", "for", "while", "switch", "case", "const", "auto", "int", "void", "nullptr" },
    };
    for (keywords) |kw| {
        if (std.mem.eql(u8, kw, ident)) return true;
    }
    return false;
}

fn printRunOutput(window: vaxis.Window, text: []const u8, start_row: usize, col: usize, scroll: usize) !void {
    var row = start_row;
    var summary: ?[]const u8 = null;

    var scan = std.mem.splitScalar(u8, text, '\n');
    while (scan.next()) |raw_line| {
        const line = stripAnsi(raw_line);
        if (std.mem.startsWith(u8, line, "passed ")) {
            summary = line;
            break;
        }
    }

    if (summary) |line| {
        if (row < window.height) {
            const style = runLineStyle(line);
            _ = try window.print(&.{.{ .text = line, .style = style }}, .{
                .row_offset = row,
                .col_offset = col,
                .wrap = .none,
            });
        }
        row += 1;
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    var skipped: usize = 0;
    while (lines.next()) |raw_line| {
        const line = stripAnsi(raw_line);
        if (std.mem.startsWith(u8, line, "passed ")) continue;
        if (skipped < scroll) {
            skipped += 1;
            continue;
        }
        if (row >= window.height) break;
        const style = runLineStyle(line);
        _ = try window.print(&.{.{ .text = line, .style = style }}, .{
            .row_offset = row,
            .col_offset = col,
            .wrap = .none,
        });
        row += 1;
    }
}

fn runLineStyle(line: []const u8) vaxis.Style {
    if (std.mem.indexOf(u8, line, "[PASS]") != null) {
        return .{ .fg = .{ .index = 2 } };
    }
    if (std.mem.indexOf(u8, line, "[FAIL]") != null) {
        return .{ .fg = .{ .index = 1 } };
    }
    if (std.mem.startsWith(u8, line, "passed ")) {
        if (summaryAllPassed(line)) {
            return .{ .fg = .{ .index = 2 }, .bold = true };
        }
        return .{ .fg = .{ .index = 1 }, .bold = true };
    }
    return .{};
}

fn summaryAllPassed(line: []const u8) bool {
    // expected format: "passed X/Y"
    if (!std.mem.startsWith(u8, line, "passed ")) return false;
    const rest = line["passed ".len..];
    const slash_idx = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
    const left = std.mem.trim(u8, rest[0..slash_idx], " \t");
    const right = std.mem.trim(u8, rest[slash_idx + 1 ..], " \t");
    const l = std.fmt.parseUnsigned(usize, left, 10) catch return false;
    const r = std.fmt.parseUnsigned(usize, right, 10) catch return false;
    return r > 0 and l == r;
}

fn stripAnsi(s: []const u8) []const u8 {
    // simple removal of leading/trailing SGR reset sequences if present
    var out = s;
    if (std.mem.startsWith(u8, out, "\x1b[")) {
        if (std.mem.indexOfScalar(u8, out, 'm')) |m| {
            out = out[m + 1 ..];
        }
    }
    if (std.mem.endsWith(u8, out, "\x1b[0m")) {
        out = out[0 .. out.len - "\x1b[0m".len];
    }
    return out;
}

fn lineCount(text: []const u8) usize {
    if (text.len == 0) return 0;
    var count: usize = 1;
    for (text) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

fn maxLineScroll(text: []const u8) usize {
    const n = lineCount(text);
    if (n == 0) return 0;
    return n - 1;
}

fn sliceFromLine(text: []const u8, start_line: usize) []const u8 {
    if (start_line == 0) return text;
    var i: usize = 0;
    var lines: usize = 0;
    while (i < text.len and lines < start_line) : (i += 1) {
        if (text[i] == '\n') lines += 1;
    }
    if (i >= text.len) return "";
    return text[i..];
}

fn createAnswerFile(allocator: std.mem.Allocator, state: *const AppState) ![]const u8 {
    if (state.problems.len == 0) return error.NoProblems;
    const problem = state.problems[state.selected];
    const language = language_options[state.selected_language];
    const answer_path = try selectedAnswerPath(allocator, state);

    const existing = std.fs.cwd().access(answer_path, .{});
    if (existing) |_| {
        return try std.fmt.allocPrint(allocator, "Exists: {s}", .{answer_path});
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const template = switch (state.selected_language) {
        0 =>
        \\# Write your LeetCode Python solution here.
        \\class Solution:
        \\    pass
        \\
        ,
        1 => goTemplateForProblem(problem),
        else =>
        \\// Write your LeetCode C++ solution here.
        \\class Solution {
        \\public:
        \\};
        \\
        ,
    };

    try std.fs.cwd().writeFile(.{
        .sub_path = answer_path,
        .data = template,
    });
    return try std.fmt.allocPrint(allocator, "Created {s} ({s})", .{ answer_path, language });
}

fn runSelectedInput(allocator: std.mem.Allocator, state: *const AppState) ![]const u8 {
    if (state.problems.len == 0) return error.NoProblems;
    const problem = state.problems[state.selected];

    switch (state.selected_language) {
        1 => {},
        0 => return try std.fmt.allocPrint(allocator, "Run not supported for Python yet.", .{}),
        else => return try std.fmt.allocPrint(allocator, "Run not supported for C++ yet.", .{}),
    }

    const last_slash = std.mem.lastIndexOfScalar(u8, problem.path, '/') orelse return error.InvalidProblemPath;
    const folder = problem.path[0..last_slash];

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "go", "run", "run.go", "input.go", "key.go" },
        .cwd = folder,
        .max_output_bytes = 1024 * 1024,
    });

    const term_ok = switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };

    if (term_ok) {
        if (result.stdout.len > 0) {
            return try std.fmt.allocPrint(allocator, "Run OK\n{s}", .{result.stdout});
        }
        return try std.fmt.allocPrint(allocator, "Run OK", .{});
    }
    if (result.stderr.len > 0) {
        return try std.fmt.allocPrint(allocator, "Run Failed\n{s}", .{result.stderr});
    }
    return try std.fmt.allocPrint(allocator, "Run Failed", .{});
}

fn goTemplateForProblem(problem: Problem) []const u8 {
    const slug = extractProblemSlug(problem.url) orelse "";
    if (std.mem.eql(u8, slug, "reverse-linked-list")) {
        return
            \\package main
            \\
            \\// ListNode is the standard LeetCode singly-linked list node.
            \\type ListNode struct {
            \\	Val  int
            \\	Next *ListNode
            \\}
            \\
            \\// Write your LeetCode Go solution here.
            \\
        ;
    }
    if (std.mem.eql(u8, slug, "binary-tree-inorder-traversal")) {
        return
            \\package main
            \\
            \\// TreeNode is the standard LeetCode binary tree node.
            \\type TreeNode struct {
            \\	Val   int
            \\	Left  *TreeNode
            \\	Right *TreeNode
            \\}
            \\
            \\// Write your LeetCode Go solution here.
            \\
        ;
    }
    return
        \\package main
        \\
        \\// Write your LeetCode Go solution here.
        \\
    ;
}

fn refreshAnswerPreview(allocator: std.mem.Allocator, state: *AppState) !void {
    state.answer_preview = "";
    state.answer_preview_path = "";
    state.run_output = "";
    state.code_scroll = 0;
    state.run_scroll = 0;
    if (state.problems.len == 0) return;

    const answer_path = selectedAnswerPath(allocator, state) catch return;
    state.answer_preview_path = answer_path;
    const content = std.fs.cwd().readFileAlloc(allocator, answer_path, 2 * 1024 * 1024) catch return;
    state.answer_preview = content;
}

fn clearAnswerPreview(state: *AppState) void {
    state.answer_open = false;
    state.answer_preview = "";
    state.answer_preview_path = "";
    state.run_output = "";
    state.status_message = "";
    state.code_scroll = 0;
    state.run_scroll = 0;
}

fn selectedAnswerPath(allocator: std.mem.Allocator, state: *const AppState) ![]const u8 {
    if (state.problems.len == 0) return error.NoProblems;
    const problem = state.problems[state.selected];
    if (problem.path.len == 0) return error.InvalidProblemPath;

    const answer_file = switch (state.selected_language) {
        0 => "input.py",
        1 => "input.go",
        else => "input.cpp",
    };

    const last_slash = std.mem.lastIndexOfScalar(u8, problem.path, '/') orelse return error.InvalidProblemPath;
    const folder = problem.path[0..last_slash];
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ folder, answer_file });
}

fn loadProblems(allocator: std.mem.Allocator) ![]const Problem {
    var list = std.ArrayList(Problem).init(allocator);
    var dir = std.fs.cwd().openDir("problems", .{ .iterate = true }) catch {
        return &.{.{
            .title = "No problems found",
            .url = "",
            .path = "",
            .markdown = "No problems found. Create markdown files in problems/.",
        }};
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;

        const path = try std.fmt.allocPrint(allocator, "problems/{s}/problem.md", .{entry.name});
        const markdown = std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024) catch continue;
        try list.append(parseProblemMarkdown(markdown, entry.name, path));
    }

    std.mem.sort(Problem, list.items, {}, problemLessThan);

    if (list.items.len == 0) {
        try list.append(.{
            .title = "No problems found",
            .url = "",
            .path = "",
            .markdown = "No problems found. Create markdown files in problems/.",
        });
    }
    return try list.toOwnedSlice();
}

fn parseProblemMarkdown(markdown: []const u8, file_name: []const u8, path: []const u8) Problem {
    var title: []const u8 = "";
    var url: []const u8 = "";

    var lines = std.mem.splitScalar(u8, markdown, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "# ")) {
            title = std.mem.trim(u8, line[2..], " \t");
            continue;
        }
        if (std.mem.startsWith(u8, line, "URL: ")) {
            url = std.mem.trim(u8, line[5..], " \t");
            continue;
        }
        if (std.mem.startsWith(u8, line, "Link: ")) {
            url = std.mem.trim(u8, line[6..], " \t");
            continue;
        }
        if (std.mem.startsWith(u8, line, "https://leetcode.com/problems/")) {
            url = line;
            continue;
        }
    }

    if (title.len == 0) title = fileNameToTitle(file_name);
    return .{
        .title = title,
        .url = url,
        .path = path,
        .markdown = markdown,
    };
}

fn fileNameToTitle(file_name: []const u8) []const u8 {
    var stem = file_name;
    if (std.mem.endsWith(u8, stem, ".md")) {
        stem = stem[0 .. stem.len - 3];
    }
    return stem;
}

fn problemLessThan(_: void, a: Problem, b: Problem) bool {
    return std.ascii.lessThanIgnoreCase(a.title, b.title);
}

fn hydrateProblems(allocator: std.mem.Allocator, problems: []const Problem) !void {
    for (problems) |problem| {
        if (problem.url.len == 0 or problem.path.len == 0) continue;
        const body = fetchProblemMarkdown(allocator, problem) catch |err| {
            std.log.warn("failed to hydrate {s}: {s}", .{ problem.title, @errorName(err) });
            continue;
        };
        const file_contents = try std.fmt.allocPrint(
            allocator,
            "# {s}\n\nURL: {s}\n\n{s}\n",
            .{ problem.title, problem.url, body },
        );
        try std.fs.cwd().writeFile(.{
            .sub_path = problem.path,
            .data = file_contents,
        });
    }
}

fn fetchProblemMarkdown(allocator: std.mem.Allocator, problem: Problem) ![]const u8 {
    if (problem.url.len == 0) return error.MissingUrl;
    const slug = extractProblemSlug(problem.url) orelse return error.InvalidProblemUrl;

    const query_body = try std.fmt.allocPrint(
        allocator,
        \\{{"query":"query questionData($titleSlug: String!) {{ question(titleSlug: $titleSlug) {{ content }} }}","variables":{{"titleSlug":"{s}"}}}}
    ,
        .{slug},
    );

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var response = std.ArrayList(u8).init(allocator);
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "origin", .value = "https://leetcode.com" },
        .{ .name = "referer", .value = problem.url },
        .{ .name = "user-agent", .value = "leetcli" },
    };

    const result = try client.fetch(.{
        .location = .{ .url = "https://leetcode.com/graphql" },
        .method = .POST,
        .payload = query_body,
        .response_storage = .{ .dynamic = &response },
        .extra_headers = &headers,
        .max_append_size = 4 * 1024 * 1024,
    });

    if (result.status != .ok) return error.HttpRequestFailed;

    const html = try extractJsonStringField(allocator, response.items, "content");
    return try htmlToMarkdown(allocator, html);
}

fn extractProblemSlug(url: []const u8) ?[]const u8 {
    const marker = "/problems/";
    const marker_idx = std.mem.indexOf(u8, url, marker) orelse return null;

    var slug = url[marker_idx + marker.len ..];
    slug = std.mem.trimRight(u8, slug, "/");

    if (std.mem.indexOfScalar(u8, slug, '/')) |slash| {
        slug = slug[0..slash];
    }

    if (slug.len == 0) return null;
    return slug;
}

fn extractJsonStringField(allocator: std.mem.Allocator, body: []const u8, field: []const u8) ![]const u8 {
    const pattern = try std.fmt.allocPrint(allocator, "\"{s}\":", .{field});
    const start = std.mem.indexOf(u8, body, pattern) orelse return error.FieldNotFound;

    var i = start + pattern.len;
    while (i < body.len and std.ascii.isWhitespace(body[i])) : (i += 1) {}
    if (i >= body.len) return error.FieldNotFound;
    if (std.mem.startsWith(u8, body[i..], "null")) return error.FieldNotFound;
    if (body[i] != '"') return error.InvalidJson;
    i += 1;

    var out = std.ArrayList(u8).init(allocator);
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (c == '"') return try out.toOwnedSlice();
        if (c != '\\') {
            try out.append(c);
            continue;
        }

        i += 1;
        if (i >= body.len) return error.InvalidJson;
        switch (body[i]) {
            '"', '\\', '/' => try out.append(body[i]),
            'b' => try out.append('\x08'),
            'f' => try out.append('\x0C'),
            'n' => try out.append('\n'),
            'r' => try out.append('\r'),
            't' => try out.append('\t'),
            'u' => {
                if (i + 4 >= body.len) return error.InvalidJson;
                const codepoint = try std.fmt.parseUnsigned(u21, body[i + 1 .. i + 5], 16);
                var utf8: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(codepoint, &utf8);
                try out.appendSlice(utf8[0..len]);
                i += 4;
            },
            else => return error.InvalidJson,
        }
    }

    return error.InvalidJson;
}

fn htmlToMarkdown(allocator: std.mem.Allocator, html: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(allocator);
    var in_pre = false;

    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            const close_rel = std.mem.indexOfScalar(u8, html[i..], '>') orelse break;
            const close = i + close_rel;
            try appendTagMarkdown(&out, html[i + 1 .. close], &in_pre);
            i = close + 1;
            continue;
        }

        const next_tag_rel = std.mem.indexOfScalar(u8, html[i..], '<') orelse (html.len - i);
        try appendDecodedHtml(&out, html[i .. i + next_tag_rel], in_pre);
        i += next_tag_rel;
    }

    return try out.toOwnedSlice();
}

fn appendTagMarkdown(out: *std.ArrayList(u8), raw_tag: []const u8, in_pre: *bool) !void {
    var tag = std.mem.trim(u8, raw_tag, " \t\r\n");
    if (tag.len == 0) return;
    if (tag[0] == '!' or tag[0] == '?') return;

    var closing = false;
    if (tag[0] == '/') {
        closing = true;
        tag = std.mem.trimLeft(u8, tag[1..], " \t");
        if (tag.len == 0) return;
    }

    if (std.mem.indexOfAny(u8, tag, " \t/")) |idx| tag = tag[0..idx];

    if (std.mem.eql(u8, tag, "br")) {
        try out.append('\n');
        return;
    }
    if (std.mem.eql(u8, tag, "p")) {
        if (closing) try out.appendSlice("\n\n");
        return;
    }
    if (std.mem.eql(u8, tag, "li")) {
        if (!closing) {
            try out.appendSlice("\n- ");
        } else {
            try out.append('\n');
        }
        return;
    }
    if (std.mem.eql(u8, tag, "pre")) {
        if (!closing and !in_pre.*) {
            in_pre.* = true;
            try out.appendSlice("\n```text\n");
        } else if (closing and in_pre.*) {
            in_pre.* = false;
            try out.appendSlice("\n```\n");
        }
        return;
    }
    if (std.mem.eql(u8, tag, "code")) {
        try out.append('`');
        return;
    }
    if (std.mem.eql(u8, tag, "strong") or std.mem.eql(u8, tag, "b")) {
        try out.appendSlice("**");
        return;
    }
    if (std.mem.eql(u8, tag, "em") or std.mem.eql(u8, tag, "i")) {
        try out.append('*');
        return;
    }
    if (tag.len == 2 and tag[0] == 'h' and tag[1] >= '1' and tag[1] <= '6') {
        if (!closing) {
            const level: usize = @intCast(tag[1] - '0');
            var n: usize = 0;
            try out.append('\n');
            while (n < level) : (n += 1) try out.append('#');
            try out.append(' ');
        } else {
            try out.appendSlice("\n\n");
        }
    }
}

fn appendDecodedHtml(out: *std.ArrayList(u8), text: []const u8, in_pre: bool) !void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '&') {
            const end_rel = std.mem.indexOfScalar(u8, text[i..], ';') orelse {
                try out.append(c);
                i += 1;
                continue;
            };
            const entity = text[i + 1 .. i + end_rel];
            if (decodeEntity(entity)) |decoded| {
                try out.appendSlice(decoded);
                i += end_rel + 1;
                continue;
            }
            try out.append(c);
            i += 1;
            continue;
        }

        if (!in_pre and std.ascii.isWhitespace(c)) {
            if (out.items.len == 0 or out.items[out.items.len - 1] == ' ' or out.items[out.items.len - 1] == '\n') {
                i += 1;
                continue;
            }
            try out.append(' ');
            i += 1;
            continue;
        }

        try out.append(c);
        i += 1;
    }
}

fn decodeEntity(entity: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, entity, "amp")) return "&";
    if (std.mem.eql(u8, entity, "lt")) return "<";
    if (std.mem.eql(u8, entity, "gt")) return ">";
    if (std.mem.eql(u8, entity, "quot")) return "\"";
    if (std.mem.eql(u8, entity, "nbsp")) return " ";
    if (std.mem.eql(u8, entity, "#39")) return "'";
    return null;
}
