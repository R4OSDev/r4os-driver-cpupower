// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const r = @import("r4os");
const a = r.abi;
const adapter = @import("firmware.zig");
var mode: u32 = 0;
var calls: u32 = 0;
fn transport(request: *const a.CpuPerformanceRequest, out: *a.CpuFirmwareInfo) callconv(.c) i32 {
    calls += 1;
    if (mode == 1) return a.cpu_capabilities_error_fault;
    out.* = .{ .cpu_index = request.cpu_index, .epoch = if (mode == 3) request.epoch + 1 else request.epoch, .firmware_generation = 17, .backend = a.cpu_firmware_backend_cppc, .state = a.cpu_performance_state_uncertain, .lease = 77, .revision = 4, .last_error = -8 };
    return 0;
}
test "firmware adapter keeps old mechanism prefixes and refused outputs unchanged without raw CPU access" {
    var mechanism: r.r4dev.DriverCpuPowerContext = .{ .table = .{ .size = 128, .firmware_execute = @intFromPtr(&transport) } };
    const request: a.CpuPerformanceRequest = .{ .cpu_index = 2, .epoch = 7 };
    var output: a.CpuFirmwareInfo = .{ .lease = 99 };
    calls = 0;
    try std.testing.expectEqual(a.err_no_fn, adapter.execute(&mechanism, &request, &output));
    try std.testing.expectEqual(@as(u32, 0), calls);
    try std.testing.expectEqual(@as(u64, 99), output.lease);
    mechanism.table.size = @sizeOf(a.DriverCpuPowerApi);
    mode = 1;
    try std.testing.expectEqual(a.cpu_capabilities_error_fault, adapter.execute(&mechanism, &request, &output));
    try std.testing.expectEqual(@as(u64, 99), output.lease);
}
test "firmware adapter preserves a complete uncertain token and rejects a substituted CPU epoch" {
    const mechanism: r.r4dev.DriverCpuPowerContext = .{ .table = .{ .firmware_execute = @intFromPtr(&transport) } };
    const request: a.CpuPerformanceRequest = .{ .cpu_index = 2, .epoch = 7 };
    var output: a.CpuFirmwareInfo = .{ .lease = 99 };
    mode = 2;
    try std.testing.expectEqual(@as(i32, 0), adapter.execute(&mechanism, &request, &output));
    try std.testing.expectEqual(@as(u64, 77), output.lease);
    try std.testing.expectEqual(a.cpu_performance_state_uncertain, output.state);
    try std.testing.expectEqual(@as(i32, -8), output.last_error);
    mode = 3;
    const before = output;
    try std.testing.expectEqual(a.cpu_capabilities_error_invalid, adapter.execute(&mechanism, &request, &output));
    try std.testing.expectEqualDeep(before, output);
}
