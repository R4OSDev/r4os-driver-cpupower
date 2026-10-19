// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Pure model/units decoding. Hardware access and sampling belong to the
//! provider; absent, stale or ambiguous inputs never become measured zeros.
const std = @import("std");

pub const Profile = enum(u32) { unsupported, virtual, intel_haswell, amd_milan_b1 };
/// Passive documented model knowledge only. Actual MCA/SMCA advertisement,
/// bank counts, enabled reporting and raw errors belong to their own receipt.
pub fn machineCheckModel(p: Profile) u32 {
    return switch (p) {
        .intel_haswell => 1,
        .amd_milan_b1 => 2,
        else => 0,
    };
}
test "MCA model knowledge excludes unknown and virtual profiles without claiming hardware banks" {
    try std.testing.expectEqual(@as(u32, 0), machineCheckModel(.unsupported));
    try std.testing.expectEqual(@as(u32, 0), machineCheckModel(.virtual));
    try std.testing.expectEqual(@as(u32, 1), machineCheckModel(.intel_haswell));
    try std.testing.expectEqual(@as(u32, 2), machineCheckModel(.amd_milan_b1));
}
pub fn profile(vendor: []const u8, family: u32, model: u32, stepping: u32, hypervisor: bool) Profile {
    if (hypervisor) return .virtual;
    if (std.mem.eql(u8, vendor, "GenuineIntel") and family == 6 and
        (model == 0x3c or model == 0x45 or model == 0x46)) return .intel_haswell;
    // AMD PPR55898 revision0.50 covers Family19h Model01h revisionB1 only.
    if (std.mem.eql(u8, vendor, "AuthenticAMD") and family == 0x19 and model == 1 and stepping == 1) return .amd_milan_b1;
    return .unsupported;
}

pub const Stamp = struct { cpu: u32, epoch: u64, generation: u32, ns: u64 };
pub const Counters = struct { stamp: Stamp, aperf: u64, mperf: u64 };
pub fn compatible(a: Stamp, b: Stamp) bool {
    return a.cpu == b.cpu and a.epoch != 0 and a.epoch == b.epoch and
        a.generation != 0 and a.generation != std.math.maxInt(u32) and a.generation == b.generation and
        b.ns > a.ns;
}
/// Average active (C0) frequency over a bounded interval, not instantaneous
/// frequency or a CPUID nominal-MHz reading. Reference must be model-proven.
pub fn activeHz(before: Counters, after: Counters, reference_hz: u64) ?u64 {
    if (!compatible(before.stamp, after.stamp) or reference_hz == 0 or reference_hz > 10_000_000_000) return null;
    const elapsed = after.stamp.ns - before.stamp.ns;
    if (elapsed < 1_000_000 or elapsed > 10_000_000_000) return null;
    // PPR55898 makes an effective-frequency overflow invalid. A descending
    // pair is also indistinguishable from reset without a separate receipt.
    // Use the same conservative rule for both initial model profiles.
    if (after.aperf < before.aperf or after.mperf < before.mperf) return null;
    const a = after.aperf - before.aperf;
    const m = after.mperf - before.mperf;
    if (m == 0 or a == 0) return null;
    // A reset can look like a huge unsigned wrap on both counters and leave
    // a plausible ratio. Reject deltas outside our100GHz reporting ceiling,
    // allowing1ms of read/clock skew. This never manufactures a real maximum.
    const maximum = @as(u128, elapsed + 1_000_000) * 100;
    if (a > maximum or m > maximum) return null;
    const hz = @as(u128, a) * reference_hz / m;
    if (hz == 0 or hz > 100_000_000_000) return null;
    return @intCast(hz);
}
pub fn intelReferenceHz(platform_info: u64) ?u64 {
    const ratio = (platform_info >> 8) & 0xff;
    return if (ratio == 0) null else ratio * 100_000_000;
}
pub fn amdReferenceHz(pstate0: u64) ?u64 {
    if (pstate0 & (@as(u64, 1) << 63) == 0) return null;
    const fid = pstate0 & 0xff;
    const divisor = (pstate0 >> 8) & 0x3f;
    // PPR55898 B1 PStateDef valid-value table: FID10h..FFh;
    // DFSID08h..1Ah, then even1Ch..2Ch. Other encodings are off/reserved.
    // Use the explicit table's conservative bound, including its L3 limit;
    // the surrounding text mentioning higher core divisors is insufficient
    // to promote table-reserved values to a trustworthy P0 reference.
    if (fid < 0x10 or divisor < 8 or divisor > 0x2c or (divisor > 0x1a and divisor & 1 != 0)) return null;
    const hz = fid * 200_000_000 / divisor;
    return if (hz < 400_000_000 or hz > 10_000_000_000) null else hz;
}
pub fn intelTemperatureMilliC(thermal_status: u64, temperature_target: u64) ?i32 {
    if (thermal_status & (@as(u64, 1) << 31) == 0) return null;
    const target: i32 = @intCast((temperature_target >> 16) & 0xff);
    if (target == 0) return null;
    const distance: i32 = @intCast((thermal_status >> 16) & 0x7f);
    return (target - distance) * 1000;
}
/// Current status and sticky history are separate; neither read clears logs.
pub fn thermalCurrent(status: u64) u32 {
    return @intCast(status & 0x5555);
}
pub fn thermalHistory(status: u64) u32 {
    return @intCast((status >> 1) & 0x5555);
}
pub fn intelMicrocode(signature: u64) ?u32 {
    const revision: u32 = @truncate(signature >> 32);
    return if (revision == 0) null else revision;
}
pub fn amdMicrocode(patch_level: u64) ?u32 {
    if (patch_level >> 32 != 0 or patch_level == 0) return null;
    return @intCast(patch_level);
}
/// This is the scaled finite hardware counter, not monotonic energy since
/// boot. The raw counter width and exponent stay part of the public sample.
pub fn energyMicrojoules(raw: u64, bits: u32, exponent: u32) ?u64 {
    if ((bits != 32 and bits != 64) or exponent > 31 or (bits == 32 and raw >> 32 != 0)) return null;
    const value = @as(u128, raw) * 1_000_000 >> @as(u7, @intCast(exponent));
    return std.math.cast(u64, value);
}
pub fn energyExponent(unit: u64) u32 {
    return @intCast((unit >> 8) & 0x1f);
}
/// A descending finite counter can mean wrap or reset. Do not fabricate a
/// monotonic total or wattage from it; retain that ambiguity explicitly.
pub fn counterDiscontinuity(before: u64, after: u64, bits: u32) bool {
    return (bits == 32 or bits == 64) and after < before;
}
pub fn isLeader(cpu: u32, scope_mask: u64) bool {
    return scope_mask != 0 and cpu < 64 and @ctz(scope_mask) == cpu;
}

test "profiles are exact vendor model revision and VM values remain virtual" {
    try std.testing.expectEqual(Profile.intel_haswell, profile("GenuineIntel", 6, 0x3c, 3, false));
    try std.testing.expectEqual(Profile.unsupported, profile("GenuineIntel", 6, 0x5e, 3, false));
    try std.testing.expectEqual(Profile.amd_milan_b1, profile("AuthenticAMD", 0x19, 1, 1, false));
    try std.testing.expectEqual(Profile.unsupported, profile("AuthenticAMD", 0x19, 1, 0, false));
    try std.testing.expectEqual(Profile.unsupported, profile("unknown", 6, 0x3c, 3, false));
    try std.testing.expectEqual(Profile.virtual, profile("GenuineIntel", 6, 0x3c, 3, true));
}
test "C0 frequency ratio is measured only with same CPU epoch clock and usable interval" {
    const first = Counters{ .stamp = .{ .cpu = 2, .epoch = 7, .generation = 3, .ns = 100_000_000 }, .aperf = 500, .mperf = 900 };
    var second = Counters{ .stamp = .{ .cpu = 2, .epoch = 7, .generation = 3, .ns = 120_000_000 }, .aperf = 800, .mperf = 1100 };
    try std.testing.expectEqual(@as(?u64, 4_500_000_000), activeHz(first, second, 3_000_000_000));
    second.stamp.cpu = 1;
    try std.testing.expect(activeHz(first, second, 3_000_000_000) == null);
    second.stamp = first.stamp;
    try std.testing.expect(activeHz(first, second, 3_000_000_000) == null);
    second.stamp.ns += 20_000_000;
    second.stamp.epoch += 1;
    try std.testing.expect(activeHz(first, second, 3_000_000_000) == null);
    second.stamp.epoch = 7;
    second.stamp.generation += 1;
    try std.testing.expect(activeHz(first, second, 3_000_000_000) == null);
    second.stamp.generation = 3;
    second.stamp.ns = first.stamp.ns + 100;
    try std.testing.expect(activeHz(first, second, 3_000_000_000) == null);
    second.stamp.ns = first.stamp.ns + 20_000_000;
    second.mperf = first.mperf;
    try std.testing.expect(activeHz(first, second, 3_000_000_000) == null);
    second.aperf = first.aperf - 1;
    second.mperf = first.mperf - 1;
    try std.testing.expect(activeHz(first, second, 3_000_000_000) == null);
}
test "active counter rollover is unknown because AMD invalidates overflow and reset is ambiguous" {
    const before = Counters{ .stamp = .{ .cpu = 0, .epoch = 1, .generation = 1, .ns = 1 }, .aperf = std.math.maxInt(u64) - 99, .mperf = std.math.maxInt(u64) - 99 };
    const after = Counters{ .stamp = .{ .cpu = 0, .epoch = 1, .generation = 1, .ns = 20_000_001 }, .aperf = 200, .mperf = 100 };
    try std.testing.expect(activeHz(before, after, 2_000_000_000) == null);
}
test "invalid thermal values differ from real zero and status differs from history" {
    try std.testing.expect(intelTemperatureMilliC(0, 100 << 16) == null);
    try std.testing.expect(intelTemperatureMilliC(@as(u64, 1) << 31, 0) == null);
    try std.testing.expectEqual(@as(?i32, 75_000), intelTemperatureMilliC((@as(u64, 1) << 31) | (25 << 16), 100 << 16));
    try std.testing.expectEqual(@as(?i32, 0), intelTemperatureMilliC((@as(u64, 1) << 31) | (100 << 16), 100 << 16));
    try std.testing.expectEqual(@as(u32, 0), thermalCurrent(2));
    try std.testing.expectEqual(@as(u32, 1), thermalHistory(2));
}
test "energy units widths overflow and resets stay explicit" {
    try std.testing.expectEqual(@as(?u64, 1_000_000), energyMicrojoules(65536, 32, 16));
    try std.testing.expectEqual(@as(?u64, 0), energyMicrojoules(0, 32, 16));
    try std.testing.expect(energyMicrojoules(@as(u64, 1) << 32, 32, 16) == null);
    try std.testing.expect(energyMicrojoules(std.math.maxInt(u64), 64, 0) == null);
    try std.testing.expect(counterDiscontinuity(0xfffffff0, 0x20, 32));
    try std.testing.expect(!counterDiscontinuity(10, 20, 32));
    try std.testing.expect(isLeader(2, 0b1100));
    try std.testing.expect(!isLeader(3, 0b1100));
    try std.testing.expect(!isLeader(0, 0));
}
test "reference and microcode are decoded only from valid model registers" {
    try std.testing.expectEqual(@as(?u64, 3_400_000_000), intelReferenceHz(34 << 8));
    try std.testing.expect(intelReferenceHz(0) == null);
    try std.testing.expectEqual(@as(?u64, 2_500_000_000), amdReferenceHz((@as(u64, 1) << 63) | (8 << 8) | 100));
    try std.testing.expect(amdReferenceHz(0) == null);
    const enabled: u64 = @as(u64, 1) << 63;
    for ([_]u64{ 0, 1, 7, 0x1b, 0x1d, 0x2b, 0x2d, 0x2e, 0x30, 0x3f }) |divisor| {
        try std.testing.expect(amdReferenceHz(enabled | (divisor << 8) | 100) == null);
    }
    try std.testing.expect(amdReferenceHz(enabled | (8 << 8) | 0xf) == null);
    try std.testing.expect(amdReferenceHz(enabled | (0x2c << 8) | 0x10) == null);
    for ([_]u64{ 8, 9, 0x1a, 0x1c, 0x2c }) |divisor| {
        try std.testing.expectEqual(@as(?u64, 100 * 200_000_000 / divisor), amdReferenceHz(enabled | (divisor << 8) | 100));
    }
    try std.testing.expectEqual(@as(?u32, 0x1234), intelMicrocode(@as(u64, 0x1234) << 32));
    try std.testing.expectEqual(@as(?u32, 0xabc), amdMicrocode(0xabc));
    try std.testing.expect(intelMicrocode(0) == null and amdMicrocode(0) == null);
}
