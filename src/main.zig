// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const r4os = @import("r4os");
const a = r4os.abi;
const Provider = @import("provider.zig").Provider;
var provider: Provider = undefined;
var cookie: u64 = 0;
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
export fn cpu_power_init(input: *const a.DriverApi) callconv(.c) i32 {
    const ctx = r4os.r4dev.DriverContext.init(input);
    if (!ctx.apiCompatible()) return a.cpu_capabilities_error_unsupported;
    const resources = ctx.resources() orelse return a.cpu_capabilities_error_unsupported;
    const mechanism = resources.cpuPower() orelse return a.cpu_capabilities_error_unsupported;
    if (!mechanism.has("counters_read")) return a.cpu_capabilities_error_unsupported;
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
    ctx.logInfo("CPUPOWER.R4D ready; passive local observations, no power policy");
    return 0;
}
export fn cpu_power_shutdown() callconv(.c) i32 {
    if (cookie == 0) return 0;
    const result = provider.mechanism.unregister(cookie);
    if (result != 0) return result;
    cookie = 0;
    return 0;
}
