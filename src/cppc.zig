// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! AMD PPR56569-A1 public3.03 sections1.8 / C00102B0..B4. Hints are abstract units;
//! their readback is not delivered performance. No automatic policy runs here.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const Mechanism = r4os.r4dev.DriverCpuPowerContext;
const Cell = struct {
    busy: std.atomic.Value(bool) = .init(false),
    info: a.CpuCppcInfo = .{},
    touched: bool = false,
    activation: bool = false,
};
pub const Provider = struct {
    mechanism: Mechanism,
    cells: [64]Cell = [_]Cell{.{}} ** 64,
    enabling: std.atomic.Value(bool) = .init(false),
    pub fn init(mechanism: Mechanism) Provider {
        return .{ .mechanism = mechanism };
    }
    fn profile(cap: a.CpuCapabilitiesInfo) bool {
        return std.mem.eql(u8, &cap.vendor_name, "AuthenticAMD") and cap.family == 0x19 and
            (cap.model >= 0x50 and cap.model <= 0x5f) and
            cap.flags & (a.cpu_capabilities_flag_signature | a.cpu_capabilities_flag_captured | a.cpu_capabilities_flag_hypervisor_present) ==
                a.cpu_capabilities_flag_signature | a.cpu_capabilities_flag_captured;
    }
    fn features(self: *const Provider, cap: a.CpuCapabilitiesInfo) ?u32 {
        if (!profile(cap) or cap.feature_count > 256) return null;
        for (0..cap.feature_count) |ordinal| {
            var f: a.CpuFeatureInfo = .{};
            if (self.mechanism.feature(cap.cpu_index, cap.epoch, @intCast(ordinal), &f) != 0 or
                f.cpu_index != cap.cpu_index or f.epoch != cap.epoch) return null;
            if (f.feature_id != a.cpu_feature_id_amd_cppc) continue;
            if (f.flags & a.cpu_feature_flag_raw == 0 or f.source_leaf != 0x80000008 or f.source_subleaf != 0 or
                f.source_register != 1 or f.source_bit != 27) return null;
            return f.raw_value;
        }
        return null;
    }
    fn supported(bits: u32) bool {
        return bits & (1 << 27) != 0;
    }
    fn read(self: *const Provider, info: *a.CpuCppcInfo, id: u32, target: *u64, valid: u32) i32 {
        var value: a.CpuRegisterInfo = .{};
        const result = self.mechanism.registerRead(info.cpu_index, info.epoch, id, &value);
        if (result != 0) return result;
        if (value.cpu_index != info.cpu_index or value.epoch != info.epoch or value.register_id != id or
            value.flags & a.cpu_register_flag_raw == 0) return a.cpu_capabilities_error_invalid;
        target.* = value.value;
        info.raw_valid_mask |= switch (id) {
            a.cpu_register_id_amd_cppc_enable => a.cpu_cppc_raw_enable,
            a.cpu_register_id_amd_cppc_capabilities1 => a.cpu_cppc_raw_capability1,
            a.cpu_register_id_amd_cppc_capabilities2 => a.cpu_cppc_raw_capability2,
            a.cpu_register_id_amd_cppc_request => a.cpu_cppc_raw_request,
            a.cpu_register_id_amd_cppc_status => a.cpu_cppc_raw_status,
            else => unreachable,
        };
        info.valid_mask |= valid;
        return 0;
    }
    fn stamp(self: *const Provider, info: *a.CpuCppcInfo) void {
        var clock: a.MonotonicClockInfo = .{};
        if (self.mechanism.clock(&clock) == 1 and clock.flags & a.monotonic_clock_flag_valid != 0 and
            clock.generation != 0 and clock.generation != std.math.maxInt(u32))
        {
            info.captured_ns = clock.instant_ns;
            info.clock_generation = clock.generation;
            info.clock_source = clock.source;
            info.valid_mask |= a.cpu_cppc_valid_time;
        }
    }
    fn normalize(info: *a.CpuCppcInfo) void {
        if (info.valid_mask & a.cpu_cppc_valid_request != 0) {
            info.minimum = @intCast((info.raw_request >> 8) & 255);
            info.maximum = @intCast(info.raw_request & 255);
            info.desired = @intCast((info.raw_request >> 16) & 255);
            info.epp = @intCast((info.raw_request >> 24) & 255);
        } else {
            info.minimum = 0;
            info.maximum = 0;
            info.desired = 0;
            info.epp = 0;
        }
        if (info.valid_mask & a.cpu_cppc_valid_range == 0) {
            info.highest = 0;
            info.nominal = 0;
            info.lowest_nonlinear = 0;
            info.lowest = 0;
        }
    }
    fn observe(self: *const Provider, info: *a.CpuCppcInfo) i32 {
        if (info.lease == 0) info.last_error = 0;
        info.valid_mask = 0;
        info.raw_valid_mask = 0;
        info.raw_enable = 0;
        info.raw_capability1 = 0;
        info.raw_capability2 = 0;
        info.raw_request = 0;
        info.raw_status = 0;
        info.captured_ns = 0;
        info.clock_generation = 0;
        info.clock_source = 0;
        info.highest = 0;
        info.nominal = 0;
        info.lowest_nonlinear = 0;
        info.lowest = 0;
        info.minimum = 0;
        info.maximum = 0;
        info.desired = 0;
        info.epp = 0;
        info.hint_sequence = 0;
        info.flags &= ~(a.cpu_performance_flag_parameters_restored | a.cpu_cppc_flag_rank_published);
        // Capture starts before the hardware window. Preemption cannot make
        // old capabilities look freshly sampled when publication finally runs.
        self.stamp(info);
        var result = self.read(info, a.cpu_register_id_amd_cppc_enable, &info.raw_enable, 0);
        if (result != 0) return result;
        if (info.raw_enable > 1) return a.cpu_capabilities_error_unsupported;
        info.valid_mask |= a.cpu_cppc_valid_enable;
        if (info.raw_enable == 0) {
            if (info.lease == 0) info.state = a.cpu_performance_state_disabled;
            return 0;
        }
        info.flags |= a.cpu_performance_flag_sticky_enabled;
        result = self.read(info, a.cpu_register_id_amd_cppc_capabilities1, &info.raw_capability1, 0);
        if (result != 0) return result;
        const raw = info.raw_capability1;
        const highest: u32 = @intCast((raw >> 24) & 255);
        const nominal: u32 = @intCast((raw >> 16) & 255);
        const nonlinear: u32 = @intCast((raw >> 8) & 255);
        const lowest: u32 = @intCast(raw & 255);
        if (raw >> 32 != 0 or lowest == 0 or lowest > nonlinear or nonlinear > nominal or nominal > highest)
            return a.cpu_capabilities_error_unsupported;
        info.highest = highest;
        info.nominal = nominal;
        info.lowest_nonlinear = nonlinear;
        info.lowest = lowest;
        info.valid_mask |= a.cpu_cppc_valid_range;
        result = self.read(info, a.cpu_register_id_amd_cppc_request, &info.raw_request, 0);
        if (result != 0) return result;
        if (info.raw_request >> 32 != 0) return a.cpu_capabilities_error_unsupported;
        info.valid_mask |= a.cpu_cppc_valid_request;
        result = self.read(info, a.cpu_register_id_amd_cppc_capabilities2, &info.raw_capability2, 0);
        if (result != 0) return result;
        if (info.raw_capability2 >> 8 != 0) return a.cpu_capabilities_error_unsupported;
        info.valid_mask |= a.cpu_cppc_valid_current_limit;
        result = self.read(info, a.cpu_register_id_amd_cppc_status, &info.raw_status, 0);
        if (result != 0) return result;
        if (info.raw_status & ~@as(u64, 2) != 0) return a.cpu_capabilities_error_unsupported;
        info.valid_mask |= a.cpu_cppc_valid_status;
        if (info.lease == 0) info.state = a.cpu_performance_state_ready;
        normalize(info);
        return 0;
    }
    fn package(self: *const Provider, cap: a.CpuCapabilitiesInfo, info: *a.CpuCppcInfo, core: *u64) bool {
        var own: a.CpuTopologyInfo = .{};
        if (cap.configured_cpus == 0 or cap.configured_cpus > 64 or
            self.mechanism.topology(cap.cpu_index, &own) != a.cpu_topology_result_ok or
            own.cpu_index != cap.cpu_index or own.configured_cpus != cap.configured_cpus or
            own.start_epoch != cap.epoch or own.flags & a.cpu_topology_flag_geometry == 0 or
            !std.mem.eql(u8, &own.vendor_name, &cap.vendor_name)) return false;
        var mask: u64 = 0;
        core.* = 0;
        for (0..cap.configured_cpus) |index| {
            var peer: a.CpuTopologyInfo = .{};
            if (self.mechanism.topology(@intCast(index), &peer) != a.cpu_topology_result_ok or
                peer.cpu_index != index or peer.flags & a.cpu_topology_flag_geometry == 0 or
                peer.configured_cpus != cap.configured_cpus or peer.package_id != own.package_id or
                !std.mem.eql(u8, &peer.vendor_name, &cap.vendor_name)) return false;
            var other: a.CpuCapabilitiesInfo = .{};
            if (self.mechanism.capabilities(@intCast(index), &other) != 0 or other.cpu_index != index or
                other.epoch == 0 or other.epoch != peer.start_epoch or other.configured_cpus != cap.configured_cpus or
                other.flags & a.cpu_capabilities_flag_schedulable == 0 or other.model != cap.model or
                peer.logical_per_package_bound != own.logical_per_package_bound or peer.package_shift != own.package_shift)
                return false;
            const bits = self.features(other) orelse return false;
            if (!supported(bits)) return false;
            const bit = @as(u64, 1) << @as(u6, @intCast(index));
            mask |= bit;
            if (peer.core_id == own.core_id and peer.smt_shift == own.smt_shift) core.* |= bit;
        }
        // The source does not specify ENABLE instance scope. Authorize every
        // configured CPU in one complete package, but attest only local readback.
        if (mask & (@as(u64, 1) << @as(u6, @intCast(cap.cpu_index))) == 0 or
            @popCount(mask) != own.logical_per_package_bound or core.* == 0) return false;
        info.qualified_mask = mask;
        info.valid_mask |= a.cpu_cppc_valid_scope;
        return true;
    }
    fn publish(self: *const Provider, cap: a.CpuCapabilitiesInfo, info: *a.CpuCppcInfo) void {
        var input: a.CpuPerformanceHint = .{ .cpu_index = info.cpu_index, .epoch = info.epoch };
        var core: u64 = 0;
        var after: a.MonotonicClockInfo = .{};
        const required = a.cpu_cppc_valid_range | a.cpu_cppc_valid_time;
        if (info.raw_enable == 1 and info.valid_mask & required == required and self.package(cap, info, &core) and
            self.mechanism.clock(&after) == 1 and after.flags & a.monotonic_clock_flag_valid != 0 and
            after.generation == info.clock_generation and after.source == info.clock_source and
            info.captured_ns != 0 and after.instant_ns >= info.captured_ns and
            after.instant_ns - info.captured_ns <= a.cpu_performance_hint_max_age_ns)
        {
            input.flags = a.cpu_performance_hint_flag_valid;
            input.captured_ns = info.captured_ns;
            input.scope_mask = info.qualified_mask;
            input.core_mask = core;
            input.rank = info.highest;
            input.scale = 0x01000000 | (info.nominal << 16) | (info.lowest_nonlinear << 8) | info.lowest;
            input.clock_generation = info.clock_generation;
            input.clock_source = info.clock_source;
        }
        var sequence: u64 = 0;
        if (self.mechanism.rankPublish(&input, &sequence) == 0 and input.flags != 0 and sequence != 0) {
            info.hint_sequence = sequence;
            info.valid_mask |= a.cpu_cppc_valid_rank;
            info.flags |= a.cpu_cppc_flag_rank_published;
        }
    }
    fn observeReturn(self: *const Provider, info: *a.CpuCppcInfo, activation: bool, touched: bool) i32 {
        // Return requires only the owned register, independent of CAP1/CAP2/status.
        info.valid_mask = 0;
        info.raw_valid_mask = 0;
        info.flags &= ~(a.cpu_performance_flag_parameters_restored | a.cpu_cppc_flag_rank_published);
        info.hint_sequence = 0;
        var result = self.read(info, a.cpu_register_id_amd_cppc_enable, &info.raw_enable, 0);
        if (result != 0) return result;
        if (info.raw_enable > 1) return a.cpu_capabilities_error_unsupported;
        info.valid_mask |= a.cpu_cppc_valid_enable;
        if (info.raw_enable == 1) info.flags |= a.cpu_performance_flag_sticky_enabled;
        if (!activation and touched and info.raw_enable == 1) {
            result = self.read(info, a.cpu_register_id_amd_cppc_request, &info.raw_request, 0);
            if (result != 0) return result;
            if (info.raw_request >> 32 != 0) return a.cpu_capabilities_error_unsupported;
            info.valid_mask |= a.cpu_cppc_valid_request;
        }
        self.stamp(info);
        return 0;
    }
    fn emptyParameters(request: a.CpuPerformanceRequest) bool {
        return request.minimum == 0 and request.maximum == 0 and request.desired == 0 and request.epp == 0;
    }
    fn validRequest(request: a.CpuPerformanceRequest) bool {
        if (request.version != 1 or request.size < @sizeOf(a.CpuPerformanceRequest) or request.reserved0 != 0) return false;
        return switch (request.operation) {
            a.cpu_performance_op_inspect => emptyParameters(request) and request.flags == 0 and request.lease == 0 and request.expected_revision == 0,
            a.cpu_performance_op_apply => request.flags & ~a.cpu_performance_request_flag_epp == 0 and
                (request.flags & a.cpu_performance_request_flag_epp != 0 or request.epp == 0),
            a.cpu_performance_op_release => emptyParameters(request) and request.flags == 0 and request.lease != 0,
            a.cpu_performance_op_enable => emptyParameters(request) and request.flags == a.cpu_performance_request_flag_sticky_enable and
                request.lease == 0 and request.expected_revision == 0,
            else => false,
        };
    }
    fn bounds(request: a.CpuPerformanceRequest, info: a.CpuCppcInfo) i32 {
        if (info.raw_enable != 1 or info.valid_mask & (a.cpu_cppc_valid_range | a.cpu_cppc_valid_request) !=
            a.cpu_cppc_valid_range | a.cpu_cppc_valid_request) return a.cpu_capabilities_error_unsupported;
        if (request.minimum < info.lowest or request.maximum > info.highest or request.minimum > request.maximum or
            request.minimum > 255 or request.maximum > 255 or request.epp > 255 or
            (request.desired != 0 and (request.desired < request.minimum or request.desired > request.maximum))) return a.cpu_capabilities_error_invalid;
        return 0;
    }
    fn dropControl(self: *const Provider, cell: *Cell, restored: bool) bool {
        const info = &cell.info;
        const result = self.mechanism.controlRelease(info.cpu_index, info.epoch, info.lease);
        if (result != 0) {
            info.state = a.cpu_performance_state_uncertain;
            info.last_error = result;
            return false;
        }
        info.lease = 0;
        info.state = if (restored) a.cpu_performance_state_restored else if (info.raw_enable == 1) a.cpu_performance_state_ready else a.cpu_performance_state_disabled;
        if (restored) info.flags |= a.cpu_performance_flag_parameters_restored;
        if (restored) info.last_error = 0;
        cell.touched = false;
        cell.activation = false;
        return true;
    }
    fn write(self: *const Provider, cell: *Cell, id: u32, expected: u64, target: u64) ?a.CpuRegisterWriteInfo {
        var receipt: a.CpuRegisterWriteInfo = .{};
        const info = &cell.info;
        const result = self.mechanism.registerCompareWrite(info.cpu_index, info.epoch, info.lease, id, expected, target, &receipt);
        if (result != 0) {
            info.last_error = result;
            return null;
        }
        if (receipt.cpu_index != info.cpu_index or receipt.epoch != info.epoch or receipt.lease != info.lease or
            receipt.register_id != id or receipt.expected != expected or receipt.requested != target or
            receipt.flags & a.cpu_register_write_flag_before == 0)
        {
            // A malformed peer cannot attest that no write occurred.
            info.last_error = a.cpu_capabilities_error_invalid;
            info.state = a.cpu_performance_state_uncertain;
            return .{ .flags = a.cpu_register_write_flag_attempted, .last_error = info.last_error };
        }
        info.last_error = receipt.last_error;
        if (receipt.flags & a.cpu_register_write_flag_attempted != 0) info.attempted_id = id;
        if (receipt.flags & a.cpu_register_write_flag_after != 0) {
            if (id == a.cpu_register_id_amd_cppc_enable) {
                info.raw_enable = receipt.observed_after;
                info.valid_mask |= a.cpu_cppc_valid_enable;
                info.raw_valid_mask |= a.cpu_cppc_raw_enable;
                if (info.raw_enable == 1) info.flags |= a.cpu_performance_flag_sticky_enabled;
            } else {
                info.raw_request = receipt.observed_after;
                info.valid_mask |= a.cpu_cppc_valid_request;
                info.raw_valid_mask |= a.cpu_cppc_raw_request;
                info.minimum = @intCast((info.raw_request >> 8) & 255);
                info.maximum = @intCast(info.raw_request & 255);
                info.desired = @intCast((info.raw_request >> 16) & 255);
                info.epp = @intCast((info.raw_request >> 24) & 255);
            }
        } else if (receipt.flags & a.cpu_register_write_flag_attempted != 0) {
            info.valid_mask &= ~@as(u32, if (id == a.cpu_register_id_amd_cppc_enable) a.cpu_cppc_valid_enable else a.cpu_cppc_valid_request);
            info.raw_valid_mask &= ~@as(u32, if (id == a.cpu_register_id_amd_cppc_enable) a.cpu_cppc_raw_enable else a.cpu_cppc_raw_request);
        }
        return receipt;
    }
    fn confirmed(receipt: a.CpuRegisterWriteInfo, target: u64) bool {
        const flags = a.cpu_register_write_flag_attempted | a.cpu_register_write_flag_written | a.cpu_register_write_flag_after;
        return receipt.flags & flags == flags and receipt.last_error == 0 and receipt.observed_after == target;
    }
    fn apply(self: *const Provider, cell: *Cell, request: a.CpuPerformanceRequest, observed: a.CpuCppcInfo) i32 {
        const result = bounds(request, observed);
        if (result != 0) return result;
        if (cell.info.lease != 0 and (cell.info.state != a.cpu_performance_state_owned or
            request.lease != cell.info.lease or request.expected_revision != cell.info.revision or cell.activation)) return a.cpu_capabilities_error_epoch;
        if (cell.info.lease == 0 and (request.lease != 0 or request.expected_revision != 0)) return a.cpu_capabilities_error_epoch;
        const old = cell.info;
        if (old.revision >= std.math.maxInt(u64) - 1) return a.cpu_capabilities_error_busy;
        const touched = cell.touched;
        const fresh = old.lease == 0;
        var info = observed;
        info.revision = std.math.add(u64, old.revision, 1) catch return a.cpu_capabilities_error_busy;
        if (fresh) {
            info.baseline_request = info.raw_request;
            info.last_written = info.raw_request;
            const acquire = self.mechanism.controlAcquire(info.cpu_index, info.epoch, &info.lease);
            if (acquire != 0) return acquire;
        }
        // Resident pending state precedes every possible instruction. Neither
        // cancellation nor a failed readback can lose the baseline/token.
        const mask: u64 = if (request.flags & a.cpu_performance_request_flag_epp != 0) 0xffffffff else 0xffffff;
        const target = (info.raw_request & ~mask) | request.maximum | (@as(u64, request.minimum) << 8) |
            (@as(u64, request.desired) << 16) | (if (request.flags & a.cpu_performance_request_flag_epp != 0) @as(u64, request.epp) << 24 else 0);
        info.state = a.cpu_performance_state_uncertain;
        info.last_written = target;
        cell.info = info;
        cell.touched = true;
        const receipt = self.write(cell, a.cpu_register_id_amd_cppc_request, observed.raw_request, target) orelse {
            const failure = cell.info.last_error;
            cell.touched = touched;
            cell.info.last_written = old.last_written;
            if (fresh) {
                if (!self.dropControl(cell, false)) return 0;
            }
            cell.info = old;
            return failure;
        };
        if (receipt.flags & a.cpu_register_write_flag_attempted == 0) {
            cell.touched = touched;
            cell.info.last_written = if (fresh) observed.raw_request else old.last_written;
            cell.info.raw_request = receipt.observed_before;
            cell.info.state = a.cpu_performance_state_conflict;
            if (fresh) {
                _ = self.dropControl(cell, false);
                if (cell.info.lease == 0) cell.info.state = a.cpu_performance_state_conflict;
            }
        } else if (confirmed(receipt, target)) cell.info.state = a.cpu_performance_state_owned;
        return 0;
    }
    fn release(self: *const Provider, cell: *Cell, request: a.CpuPerformanceRequest, observed: a.CpuCppcInfo) i32 {
        if (cell.info.lease == 0 or request.lease != cell.info.lease or request.expected_revision != cell.info.revision) return a.cpu_capabilities_error_epoch;
        // Exhaustion closes new work, never the owner's remaining return path.
        // At the terminal revision, repeated release remains idempotent and can
        // only restore the same baseline; tokens and CPU epochs never recycle.
        const revision = cell.info.revision +| 1;
        cell.info = observed;
        cell.info.revision = revision;
        if (cell.activation or !cell.touched) {
            cell.info.last_error = 0;
            _ = self.dropControl(cell, false);
            return 0;
        }
        const baseline = cell.info.baseline_request;
        if (observed.valid_mask & a.cpu_cppc_valid_request == 0) {
            cell.info.state = a.cpu_performance_state_uncertain;
            return 0;
        }
        if (observed.raw_request == baseline) {
            _ = self.dropControl(cell, true);
            return 0;
        }
        if (observed.raw_request != cell.info.last_written) {
            cell.info.state = a.cpu_performance_state_conflict;
            cell.info.last_error = a.cpu_capabilities_error_busy;
            return 0;
        }
        cell.info.state = a.cpu_performance_state_uncertain;
        const receipt = self.write(cell, a.cpu_register_id_amd_cppc_request, observed.raw_request, baseline) orelse return 0;
        if (receipt.flags & a.cpu_register_write_flag_attempted != 0) cell.info.last_written = baseline;
        if (confirmed(receipt, baseline)) _ = self.dropControl(cell, true);
        return 0;
    }
    fn enable(self: *Provider, cell: *Cell, cap: a.CpuCapabilitiesInfo, observed: a.CpuCppcInfo) i32 {
        if (cell.info.lease != 0) return a.cpu_capabilities_error_busy;
        var info = observed;
        if (info.raw_enable == 1) {
            cell.info = info;
            return 0;
        }
        if (self.enabling.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return a.cpu_capabilities_error_busy;
        defer self.enabling.store(false, .release);
        var core: u64 = 0;
        if (!self.package(cap, &info, &core)) return a.cpu_capabilities_error_unsupported;
        if (cell.info.revision >= std.math.maxInt(u64) - 1) return a.cpu_capabilities_error_busy;
        info.revision = std.math.add(u64, cell.info.revision, 1) catch return a.cpu_capabilities_error_busy;
        const result = self.mechanism.controlAcquire(info.cpu_index, info.epoch, &info.lease);
        if (result != 0) return result;
        cell.info = info;
        cell.info.state = a.cpu_performance_state_uncertain;
        cell.activation = true;
        cell.touched = true;
        const receipt = self.write(cell, a.cpu_register_id_amd_cppc_enable, 0, 1) orelse {
            const failure = cell.info.last_error;
            cell.touched = false;
            if (!self.dropControl(cell, false)) return 0;
            return failure;
        };
        if (receipt.flags & a.cpu_register_write_flag_after != 0 and receipt.observed_after <= 1) {
            _ = self.dropControl(cell, false);
        } else if (receipt.flags & a.cpu_register_write_flag_attempted == 0) {
            cell.info.raw_enable = receipt.observed_before;
            if (cell.info.raw_enable == 1) cell.info.flags |= a.cpu_performance_flag_sticky_enabled;
            _ = self.dropControl(cell, false);
        }
        return 0;
    }
    pub fn execute(self: *Provider, request: a.CpuPerformanceRequest, out: *a.CpuCppcInfo) i32 {
        if (!validRequest(request) or out.version != 1 or out.size < @sizeOf(a.CpuCppcInfo)) return a.cpu_capabilities_error_invalid;
        if (request.cpu_index >= self.cells.len) return a.cpu_capabilities_error_index;
        var cap: a.CpuCapabilitiesInfo = .{};
        const result = self.mechanism.capabilities(request.cpu_index, &cap);
        if (result != 0) return result;
        if (request.epoch == 0 or cap.epoch != request.epoch) return a.cpu_capabilities_error_epoch;
        if (self.mechanism.currentCpu() != request.cpu_index) return a.cpu_capabilities_error_context;
        if (cap.flags & a.cpu_capabilities_flag_schedulable == 0) return a.cpu_capabilities_error_offline;
        const cell = &self.cells[request.cpu_index];
        if (cell.busy.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return a.cpu_capabilities_error_busy;
        defer cell.busy.store(false, .release);
        if (cell.info.lease != 0 and cell.info.epoch != request.epoch) return a.cpu_capabilities_error_epoch;
        var info = if (cell.info.epoch == request.epoch) cell.info else a.CpuCppcInfo{ .cpu_index = request.cpu_index, .epoch = request.epoch };
        const bits = self.features(cap);
        info.features = bits orelse 0;
        if (cap.flags & a.cpu_capabilities_flag_hypervisor_present != 0) info.flags |= a.cpu_performance_flag_virtual;
        if (bits == null or !supported(info.features)) {
            if (request.operation != a.cpu_performance_op_inspect) return a.cpu_capabilities_error_unsupported;
            info.state = a.cpu_performance_state_unsupported;
            info.valid_mask = 0;
            info.raw_valid_mask = 0;
            self.publish(cap, &info);
            normalize(&info);
            out.* = info;
            return 0;
        }
        info.flags |= a.cpu_performance_flag_epp;
        if (request.operation == a.cpu_performance_op_release and (info.lease == 0 or request.lease != info.lease or
            request.expected_revision != info.revision)) return a.cpu_capabilities_error_epoch;
        const observed = if (request.operation == a.cpu_performance_op_release)
            self.observeReturn(&info, cell.activation, cell.touched)
        else
            self.observe(&info);
        if (observed != 0) {
            if (request.operation != a.cpu_performance_op_inspect and request.operation != a.cpu_performance_op_release) return observed;
            info.state = a.cpu_performance_state_uncertain;
            info.last_error = observed;
            self.publish(cap, &info);
            normalize(&info);
            out.* = info;
            return 0;
        }
        const operation = switch (request.operation) {
            a.cpu_performance_op_inspect => blk: {
                cell.info = info;
                break :blk @as(i32, 0);
            },
            a.cpu_performance_op_apply => self.apply(cell, request, info),
            a.cpu_performance_op_release => self.release(cell, request, info),
            a.cpu_performance_op_enable => self.enable(cell, cap, info),
            else => unreachable,
        };
        if (operation != 0) return operation;
        self.publish(cap, &cell.info);
        normalize(&cell.info);
        out.* = cell.info;
        return 0;
    }
};
