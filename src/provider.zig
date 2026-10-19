// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Passive, bounded observations. The kernel authenticates the loaded owner
//! and retains membership; this module owns model decoding and cached samples.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const Mechanism = r4os.r4dev.DriverCpuPowerContext;
const d = @import("decode.zig");
const fields: u32 = 0xfff;
const counters = a.cpu_power_valid_aperf | a.cpu_power_valid_mperf;
const Cell = struct {
    busy: std.atomic.Value(bool) = .init(false),
    sample: a.CpuPowerInfo = .{},
};

pub const Provider = struct {
    mechanism: Mechanism,
    cells: [64]Cell = [_]Cell{.{}} ** 64,

    pub fn init(mechanism: Mechanism) Provider {
        return .{ .mechanism = mechanism };
    }
    fn metadata(cap: a.CpuCapabilitiesInfo) a.CpuPowerInfo {
        const profile = d.profile(&cap.vendor_name, cap.family, cap.model, cap.stepping, cap.flags & a.cpu_capabilities_flag_hypervisor_present != 0);
        var value: a.CpuPowerInfo = .{
            .cpu_index = cap.cpu_index,
            .epoch = cap.epoch,
            .family = cap.family,
            .model = cap.model,
            .stepping = cap.stepping,
            .vendor_name = cap.vendor_name,
            .profile = @intFromEnum(profile),
            .flags = a.cpu_power_flag_installed,
            .state = a.cpu_power_state_no_sample,
            .package_leader = a.cpu_power_cpu_none,
            .core_leader = a.cpu_power_cpu_none,
        };
        const name = switch (profile) {
            .virtual => "virtual: no physical sensors",
            .unsupported => "unsupported CPU model",
            .intel_haswell => "Intel Haswell 3C/45/46",
            .amd_milan_b1 => "AMD 19h/01h B1",
        };
        @memcpy(value.profile_name[0..name.len], name);
        if (profile == .virtual) value.flags |= a.cpu_power_flag_virtual;
        if (profile == .virtual or profile == .unsupported) value.unsupported_mask = fields;
        return value;
    }
    fn validOutput(out: *const a.CpuPowerInfo) bool {
        return out.version == 1 and out.size >= @sizeOf(a.CpuPowerInfo);
    }
    fn capabilities(self: *const Provider, cpu: u32, epoch: u64, out: *a.CpuCapabilitiesInfo) i32 {
        if (cpu >= self.cells.len) return a.cpu_capabilities_error_index;
        const result = self.mechanism.capabilities(cpu, out);
        if (result != 0) return result;
        if (epoch == 0 or out.epoch != epoch) return a.cpu_capabilities_error_epoch;
        if (out.flags & a.cpu_capabilities_flag_captured == 0) return a.cpu_capabilities_error_busy;
        return 0;
    }
    fn clock(self: *const Provider, out: *a.MonotonicClockInfo) bool {
        return self.mechanism.clock(out) == 1 and out.flags & a.monotonic_clock_flag_valid != 0 and
            out.generation != 0 and out.generation != std.math.maxInt(u32) and out.instant_ns != 0;
    }
    pub fn snapshot(self: *Provider, cpu: u32, epoch: u64, out: *a.CpuPowerInfo) i32 {
        if (!validOutput(out)) return a.cpu_capabilities_error_invalid;
        var cap: a.CpuCapabilitiesInfo = .{};
        const result = self.capabilities(cpu, epoch, &cap);
        if (result != 0) return result;
        const cell = &self.cells[cpu];
        // A callback may have been preempted on this same CPU. Never wait for
        // it: the caller can retry after its actual return.
        if (cell.busy.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return a.cpu_capabilities_error_busy;
        var value = cell.sample;
        cell.busy.store(false, .release);
        if (value.sequence == 0 or value.epoch != epoch) value = metadata(cap);
        var now: a.MonotonicClockInfo = .{};
        if (value.sequence != 0 and (!self.clock(&now) or value.clock_generation != now.generation or
            value.clock_source != now.source or value.captured_ns > now.instant_ns or
            cap.flags & a.cpu_capabilities_flag_schedulable == 0))
        {
            value.valid_mask = 0;
            value.state = a.cpu_power_state_stale;
            value.flags |= a.cpu_power_flag_stale;
        }
        out.* = value;
        return 0;
    }
    fn read(self: *const Provider, value: *a.CpuPowerInfo, id: u32, mask: u32) !?u64 {
        var raw: a.CpuRegisterInfo = .{};
        const result = self.mechanism.registerRead(value.cpu_index, value.epoch, id, &raw);
        switch (result) {
            0 => {
                if (raw.cpu_index != value.cpu_index or raw.epoch != value.epoch or raw.register_id != id or
                    raw.flags & a.cpu_register_flag_raw == 0) return error.Invalid;
                return raw.value;
            },
            a.cpu_capabilities_error_unsupported => value.unsupported_mask |= mask,
            a.cpu_capabilities_error_fault => value.fault_mask |= mask,
            else => return error.Retry,
        }
        return null;
    }
    fn scopes(self: *const Provider, value: *a.CpuPowerInfo, cap: a.CpuCapabilitiesInfo) void {
        var own: a.CpuTopologyInfo = .{};
        if (self.mechanism.topology(cap.cpu_index, &own) != a.cpu_topology_result_ok or
            own.start_epoch != cap.epoch or own.flags & a.cpu_topology_flag_geometry == 0 or
            !std.mem.eql(u8, &own.vendor_name, &cap.vendor_name) or cap.configured_cpus > 64) return;
        var package: u64 = 0;
        var core: u64 = 0;
        for (0..cap.configured_cpus) |index| {
            var peer: a.CpuTopologyInfo = .{};
            if (self.mechanism.topology(@intCast(index), &peer) != a.cpu_topology_result_ok or
                peer.flags & a.cpu_topology_flag_geometry == 0 or
                !std.mem.eql(u8, &peer.vendor_name, &cap.vendor_name)) return;
            if (peer.package_id == own.package_id) {
                package |= @as(u64, 1) << @as(u6, @intCast(index));
                if (peer.core_id == own.core_id) core |= @as(u64, 1) << @as(u6, @intCast(index));
            }
        }
        if (package == 0 or core == 0) return;
        value.package_mask = package;
        // Intel PP0 is the package's cores domain, not one physical core.
        value.core_mask = if (value.profile == a.cpu_power_profile_intel_haswell) package else core;
        value.package_leader = @ctz(value.package_mask);
        value.core_leader = @ctz(value.core_mask);
        value.valid_mask |= a.cpu_power_valid_package_scope | a.cpu_power_valid_core_scope;
        if (@popCount(value.package_mask) > 1) value.flags |= a.cpu_power_flag_package_shared;
        if (@popCount(value.core_mask) > 1) value.flags |= a.cpu_power_flag_core_shared;
    }
    fn readCounters(self: *const Provider, value: *a.CpuPowerInfo) !?a.CpuPowerCounters {
        var pair: a.CpuPowerCounters = .{};
        switch (self.mechanism.countersRead(value.cpu_index, value.epoch, &pair)) {
            0 => {
                if (pair.cpu_index != value.cpu_index or pair.epoch != value.epoch or pair.flags & a.cpu_register_flag_raw == 0 or
                    pair.captured_ns == 0 or pair.clock_generation == 0 or pair.clock_generation == std.math.maxInt(u32) or pair.capture_sequence == 0) return error.Invalid;
                value.aperf = pair.aperf;
                value.mperf = pair.mperf;
                value.valid_mask |= counters;
                return pair;
            },
            a.cpu_capabilities_error_unsupported => value.unsupported_mask |= counters,
            a.cpu_capabilities_error_fault => value.fault_mask |= counters,
            else => return error.Retry,
        }
        return null;
    }
    fn observe(self: *const Provider, value: *a.CpuPowerInfo) !?a.CpuPowerCounters {
        const intel = value.profile == a.cpu_power_profile_intel_haswell;
        const reference_id = if (intel) a.cpu_register_id_intel_platform_info else a.cpu_register_id_amd_pstate0;
        if (try self.read(value, reference_id, a.cpu_power_valid_reference_hz)) |raw| {
            value.raw_reference = raw;
            const hz = if (intel) d.intelReferenceHz(raw) else d.amdReferenceHz(raw);
            if (hz) |frequency| {
                value.reference_hz = frequency;
                value.valid_mask |= a.cpu_power_valid_reference_hz;
            }
        }
        if (try self.read(value, a.cpu_register_id_microcode, a.cpu_power_valid_microcode)) |raw| {
            value.raw_microcode = raw;
            const revision = if (intel) d.intelMicrocode(raw) else d.amdMicrocode(raw);
            if (revision) |number| {
                value.microcode_revision = number;
                value.valid_mask |= a.cpu_power_valid_microcode;
            }
        }
        if (intel) {
            const target = try self.read(value, a.cpu_register_id_intel_temperature_target, a.cpu_power_valid_temperature);
            const thermal = try self.read(value, a.cpu_register_id_intel_thermal_status, a.cpu_power_valid_temperature | a.cpu_power_valid_thermal_status);
            if (target) |raw| value.raw_temperature_target = raw;
            if (thermal) |raw| {
                value.raw_thermal_status = raw;
                value.thermal_current = d.thermalCurrent(raw);
                value.thermal_history = d.thermalHistory(raw);
                value.valid_mask |= a.cpu_power_valid_thermal_status;
                if (target) |raw_target| {
                    if (d.intelTemperatureMilliC(raw, raw_target)) |temperature| {
                        value.temperature_millic = temperature;
                        value.valid_mask |= a.cpu_power_valid_temperature;
                    }
                }
            }
        } else value.unsupported_mask |= a.cpu_power_valid_temperature | a.cpu_power_valid_thermal_status;
        const unit = try self.read(value, if (intel) a.cpu_register_id_intel_energy_unit else a.cpu_register_id_amd_energy_unit, a.cpu_power_valid_energy_unit | a.cpu_power_valid_package_energy | a.cpu_power_valid_core_energy);
        if (unit) |raw| {
            value.raw_energy_unit = raw;
            value.energy_exponent = d.energyExponent(raw);
            value.valid_mask |= a.cpu_power_valid_energy_unit;
            if (try self.read(value, if (intel) a.cpu_register_id_intel_package_energy else a.cpu_register_id_amd_package_energy, a.cpu_power_valid_package_energy)) |energy| {
                value.package_energy_raw = energy;
                value.package_energy_bits = 32;
                if (d.energyMicrojoules(energy, 32, value.energy_exponent)) |uj| {
                    value.package_energy_uj = uj;
                    value.valid_mask |= a.cpu_power_valid_package_energy;
                }
            }
            if (try self.read(value, if (intel) a.cpu_register_id_intel_core_energy else a.cpu_register_id_amd_core_energy, a.cpu_power_valid_core_energy)) |energy| {
                value.core_energy_raw = energy;
                value.core_energy_bits = 32;
                if (d.energyMicrojoules(energy, 32, value.energy_exponent)) |uj| {
                    value.core_energy_uj = uj;
                    value.valid_mask |= a.cpu_power_valid_core_energy;
                }
            }
        }
        return try self.readCounters(value);
    }
    fn stamp(value: a.CpuPowerInfo) d.Stamp {
        return .{ .cpu = value.cpu_index, .epoch = value.epoch, .generation = value.clock_generation, .ns = value.captured_ns };
    }
    pub fn capture(self: *Provider, cpu: u32, epoch: u64, out: *a.CpuPowerInfo) i32 {
        if (!validOutput(out)) return a.cpu_capabilities_error_invalid;
        var cap: a.CpuCapabilitiesInfo = .{};
        const result = self.capabilities(cpu, epoch, &cap);
        if (result != 0) return result;
        if (self.mechanism.currentCpu() != cpu) return a.cpu_capabilities_error_context;
        if (cap.flags & a.cpu_capabilities_flag_schedulable == 0) return a.cpu_capabilities_error_offline;
        const cell = &self.cells[cpu];
        if (cell.busy.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return a.cpu_capabilities_error_busy;
        defer cell.busy.store(false, .release);
        var before: a.MonotonicClockInfo = .{};
        if (!self.clock(&before)) return a.cpu_capabilities_error_busy;
        var value = metadata(cap);
        var pair: ?a.CpuPowerCounters = null;
        const profile: d.Profile = @enumFromInt(value.profile);
        if (profile == .intel_haswell or profile == .amd_milan_b1) {
            pair = self.observe(&value) catch |err| return if (err == error.Invalid) a.cpu_capabilities_error_invalid else a.cpu_capabilities_error_busy;
            self.scopes(&value, cap);
            value.state = a.cpu_power_state_observed;
        } else value.state = if (profile == .virtual) a.cpu_power_state_virtual else a.cpu_power_state_unsupported;
        var after: a.MonotonicClockInfo = .{};
        if (!self.clock(&after) or after.generation != before.generation or after.source != before.source or
            after.instant_ns < before.instant_ns or self.mechanism.currentCpu() != cpu) return a.cpu_capabilities_error_busy;
        var latest: a.CpuCapabilitiesInfo = .{};
        if (self.capabilities(cpu, epoch, &latest) != 0 or latest.flags & a.cpu_capabilities_flag_schedulable == 0) return a.cpu_capabilities_error_epoch;
        value.captured_ns = after.instant_ns;
        if (pair) |p| {
            if (p.clock_generation != after.generation or p.clock_source != after.source or
                p.captured_ns < before.instant_ns or p.captured_ns > after.instant_ns or p.capture_sequence != cap.capture_sequence) return a.cpu_capabilities_error_busy;
            value.captured_ns = p.captured_ns;
        }
        value.clock_generation = after.generation;
        value.clock_source = after.source;
        value.sequence = std.math.add(u64, cell.sample.sequence, 1) catch return a.cpu_capabilities_error_busy;
        value.flags |= a.cpu_power_flag_sampled;
        const old = cell.sample;
        if (d.compatible(stamp(old), stamp(value)) and old.clock_source == value.clock_source) {
            value.previous_ns = old.captured_ns;
            value.interval_ns = value.captured_ns - old.captured_ns;
            if (old.valid_mask & counters == counters and value.valid_mask & (counters | a.cpu_power_valid_reference_hz) == counters | a.cpu_power_valid_reference_hz and
                old.reference_hz == value.reference_hz)
            {
                if (d.activeHz(.{ .stamp = stamp(old), .aperf = old.aperf, .mperf = old.mperf }, .{ .stamp = stamp(value), .aperf = value.aperf, .mperf = value.mperf }, value.reference_hz)) |hz| {
                    value.active_hz = hz;
                    value.valid_mask |= a.cpu_power_valid_active_hz;
                }
            }
            if ((old.valid_mask & value.valid_mask & a.cpu_power_valid_package_energy != 0 and
                d.counterDiscontinuity(old.package_energy_raw, value.package_energy_raw, value.package_energy_bits)) or
                (old.valid_mask & value.valid_mask & a.cpu_power_valid_core_energy != 0 and
                    d.counterDiscontinuity(old.core_energy_raw, value.core_energy_raw, value.core_energy_bits))) value.flags |= a.cpu_power_flag_energy_discontinuity;
        }
        cell.sample = value;
        out.* = value;
        return 0;
    }
};
