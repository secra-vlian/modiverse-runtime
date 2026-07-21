# Deferred aarch64 L1/L2 archives

These directories hold OpenObserve / LibreOffice builds that **do not** meet the
publish contract (bundled `libc.so.6` / `ld-linux*`). They are kept only for
forensics and must not be published or included in L0 offline media.

Rebuild with `scripts/runtime-build/build-aarch64.sh` after the L1/L2 strategy
lands (OO: ≤glibc 2.36 or exclusion; LO: strip glibc + relative links), then
move compliant archives back under `runtime/aarch64/`.
