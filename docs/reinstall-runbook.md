# STD 7.3.0-std — reinstall runbook (fail-closed)

Full remove → revert → rebuild → verify cycle for the vanilla-arch 7.3 tree.
Companion to `README.md` (Quick Start / Verify / Install Contracts); flags and
thresholds below mirror `scripts/install.sh`, `scripts/uninstall.sh` and
`scripts/cleanup.sh` exactly. Read-only steps never mutate; every mutating step
is two-key guarded (`--yes`) and uses `sudo -n` only.

## Safety contract (applies to every step)

- **fish-safe bash prefix:** paste into `bash` or `fish`. Every installer
  invocation is prefixed with `bash` (never `./scripts/...`, never `source`),
  one command per line, no `VAR=val cmd` env-prefix (fish rejects it; use
  `env VAR=val` when needed), no chaining with `&&`.
- **Absolute paths:** `KERNEL_DIR` and the script paths below are absolute.
  Substitute the checkout path if yours differs; never pass a relative
  `KERNEL_DIR`/`BOOT_DIR`. The scripts canonicalize with `realpath -m` and
  refuse root, empty, same, or nested `KERNEL_DIR`/`BOOT_DIR`.
- **`sudo -n` only:** never run bare `sudo`, never escalate with `EUID==0`.
  All privilege escalation happens inside the scripts via `sudo -n`
  (fail-closed: without `sudo -n` they warn/skip instead of mutating).
  Manual fallback commands below also use `sudo -n`.
- **`--status` / `--dry-run` never mutate:** no clone, no patch, no build, no
  `pacman`, no DKMS, no boot writes. Always run them before any mutating step.
- Do NOT reboot without a verified Limine entry (see step 6).

Conventions used below (`KDIR` is the absolute target tree):

```text
KDIR = /home/galpt/Desktop/github/workspace-for-sdt/linux-fresh-7.3
BOOT = /boot (default; pass --boot-dir explicitly for mocked runs)
VER  = 7.3.0-std (clean, via --allow-dirty-suppress)
```

## 0. Read-only previews (no mutation, run first)

```bash
bash /home/galpt/Desktop/github/workspace-for-sdt/scripts/install.sh --status --boot-dir /boot /home/galpt/Desktop/github/workspace-for-sdt/linux-fresh-7.3
bash /home/galpt/Desktop/github/workspace-for-sdt/scripts/install.sh --dry-run --boot-dir /boot /home/galpt/Desktop/github/workspace-for-sdt/linux-fresh-7.3
bash /home/galpt/Desktop/github/workspace-for-sdt/scripts/uninstall.sh --status --boot-dir /boot /home/galpt/Desktop/github/workspace-for-sdt/linux-fresh-7.3
bash /home/galpt/Desktop/github/workspace-for-sdt/scripts/uninstall.sh --dry-run --boot-dir /boot /home/galpt/Desktop/github/workspace-for-sdt/linux-fresh-7.3
bash /home/galpt/Desktop/github/workspace-for-sdt/scripts/cleanup.sh --status /home/galpt/Desktop/github/workspace-for-sdt/linux-fresh-7.3
bash /home/galpt/Desktop/github/workspace-for-sdt/scripts/cleanup.sh --dry-run /home/galpt/Desktop/github/workspace-for-sdt/linux-fresh-7.3
```

Expect: exact read-only strings and exit codes (no code change, wording only).
`--status` prints `Status (read-only, no changes made)` through
`Status complete (read-only, no changes made)` and exits `0` (cleanup:
`Status (read-only, no files removed)`). `--dry-run` prints `Dry-run OK.
No changes made` (uninstall: `Reverse dry-run OK. No changes made`; cleanup:
`Dry-run: no files removed`) and exits `0` only when preflight passes.
Note: `install.sh --dry-run` fails preflight (`may already be applied`,
exit `1`) when STD patches are already applied — that is the signal to
revert first (step 2) rather than a bug. No `--status`/`--dry-run` path
touches the tree, `/boot`, `/lib/modules`, or DKMS.

## 1. Optional: prune installed boot artifacts (allowlisted, running-guard)

Only needed when a previous STD install left `/boot` / `/lib/modules` /
BLS / Limine entries behind (e.g. stale `7.3.0-std-dirty` sibling). Preview
first, then delete. Refuses the running kernel (`uname -r` match aborts),
requires `--yes` (two-key guard), and fails closed without `sudo -n`.

```bash
bash /home/galpt/Desktop/github/workspace-for-sdt/scripts/uninstall.sh --remove --dry-run --boot-dir /boot /home/galpt/Desktop/github/workspace-for-sdt/linux-fresh-7.3
bash /home/galpt/Desktop/github/workspace-for-sdt/scripts/uninstall.sh --remove --status --yes --boot-dir /boot /home/galpt/Desktop/github/workspace-for-sdt/linux-fresh-7.3
bash /home/galpt/Desktop/github/workspace-for-sdt/scripts/uninstall.sh --remove --yes --boot-dir /boot /home/galpt/Desktop/github/workspace-for-sdt/linux-fresh-7.3
```

Allowlisted coverage only: `vmlinuz-<ver>` / `System.map-<ver>` /
`initramfs-<ver>.img` under `BOOT_DIR`, BLS entries containing `<ver>`,
Limine STD block (4 candidates, backup + rollback), exact
`/lib/modules/<ver>`, DKMS entries for `-k <ver>`, and the `-dirty` sibling
when the target is clean. Bare `7.3.0-dirty` is never treated as STD.

Rotation (docs-only, no code change): the observed stale `7.3.0-dirty`
sibling (`12` `.ko` under `/lib/modules/7.3.0-dirty`, one BLS
`*-7.3.0-dirty.conf`, `/boot/<machine-id>/7.3.0-dirty/{linux,initrd}`) is
pruned by the same `--remove` path once the target is clean `7.3.0-std`.
`/boot` pressure (`4.9G`, `61%`, `2.0G` avail) is dominated by redundant
initramfs images plus `limine_history` (`812M`: `3x253M` initramfs + `3x18M`
vmlinuz, owned by `limine-snapper-sync`); history is out of scope for
`--remove` — never `rm -rf` it by hand, rotate it via snapper/limine tooling.
GRUB refresh inside `--remove` stays warn-only with backup preserved for
manual restore (`sudo -n cp -a backup cfg`); only Limine auto-rolls-back.

`install.sh` delegates the same path, so this equivalent shim is also valid:

```bash
bash /home/galpt/Desktop/github/workspace-for-sdt/scripts/install.sh --remove --dry-run --boot-dir /boot /home/galpt/Desktop/github/workspace-for-sdt/linux-fresh-7.3
bash /home/galpt/Desktop/github/workspace-for-sdt/scripts/install.sh --remove --yes --boot-dir /boot /home/galpt/Desktop/github/workspace-for-sdt/linux-fresh-7.3
```

## 2. Revert applied patches (required when the tree is already patched)

`install.sh` preflight rejects already-applied patches. Revert to a clean
tree first (scoped removal only: `std.c`/`std.h`, stale `std.o`/`.std.o.cmd`,
`*.orig`/`*.rej`; never deletes the tree):

```bash
bash /home/galpt/Desktop/github/workspace-for-sdt/scripts/uninstall.sh --yes --boot-dir /boot /home/galpt/Desktop/github/workspace-for-sdt/linux-fresh-7.3
```

Without `--yes` the script prompts (`Revert STD patches ...? [y/N]`);
`--yes` is the non-interactive second key.

## 3. Reinstall (forces `7.3.0-std`)

`--allow-dirty-suppress` pins `CONFIG_LOCALVERSION_AUTO=n` +
`LOCALVERSION=""` so the rebuilt tree yields exactly `7.3.0-std`
(verified: `LOCALVERSION="" make -s kernelrelease` → `7.3.0-std`; without the
flag the same tree yields `7.3.0-std-dirty`). `--yes` is the two-key guard.
`--status`/`--dry-run` variants of these commands never mutate.

Standard reinstall (skips NVIDIA DKMS rebuild with a hint):

```bash
bash /home/galpt/Desktop/github/workspace-for-sdt/scripts/install.sh --yes --allow-dirty-suppress --boot-dir /boot /home/galpt/Desktop/github/workspace-for-sdt/linux-fresh-7.3
```

NVIDIA workstation variant (opt-in DKMS rebuild for the new kernel:
`dkms_pre` scoped to `-k <ver>` → `autoinstall -k` → explicit
`install -f` fallback → `depmod -a` → `modinfo`/`find` verify of `nvidia.ko`):

```bash
bash /home/galpt/Desktop/github/workspace-for-sdt/scripts/install.sh --yes --allow-dirty-suppress --reinstall-nvidia --boot-dir /boot /home/galpt/Desktop/github/workspace-for-sdt/linux-fresh-7.3
```

Related opt-ins (each requires `--yes`, each is preview-only under
`--dry-run`/`--status`, each warn-only unless strict): `--install-deps`
(Arch-first: `pacman`, `apt-get`, `dnf`, `zypper`), `--write-modprobe`
(allowlisted to `/etc/modprobe.d/std-nvidia.conf`), `--write-bls` (opt-in
BLS entry), `--strict-boot-artifacts` (fatal boot-artifact copy/checksum),
`--strict-nvidia` (fatal NVIDIA warnings), `--allow-degraded-initramfs`
(demote degraded initramfs to `WARNING`; rebuild manually otherwise).

## 4. Prune patch leftovers (allowlisted)

Preview, then delete. Allowlist only: `*.orig` / `*.rej` (maxdepth 4) plus
`kernel/sched/std.o` and `kernel/sched/.std.o.cmd`. Nothing else is ever
removed.

```bash
bash /home/galpt/Desktop/github/workspace-for-sdt/scripts/cleanup.sh --dry-run /home/galpt/Desktop/github/workspace-for-sdt/linux-fresh-7.3
bash /home/galpt/Desktop/github/workspace-for-sdt/scripts/cleanup.sh --yes /home/galpt/Desktop/github/workspace-for-sdt/linux-fresh-7.3
```

## 5. Disk-saving hygiene (no data loss)

- `make clean` only, keeps `.config` — the installer runs
  `make -C <KDIR> clean` before the full build and never `mrproper` /
  `distclean` (either would delete the just-written `.config`). Never run
  `mrproper`/`distclean` on the reinstall tree yourself. The cold build is
  intentional after the inherited `.config` overwrite; `JOBS="$(nproc)"` is
  unbounded by design (constrain via `env MAKEFLAGS=-jN` when needed).
  `DEBUG_INFO=y` + `BTF` bloat (`6480` `.ko`, `2.3G` under
  `/lib/modules/7.3.0-std`) is inherited from the running config, not forced
  by STD — healthy installs carry several thousand `.ko` files.
- Never `rm -rf` the tree, `.git`, `/boot`, or `/lib/modules` by hand.
  The only `rm -rf` paths in the tooling are allowlisted and guarded:
  `--fresh` re-clone (requires `--yes` plus a tree-sanity check) and the
  exact `/lib/modules/<ver>` removal inside `--remove` (requires `--yes`,
  refuses the running kernel).
- `include/config/kernel.release` is stale after flag changes; live
  `make -s kernelrelease` (after `make prepare`) is the source of truth.
  Limine `*.std-backup-*` plus `.bak`/`.old` are preserved for manual restore
  and never auto-deleted; rotate old backups by hand when they accumulate.
- `/tmp` prune only: installer/uninstaller temp files live under
  `/tmp/std-*` (`std-install-*.log`, `std-uninstall-*.log`, `std-cp-*`,
  `std-limine-*`, `std-bls-*`, all `mktemp` `0600`). List, then delete files only:

```bash
ls /tmp/std-*
rm -f /tmp/std-install-*.log /tmp/std-uninstall-*.log
```

## 6. Verify (on the freshly built + booted STD kernel)

Boot the new entry first (Limine STD+`<ver>` must be present — step 6d —
before rebooting). Then, one command per line:

```bash
uname -r
sysctl kernel.std_running
cat /proc/sys/kernel/std_running
cat /proc/sys/kernel/std_stats
```

Expect:

- a. `uname -r` → `7.3.0-std` (clean reinstall). `7.3.0-std-dirty` is only
  acceptable with expected STD dirt and without `--allow-dirty-suppress`;
  bare `7.3.0-dirty` or any `*+` suffix fails the naming contract.
- b. `sysctl kernel.std_running` → `1` (master switch; `0` disables
  steering; boot override `std_running=0/1`).
- c. `cat /proc/sys/kernel/std_running /proc/sys/kernel/std_stats` → `1`
  plus the dynamic-width bordered per-CPU table with `fastpath` / `steered`
  / `fallback` columns (`0444` read-only, `-EROFS` on write).

```bash
sudo -n stat -c %s /boot/initramfs-7.3.0-std.img
find /lib/modules/7.3.0-std -name '*.ko*' | wc -l
sudo -n grep STD /boot/limine.conf
sudo -n grep 7.3.0-std /boot/limine.conf
```

```bash
taskset -c 0 sleep 0
taskset -p $$
```

```bash
sudo -n modinfo -k 7.3.0-std -F filename nvidia
sudo -n find /lib/modules/7.3.0-std -name 'nvidia.ko*'
dkms status
```

Expect:

- d. Initramfs size `>50M` (`52428800` bytes; stock is hundreds of MB —
  a tens-of-MB image is degraded, 0-byte is fail-closed). Module count
  `>=1000` (a healthy install carries several thousand `.ko` files).
  Both are fail-hard health-gate inputs alongside the log signatures
  (`ERROR: module not found`, `No modules were added`,
  `errors were encountered during the build` always fail; lone narrow
  `_addedmodules[]: bad array subscript` demotes to `WARNING` only when the
  image is present plus `>=50M` plus `>=1000` plus a builder success marker
  plus no hard signature). Distinct reason tokens: `hard-log[*]`,
  `soft-log[_addedmodules-bad-array]`, `size<50M`, `modules<1000`,
  `missing-initrd`.
- e. Limine guarantee: **BOTH** `STD` and the exact `<ver>` in the same
  `limine.conf` (4 candidates under `BOOT_DIR`). BLS entries never satisfy
  Limine. `sha256` + `b2sum` verify both `cp -a` and `vfat`-fallback copy
  paths. If `WARNING: STD kernel <ver> not listed`, sync with
  `sudo -n limine-entry-tool --add-kernel std` + `--tree` (or `limine-update`;
  filtered STD-block fallback with backup/rollback otherwise) and re-verify
  before reboot. GRUB `mkconfig` + verify, BLS verify-only unless
  `--write-bls`.
- f. Affinity smoke-test: `taskset -c 0 sleep 0` plus `taskset -p $$`
  (1–2 CPU systems pass through unchanged; steering is best-effort soft hint).
- g. NVIDIA DKMS: `sudo -n modinfo -k 7.3.0-std -F filename nvidia` prints
  the `nvidia.ko` path (`find` fallback when `modinfo` misses); `dkms status`
  lists `nvidia/... , 7.3.0-std, x86_64: installed`. Mirrors `dkms_post`
  (`dkms_pre` scoped to `-k <ver>` → `autoinstall -k` → explicit `install -f`
  fallback → `depmod -a` → `modinfo`/`find` verify).

## Failure handling

- Degraded initramfs gate failure → do NOT boot. Rebuild manually
  (no auto-fix), e.g. `sudo -n mkinitcpio -k 7.3.0-std -g
  /boot/initramfs-7.3.0-std.img`, re-check sizes, or rerun with
  `--allow-degraded-initramfs` to record an explicit `WARNING` override.
- `verify_kernelrelease` failure (`*-dirty`/`*+`, extra dirt, `AUTO` mismatch,
  missing `-std` pin) → commit/revert extra dirt, or rerun with explicit
  `--allow-dirty-suppress`; prune stale `-dirty` boot/modules artifacts via
  step 1 afterwards.
- 1–2 CPU systems pass through unchanged; `taskset -c 0 sleep 0` plus
  `taskset -p $$` smoke-test affinity safety after boot.
