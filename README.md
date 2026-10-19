# CPUPOWER

CPUPOWER.R4D is the external owner of passive CPU telemetry for R4OS. It uses
the authenticated, named local CPU mechanism; no arbitrary MSR address or power
request is accepted. Its manifest declares parallel callbacks with owned
lifetimes. It creates no threads and holds no permanent CPU placement pins.

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
Tctl/Tdie offsets. No power limits, HWP, EPP, CPPC or P-states are written.

Build on Linux with `./Build.sh`, on Windows with `Build.bat`. Both launch the
same PowerShell 7 module builder. `test` executes the real provider/cache and
pure decoder with hardware peers; it executes no host CPU instructions.

Primary references: [Intel SDM, revision 093](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html),
Volume 4 section 2.13 and inherited model tables;
[AMD PPR 55898, revision 0.50, Milan B1](https://docs.amd.com/v/u/en-US/55898_B1_pub_0_50),
Volume 1 effective frequency, PATCH_LEVEL, P-state 0 and energy registers;
[AMD energy driver scope notes](https://github.com/amd/amd_energy/blob/master/README.md).
The implementation is original R4OS code; no third-party driver source is copied.
