// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Real CPPC owner, simulated named-register/CPU peer; no host CPU instructions.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const Provider = @import("cppc.zig").Provider;
const t = std.testing;
const original: u64 = 200 | (10 << 8) | (96 << 24);
const normal_features: u32 = 1 << 27;
var fixture: struct {
    cpu: u32 = 2,
    epoch: u64 = 7,
    model: u32 = 0x50,
    family: u32 = 0x19,
    caps: u64 = (200 << 24) | (150 << 16) | (40 << 8) | 10,
    limit: u64 = 170,
    status: u64 = 2,
    ns: u64 = 100_000_000,
    clock_generation: u32 = 3,
    late: bool = false,
    clock_changed: bool = false,
    clock_calls: u32 = 0,
    published: u32 = 0,
    revoked: u32 = 0,
    last_hint: a.CpuPerformanceHint = .{},
    virtual: bool = false,
    features: u32 = normal_features,
    enable: u64 = 1,
    request: u64 = original,
    package_bound: u32 = 4,
    peer_offline: bool = false,
    peer_model: bool = false,
    reads: u32 = 0,
    writes: u32 = 0,
    acquires: u32 = 0,
    releases: u32 = 0,
    pinned: u64 = 0,
    next_token: u64 = 100,
    before_mismatch: bool = false,
    write_fault: bool = false,
    after_fault: bool = false,
    read_fault: bool = false,
    read_fault_id: u32 = 0,
    before_error: bool = false,
    release_busy: bool = false,
    bad_receipt: bool = false,
} = .{};
fn current() callconv(.c) u32 {
    return fixture.cpu;
}
fn cap(cpu: u32, out: *a.CpuCapabilitiesInfo) callconv(.c) i32 {
    out.* = .{ .cpu_index = cpu, .epoch = fixture.epoch, .family = fixture.family, .model = if (fixture.peer_model and cpu == 1) 0x3c else fixture.model, .feature_count = 1, .configured_cpus = 4, .vendor_name = "AuthenticAMD".*, .flags = a.cpu_capabilities_flag_signature | a.cpu_capabilities_flag_captured | a.cpu_capabilities_flag_schedulable };
    if (fixture.virtual) out.flags |= a.cpu_capabilities_flag_hypervisor_present;
    if (fixture.peer_offline and cpu == 1) out.flags &= ~a.cpu_capabilities_flag_schedulable;
    return 0;
}
fn feature(cpu: u32, epoch: u64, ordinal: u32, out: *a.CpuFeatureInfo) callconv(.c) i32 {
    std.debug.assert(ordinal == 0);
    out.* = .{ .cpu_index = cpu, .epoch = epoch, .feature_id = a.cpu_feature_id_amd_cppc, .flags = a.cpu_feature_flag_raw, .source_leaf = 0x80000008, .source_register = 1, .source_bit = 27, .raw_value = fixture.features };
    return 0;
}
fn topology(cpu: u32, out: *a.CpuTopologyInfo) callconv(.c) i32 {
    out.* = .{ .cpu_index = cpu, .start_epoch = fixture.epoch, .vendor_name = "AuthenticAMD".*, .flags = a.cpu_topology_flag_geometry, .configured_cpus = 4, .logical_per_package_bound = fixture.package_bound, .core_id = cpu / 2, .smt_shift = 1, .package_shift = 2 };
    return a.cpu_topology_result_ok;
}
fn clock(out: *a.MonotonicClockInfo) callconv(.c) i32 {
    fixture.clock_calls += 1;
    fixture.ns += if (fixture.late and fixture.clock_calls > 1) 2_000_000_000 else 1000;
    out.* = .{ .flags = a.monotonic_clock_flag_valid, .generation = fixture.clock_generation + @as(u32, @intFromBool(fixture.clock_changed and fixture.clock_calls > 1)), .source = 1, .instant_ns = fixture.ns };
    return 1;
}
fn read(cpu: u32, epoch: u64, id: u32, out: *a.CpuRegisterInfo) callconv(.c) i32 {
    fixture.reads += 1;
    if (fixture.read_fault or fixture.read_fault_id == id) return a.cpu_capabilities_error_fault;
    if (id != a.cpu_register_id_amd_cppc_enable) std.debug.assert(fixture.enable == 1);
    const value: u64 = switch (id) {
        a.cpu_register_id_amd_cppc_enable => fixture.enable,
        a.cpu_register_id_amd_cppc_capabilities1 => fixture.caps,
        a.cpu_register_id_amd_cppc_request => fixture.request,
        a.cpu_register_id_amd_cppc_capabilities2 => fixture.limit,
        a.cpu_register_id_amd_cppc_status => fixture.status,
        else => unreachable,
    };
    out.* = .{ .cpu_index = cpu, .epoch = epoch, .register_id = id, .flags = a.cpu_register_flag_raw, .value = value };
    return 0;
}
fn acquire(cpu: u32, epoch: u64, token: *u64) callconv(.c) i32 {
    std.debug.assert(cpu == fixture.cpu and epoch == fixture.epoch and fixture.pinned == 0);
    fixture.acquires += 1;
    fixture.pinned = fixture.next_token;
    fixture.next_token += 1;
    token.* = fixture.pinned;
    return 0;
}
fn release(cpu: u32, epoch: u64, token: u64) callconv(.c) i32 {
    std.debug.assert(cpu == fixture.cpu and epoch == fixture.epoch and token != 0 and token == fixture.pinned);
    if (fixture.release_busy) return a.cpu_capabilities_error_busy;
    fixture.releases += 1;
    fixture.pinned = 0;
    return 0;
}
fn write(cpu: u32, epoch: u64, token: u64, id: u32, expected: u64, requested: u64, out: *a.CpuRegisterWriteInfo) callconv(.c) i32 {
    std.debug.assert(cpu == fixture.cpu and epoch == fixture.epoch and token != 0 and token == fixture.pinned);
    if (fixture.before_error) return a.cpu_capabilities_error_context;
    const slot = if (id == a.cpu_register_id_amd_cppc_enable) &fixture.enable else &fixture.request;
    if (fixture.before_mismatch) slot.* += 1; // A real foreign update before the comparison read.
    out.* = .{ .cpu_index = cpu, .epoch = epoch, .lease = token, .register_id = id, .expected = expected, .requested = requested, .observed_before = slot.*, .flags = a.cpu_register_write_flag_before };
    if (slot.* != expected) {
        out.last_error = a.cpu_capabilities_error_busy;
        return 0;
    }
    fixture.writes += 1;
    out.flags |= a.cpu_register_write_flag_attempted;
    if (!fixture.write_fault) {
        slot.* = requested;
        out.flags |= a.cpu_register_write_flag_written;
    } else out.last_error = a.cpu_capabilities_error_fault;
    if (!fixture.after_fault) {
        out.observed_after = slot.*;
        out.flags |= a.cpu_register_write_flag_after;
    } else out.last_error = a.cpu_capabilities_error_fault;
    if (fixture.bad_receipt) out.epoch = 0;
    return 0;
}
fn rank(input: *const a.CpuPerformanceHint, sequence: *u64) callconv(.c) i32 {
    tryRank(input.*, sequence);
    return 0;
}
fn tryRank(input: a.CpuPerformanceHint, sequence: *u64) void {
    std.debug.assert(input.cpu_index == fixture.cpu and input.epoch == fixture.epoch);
    fixture.last_hint = input;
    if (input.flags == 0) {
        fixture.revoked += 1;
        sequence.* = 0;
        return;
    }
    std.debug.assert(input.scope_mask == 15 and input.core_mask == 12 and input.rank > 0 and input.scale != 0);
    fixture.published += 1;
    sequence.* = fixture.published;
}
fn init() Provider {
    fixture = .{};
    return Provider.init(.{ .table = .{ .current_cpu = @intFromPtr(&current), .capabilities = @intFromPtr(&cap), .feature = @intFromPtr(&feature), .topology = @intFromPtr(&topology), .register_read = @intFromPtr(&read), .clock = @intFromPtr(&clock), .control_acquire = @intFromPtr(&acquire), .control_release = @intFromPtr(&release), .register_compare_write = @intFromPtr(&write), .rank_publish = @intFromPtr(&rank) } });
}
fn inspect() a.CpuPerformanceRequest {
    return .{ .cpu_index = 2, .epoch = 7 };
}
fn application() a.CpuPerformanceRequest {
    return .{ .cpu_index = 2, .epoch = 7, .operation = a.cpu_performance_op_apply, .minimum = 20, .maximum = 180, .epp = 128, .flags = a.cpu_performance_request_flag_epp };
}
fn returning(info: a.CpuCppcInfo) a.CpuPerformanceRequest {
    return .{ .cpu_index = 2, .epoch = 7, .operation = a.cpu_performance_op_release, .lease = info.lease, .expected_revision = info.revision };
}
fn enabling() a.CpuPerformanceRequest {
    return .{ .cpu_index = 2, .epoch = 7, .operation = a.cpu_performance_op_enable, .flags = a.cpu_performance_request_flag_sticky_enable };
}
test "CPPC VM unknown model and unimplemented CPUID combinations reject before MSRs" {
    var p = init();
    const modes = [_]u32{ 0, 1, 2, 3, 4, 5 };
    for (modes) |mode| {
        fixture = .{};
        switch (mode) {
            0 => fixture.virtual = true,
            1 => fixture.model = 0x3c,
            2 => fixture.features = 0,
            3 => fixture.model = 0x4f,
            4 => fixture.model = 0x60,
            5 => fixture.family = 0x17,
            else => unreachable,
        }
        var value: a.CpuCppcInfo = .{};
        try t.expectEqual(@as(i32, 0), p.execute(inspect(), &value));
        try t.expectEqual(a.cpu_performance_state_unsupported, value.state);
        const saved = value;
        try t.expectEqual(a.cpu_capabilities_error_unsupported, p.execute(application(), &value));
        try t.expectEqualDeep(saved, value);
        try t.expectEqual(@as(u32, 0), fixture.reads);
        try t.expectEqual(@as(u32, 0), fixture.writes);
        try t.expectEqual(@as(u32, 0), fixture.acquires);
    }
}
test "CPPC disabled reads onlyENABLE and enable requires explicit irreversible all-CPU consent" {
    var p = init();
    fixture.enable = 0;
    var value: a.CpuCppcInfo = .{};
    try t.expectEqual(@as(i32, 0), p.execute(inspect(), &value));
    try t.expectEqual(a.cpu_performance_state_disabled, value.state);
    try t.expectEqual(@as(u32, 1), fixture.reads);
    var bad = enabling();
    bad.flags = 0;
    const saved = value;
    try t.expectEqual(a.cpu_capabilities_error_invalid, p.execute(bad, &value));
    try t.expectEqualDeep(saved, value);
    try t.expectEqual(@as(i32, 0), p.execute(enabling(), &value));
    try t.expectEqual(@as(u64, 1), fixture.enable);
    try t.expectEqual(@as(u32, 1), fixture.writes);
    try t.expectEqual(@as(u64, original), fixture.request);
    try t.expectEqual(@as(u64, 0), fixture.pinned);
    try t.expectEqual(@as(u64, 15), value.qualified_mask);
    try t.expect(value.flags & a.cpu_performance_flag_sticky_enabled != 0);
    try t.expect(value.flags & a.cpu_performance_flag_parameters_restored == 0);
    try t.expectEqual(@as(i32, 0), p.execute(enabling(), &value));
    try t.expectEqual(@as(u32, 1), fixture.writes);
}
test "CPPC activation refuses incomplete offline and mixed model packages without writes" {
    for (0..3) |mode| {
        var p = init();
        fixture.enable = 0;
        switch (mode) {
            0 => fixture.package_bound = 8,
            1 => fixture.peer_offline = true,
            2 => fixture.peer_model = true,
            else => unreachable,
        }
        var value: a.CpuCppcInfo = .{ .lease = 71 };
        const saved = value;
        try t.expectEqual(a.cpu_capabilities_error_unsupported, p.execute(enabling(), &value));
        try t.expectEqualDeep(saved, value);
        try t.expectEqual(@as(u32, 0), fixture.writes);
        try t.expectEqual(@as(u32, 0), fixture.acquires);
    }
}
test "CPPC bounds unsupported EPP inherited package and bad epochs preserve output before writes" {
    var p = init();
    var value: a.CpuCppcInfo = .{ .lease = 71 };
    const saved = value;
    for (0..10) |mode| {
        fixture = .{};
        var request = application();
        const expected: i32 = switch (mode) {
            0 => blk: {
                request.minimum = 9;
                break :blk a.cpu_capabilities_error_invalid;
            },
            1 => blk: {
                request.maximum = 201;
                break :blk a.cpu_capabilities_error_invalid;
            },
            2 => blk: {
                request.desired = 181;
                break :blk a.cpu_capabilities_error_invalid;
            },
            3 => blk: {
                request.minimum = 181;
                break :blk a.cpu_capabilities_error_invalid;
            },
            4 => blk: {
                request.epp = 256;
                break :blk a.cpu_capabilities_error_invalid;
            },
            5 => blk: {
                fixture.features = 0;
                fixture.request &= ~@as(u64, 0xff000000);
                break :blk a.cpu_capabilities_error_unsupported;
            },
            6 => blk: {
                fixture.request |= @as(u64, 1) << 42;
                break :blk a.cpu_capabilities_error_unsupported;
            },
            7 => blk: {
                request.epoch = 6;
                break :blk a.cpu_capabilities_error_epoch;
            },
            8 => blk: {
                request.flags |= 128;
                break :blk a.cpu_capabilities_error_invalid;
            },
            9 => blk: {
                request.reserved0 = 1;
                break :blk a.cpu_capabilities_error_invalid;
            },
            else => unreachable,
        };
        try t.expectEqual(expected, p.execute(request, &value));
        try t.expectEqualDeep(saved, value);
        try t.expectEqual(@as(u32, 0), fixture.writes);
        try t.expectEqual(@as(u32, 0), fixture.acquires);
    }
}
test "CPPC local repeated requests preserve AMD byte order EPP token and exact original until verified release" {
    var p = init();
    var value: a.CpuCppcInfo = .{};
    try t.expectEqual(@as(i32, 0), p.execute(application(), &value));
    try t.expectEqual(a.cpu_performance_state_owned, value.state);
    try t.expectEqual(@as(u32, 20), value.minimum);
    try t.expectEqual(@as(u32, 180), value.maximum);
    try t.expectEqual(@as(u32, 128), value.epp);
    try t.expectEqual(original & ~@as(u64, 0xffffffff), fixture.request & ~@as(u64, 0xffffffff));
    try t.expectEqual(original, value.baseline_request);
    const token = value.lease;
    var request = application();
    request.lease = token;
    request.expected_revision = value.revision;
    request.minimum = 30;
    request.maximum = 150;
    request.desired = 80;
    request.flags = 0;
    request.epp = 0;
    try t.expectEqual(@as(i32, 0), p.execute(request, &value));
    try t.expectEqual(token, value.lease);
    try t.expectEqual(@as(u32, 128), value.epp);
    try t.expectEqual(@as(u32, 80), value.desired);
    const saved = value;
    try t.expectEqual(a.cpu_capabilities_error_epoch, p.execute(request, &value));
    try t.expectEqualDeep(saved, value);
    try t.expectEqual(@as(i32, 0), p.execute(returning(value), &value));
    try t.expectEqual(original, fixture.request);
    try t.expectEqual(@as(u64, 0), value.lease);
    try t.expectEqual(@as(u64, 0), fixture.pinned);
    try t.expectEqual(a.cpu_performance_state_restored, value.state);
    try t.expect(value.flags & a.cpu_performance_flag_parameters_restored != 0);
    try t.expectEqual(@as(u64, 1), fixture.enable);
}
test "CPPC readback fault and malformed receipt retain resident owner until an explicit real return" {
    for (0..2) |mode| {
        var p = init();
        var value: a.CpuCppcInfo = .{};
        fixture.after_fault = mode == 0;
        fixture.bad_receipt = mode == 1;
        try t.expectEqual(@as(i32, 0), p.execute(application(), &value));
        try t.expectEqual(a.cpu_performance_state_uncertain, value.state);
        try t.expect(value.lease != 0 and fixture.pinned == value.lease);
        try t.expect(value.flags & a.cpu_performance_flag_parameters_restored == 0);
        fixture.after_fault = false;
        fixture.bad_receipt = false;
        try t.expectEqual(@as(i32, 0), p.execute(inspect(), &value));
        try t.expectEqual(a.cpu_performance_state_uncertain, value.state);
        try t.expectEqual(@as(i32, 0), p.execute(returning(value), &value));
        try t.expectEqual(original, fixture.request);
        try t.expectEqual(@as(u64, 0), fixture.pinned);
        try t.expectEqual(a.cpu_performance_state_restored, value.state);
    }
}
test "CPPC WRMSR fault is never a successful request and known unchanged baseline returns without writing again" {
    var p = init();
    var value: a.CpuCppcInfo = .{};
    fixture.write_fault = true;
    try t.expectEqual(@as(i32, 0), p.execute(application(), &value));
    try t.expectEqual(a.cpu_performance_state_uncertain, value.state);
    try t.expectEqual(a.cpu_capabilities_error_fault, value.last_error);
    try t.expectEqual(original, fixture.request);
    fixture.write_fault = false;
    try t.expectEqual(@as(i32, 0), p.execute(returning(value), &value));
    try t.expectEqual(@as(u32, 1), fixture.writes);
    try t.expectEqual(a.cpu_performance_state_restored, value.state);
    try t.expectEqual(@as(i32, 0), value.last_error);
}
test "CPPC external conflict never overwrites firmware and failed admission releases only untouched new ownership" {
    var p = init();
    var value: a.CpuCppcInfo = .{};
    fixture.before_error = true;
    try t.expectEqual(a.cpu_capabilities_error_context, p.execute(application(), &value));
    try t.expectEqual(@as(u64, 0), fixture.pinned);
    fixture.before_error = false;
    fixture.before_mismatch = true;
    try t.expectEqual(@as(i32, 0), p.execute(application(), &value));
    try t.expectEqual(a.cpu_performance_state_conflict, value.state);
    try t.expectEqual(@as(u64, 0), fixture.pinned);
    try t.expectEqual(@as(u32, 0), fixture.writes);
    fixture.before_mismatch = false;
    try t.expectEqual(@as(i32, 0), p.execute(inspect(), &value));
    try t.expectEqual(@as(i32, 0), value.last_error);
    try t.expectEqual(@as(i32, 0), p.execute(application(), &value));
    const intended = fixture.request;
    fixture.request = 0x01020304;
    try t.expectEqual(@as(i32, 0), p.execute(returning(value), &value));
    try t.expectEqual(a.cpu_performance_state_conflict, value.state);
    try t.expectEqual(@as(u64, 0x01020304), fixture.request);
    try t.expectEqual(@as(u32, 1), fixture.writes);
    try t.expect(fixture.pinned != 0);
    fixture.request = intended;
    try t.expectEqual(@as(i32, 0), p.execute(returning(value), &value));
    try t.expectEqual(@as(u64, 0), fixture.pinned);
}
test "CPPC interrupted restoration and failed resource return retain exact token through idempotent retry" {
    var p = init();
    var value: a.CpuCppcInfo = .{};
    try t.expectEqual(@as(i32, 0), p.execute(application(), &value));
    // The already owned return must not depend on dynamic capability sensors.
    fixture.read_fault_id = a.cpu_register_id_amd_cppc_capabilities1;
    fixture.after_fault = true;
    try t.expectEqual(@as(i32, 0), p.execute(returning(value), &value));
    try t.expectEqual(a.cpu_performance_state_uncertain, value.state);
    try t.expectEqual(original, fixture.request);
    const writes = fixture.writes;
    fixture.after_fault = false;
    fixture.release_busy = true;
    try t.expectEqual(@as(i32, 0), p.execute(returning(value), &value));
    try t.expect(value.lease != 0 and fixture.pinned != 0);
    try t.expect(value.flags & a.cpu_performance_flag_parameters_restored == 0);
    fixture.release_busy = false;
    try t.expectEqual(@as(i32, 0), p.execute(returning(value), &value));
    try t.expectEqual(@as(u64, 0), fixture.pinned);
    try t.expectEqual(writes, fixture.writes);
}
test "CPPC uncertain sticky activation release never claims the CPU interface was disabled or parameters restored" {
    var p = init();
    fixture.enable = 0;
    fixture.after_fault = true;
    var value: a.CpuCppcInfo = .{};
    try t.expectEqual(@as(i32, 0), p.execute(enabling(), &value));
    try t.expectEqual(a.cpu_performance_state_uncertain, value.state);
    try t.expect(fixture.pinned != 0);
    fixture.after_fault = false;
    try t.expectEqual(@as(i32, 0), p.execute(returning(value), &value));
    try t.expectEqual(@as(u64, 1), fixture.enable);
    try t.expectEqual(@as(u64, 0), fixture.pinned);
    try t.expect(value.flags & a.cpu_performance_flag_sticky_enabled != 0);
    try t.expect(value.flags & a.cpu_performance_flag_parameters_restored == 0);
    p = init();
    fixture.enable = 0;
    fixture.before_mismatch = true;
    try t.expectEqual(@as(i32, 0), p.execute(enabling(), &value));
    try t.expectEqual(@as(u64, 1), fixture.enable);
    try t.expectEqual(@as(u32, 0), fixture.writes);
    try t.expectEqual(@as(u64, 0), fixture.pinned);
    try t.expect(value.flags & a.cpu_performance_flag_sticky_enabled != 0);
    try t.expect(value.flags & a.cpu_performance_flag_parameters_restored == 0);
}
test "CPPC same CPU callback is try-only and revision exhaustion still permits exact cleanup" {
    var p = init();
    var value: a.CpuCppcInfo = .{};
    p.cells[2].busy.store(true, .release);
    try t.expectEqual(a.cpu_capabilities_error_busy, p.execute(application(), &value));
    p.cells[2].busy.store(false, .release);
    try t.expectEqual(@as(i32, 0), p.execute(application(), &value));
    p.cells[2].info.revision = std.math.maxInt(u64);
    value.revision = std.math.maxInt(u64);
    var request = application();
    request.lease = value.lease;
    request.expected_revision = value.revision;
    try t.expectEqual(a.cpu_capabilities_error_busy, p.execute(request, &value));
    try t.expectEqual(@as(i32, 0), p.execute(returning(value), &value));
    try t.expectEqual(@as(u64, 0), fixture.pinned);
    try t.expectEqual(original, fixture.request);
}

test "CPPC raw CAP1 is ordered AMD bytes; CAP2/status remain independent unitless observations" {
    var p = init();
    var value: a.CpuCppcInfo = .{};
    try t.expectEqual(@as(i32, 0), p.execute(inspect(), &value));
    try t.expectEqual(@as(u32, 200), value.highest);
    try t.expectEqual(@as(u32, 150), value.nominal);
    try t.expectEqual(@as(u32, 40), value.lowest_nonlinear);
    try t.expectEqual(@as(u32, 10), value.lowest);
    try t.expectEqual(@as(u64, 170), value.raw_capability2);
    try t.expectEqual(@as(u64, 2), value.raw_status);
    try t.expectEqual(@as(u32, 10), value.minimum);
    try t.expectEqual(@as(u32, 200), value.maximum);
    try t.expectEqual(@as(u32, 31), value.raw_valid_mask);
    try t.expect(value.hint_sequence != 0 and value.flags & a.cpu_cppc_flag_rank_published != 0);
    try t.expectEqual(@as(u32, 0x0196280a), fixture.last_hint.scale);
    const first = value.captured_ns;
    fixture.caps = (210 << 24) | (150 << 16) | (40 << 8) | 10;
    try t.expectEqual(@as(i32, 0), p.execute(inspect(), &value));
    try t.expectEqual(@as(u32, 210), fixture.last_hint.rank);
    try t.expectEqual(@as(u32, 0x0196280a), fixture.last_hint.scale);
    try t.expect(value.captured_ns > first and value.captured_ns < fixture.ns);
    // Default reset-zero request is a real baseline, never replaced by caps.
    fixture.request = 0;
    try t.expectEqual(@as(i32, 0), p.execute(application(), &value));
    try t.expectEqual(@as(u64, 0), value.baseline_request);
    try t.expectEqual(@as(u64, 180 | (20 << 8) | (128 << 24)), fixture.request);
    try t.expectEqual(@as(i32, 0), p.execute(returning(value), &value));
    try t.expectEqual(@as(u64, 0), fixture.request);
}
test "CPPC bad CAP1/time invalidates rank; independent sensor failure does not prevent exact return" {
    for (0..4) |mode| {
        var p = init();
        var value: a.CpuCppcInfo = .{};
        switch (mode) {
            0 => fixture.caps = (100 << 24) | (150 << 16) | (40 << 8) | 10,
            1 => fixture.caps |= @as(u64, 1) << 32,
            2 => fixture.late = true,
            3 => fixture.clock_changed = true,
            else => unreachable,
        }
        try t.expectEqual(@as(i32, 0), p.execute(inspect(), &value));
        try t.expectEqual(@as(u32, 0), fixture.published);
        try t.expect(fixture.revoked != 0 and value.hint_sequence == 0);
        if (mode < 2) try t.expectEqual(@as(u32, 0), value.highest);
    }
    var p = init();
    var value: a.CpuCppcInfo = .{};
    try t.expectEqual(@as(i32, 0), p.execute(application(), &value));
    fixture.read_fault_id = a.cpu_register_id_amd_cppc_capabilities2;
    try t.expectEqual(@as(i32, 0), p.execute(returning(value), &value));
    try t.expectEqual(original, fixture.request);
    try t.expectEqual(@as(u64, 0), fixture.pinned);
    try t.expect(value.flags & a.cpu_performance_flag_parameters_restored != 0);
}
