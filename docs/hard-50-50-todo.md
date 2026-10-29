# Hard 50/50 Grouping — TODO Tracker (canonical)

Status: TODO / design tracking only. NOT enforced.

Current behavior (unchanged): STD steering is a best-effort soft hint.
Fair and idle tasks prefer housekeeping CPUs; deadline and real-time
tasks prefer non-housekeeping CPUs. Affinity is honored via `cpumask`
intersection with fallback to the class-selected CPU; idle spreading is
attempted without guarantee. Stop tasks are never intercepted; pinned,
migrate-disabled, core-scheduled (rq-wide, may over-skip), and EXT
(defer to SCX) pass through. Systems with fewer than 3 online CPUs pass
through. No new scheduling class. See `src/std.c`, `src/std.h`.

## Goal (future, requires explicit approval before code change)

Evaluate a strict-halves mode ("hard 50/50"): CPUs split into two
hard groups of equal size — one half for fair/idle, one half for
deadline/real-time — with cross-group placement denied except where
affinity or passthrough guards force it.

This file is the canonical tracker. In-code markers (`TODO(hard-50-50)`)
in `src/std.c` / `src/std.h` point here. No hard-halves logic change
lands until the design below is approved.

## Non-goals / invariants (must hold for any future patch)

- No new scheduling class (shim above deadline only).
- Do not break current soft-hint behavior until the hard mode is
  approved, implemented, and verified.
- Affinity safety: never place a task where `p->cpus_ptr` forbids it.
- Keep existing passthroughs: stop (never intercept), `nr_cpus_allowed == 1`,
  migration-disabled, rq-wide core-scheduling check (may over-skip), EXT to
  SCX, `<3` CPUs, `!housekeeping_enabled`, `!std_running` (near-zero cost off).
- `README.md` stays at 111 lines; no changelog file; no steering-behavior
  change in `patches/vanilla-arch/7.3/*` until approved (stats proc-contract
  correctness + comment/wording accuracy only).
- Stats (`std_stats`: `fastpath` / `steered` / `fallback`, read-only
  `-EROFS` on write) semantics stay backward-compatible or are versioned
  explicitly in the design review.

## Open design questions (must resolve before code)

1. Halves definition: static `cpu / (num_online_cpus / 2)` split vs.
   housekeeping-mask-derived halves? How to handle odd CPU counts,
   offline/hotplug CPUs, and `isolcpus` / `nohz_full` overlap?
2. Hard semantics: deny cross-group pick outright, or deny only when the
   preferred half is usable (affinity + active)? What counts as
   `fallback` vs. an error under a hard partition?
3. Affinity spanning halves: task pinned to both halves — which half wins,
   and does class preference still apply within the allowed set?
4. Interface: new `std_running` mode value, new sysctl, or boot param
   (e.g. `std_running=` extension)? Default must remain soft hint.
5. Interaction with cpusets / cgroups, `cpumask_any_distribute` spread,
   and idle-CPU scan order under a hard split.
6. Patch series impact: `0003-std-shim.patch` / `0004-std-hooks.patch`
   regen, `checkpatch.pl --strict`, `patch --dry-run` + `git apply --check`.

## Acceptance for any future enforcement patch

- Design answers for §Open questions recorded here and approved.
- `src/std.c` / `src/std.h` logic change + regenerated `patches/`
  series; `patch -p1 --dry-run` and `git apply --check` pass.
- `bash -n` on touched scripts; `wc -l README.md` still `111`
  unless a README change is separately approved.
- `taskset` smoke test updated for hard halves; 1–2 CPU passthrough
  still verified; `std_stats` table verified.
- No new scheduling class; no changelog unless separately requested.

## Verification (combined slice: hardening + TODO tracking)

```bash
wc -l README.md src/std.c src/std.h docs/hard-50-50-todo.md
bash -n scripts/install.sh
bash -n scripts/uninstall.sh
bash -n scripts/cleanup.sh
bash -n scripts/verify-std.sh
git status --short
git diff --stat
```

Expect: `README.md` is `111` lines; scripts syntax OK; steering
behavior unchanged (soft hint only). This slice combines correctness
hardening (stats proc contract, sysctl sentinel, scripts
allowlist/modeset/checkpatch guards, patch regen in sync with `src/`)
with TODO design tracking (this file + in-code markers, comment-only
in `patches/`); no steering-logic change and no hard-halves
enforcement.
