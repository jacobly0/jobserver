pub fn main() !void {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const args = try std.process.argsAlloc(arena);
    const proc_num_str = args[1];
    const proc_num = try std.fmt.parseInt(usize, proc_num_str, 10);

    var client: Client = try .init();
    defer client.deinit();

    // Give threads a variable work time, 400--800ms.
    var rng: std.Random.DefaultPrng = .init(0);
    const r = rng.random();
    const work_ms_0 = r.intRangeAtMost(u32, 400, 800);
    const work_ms_1 = r.intRangeAtMost(u32, 400, 800);
    const work_ms_2 = r.intRangeAtMost(u32, 400, 800);
    const work_ms_3 = r.intRangeAtMost(u32, 400, 800);

    const t0 = try std.Thread.spawn(.{}, workerThread, .{ &client, proc_num, 0, work_ms_0 });
    defer t0.join();

    const t1 = try std.Thread.spawn(.{}, workerThread, .{ &client, proc_num, 1, work_ms_1 });
    defer t1.join();

    const t2 = try std.Thread.spawn(.{}, workerThread, .{ &client, proc_num, 2, work_ms_2 });
    defer t2.join();

    const t3 = try std.Thread.spawn(.{}, workerThread, .{ &client, proc_num, 3, work_ms_3 });
    defer t3.join();
}

fn workerThread(client: *Client, proc_num: usize, thread_num: usize, work_ms: u32) !void {
    const permit = try client.acquire();
    defer permit.release();

    std.log.info("start {d}:{d}", .{ proc_num, thread_num });
    defer std.log.info("stop {d}:{d}", .{ proc_num, thread_num });

    // All the threads do work for some amount of time...
    std.Thread.sleep(std.time.ns_per_ms * work_ms);

    if (thread_num == 3) {
        // But the code running on thread 3 ends up crashing!
        std.log.info("CRASH {d}", .{proc_num});
        std.posix.exit(1);
    }
}

const Client = @import("jobserver.zig").Client;
const std = @import("std");
