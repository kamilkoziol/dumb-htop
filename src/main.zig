const std = @import("std");

// const Ansi = enum {
//     reset,
//     clear,
//     red,
//     green,
//     yellow,
//     cyan,
//
//     pub fn format(self: Ansi, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
//         try writer.writeAll(switch (self) {
//             .reset  => "\x1b[0m",
//             .clear  => "\x1b[2J\x1b[H",
//             .red    => "\x1b[31m",
//             .green  => "\x1b[32m",
//             .yellow => "\x1b[33m",
//             .cyan   => "\x1b[36m",
//         });
//     }
// };

const IDLE_INDEX = 3;
const IOWAIT_INDEX = 4;

const ThreadTimes = struct {
    busy: u32,
    idle: u32,
};

fn readProc(alloc: std.mem.Allocator, io: std.Io) !std.StringHashMap(ThreadTimes) {
    const f = std.Io.Dir.openFileAbsolute(io, "/proc/stat", .{ .mode = .read_only }) catch |err| {
        std.debug.print("error open {any}", .{err});
        return err;
    };
    defer f.close(io);

    const file_buffer: []u8 = try alloc.alloc(u8, 1024 * 1024);
    defer alloc.free(file_buffer);

    var file_reader = f.reader(io, file_buffer);

    var map: std.StringHashMap(ThreadTimes) = .init(alloc);

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
        const owned_key = try alloc.dupe(u8, key);
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
        try map.put(owned_key, .{ .idle = idle, .busy = busy });
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

fn cleanupMap(map: *std.StringHashMap(ThreadTimes), alloc: std.mem.Allocator) void {
    var keyIterator = map.keyIterator();
    while (keyIterator.next()) |key| {
        alloc.free(key.*);
    }
    map.deinit();
}

fn visualizeData(io: std.Io, prev: std.StringHashMap(ThreadTimes), current: std.StringHashMap(ThreadTimes)) void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var keyIterator = current.keyIterator();
    while (keyIterator.next()) |key| {
        const currentValue = current.get(key.*).?;
        const prevValue = prev.get(key.*).?;
        printBar(key.*, prevValue, currentValue, stdout);
    }
    stdout.flush() catch unreachable;
}

fn printBar(key: []const u8, prev: ThreadTimes, current: ThreadTimes, stdout: *std.Io.Writer) void {
    const busy: f32 = @floatFromInt(current.busy - prev.busy);
    const idle: f32 = @floatFromInt(current.idle - prev.idle);
    const total = busy + idle;
    const percentage = busy / total * 100;

    const barCharacter = '|';
    const emptyCharacter = ' ';

    const barLength: u8 = 10;
    const filled: u8 = @intFromFloat(busy / total * barLength);

    var bar: [barLength]u8 = undefined;
    @memset(bar[0..filled], barCharacter);
    @memset(bar[filled..], emptyCharacter);

    stdout.print("{s}[{s}] {d:.1}%\n", .{ key[3..], bar, percentage }) catch unreachable;

    return;
}

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var prev: ?std.StringHashMap(ThreadTimes) = null;
    var current = try readProc(alloc, init.io);
    defer {
        cleanupMap(&current, alloc);
        if (prev) |*p| cleanupMap(p, alloc);
    }
    while (true) {
        try std.Io.sleep(init.io, std.Io.Duration.fromSeconds(1), std.Io.Clock.real);
        if (prev) |*p| cleanupMap(p, alloc);
        prev = current;
        current = try readProc(alloc, init.io);
        visualizeData(init.io, prev.?, current);
    }
}
