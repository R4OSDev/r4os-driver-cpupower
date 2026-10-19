// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! These tests execute the real provider/cache with a named-register peer.
//! They execute no host CPUID, RDMSR, WRMSR or privileged instruction.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const Provider = @import("provider.zig").Provider;
const t = std.testing;
test {
    _ = @import("firmware_test.zig");
    _ = @import("hwp_test.zig");
    _ = @import("cppc_test.zig");
}
var fixture: struct {
    cpu: u32 = 2,
    epoch: u64 = 7,
    ns: u64 = 100_000_000,
    generation: u32 = 3,
    virtual: bool = false,
    amd: bool = false,
    reads: u32 = 0,
    aperf: u64 = 100_000_000,
    mperf: u64 = 100_000_000,
    energy: u64 = 65536,
    migrate: bool = false,
    change_clock: bool = false,
    unsupported: bool = false,
} = .{};
fn current() callconv(.c) u32 {
    return fixture.cpu;
}
fn cap(cpu: u32, out: *a.CpuCapabilitiesInfo) callconv(.c) i32 {
    out.* = .{ .cpu_index = cpu, .epoch = fixture.epoch, .capture_sequence = 2, .family = if (fixture.amd) 0x19 else 6, .model = if (fixture.amd) 1 else 0x3c, .stepping = if (fixture.amd) 1 else 3, .vendor_name = if (fixture.amd) "AuthenticAMD".* else "GenuineIntel".*, .configured_cpus = 4, .flags = a.cpu_capabilities_flag_captured | a.cpu_capabilities_flag_signature | a.cpu_capabilities_flag_schedulable };
    if (fixture.virtual) out.flags |= a.cpu_capabilities_flag_hypervisor_present;
    return 0;
}
fn topology(cpu: u32, out: *a.CpuTopologyInfo) callconv(.c) i32 {
    out.* = .{ .cpu_index = cpu, .start_epoch = fixture.epoch, .vendor_name = if (fixture.amd) "AuthenticAMD".* else "GenuineIntel".*, .flags = a.cpu_topology_flag_geometry, .package_id = 0, .core_id = cpu / 2, .configured_cpus = 4 };
    return a.cpu_topology_result_ok;
}
fn clock(out: *a.MonotonicClockInfo) callconv(.c) i32 {
    out.* = .{ .flags = a.monotonic_clock_flag_valid, .generation = fixture.generation, .source = 2, .instant_ns = fixture.ns };
    return 1;
}
fn pair(cpu: u32, epoch: u64, out: *a.CpuPowerCounters) callconv(.c) i32 {
    fixture.reads += 2;
    if (fixture.unsupported) return a.cpu_capabilities_error_unsupported;
    out.* = .{ .cpu_index = cpu, .epoch = epoch, .flags = a.cpu_register_flag_raw, .aperf = fixture.aperf, .mperf = fixture.mperf, .captured_ns = fixture.ns, .clock_generation = fixture.generation, .clock_source = 2, .capture_sequence = 2 };
    return 0;
}
fn read(cpu: u32, epoch: u64, id: u32, out: *a.CpuRegisterInfo) callconv(.c) i32 {
    fixture.reads += 1;
    if (fixture.unsupported) return if (id == a.cpu_register_id_intel_platform_info) a.cpu_capabilities_error_fault else a.cpu_capabilities_error_unsupported;
    const value: u64 = switch (id) {
        a.cpu_register_id_intel_platform_info => 30 << 8,
        a.cpu_register_id_aperf => fixture.aperf,
        a.cpu_register_id_mperf => fixture.mperf,
        a.cpu_register_id_microcode => if (fixture.amd) 0x8001234 else @as(u64, 0x1234) << 32,
        a.cpu_register_id_amd_pstate0 => (@as(u64, 1) << 63) | (8 << 8) | 100,
        a.cpu_register_id_intel_temperature_target => 100 << 16,
        a.cpu_register_id_intel_thermal_status => (@as(u64, 1) << 31) | (25 << 16) | 2,
        a.cpu_register_id_intel_energy_unit => 16 << 8,
        a.cpu_register_id_amd_energy_unit => 16 << 8,
        a.cpu_register_id_amd_package_energy, a.cpu_register_id_amd_core_energy => fixture.energy,
        a.cpu_register_id_intel_package_energy, a.cpu_register_id_intel_core_energy => fixture.energy,
        else => return a.cpu_capabilities_error_unsupported,
    };
    out.* = .{ .cpu_index = cpu, .epoch = epoch, .register_id = id, .flags = a.cpu_register_flag_raw, .value = value };
    if (fixture.migrate) fixture.cpu = 1;
    if (fixture.change_clock) fixture.generation += 1;
    return 0;
}
fn init() Provider {
    fixture = .{};
    return Provider.init(.{ .table = .{ .current_cpu = @intFromPtr(&current), .capabilities = @intFromPtr(&cap), .topology = @intFromPtr(&topology), .register_read = @intFromPtr(&read), .clock = @intFromPtr(&clock), .counters_read = @intFromPtr(&pair) } });
}
test "actual provider keeps VM unavailable without any model register read or sampling on snapshot" {
    var provider = init();
    fixture.virtual = true;
    var value: a.CpuPowerInfo = .{};
    try t.expectEqual(@as(i32, 0), provider.snapshot(2, 7, &value));
    try t.expectEqual(@as(u64, 0), value.sequence);
    try t.expectEqual(@as(i32, 0), provider.capture(2, 7, &value));
    try t.expectEqual(a.cpu_power_state_virtual, value.state);
    try t.expectEqual(@as(u32, 0), value.valid_mask);
    try t.expectEqual(@as(u32, 0xfff), value.unsupported_mask);
    try t.expectEqual(@as(u64, 1), value.sequence);
    fixture.ns += 20_000_000;
    try t.expectEqual(@as(i32, 0), provider.snapshot(2, 7, &value));
    try t.expectEqual(@as(u64, 1), value.sequence);
    try t.expectEqual(@as(u32, 0), fixture.reads);
}
test "actual provider captures model units raw data scopes C0 ratio and finite energy rollover" {
    var provider = init();
    var value: a.CpuPowerInfo = .{};
    try t.expectEqual(@as(i32, 0), provider.capture(2, 7, &value));
    try t.expectEqual(@as(u32, 0), value.valid_mask & a.cpu_power_valid_active_hz);
    try t.expectEqual(@as(u32, 0x1234), value.microcode_revision);
    try t.expectEqual(@as(i32, 75000), value.temperature_millic);
    try t.expectEqual(@as(u32, 0), value.thermal_current);
    try t.expectEqual(@as(u32, 1), value.thermal_history);
    try t.expectEqual(@as(u64, 1_000_000), value.package_energy_uj);
    try t.expectEqual(@as(u32, 32), value.package_energy_bits);
    try t.expectEqual(@as(u64, 15), value.package_mask);
    try t.expectEqual(@as(u64, 15), value.core_mask); // Intel PP0 includes all package cores.
    try t.expectEqual(@as(u32, 0), value.package_leader);
    fixture.ns += 20_000_000;
    fixture.aperf += 60_000_000;
    fixture.mperf += 40_000_000;
    fixture.energy = 10;
    try t.expectEqual(@as(i32, 0), provider.capture(2, 7, &value));
    try t.expectEqual(@as(u64, 4_500_000_000), value.active_hz);
    try t.expect(value.valid_mask & a.cpu_power_valid_active_hz != 0);
    try t.expectEqual(@as(u64, 20_000_000), value.interval_ns);
    try t.expect(value.flags & a.cpu_power_flag_energy_discontinuity != 0);
    const reads = fixture.reads;
    try t.expectEqual(@as(i32, 0), provider.snapshot(2, 7, &value));
    try t.expectEqual(reads, fixture.reads);
    fixture.generation += 1;
    try t.expectEqual(@as(i32, 0), provider.snapshot(2, 7, &value));
    try t.expectEqual(a.cpu_power_state_stale, value.state);
    try t.expectEqual(@as(u32, 0), value.valid_mask);
    fixture.epoch += 1;
    try t.expectEqual(@as(i32, 0), provider.snapshot(2, 8, &value));
    try t.expectEqual(a.cpu_power_state_no_sample, value.state);
    try t.expectEqual(@as(u64, 0), value.sequence);
}
test "actual provider refuses concurrent cache use migration changed clock and bad headers without output writes" {
    var provider = init();
    var value: a.CpuPowerInfo = .{ .sequence = 71 };
    const saved = value;
    provider.cells[2].busy.store(true, .release);
    try t.expectEqual(a.cpu_capabilities_error_busy, provider.snapshot(2, 7, &value));
    try t.expectEqual(a.cpu_capabilities_error_busy, provider.capture(2, 7, &value));
    try t.expectEqualDeep(saved, value);
    provider.cells[2].busy.store(false, .release);
    fixture.migrate = true;
    try t.expectEqual(a.cpu_capabilities_error_busy, provider.capture(2, 7, &value));
    try t.expectEqualDeep(saved, value);
    fixture.cpu = 2;
    fixture.migrate = false;
    fixture.change_clock = true;
    try t.expectEqual(a.cpu_capabilities_error_busy, provider.capture(2, 7, &value));
    try t.expectEqualDeep(saved, value);
    try t.expectEqual(a.cpu_capabilities_error_epoch, provider.capture(2, 8, &value));
    try t.expectEqualDeep(saved, value);
    value.version = 2;
    const invalid = value;
    try t.expectEqual(a.cpu_capabilities_error_invalid, provider.capture(2, 7, &value));
    try t.expectEqualDeep(invalid, value);
}
test "actual provider reports unsupported and fault fields without plausible zero sensors" {
    var provider = init();
    fixture.unsupported = true;
    var value: a.CpuPowerInfo = .{};
    try t.expectEqual(@as(i32, 0), provider.capture(2, 7, &value));
    try t.expect(value.fault_mask & a.cpu_power_valid_reference_hz != 0);
    try t.expect(value.unsupported_mask & a.cpu_power_valid_temperature != 0);
    try t.expect(value.valid_mask & (a.cpu_power_valid_active_hz | a.cpu_power_valid_temperature |
        a.cpu_power_valid_package_energy | a.cpu_power_valid_microcode) == 0);
}
test "actual AMD B1 provider keeps patch low32 P0 reference unavailable temperature and SMT core scope" {
    var provider = init();
    fixture.amd = true;
    var value: a.CpuPowerInfo = .{};
    try t.expectEqual(@as(i32, 0), provider.capture(2, 7, &value));
    try t.expectEqual(a.cpu_power_profile_amd_milan_b1, value.profile);
    try t.expectEqual(@as(u32, 0x8001234), value.microcode_revision);
    try t.expectEqual(@as(u64, 2_500_000_000), value.reference_hz);
    try t.expectEqual(@as(u64, 1_000_000), value.core_energy_uj);
    try t.expectEqual(@as(u32, 32), value.core_energy_bits);
    try t.expectEqual(@as(u64, 15), value.package_mask);
    try t.expectEqual(@as(u64, 12), value.core_mask);
    try t.expectEqual(@as(u32, 2), value.core_leader);
    try t.expect(value.valid_mask & a.cpu_power_valid_temperature == 0);
    try t.expect(value.unsupported_mask & a.cpu_power_valid_temperature != 0);
    fixture.ns += 20_000_000;
    fixture.aperf += 60_000_000;
    fixture.mperf += 40_000_000;
    try t.expectEqual(@as(i32, 0), provider.capture(2, 7, &value));
    try t.expectEqual(@as(u64, 3_750_000_000), value.active_hz);
    fixture.cpu = 3;
    try t.expectEqual(@as(i32, 0), provider.capture(3, 7, &value));
    try t.expectEqual(@as(u32, 2), value.core_leader);
    try t.expectEqual(@as(u64, 12), value.core_mask);
}
