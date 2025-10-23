pub fn main() !void {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const num_tokens = 2; // for a simple example. in reality, set this to the core count or something.

    var env = try std.process.getEnvMap(arena);
    var server: Server = try .init(num_tokens, &env);
    defer server.deinit();

    const t0 = try std.Thread.spawn(.{}, Server.run, .{&server});
    defer t0.join();

    var children: [1]std.process.Child = undefined;
    for (&children, 0..) |*c, child_num| {
        const child_num_str = try std.fmt.allocPrint(arena, "{d}", .{child_num});
        const argv = try arena.dupe([]const u8, &.{ switch (builtin.os.tag) {
            else => "./worker",
            .windows => ".\\worker.exe",
        }, child_num_str });
        c.* = .init(argv, arena);
        c.env_map = &env;
    }

    std.log.info("Spawning {d} workers ({d} available job tokens)", .{ children.len, num_tokens });
    for (&children) |*c| try c.spawn();
    for (&children) |*c| _ = try c.wait();
    std.log.info("All {d} workers exited", .{children.len});
}

const builtin = @import("builtin");
const Server = @import("jobserver.zig").Server;
const std = @import("std");
const windows = std.os.windows;

// pub extern "kernel32" fn CreateNamedPipe(
//     windows.LPCWSTR,
//     u32,
//     u32,
//     u32,
//     u32,
//     u32,
//     u32,
//     ?*windows.SECURITY_ATTRIBUTES,
// ) callconv(.winapi) windows.HANDLE;

pub extern "kernel32" fn ConnectNamedPipe(
    windows.HANDLE,
    ?*windows.OVERLAPPED,
) callconv(.winapi) windows.BOOL;

fn serverThread(server: *Server) void {
    if (ConnectNamedPipe(server.named_pipe_handle, null) == 0) {
        std.debug.print("{t}\n", .{windows.GetLastError()});
    }
}
