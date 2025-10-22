pub const Server = switch (builtin.os.tag) {
    else => struct {
        sem_id: c_int,

        pub fn init(num_tokens: usize, env_map: *std.process.EnvMap) !@This() {
            const sem_id = createSemaphore();
            setSemaphore(sem_id, @intCast(num_tokens));
            var buf: [std.fmt.count("{d}", .{std.math.maxInt(c_int)})]u8 = undefined;
            try env_map.put(
                "JOBSERVER_SEMID",
                std.fmt.bufPrint(&buf, "{d}", .{sem_id}) catch unreachable,
            );
            return .{ .sem_id = sem_id };
        }

        pub fn deinit(server: *@This()) void {
            server.* = undefined;
        }

        /// `semget(IPC_PRIVATE, 1, 0o777)`
        fn createSemaphore() c_int {
            const IPC_PRIVATE = 0;
            const res = std.os.linux.syscall3(.semget, IPC_PRIVATE, 1, 0o777);
            switch (std.posix.errno(res)) {
                .SUCCESS => {},
                else => |e| std.process.fatal("semget failed: {t}", .{e}),
            }
            return @intCast(res);
        }

        /// `semctl(sem_id, 0, SETVAL, n)`
        fn setSemaphore(sem_id: c_int, n: c_ulong) void {
            const SETVAL = 16;
            const res = std.os.linux.syscall4(.semctl, @intCast(sem_id), 0, SETVAL, n);
            switch (std.posix.errno(res)) {
                .SUCCESS => {},
                else => |e| std.process.fatal("semctl failed: {t}", .{e}),
            }
        }
    },
    .windows => struct {
        named_pipe_handle: windows.HANDLE,

        var pipe_name_counter = std.atomic.Value(u32).init(1);

        pub fn init(num_tokens: usize, env_map: *std.process.EnvMap) !@This() {
            var tmp_buf: [128]u8 = undefined;
            // Forge a random path for the pipe.
            const pipe_path = std.fmt.bufPrintSentinel(
                &tmp_buf,
                "\\\\.\\pipe\\zig-jobserver-{d}-{d}",
                .{ windows.GetCurrentProcessId(), pipe_name_counter.fetchAdd(1, .monotonic) },
                0,
            ) catch unreachable;

            var tmp_bufw: [128]u16 = undefined;

            // Anonymous pipes are built upon Named pipes.
            // https://docs.microsoft.com/en-us/windows/win32/api/namedpipeapi/nf-namedpipeapi-createpipe
            // Asynchronous (overlapped) read and write operations are not supported by anonymous pipes.
            // https://docs.microsoft.com/en-us/windows/win32/ipc/anonymous-pipe-operations
            const len = std.unicode.wtf8ToWtf16Le(&tmp_bufw, pipe_path) catch unreachable;
            tmp_bufw[len] = 0;
            const pipe_path_w = tmp_bufw[0..len :0];

            const named_pipe_handle = windows.kernel32.CreateNamedPipeW(
                pipe_path_w.ptr,
                windows.PIPE_ACCESS_INBOUND | windows.FILE_FLAG_OVERLAPPED,
                windows.PIPE_TYPE_BYTE,
                @intCast(num_tokens),
                0,
                0,
                0,
                null,
            );
            if (named_pipe_handle == windows.INVALID_HANDLE_VALUE) {
                switch (windows.GetLastError()) {
                    else => |err| return windows.unexpectedError(err),
                }
            }
            try env_map.put("JOBSERVER_NAMEDPIPE", pipe_path);
            return .{ .named_pipe_handle = named_pipe_handle };
        }

        pub fn deinit(server: *@This()) void {
            windows.CloseHandle(server.named_pipe_handle);
            server.* = undefined;
        }
    },
};

pub const Client = switch (builtin.os.tag) {
    else => struct {
        sem_id: c_int,

        pub const Permit = struct {
            sem_id: c_int,

            pub fn release(permit: @This()) void {
                modifySemaphore(permit.sem_id, 1);
            }
        };

        pub fn init() !@This() {
            return .{
                .sem_id = try std.fmt.parseInt(
                    c_int,
                    posix.getenv("JOBSERVER_SEMID") orelse return error.NoJobServer,
                    10,
                ),
            };
        }

        pub fn deinit(client: *@This()) void {
            client.* = undefined;
        }

        pub fn acquire(client: @This()) !Permit {
            modifySemaphore(client.sem_id, -1);
            return .{ .sem_id = client.sem_id };
        }

        /// `semop(sem_id, &.{.{ .sem_num = 0, .sem_op = delta, .sem_flg = SEM_UNDO }})`
        fn modifySemaphore(id: c_int, delta: c_short) void {
            // Defined by Linux in `include/uapi/linux/sem.h`.
            const sembuf = extern struct {
                sem_num: c_ushort,
                sem_op: c_short,
                sem_flg: c_short,
            };
            const SEM_UNDO = 0x1000;
            var buf: sembuf = .{
                .sem_num = 0,
                .sem_op = delta,
                .sem_flg = SEM_UNDO,
            };
            const res = std.os.linux.syscall3(.semop, @intCast(id), @intFromPtr(&buf), 1);
            switch (std.posix.errno(res)) {
                .SUCCESS => {},
                else => |e| std.process.fatal("semop failed: {t}", .{e}),
            }
        }
    },
    .windows => struct {
        pub const Permit = struct {
            named_pipe_handle: windows.HANDLE,

            pub fn release(permit: @This()) void {
                windows.CloseHandle(permit.named_pipe_handle);
            }
        };

        pub fn init() !@This() {
            return .{};
        }

        pub fn deinit(client: *Client) void {
            client.* = undefined;
        }

        pub fn acquire(_: Client) !Permit {
            return .{
                .named_pipe_handle = try windows.OpenFile(
                    std.process.getenvW(
                        std.unicode.wtf8ToWtf16LeStringLiteral("JOBSERVER_NAMEDPIPE"),
                    ) orelse return error.NoJobServer,
                    .{ .access_mask = 0, .creation = windows.FILE_OPEN },
                ),
            };
        }
    },
};

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const windows = std.os.windows;
