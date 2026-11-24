# SitePulse Cargo target benchmark

Issue [#384](https://github.com/gurkanindibay/ai-powered-engineering/issues/384) tracks disk
use when parallel agents build the SitePulse backend. PR [#385](https://github.com/gurkanindibay/ai-powered-engineering/pull/385)
added the smaller Cargo profile and the target pool. The benchmark compares the two profiles on one
source revision and measures builds from more source trees than there are target slots.

## Results (2026-11-24)

Measured on revision `5091dd11` with Rust `1.98.1`, Linux x86_64, and six Cargo jobs. The baseline
target used 17.67 GB on disk (16.46 GiB) at peak; the slim pooled target used 3.88 GB (3.62 GiB),
a 78% reduction. The cold build fell from 108.28 seconds to 77.01 seconds. The incremental rebuild
rose from 21.26 to 38.53 seconds because the pooled profile disables incremental compilation.

| Measurement | Baseline | Slim profile and pool |
| --- | ---: | ---: |
| Cold build | 108.28 s | 77.01 s |
| Workspace-only rebuild | 21.26 s | 38.53 s |
| Cold sampled peak allocation | 16.62 GB | 3.88 GB |
| Target directory after build | 17.67 GB | 3.88 GB |
| Linked test binaries | 48 | 48 |

With three source trees sharing two slots, the first cold build took 75.91 seconds and the two
warm users took 2.06 seconds each with no dependency recompiles. A fourth-tree handoff rebuilt one
workspace package in 39.10 seconds and rebuilt no dependencies. The two slots peaked at 7.77 GB
together; the run left no orphaned targets. A temporary panic probe retained a backtrace location
(`src/lib.rs:26:48`) under the slim profile.

Peak allocation is sampled every two seconds, so short spikes may be higher. The pool bounds the
number of target directories, not each slot's future size; the watchdog and age-based sweep remain
necessary controls.

## Reproduce

Use a Linux checkout with Cargo, a populated registry cache for the locked dependencies, and at least
35 GiB free on the scratch volume. The benchmark builds all backend test executables without running
them, except for one temporary panic test that checks source line information in the backtrace.

```sh
cargo fetch --locked --manifest-path apps/development-time/SitePulse/backend/Cargo.toml
python3 scripts/cargo_target_benchmark.py --revision 5091dd11 --jobs 6 --json
```

The script exports the same tracked backend files to temporary source trees. The baseline removes
the two debug profile overrides from PR #385 and enables incremental compilation. The current
profile uses those overrides and leases a target directory, which disables incremental compilation.
Each profile starts with an empty target directory. The rebuild touches `src/lib.rs` to force Cargo
to rebuild affected workspace targets. Then three source trees build through two slots, followed
by a fourth tree that takes an idle slot. The script reports how many unique dependency packages
Cargo recompiles and the allocated bytes sampled every two seconds.

The script samples disk usage by walking the target directories and counting allocated filesystem
blocks. Brief spikes between samples can exceed the reported peak. Each pool slot is a directory
that can grow with the set of artifact variants it has seen. The slot count bounds the number of
target directories. Disk thresholds and periodic sweeps are separate controls.
