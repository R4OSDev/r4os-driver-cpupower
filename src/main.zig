// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const r4os = @import("r4os");
const a = r4os.abi;
const Provider = @import("provider.zig").Provider;
const Hwp = @import("hwp.zig").Provider;
const Cppc = @import("cppc.zig").Provider;
var provider: Provider = undefined;
var hwp: Hwp = undefined;
var cppc: Cppc = undefined;
var cookie: u64 = 0;
var firmware_cookie: u64 = 0;
comptime {
    asm (r4os.r4dev.driverEntriesAsm("cpu_power_init", "cpu_power_shutdown"));
}
fn snapshot(context: usize, cpu: u32, epoch: u64, out: *a.CpuPowerInfo) callconv(.c) i32 {
    const owner: *Provider = @ptrFromInt(context);
    return owner.snapshot(cpu, epoch, out);
}
fn capture(context: usize, cpu: u32, epoch: u64, out: *a.CpuPowerInfo) callconv(.c) i32 {
    const owner: *Provider = @ptrFromInt(context);
    return owner.capture(cpu, epoch, out);
}
fn performance(context: usize, request: *const a.CpuPerformanceRequest, out: *a.CpuPerformanceInfo) callconv(.c) i32 {
    const owner: *Hwp = @ptrFromInt(context);
    return owner.execute(request.*, out);
}
fn amdCppc(context: usize, request: *const a.CpuPerformanceRequest, out: *a.CpuCppcInfo) callconv(.c) i32 {
    const owner: *Cppc = @ptrFromInt(context);
    return owner.execute(request.*, out);
}
fn firmware(context: usize, request: *const a.CpuPerformanceRequest, out: *a.CpuFirmwareInfo) callconv(.c) i32 {
    const owner: *Provider = @ptrFromInt(context);
    return @import("firmware.zig").execute(&owner.mechanism, request, out);
}
export fn cpu_power_init(input: *const a.DriverApi) callconv(.c) i32 {
    const ctx = r4os.r4dev.DriverContext.init(input);
    if (!ctx.apiCompatible()) return a.cpu_capabilities_error_unsupported;
    const resources = ctx.resources() orelse return a.cpu_capabilities_error_unsupported;
    const mechanism = resources.cpuPower() orelse return a.cpu_capabilities_error_unsupported;
    inline for (.{ "counters_read", "feature", "register_performance", "control_acquire", "control_release", "register_compare_write", "register_cppc", "rank_publish" }) |field| {
        if (!mechanism.has(field)) return a.cpu_capabilities_error_unsupported;
    }
    if (cookie != 0) return a.cpu_capabilities_error_busy;
    provider = Provider.init(mechanism);
    const backend: a.CpuPowerBackend = .{
        .context = @intFromPtr(&provider),
        .snapshot = @intFromPtr(&snapshot),
        .capture = @intFromPtr(&capture),
        .flags = a.cpu_power_backend_flag_parallel,
    };
    const result = mechanism.register(&backend, &cookie);
    if (result != 0) return result;
    hwp = Hwp.init(mechanism);
    const control: a.CpuPerformanceBackend = .{
        .context = @intFromPtr(&hwp),
        .execute = @intFromPtr(&performance),
        .flags = a.cpu_power_backend_flag_parallel,
    };
    const attached = mechanism.registerPerformance(cookie, &control);
    if (attached != 0) {
        const released = mechanism.unregister(cookie);
        if (released != 0) return released;
        cookie = 0;
        return attached;
    }
    cppc = Cppc.init(mechanism);
    const amd_control: a.CpuCppcBackend = .{
        .context = @intFromPtr(&cppc),
        .execute = @intFromPtr(&amdCppc),
        .flags = a.cpu_power_backend_flag_parallel,
    };
    const amd_attached = mechanism.registerCppc(cookie, &amd_control);
    if (amd_attached != 0) {
        const released = mechanism.unregister(cookie);
        if (released != 0) return released;
        cookie = 0;
        return amd_attached;
    }
    if (mechanism.has("firmware_register") and mechanism.has("firmware_unregister") and mechanism.has("firmware_execute")) {
        const fw: a.CpuFirmwareBackend = .{ .context = @intFromPtr(&provider), .execute = @intFromPtr(&firmware), .flags = a.cpu_power_backend_flag_parallel };
        const attached_fw = mechanism.firmwareRegister(1, &fw, &firmware_cookie);
        if (attached_fw != 0) {
            const released = mechanism.unregister(cookie);
            if (released != 0) return released;
            cookie = 0;
            return attached_fw;
        }
    }
    ctx.logInfo("CPUPOWER.R4D ready; direct HWP/CPPC and separate external firmware transport, no governor");
    return 0;
}
export fn cpu_power_shutdown() callconv(.c) i32 {
    if (cookie == 0) return 0;
    if (firmware_cookie != 0) {
        const result = provider.mechanism.firmwareUnregister(1, firmware_cookie);
        if (result != 0) return result;
        firmware_cookie = 0;
    }
    const result = provider.mechanism.unregister(cookie);
    if (result != 0) return result;
    cookie = 0;
    return 0;
}
