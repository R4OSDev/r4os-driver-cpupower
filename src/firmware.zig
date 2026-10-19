// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! The separately typed firmware adapter may wait; it never uses a CPU-local
//! register Session or falls back after an uncertain direct-hardware request.
const r = @import("r4os");
const a = r.abi;
pub fn execute(mechanism: *const r.r4dev.DriverCpuPowerContext, request: *const a.CpuPerformanceRequest, out: *a.CpuFirmwareInfo) i32 {
    if (request.version != 1 or request.size < @sizeOf(a.CpuPerformanceRequest) or request.cpu_index >= 64 or request.epoch == 0 or request.reserved0 != 0 or
        request.operation > a.cpu_performance_op_enable or out.version != 1 or out.size < @sizeOf(a.CpuFirmwareInfo)) return a.cpu_capabilities_error_invalid;
    var value: a.CpuFirmwareInfo = .{};
    const rc = mechanism.firmwareExecute(request, &value);
    if (rc != 0) return rc;
    if (value.version != 1 or value.size != @sizeOf(a.CpuFirmwareInfo) or value.cpu_index != request.cpu_index or value.epoch != request.epoch or
        value.backend > a.cpu_firmware_backend_pss or value.state > a.cpu_performance_state_conflict or value.firmware_generation == 0 or
        value.reserved0 != 0 or value.reserved1 != 0 or value.reserved2 != 0) return a.cpu_capabilities_error_invalid;
    // A complete refusal/uncertainty receipt still carries its exact token;
    // never discard that ownership because last_error is nonzero.
    out.* = value;
    return 0;
}
