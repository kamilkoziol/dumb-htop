const std = @import("std");

const Ansi = enum {
    reset,
    clear,
    red,
    green,
    yellow,
    cyan,
    altOn,
    altOff,

    pub fn format(self: Ansi, writer: *std.Io.Writer) !void {
        try writer.writeAll(switch (self) {
            .reset => "\x1b[0m",
            .clear => "\x1b[2J\x1b[H",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .cyan => "\x1b[36m",
            .altOn => "\x1b[?1049h",
            .altOff => "\x1b[?1049l",
        });
    }
};

const IDLE_INDEX = 3;
const IOWAIT_INDEX = 4;

const ThreadTimes = struct {
    busy: u32,
    idle: u32,
};

const TerminalSize = struct {
    width: u16,
    height: u16,
};

fn getTerminalSize() TerminalSize {
    var winSize: std.posix.winsize = undefined;
    const ret = std.os.linux.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&winSize));
    const err = std.os.linux.errno(ret);
    const size = switch (err) {
        .SUCCESS => TerminalSize{ .height = winSize.row, .width = winSize.col },
        else => TerminalSize{ .height = 30, .width = 40 },
    };

    return size;
}
fn readProc(alloc: std.mem.Allocator, io: std.Io) !std.AutoHashMap(u16, ThreadTimes) {
    const f = std.Io.Dir.openFileAbsolute(io, "/proc/stat", .{ .mode = .read_only }) catch |err| {
        std.debug.print("error open {any}", .{err});
        return err;
    };
    defer f.close(io);

    const file_buffer: []u8 = try alloc.alloc(u8, 1024 * 1024);
    defer alloc.free(file_buffer);

    var file_reader = f.reader(io, file_buffer);

    var map: std.AutoHashMap(u16, ThreadTimes) = .init(alloc);

    while (file_reader.interface.takeDelimiterExclusive('\n')) |line| {
        file_reader.interface.toss(1);
        if (!std.mem.startsWith(u8, line, "cpu")) {
            continue;
        }
        if (line.len < 4) {
            continue;
        }
        if (line[3] == ' ') {
            continue;
        }

        var iter = std.mem.splitSequence(u8, line, " ");
        var i: i32 = 0;

        var busy: u32 = 0;
        var idle: u32 = 0;

        const key = iter.next() orelse {
            continue;
        };
        const threadNumber = try std.fmt.parseUnsigned(u16, key[3..], 10);
        while (iter.next()) |val| : (i += 1) {
            const int_val = std.fmt.parseUnsigned(u32, val, 10) catch |err| {
                std.debug.print("parseint error: {any} value :>>{s}<<\n", .{ err, val });
                continue;
            };
            if (i == IDLE_INDEX or i == IOWAIT_INDEX) {
                idle += int_val;
            } else {
                busy += int_val;
            }
        }
        try map.put(threadNumber, .{ .idle = idle, .busy = busy });
    } else |err| {
        switch (err) {
            error.EndOfStream => {},
            error.ReadFailed, error.StreamTooLong => {
                return err;
            },
        }
    }
    return map;
}

fn cleanupMap(map: *std.AutoHashMap(u16, ThreadTimes)) void {
    map.deinit();
}

fn visualizeData(writer: *std.Io.Writer, prev: std.AutoHashMap(u16, ThreadTimes), current: std.AutoHashMap(u16, ThreadTimes)) void {
    var i: u16 = 0;
    while (i < current.count()) : (i += 1) {
        const currentValue = current.get(i);
        const prevValue = prev.get(i);
        printBar(i, prevValue, currentValue, writer);
    }
}

fn printBar(key: u16, prev: ?ThreadTimes, current: ?ThreadTimes, stdout: *std.Io.Writer) void {
    const prevValue = prev orelse return;
    const currentValue = current orelse return;
    const busy: f32 = @floatFromInt(currentValue.busy - prevValue.busy);
    const idle: f32 = @floatFromInt(currentValue.idle - prevValue.idle);
    const total = busy + idle;
    const percentage = busy / total * 100;

    const barCharacter = '|';
    const emptyCharacter = ' ';

    const barLength: u8 = 50;
    const filled: u8 = @intFromFloat(busy / total * barLength);

    var bar: [barLength]u8 = undefined;
    @memset(bar[0..filled], barCharacter);
    @memset(bar[filled..], emptyCharacter);

    stdout.print("{d}[{s}] {d:.1}%\n", .{ key, bar, percentage }) catch unreachable;

    return;
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    var prev: ?std.AutoHashMap(u16, ThreadTimes) = null;
    var current = try readProc(alloc, init.io);
    defer {
        cleanupMap(&current);
        if (prev) |*p| cleanupMap(p);
    }

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    stdout.print("{f}", .{Ansi.altOn});

    while (true) {
        try std.Io.sleep(init.io, std.Io.Duration.fromSeconds(1), std.Io.Clock.real);
        if (prev) |*p| cleanupMap(p);
        prev = current;
        current = try readProc(alloc, init.io);
        visualizeData(stdout, prev.?, current);
        try stdout.flush();
    }
}
