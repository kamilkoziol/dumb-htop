const std = @import("std");

const IDLE_INDEX = 4;
const IOWAIT_INDEX = 5;

const ThreadTimes = struct {
    total: u32,
    idle: u32,
};

fn getThreadTimes(line: []u8) !ThreadTimes {
    var total: u32 = 0;
    var idle: u32 = 0;

    var iter = std.mem.splitSequence(u8, line, " ");
    var i: i32 = 0;
    std.debug.print("line :{s}", .{line});
    while (iter.next()) |val| : (i += 1) {
        if (i == 0) {
            continue;
        }
        const int_val = std.fmt.parseUnsigned(u32, val, 10) catch |err| {
            std.debug.print("parseint error: {any} value :>>{s}<<\n", .{ err, val });
            continue;
        };
        if (i == IDLE_INDEX or i == IOWAIT_INDEX) {
            idle += int_val;
        }
        total += int_val;
    }
    const ret = ThreadTimes{ .total = total, .idle = idle };
    return ret;
}

fn getThreadNum() !u8 {
    const f = std.fs.openFileAbsolute("/proc/stat", .{ .mode = .read_only }) catch |err| {
        std.debug.print("error open {any}", .{err});
        return err;
    };
    defer f.close();

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();
    const file_buffer: []u8 = try alloc.alloc(u8, 1024 * 1024);
    defer alloc.free(file_buffer);

    var file_reader = f.reader(file_buffer);

    var count: u8 = 0;

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
        count += 1;
    } else |err| {
        switch (err) {
            error.EndOfStream => {},
            error.ReadFailed, error.StreamTooLong => {
                return err;
            },
        }
    }
    return count;
}

fn readProc(alloc: std.mem.Allocator, map: *std.StringHashMap(ThreadTimes)) !void {
    const f = std.fs.openFileAbsolute("/proc/stat", .{ .mode = .read_only }) catch |err| {
        std.debug.print("error open {any}", .{err});
        return err;
    };
    defer f.close();

    const file_buffer: []u8 = try alloc.alloc(u8, 1024 * 1024);
    defer alloc.free(file_buffer);

    var file_reader = f.reader(file_buffer);

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

        var total: u32 = 0;
        var idle: u32 = 0;

        const key = iter.next() orelse {
            continue;
        };
        while (iter.next()) |val| : (i += 1) {
            if (i == 0) {
                continue;
            }
            const int_val = std.fmt.parseUnsigned(u32, val, 10) catch |err| {
                std.debug.print("parseint error: {any} value :>>{s}<<\n", .{ err, val });
                continue;
            };
            if (i == IDLE_INDEX or i == IOWAIT_INDEX) {
                idle += int_val;
            }
            total += int_val;
        }
        try map.put(key, .{ .idle = idle, .total = total });
    } else |err| {
        switch (err) {
            error.EndOfStream => {},
            error.ReadFailed, error.StreamTooLong => {
                return err;
            },
        }
    }
    return;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var current: std.StringHashMap(ThreadTimes) = .init(alloc);
    _ = try readProc(alloc, &current);
    std.debug.print("map: {any}", .{current});
}
