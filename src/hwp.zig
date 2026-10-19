// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Intel SDM093 Vol3B17.4 / Vol4 table2-39. Hints are abstract units;
//! their readback is not delivered performance. No automatic policy runs here.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const Mechanism = r4os.r4dev.DriverCpuPowerContext;
const Cell = struct {
    busy: std.atomic.Value(bool) = .init(false),
    info: a.CpuPerformanceInfo = .{},
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
        return std.mem.eql(u8, &cap.vendor_name, "GenuineIntel") and cap.family == 6 and
            (cap.model == 0x4e or cap.model == 0x5e) and
            cap.flags & (a.cpu_capabilities_flag_signature | a.cpu_capabilities_flag_captured | a.cpu_capabilities_flag_hypervisor_present) ==
                a.cpu_capabilities_flag_signature | a.cpu_capabilities_flag_captured;
    }
    fn features(self: *const Provider, cap: a.CpuCapabilitiesInfo) ?u32 {
        if (!profile(cap) or cap.feature_count > 256) return null;
        for (0..cap.feature_count) |ordinal| {
            var f: a.CpuFeatureInfo = .{};
            if (self.mechanism.feature(cap.cpu_index, cap.epoch, @intCast(ordinal), &f) != 0 or
                f.cpu_index != cap.cpu_index or f.epoch != cap.epoch) return null;
            if (f.feature_id != a.cpu_feature_id_intel_hwp) continue;
            if (f.flags & a.cpu_feature_flag_raw == 0 or f.source_leaf != 6 or f.source_subleaf != 0 or
                f.source_register != 0 or f.source_bit != 7) return null;
            return f.raw_value;
        }
        return null;
    }
    fn supported(bits: u32) bool {
        return bits & (1 << 7) != 0 and bits & ((1 << 16) | (1 << 18) | (1 << 22)) == 0;
    }
    fn read(self: *const Provider, info: *a.CpuPerformanceInfo, id: u32, target: *u64, mask: u32) i32 {
        var value: a.CpuRegisterInfo = .{};
        const result = self.mechanism.registerRead(info.cpu_index, info.epoch, id, &value);
        if (result != 0) return result;
        if (value.cpu_index != info.cpu_index or value.epoch != info.epoch or value.register_id != id or
            value.flags & a.cpu_register_flag_raw == 0) return a.cpu_capabilities_error_invalid;
        target.* = value.value;
        info.valid_mask |= mask;
        return 0;
    }
    fn knownFields(bits: u32) u64 {
        var result: u64 = 0xffffff;
        if (bits & (1 << 10) != 0) result |= 0xff000000;
        if (bits & (1 << 9) != 0) result |= @as(u64, 0x3ff) << 32;
        if (bits & (1 << 11) != 0) result |= @as(u64, 1) << 42;
        if (bits & (1 << 17) != 0) result |= @as(u64, 0x1f) << 59;
        return result;
    }
    fn stamp(self: *const Provider, info: *a.CpuPerformanceInfo) void {
        var clock: a.MonotonicClockInfo = .{};
        if (self.mechanism.clock(&clock) == 1 and clock.flags & a.monotonic_clock_flag_valid != 0 and
            clock.generation != 0 and clock.generation != std.math.maxInt(u32))
        {
            info.captured_ns = clock.instant_ns;
            info.valid_mask |= a.cpu_performance_valid_time;
        }
    }
    fn normalize(info: *a.CpuPerformanceInfo) void {
        if (info.valid_mask & a.cpu_performance_valid_request != 0) {
            info.minimum = @intCast(info.raw_request & 255);
            info.maximum = @intCast((info.raw_request >> 8) & 255);
            info.desired = @intCast((info.raw_request >> 16) & 255);
            info.epp = if (info.features & (1 << 10) != 0) @intCast((info.raw_request >> 24) & 255) else 0;
        } else {
            info.minimum = 0;
            info.maximum = 0;
            info.desired = 0;
            info.epp = 0;
        }
        if (info.valid_mask & a.cpu_performance_valid_capabilities == 0) {
            info.highest = 0;
            info.guaranteed = 0;
            info.efficient = 0;
            info.lowest = 0;
        }
    }
    fn observe(self: *const Provider, info: *a.CpuPerformanceInfo) i32 {
        if (info.lease == 0) info.last_error = 0;
        info.valid_mask = 0;
        info.raw_enable = 0;
        info.raw_capabilities = 0;
        info.raw_request = 0;
        info.raw_package = 0;
        info.captured_ns = 0;
        info.highest = 0;
        info.guaranteed = 0;
        info.efficient = 0;
        info.lowest = 0;
        info.minimum = 0;
        info.maximum = 0;
        info.desired = 0;
        info.epp = 0;
        info.flags &= ~a.cpu_performance_flag_parameters_restored;
        var result = self.read(info, a.cpu_register_id_intel_hwp_enable, &info.raw_enable, a.cpu_performance_valid_enable);
        if (result != 0) return result;
        if (info.raw_enable > 1) return a.cpu_capabilities_error_unsupported;
        if (info.raw_enable == 0) {
            // Additional HWP registers #GP while disabled. Never probe them.
            if (info.lease == 0) info.state = a.cpu_performance_state_disabled;
            self.stamp(info);
            return 0;
        }
        info.flags |= a.cpu_performance_flag_sticky_enabled;
        result = self.read(info, a.cpu_register_id_intel_hwp_capabilities, &info.raw_capabilities, a.cpu_performance_valid_capabilities);
        if (result != 0) return result;
        const raw = info.raw_capabilities;
        info.highest = @intCast(raw & 255);
        info.guaranteed = @intCast((raw >> 8) & 255);
        info.efficient = @intCast((raw >> 16) & 255);
        info.lowest = @intCast((raw >> 24) & 255);
        if (raw >> 32 != 0 or info.lowest == 0 or info.highest < info.lowest or
            info.guaranteed < info.lowest or info.guaranteed > info.highest or
            info.efficient < info.lowest or info.efficient > info.highest) return a.cpu_capabilities_error_unsupported;
        result = self.read(info, a.cpu_register_id_intel_hwp_request, &info.raw_request, a.cpu_performance_valid_request);
        if (result != 0) return result;
        if (info.raw_request & ~knownFields(info.features) != 0) return a.cpu_capabilities_error_unsupported;
        info.minimum = @intCast(info.raw_request & 255);
        info.maximum = @intCast((info.raw_request >> 8) & 255);
        info.desired = @intCast((info.raw_request >> 16) & 255);
        if (info.features & (1 << 10) != 0) info.epp = @intCast((info.raw_request >> 24) & 255);
        if (info.features & (1 << 11) != 0) {
            result = self.read(info, a.cpu_register_id_intel_hwp_package, &info.raw_package, a.cpu_performance_valid_package);
            if (result != 0) return result;
        }
        if (info.lease == 0) info.state = a.cpu_performance_state_ready;
        self.stamp(info);
        return 0;
    }
    fn package(self: *const Provider, cap: a.CpuCapabilitiesInfo, info: *a.CpuPerformanceInfo) bool {
        var own: a.CpuTopologyInfo = .{};
        if (cap.configured_cpus == 0 or cap.configured_cpus > 64 or
            self.mechanism.topology(cap.cpu_index, &own) != a.cpu_topology_result_ok or
            own.cpu_index != cap.cpu_index or own.configured_cpus != cap.configured_cpus or
            own.start_epoch != cap.epoch or own.flags & a.cpu_topology_flag_geometry == 0 or
            !std.mem.eql(u8, &own.vendor_name, &cap.vendor_name)) return false;
        var mask: u64 = 0;
        for (0..cap.configured_cpus) |index| {
            var peer: a.CpuTopologyInfo = .{};
            if (self.mechanism.topology(@intCast(index), &peer) != a.cpu_topology_result_ok or
                peer.cpu_index != index or peer.flags & a.cpu_topology_flag_geometry == 0 or
                peer.configured_cpus != cap.configured_cpus or
                !std.mem.eql(u8, &peer.vendor_name, &cap.vendor_name)) return false;
            if (peer.package_id != own.package_id) continue;
            var other: a.CpuCapabilitiesInfo = .{};
            if (self.mechanism.capabilities(@intCast(index), &other) != 0 or other.cpu_index != index or
                other.epoch == 0 or other.epoch != peer.start_epoch or other.configured_cpus != cap.configured_cpus or
                other.flags & a.cpu_capabilities_flag_schedulable == 0 or other.model != cap.model or
                peer.logical_per_package_bound != own.logical_per_package_bound) return false;
            const bits = self.features(other) orelse return false;
            if (!supported(bits)) return false;
            mask |= @as(u64, 1) << @as(u6, @intCast(index));
        }
        // The advertised bound can exceed admitted membership. Such a package
        // is not evidence that all affected CPUs are known; activation refuses.
        if (mask & (@as(u64, 1) << @as(u6, @intCast(cap.cpu_index))) == 0 or
            @popCount(mask) != own.logical_per_package_bound) return false;
        info.package_mask = mask;
        info.package_leader = @ctz(mask);
        info.valid_mask |= a.cpu_performance_valid_scope;
        return true;
    }
    fn observeReturn(self: *const Provider, info: *a.CpuPerformanceInfo, activation: bool, touched: bool) i32 {
        // Cleanup depends on the owned register, never an unrelated dynamic
        // capability/package read or optional diagnostic being available.
        info.valid_mask = 0;
        info.flags &= ~a.cpu_performance_flag_parameters_restored;
        var result = self.read(info, a.cpu_register_id_intel_hwp_enable, &info.raw_enable, a.cpu_performance_valid_enable);
        if (result != 0) return result;
        if (info.raw_enable > 1) return a.cpu_capabilities_error_unsupported;
        if (info.raw_enable == 1) info.flags |= a.cpu_performance_flag_sticky_enabled;
        if (!activation and touched and info.raw_enable == 1) {
            result = self.read(info, a.cpu_register_id_intel_hwp_request, &info.raw_request, a.cpu_performance_valid_request);
            if (result != 0) return result;
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
    fn bounds(request: a.CpuPerformanceRequest, info: a.CpuPerformanceInfo) i32 {
        if (info.raw_enable != 1 or info.valid_mask & (a.cpu_performance_valid_capabilities | a.cpu_performance_valid_request) !=
            a.cpu_performance_valid_capabilities | a.cpu_performance_valid_request or info.raw_request & (@as(u64, 1) << 42) != 0) return a.cpu_capabilities_error_unsupported;
        if (request.flags & a.cpu_performance_request_flag_epp != 0 and info.features & (1 << 10) == 0) return a.cpu_capabilities_error_unsupported;
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
            if (id == a.cpu_register_id_intel_hwp_enable) {
                info.raw_enable = receipt.observed_after;
                info.valid_mask |= a.cpu_performance_valid_enable;
                if (info.raw_enable == 1) info.flags |= a.cpu_performance_flag_sticky_enabled;
            } else {
                info.raw_request = receipt.observed_after;
                info.valid_mask |= a.cpu_performance_valid_request;
                info.minimum = @intCast(info.raw_request & 255);
                info.maximum = @intCast((info.raw_request >> 8) & 255);
                info.desired = @intCast((info.raw_request >> 16) & 255);
                info.epp = if (info.features & (1 << 10) != 0) @intCast((info.raw_request >> 24) & 255) else 0;
            }
        } else if (receipt.flags & a.cpu_register_write_flag_attempted != 0) {
            info.valid_mask &= ~@as(u32, if (id == a.cpu_register_id_intel_hwp_enable) a.cpu_performance_valid_enable else a.cpu_performance_valid_request);
        }
        return receipt;
    }
    fn confirmed(receipt: a.CpuRegisterWriteInfo, target: u64) bool {
        const flags = a.cpu_register_write_flag_attempted | a.cpu_register_write_flag_written | a.cpu_register_write_flag_after;
        return receipt.flags & flags == flags and receipt.last_error == 0 and receipt.observed_after == target;
    }
    fn apply(self: *const Provider, cell: *Cell, request: a.CpuPerformanceRequest, observed: a.CpuPerformanceInfo) i32 {
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
        const target = (info.raw_request & ~mask) | request.minimum | (@as(u64, request.maximum) << 8) |
            (@as(u64, request.desired) << 16) | (if (request.flags & a.cpu_performance_request_flag_epp != 0) @as(u64, request.epp) << 24 else 0);
        info.state = a.cpu_performance_state_uncertain;
        info.last_written = target;
        cell.info = info;
        cell.touched = true;
        const receipt = self.write(cell, a.cpu_register_id_intel_hwp_request, observed.raw_request, target) orelse {
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
    fn release(self: *const Provider, cell: *Cell, request: a.CpuPerformanceRequest, observed: a.CpuPerformanceInfo) i32 {
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
        if (observed.valid_mask & a.cpu_performance_valid_request == 0) {
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
        const receipt = self.write(cell, a.cpu_register_id_intel_hwp_request, observed.raw_request, baseline) orelse return 0;
        if (receipt.flags & a.cpu_register_write_flag_attempted != 0) cell.info.last_written = baseline;
        if (confirmed(receipt, baseline)) _ = self.dropControl(cell, true);
        return 0;
    }
    fn enable(self: *Provider, cell: *Cell, cap: a.CpuCapabilitiesInfo, observed: a.CpuPerformanceInfo) i32 {
        if (cell.info.lease != 0) return a.cpu_capabilities_error_busy;
        var info = observed;
        if (info.raw_enable == 1) {
            cell.info = info;
            return 0;
        }
        if (self.enabling.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return a.cpu_capabilities_error_busy;
        defer self.enabling.store(false, .release);
        if (!self.package(cap, &info)) return a.cpu_capabilities_error_unsupported;
        if (cell.info.revision >= std.math.maxInt(u64) - 1) return a.cpu_capabilities_error_busy;
        info.revision = std.math.add(u64, cell.info.revision, 1) catch return a.cpu_capabilities_error_busy;
        const result = self.mechanism.controlAcquire(info.cpu_index, info.epoch, &info.lease);
        if (result != 0) return result;
        cell.info = info;
        cell.info.state = a.cpu_performance_state_uncertain;
        cell.activation = true;
        cell.touched = true;
        const receipt = self.write(cell, a.cpu_register_id_intel_hwp_enable, 0, 1) orelse {
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
    pub fn execute(self: *Provider, request: a.CpuPerformanceRequest, out: *a.CpuPerformanceInfo) i32 {
        if (!validRequest(request) or out.version != 1 or out.size < @sizeOf(a.CpuPerformanceInfo)) return a.cpu_capabilities_error_invalid;
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
        var info = if (cell.info.epoch == request.epoch) cell.info else a.CpuPerformanceInfo{ .cpu_index = request.cpu_index, .epoch = request.epoch, .package_leader = a.cpu_power_cpu_none };
        const bits = self.features(cap);
        info.features = bits orelse 0;
        if (cap.flags & a.cpu_capabilities_flag_hypervisor_present != 0) info.flags |= a.cpu_performance_flag_virtual;
        if (bits == null or !supported(info.features)) {
            if (request.operation != a.cpu_performance_op_inspect) return a.cpu_capabilities_error_unsupported;
            info.state = a.cpu_performance_state_unsupported;
            info.valid_mask = 0;
            normalize(&info);
            out.* = info;
            return 0;
        }
        if (info.features & (1 << 10) != 0) info.flags |= a.cpu_performance_flag_epp;
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
        normalize(&cell.info);
        out.* = cell.info;
        return 0;
    }
};
