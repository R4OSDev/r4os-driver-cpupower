# CPUPOWER

CPUPOWER.R4D owns passive CPU telemetry and explicit local performance requests
for R4OS. It uses the authenticated, named CPU mechanism; no arbitrary MSR
address is accepted. Its manifest declares parallel callbacks with owned
lifetimes. It creates no threads. Passive observations retain no CPU pins;
explicit performance requests retain exact CPU membership until actual return.

The separate optional idle policy introduced in0.85.31 permits only locally
qualified firmware entries, caps declared entry/exit latency at100us and
requires a remaining timer budget exceeding four times that latency. This
small initial intent is copied into the kernel; CPUPOWER adds no worker or
idle callback. It is independent from PowerService frequency profiles.
No feature-enabling MSR write is issued. Policy/provider withdrawal closes
new entries and requires actual previous exits before unload; HLT remains
the fallback. This policy makes no residency or energy measurement claim.

The optional 0.85.30 firmware adapter uses independently typed
`CpuFirmwareInfo` receipts and the external ACPIPLAT worker transport. It may
wait and never enters the local-register HWP/CPPC Session. CPUPOWER and ACPIPLAT
retain independent exact provider generations; full firmware domains exclude
direct CPU controls. Missing firmware is unavailable, and an uncertain receipt
keeps its actual token. `SYSINFO /CPUFW:<cpu>` explicitly inspects this route.
No physical clock or energy result follows from a loaded AML namespace.

`SYSINFO /CPUPOWER[:n]` and `SPECTRA METRICS CPUPOWER` read cached observations.
`SPECTRA CHECK SMP /POWER` explicitly refreshes twice on every available CPU
using existing owned compute workers and actual joins. No sample is invented at
boot. Each record retains its exact CPU epoch, provider generation, clock source
and generation, capture time, validity, unsupported fields and recovered faults.

Initial physical decoding is restricted to Intel family 6 models 3C/45/46 and
AMD family 19h model 01h stepping 1 (Milan B1). Virtual and other processors expose
explicit unavailable states without probing these model registers. These model
profiles are source/fixture qualified; the local KVM guest does not qualify their
physical sensors.

Active frequency is the average C0 APERF/MPERF ratio against a proven reference,
using an interrupt-free named read pair and a compatible 1 ms to 10 s interval.
Nominal CPUID MHz and TSC frequency are separate. Zero, reset, overflow,
incompatible CPU/clock epochs and implausible deltas leave the result unknown.
No fixed accuracy guarantee is made. Thermal current status is separate from
sticky history, which is never cleared. Intel's zero-preload/CPUID signature
latch is only the documented microcode revision read procedure; AMD's patch
register is read only. This module loads no microcode.

Energy is the scaled finite hardware counter, with explicit width, exponent and
known scope. Intel PP0 describes package cores; AMD core readings can be shared
by SMT siblings. Only known domain leaders are displayed as energy values.
Descending counters mean wrap or reset; there is no accumulated total or watts.
AMD temperature is unavailable in this initial MSR profile, without guessing
Tctl/Tdie offsets. Telemetry never changes requests or power limits.

Explicit HWP/EPP control (0.1.1) is restricted to native Intel6:4E/5E with
verified CPUID support. Virtual/other models, PECI override, fast access and newer
package polarity combinations are refused before model MSR instructions. EPP
is independent and optional. A separate `cpuPerformance` inspect operation reads
actual enabled/capability/request state; normal metrics remain passive.

Apply validates abstract min/max/desired levels against fresh local capabilities;
0 desired selects autonomous operation. EPP0..255 is a preference, not a power
cap. The owner preserves activity/valid bits and refuses inherited package
control. No772 package request is written. Compare/write/readback receipts keep
real faults and external conflicts distinct; readback is a stored hint, not
achieved frequency. The MSR sequence has no hardware atomicity against an
asynchronous firmware writer; cooperative owners must serialize requests.
Observed conflicts retain ownership. Explicit release on the same CPU restores only the exact
owned baseline and retains uncertain resources. Live tokens block CPU lifecycle
and driver unload, including unrelated CPU lifecycle through the conservative
global membership barrier. Callers must release before offline/shutdown; an
external governor and coordinated shutdown belong to the PowerService stage.

770 activation is package-wide and reset-only. It requires a separate enable
operation with explicit sticky consent and complete known compatible online
package membership. It is never reversed or described as disabled on release.
No startup activation, governor, interrupt policy, CPPC or legacy P-state writes
are performed. Actual sources/fault fixtures qualify the implementation; the
local KVM4 guest qualifies refusals/lifetimes, not native savings or performance.

Build on Linux with `./Build.sh`, on Windows with `Build.bat`. Both launch the
same PowerShell 7 module builder. `test` executes the real provider/cache and
pure decoders and the HWP owner with simulated hardware peers; it executes no
host CPU instructions.

Primary references: [Intel SDM, revision 093](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html),
Volume3B17.4 and Volume4 model tables (HWP table2-39, native6:4E/5E);
[AMD PPR 55898, revision 0.50, Milan B1](https://docs.amd.com/v/u/en-US/55898_B1_pub_0_50),
Volume 1 effective frequency, PATCH_LEVEL, P-state 0 and energy registers;
[AMD energy driver scope notes](https://github.com/amd/amd_energy/blob/master/README.md).
The implementation is original R4OS code; no third-party driver source is copied.

Since0.1.5, passive metadata flags identify documented MCA model knowledge
for the existing native Haswell profile and SMCA model knowledge for the exact
Milan19h/01h/B1 profile. Unknown and virtual profiles set neither flag. This
does not claim actual bank presence, enabled reporting or current health and
starts no sampling or MSR operation. The kernel owns the necessary resident
hardware-error capture; Spectra owns raw presentation and error decoding.
