pub const Server = switch (builtin.os.tag) {
    else => struct {
        sem_id: c_int,

        pub fn init(num_tokens: usize, env_map: *std.process.EnvMap) !Server {
            const sem_id = createSemaphore();
            setSemaphore(sem_id, @intCast(num_tokens));
            var buf: [std.fmt.count("{d}", .{std.math.maxInt(c_int)})]u8 = undefined;
            try env_map.put(
                "JOBSERVER_SEMID",
                std.fmt.bufPrint(&buf, "{d}", .{sem_id}) catch unreachable,
            );
            return .{ .sem_id = sem_id };
        }

        pub fn deinit(server: *Server) void {
            server.* = undefined;
        }

        pub fn spawn(_: *Server) !std.Thread {
            return undefined;
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
        path_buf: [windows.PATH_MAX_WIDE]u16,
        num_tokens: usize,

        var pipe_name_counter = std.atomic.Value(u32).init(1);

        pub fn init(num_tokens: usize, env_map: *std.process.EnvMap) !Server {
            var tmp_buf: [128]u8 = undefined;
            // Forge a random path for the pipe.
            const pipe_path = std.fmt.bufPrintSentinel(
                &tmp_buf,
                "\\\\.\\pipe\\zig-jobserver-{d}-{d}",
                .{ windows.GetCurrentProcessId(), pipe_name_counter.fetchAdd(1, .monotonic) },
                0,
            ) catch unreachable;

            try env_map.put("JOBSERVER_NAMEDPIPE", pipe_path);

            // Anonymous pipes are built upon Named pipes.
            // https://docs.microsoft.com/en-us/windows/win32/api/namedpipeapi/nf-namedpipeapi-createpipe
            // Asynchronous (overlapped) read and write operations are not supported by anonymous pipes.
            // https://docs.microsoft.com/en-us/windows/win32/ipc/anonymous-pipe-operations
            var server: Server = .{
                .path_buf = undefined,
                .num_tokens = num_tokens,
            };
            const len = std.unicode.wtf8ToWtf16Le(&server.path_buf, pipe_path) catch unreachable;
            server.path_buf[len] = 0;
            return server;
        }

        pub fn deinit(server: *Server) void {
            server.* = undefined;
        }

        pub fn spawn(server: *Server) !std.Thread {
            const token = windows.kernel32.CreateNamedPipeW(
                @ptrCast(&server.path_buf),
                windows.PIPE_ACCESS_INBOUND,
                windows.PIPE_TYPE_BYTE,
                @intCast(server.num_tokens),
                0,
                0,
                0,
                null,
            );
            if (token == windows.INVALID_HANDLE_VALUE) {
                switch (windows.GetLastError()) {
                    else => |err| return windows.unexpectedError(err),
                }
            }
            return .spawn(.{}, run, .{ server, token });
        }

        fn run(_: *Server, token: windows.HANDLE) !void {
            defer windows.CloseHandle(token);
            while (true) {
                _ = ConnectNamedPipe(token, null);
                var buf: [1]u8 = undefined;
                _ = try windows.ReadFile(token, &buf, null);
                _ = DisconnectNamedPipe(token);
            }
        }
    },
};

pub const Client = switch (builtin.os.tag) {
    else => struct {
        sem_id: c_int,

        pub const Permit = struct {
            sem_id: c_int,

            pub fn release(permit: Permit) void {
                modifySemaphore(permit.sem_id, 1);
            }
        };

        pub fn init() !Client {
            return .{
                .sem_id = try std.fmt.parseInt(
                    c_int,
                    posix.getenv("JOBSERVER_SEMID") orelse return error.NoJobServer,
                    10,
                ),
            };
        }

        pub fn deinit(client: *Client) void {
            client.* = undefined;
        }

        pub fn acquire(client: Client) !Permit {
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

            pub fn release(permit: Permit) void {
                windows.CloseHandle(permit.named_pipe_handle);
            }
        };

        pub fn init() !Client {
            return .{};
        }

        pub fn deinit(client: *Client) void {
            client.* = undefined;
        }

        pub fn acquire(_: Client) !Permit {
            const path = std.process.getenvW(
                std.unicode.wtf8ToWtf16LeStringLiteral("JOBSERVER_NAMEDPIPE"),
            ) orelse return error.NoJobServer;
            var nt_path_buf: [windows.PATH_MAX_WIDE]u16 = undefined;
            const nt_path = nt_path_buf[0..path.len];
            nt_path[0..4].* = .{ '\\', '?', '?', '\\' };
            @memcpy(nt_path[4..], path[4..]);
            const handle = while (true) {
                break windows.OpenFile(
                    nt_path,
                    .{
                        .access_mask = windows.SYNCHRONIZE,
                        .creation = windows.FILE_OPEN,
                        .share_access = 0,
                    },
                ) catch |err| switch (err) {
                    error.NoDevice => {
                        if (WaitNamedPipeW(path, NMPWAIT_WAIT_FOREVER) == 0) {
                            std.debug.panic("{t}", .{windows.GetLastError()});
                        }
                        continue;
                    },
                    else => return err,
                };
            };
            return .{ .named_pipe_handle = handle };
        }
    },
};

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const windows = std.os.windows;

pub extern "kernel32" fn WaitNamedPipeW(
    windows.LPCWSTR,
    u32,
) callconv(.winapi) windows.BOOL;

const NMPWAIT_WAIT_FOREVER: u32 = 0xffffffff;

pub extern "kernel32" fn ConnectNamedPipe(
    windows.HANDLE,
    ?*windows.OVERLAPPED,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn DisconnectNamedPipe(
    windows.HANDLE,
) callconv(.winapi) windows.BOOL;
