#!/bin/bash
# STD post-boot read-only verify bundle for vanilla-arch 7.3.
# Never mutates, never reboots. Uses `sudo -n` only (fail-closed).
# Run after booting the STD entry. One command per line, fish-safe:
# paste into `bash` or `fish`, never `./scripts/...`, never `source`,
# no `VAR=val cmd` prefix (use `env VAR=val` when needed), no `&&` chaining.
#
# Manual bundle (fish-safe, one command per line, substitute VER as needed;
# VER defaults to `7.3.0-std` in the automated bundle; `uname -r` matches
# it on a healthy STD boot):
#
# No-sudo block (paste one line at a time):
#   uname -r
#   sysctl kernel.std_running
#   cat /proc/sys/kernel/std_running
#   cat /proc/sys/kernel/std_stats
#   taskset -c 0 sleep 0
#   taskset -p $$ (bash; in fish use `taskset -p $fish_pid`)
#   find -- /lib/modules/7.3.0-std -name '*.ko*' | wc -l
#   dkms status
#
# Sudo block (fail-closed `sudo -n` only, never bare `sudo`; one line at a time):
#   sudo -n stat -c %s -- /boot/initramfs-7.3.0-std.img
#   sudo -n grep -F -- "/STD kernel" /boot/limine.conf | grep -F -- "(7.3.0-std)" (same line via pipe; legacy `:STD 7.3.0-std` also accepted with token-boundary; BLS never satisfies)
#   sudo -n modinfo -k 7.3.0-std -F filename nvidia
#   sudo -n find -- /lib/modules/7.3.0-std -name 'nvidia.ko*'
#   sudo -n dmesg | grep -E -- 'std_running|std_stats|register_sysctl_sz|procname null|(^|[^A-Za-z0-9_])STD([^A-Za-z0-9_]|$)'
#
# Automated bundle (same checks, still read-only):
#   bash /home/galpt/Desktop/github/workspace-for-sdt/scripts/verify-std.sh
#   bash /home/galpt/Desktop/github/workspace-for-sdt/scripts/verify-std.sh --boot-dir /boot 7.3.0-std
#
# Expected vs anomalous (no mutation, no reboot):
#   uname -r: expected `7.3.0-std` (clean) or `7.3.0-std-dirty` (only with
#     expected STD dirt); anomalous is bare `7.3.0-dirty`, any `*+` suffix,
#     or a non-STD release (e.g. `7.3.0-1.3-devario-kpp` means the wrong
#     entry was booted).
#   sysctl kernel.std_running: expected exact `kernel.std_running = 1`
#     (anchored `^kernel\.std_running *= *[01]$`; master switch); `1` is
#     steering (default), `0` is off
#     (boot override `std_running=0/1`); missing key means non-STD.
#   cat std_running: expected `0` or `1`; same cases as sysctl.
#   cat std_stats: expected dynamic-width bordered approximate table with
#     `fastpath` / `steered` / `fallback` in order (scaled SI-1000),
#     `+...+` top/middle/bottom borders plus `|` header/value rows (checked:
#     exact `| fastpath | steered | fallback |` header in order, every `|`
#     row exactly 3 columns (4 pipes), no sparse/bulk/decaying/host_load/
#     enforced/denied/starve_bypass (word-boundary), >=3 `+` borders,
#     >=2 `|` rows, >=5 lines; `0444`
#     read-only via stat, never chmod; write probe omitted to stay read-only,
#     `-EROFS` on write is source-documented from proc_std_stats, not
#     live-probed); anomalous is missing file, empty output, a table
#     without `+---+` borders and the strict 3 columns, or any CAKE-style
#     10-column table (extra columns / forbidden tokens fail closed).
#   dmesg negative: expected empty for `grep -E -- 'std_running|std_stats|register_sysctl_sz|procname null|(^|[^A-Za-z0-9_])STD([^A-Za-z0-9_]|$)'`
#     (STD emits no printk; do NOT use `grep -i std` alone: `zstd`,
#     `systemd`, `BTRFS` are false positives; portable `(^|[^A-Za-z0-9_])STD`
#     boundary is used because `\b` is GNU-only; `register_sysctl_sz` /
#     `procname null` catch sysctl-table registration failures); anomalous is
#     any `STD`, `BUG`, `Oops`, or stack-trace line. Known non-STD warnings
#     (ACPI firmware bug, nvidia taint, NVRM asserts) are warn-only.
#     `dmesg` without privilege fails (`Operation not permitted`); rerun
#     the `sudo -n` variant instead of changing permissions.
#   taskset smoke: expected exit `0` for `taskset -c 0 sleep 0` plus a
#     printed affinity mask for `taskset -p $$` (1-2 CPU systems pass
#     through unchanged; steering denies only with in-group allowed);
#     anomalous is a non-zero exit or affinity error.
#   stat initrd: expected size `>=50M` (`52428800` bytes; stock is hundreds
#     of MB); anomalous is missing image, `0` bytes, or `<50M` (degraded,
#     fail-closed: do NOT boot, rebuild manually).
#   modules: expected `>=1000` `.ko` files under `/lib/modules/<ver>`
#     (healthy installs carry several thousand); anomalous is a missing
#     directory or count `<1000` (degraded install).
#   Limine: expected canonical `/STD kernel (<ver>)` with `STD` and the exact
#     `<ver>` on the SAME line (piped `grep -F -- "/STD kernel" | grep -F -- "(<ver>)"`
#     enforces same-line exact, file-level co-occurrence alone does NOT satisfy;
#     legacy `:STD <ver>` also accepted for compat with token-boundary)
#     in `limine.conf` (4 candidates under BOOT_DIR); anomalous is either
#     token missing, no `limine.conf` found, or BLS-only (a BLS entry
#     never satisfies Limine). Do NOT reboot without a Limine STD+ver entry.
#   modinfo nvidia: expected an `nvidia.ko` path for `-k <ver>` (`find`
#     fallback when `modinfo` misses); anomalous is no path from either
#     (DKMS not rebuilt for `<ver>`).
#   dkms status: expected `nvidia/... , <ver>, <arch>: installed`
#     (`<arch>` is `uname -m`, `x86_64` on this host);
#     anomalous is `built`/`added`/`failed`, or no entry for `<ver>`
#     (entries for other kernels do not satisfy this check).
# File mode is intentionally 0644 (never executable): paste lines into
# `bash`/`fish` or run `bash scripts/verify-std.sh`, never `./scripts/...`.
set -euo pipefail

DEFAULT_VER="7.3.0-std"
DEFAULT_BOOT="${BOOT_DIR:-/boot}"

BOOT_DIR="${DEFAULT_BOOT}"
TARGET_VER=""

usage() {
	echo "Usage: $0 [--boot-dir DIR] [VER]"
	echo "  --boot-dir DIR  Boot directory, default ${DEFAULT_BOOT}"
	echo "  VER             Kernel release to verify, default ${DEFAULT_VER}"
	echo "Read-only post-boot verify (never mutates, never reboots; sudo -n only)."
}

while [ $# -gt 0 ]; do
	case "$1" in
		--boot-dir)
			if [ $# -lt 2 ]; then
				echo "Missing value for --boot-dir" >&2
				usage >&2
				exit 2
			fi
			BOOT_DIR="$2"
			shift 2
			;;
		--boot-dir=*)
			BOOT_DIR="${1#--boot-dir=}"
			shift
			;;
		--)
			shift
			while [ $# -gt 0 ]; do
				if [ -n "${TARGET_VER}" ]; then
					echo "Too many positional args" >&2
					usage >&2
					exit 2
				fi
				TARGET_VER="$1"
				shift
			done
			break
			;;
		-h|--help)
			usage
			exit 0
			;;
		-*)
			echo "Unknown option: $1" >&2
			usage >&2
			exit 2
			;;
		*)
			if [ -n "${TARGET_VER}" ]; then
				echo "Too many positional args" >&2
				usage >&2
				exit 2
			fi
			TARGET_VER="$1"
			shift
			;;
	esac
done

# Confinement: refuse empty/root BOOT_DIR before canonicalization (realpath -m
# would map "" to PWD and hide an empty --boot-dir), then canonicalize and
# refuse root again. realpath -m (missing-ok) supports mocked --boot-dir paths
# that may not exist yet. Safety comes from the refuse-root guard, not existence
# checks: any non-root BOOT_DIR is accepted (including mocked missing-ok paths).
# TOCTOU note: test-then-use (boot_test_file then boot_stat_size/boot_grep_same_line)
# may race with concurrent boot writes; accepted because this bundle is strictly
# read-only (never mutates, never reboots), so the worst case is a stale SKIP/FAIL
# prompting a manual re-run, never a bad write.
case "${BOOT_DIR}" in
	""|"/"|"//") echo "Refusing unsafe BOOT_DIR: ${BOOT_DIR}" >&2; exit 2 ;;
esac
if command -v realpath >/dev/null 2>&1; then
	BOOT_DIR="$(realpath -m -- "${BOOT_DIR}")"
else
	BOOT_DIR="$(readlink -f -- "${BOOT_DIR}" 2>/dev/null || printf '%s' "${BOOT_DIR}")"
fi
case "${BOOT_DIR}" in
	""|"/"|"//") echo "Refusing unsafe BOOT_DIR: ${BOOT_DIR}" >&2; exit 2 ;;
esac

if [ -z "${TARGET_VER}" ]; then
	TARGET_VER="${DEFAULT_VER}"
fi

# Allowlisted release/token check: ^[A-Za-z0-9_][A-Za-z0-9._+-]*$ (no slash,
# no glob, no empty, no leading dash/dot; explicit dot-only guard rejects
# "." and ".." directory traversal even though the regex already excludes
# a lone "." via the leading-class rule).
# Newline/tab/space/control pre-reject before grep: grep -E ^...$ matches
# per line, so an embedded newline ("ok\nbad") would otherwise pass.
# The shell case fails closed on any char outside the allowlist (covers
# space, tab, newline and controls) plus a leading-class check, then grep
# re-validates the full token as defense in depth.
is_safe_ver() {
	case "${1:-}" in
		"."|"..") return 1 ;;
	esac
	case "${1:-}" in
		*[!A-Za-z0-9._+-]*) return 1 ;;
	esac
	case "${1:-}" in
		[A-Za-z0-9_]* ) ;;
		*) return 1 ;;
	esac
	printf '%s' "${1:-}" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9._+-]*$'
}

if ! is_safe_ver "${TARGET_VER}"; then
	echo "Refusing unsafe VER: ${TARGET_VER}" >&2
	exit 2
fi

# Privilege probe (fail-closed: only `sudo -n` is ever used, never bare sudo).
HAVE_SUDO=0
if sudo -n true 2>/dev/null; then
	HAVE_SUDO=1
	echo "Privilege: sudo -n available (fail-closed reads only)."
else
	echo "Note: sudo -n unavailable; privileged reads fall back to direct access only."
fi

echo "Verify (read-only, no changes made; no reboot performed):"
echo "  target: ${TARGET_VER}"
echo "  boot: ${BOOT_DIR}"
echo "  running: $(uname -r 2>/dev/null || echo unknown)"

# Read helpers: direct read first (supports mocked BOOT_DIR),
# sudo -n fallback for root-only paths. No mutation. TOCTOU between
# boot_test_file and the subsequent read is accepted (see confinement note):
# re-reads are cheap and read-only, so a concurrent writer can only cause
# a retryable SKIP/FAIL, never corruption.
boot_test_file() {
	cand="$1"
	if [ -f "${cand}" ]; then
		return 0
	fi
	if [ "${HAVE_SUDO}" -eq 1 ] && sudo -n test -f "${cand}" 2>/dev/null; then
		return 0
	fi
	return 1
}

boot_grep_same_line() {
	# Same-line check via pipe: line must contain BOTH pat1 and pat2 (exact ver).
	# File-level co-occurrence in different lines does NOT satisfy Limine
	# (title line is `/STD kernel (ver)` canonical, `:STD <ver>` legacy compat). Uses fixed strings (-F) with `--`.
	# Exact ver: canonical requires "(ver)" with parens (prevents 7.3.0-std matching 7.3.0-std-dirty);
	# legacy ":STD ver" requires token-boundary (ver not followed by [A-Za-z0-9._+-]).
	pat1="$1"
	pat2="$2"
	file="$3"
	case "${pat1}" in
		"/STD kernel"*)
			case "${pat2}" in
				"("*")") exact="${pat2}" ;;
				*) exact="(${pat2})" ;;
			esac
			if [ -f "${file}" ] && grep -F -- "${pat1}" "${file}" 2>/dev/null | grep -F -q -- "${exact}"; then
				return 0
			fi
			if [ "${HAVE_SUDO}" -eq 1 ] && sudo -n grep -F -- "${pat1}" "${file}" 2>/dev/null | grep -F -q -- "${exact}"; then
				return 0
			fi
			return 1
			;;
		":STD"*)
			if [ -f "${file}" ] && awk -v ver="${pat2}" 'index($0, ":STD")>0 { p=index($0, ":STD"); rest=substr($0, p+4); sub(/^[ \t]+/, "", rest); if (substr(rest,1,length(ver))==ver) { after=substr(rest, length(ver)+1, 1); if (after=="" || after !~ /[A-Za-z0-9._+\-]/) { found=1; exit 0 } } } END { exit !found }' "${file}" 2>/dev/null; then
				return 0
			fi
			if [ "${HAVE_SUDO}" -eq 1 ] && sudo -n awk -v ver="${pat2}" 'index($0, ":STD")>0 { p=index($0, ":STD"); rest=substr($0, p+4); sub(/^[ \t]+/, "", rest); if (substr(rest,1,length(ver))==ver) { after=substr(rest, length(ver)+1, 1); if (after=="" || after !~ /[A-Za-z0-9._+\-]/) { found=1; exit 0 } } } END { exit !found }' "${file}" 2>/dev/null; then
				return 0
			fi
			return 1
			;;
		*)
			if [ -f "${file}" ] && grep -F -- "${pat1}" "${file}" 2>/dev/null | grep -F -q -- "${pat2}"; then
				return 0
			fi
			if [ "${HAVE_SUDO}" -eq 1 ] && sudo -n grep -F -- "${pat1}" "${file}" 2>/dev/null | grep -F -q -- "${pat2}"; then
				return 0
			fi
			return 1
			;;
	esac
}

boot_stat_size() {
	cand="$1"
	if [ -f "${cand}" ]; then
		stat -c %s -- "${cand}" 2>/dev/null || echo 0
		return 0
	fi
	if [ "${HAVE_SUDO}" -eq 1 ]; then
		sudo -n stat -c %s -- "${cand}" 2>/dev/null || echo 0
		return 0
	fi
	echo 0
	return 0
}

FAIL_COUNT=0
note_fail() {
	echo "  ANOMALOUS: $1" >&2
	FAIL_COUNT=$((FAIL_COUNT + 1))
}

# 1. uname -r (no sudo).
echo "--- uname ---"
running="$(uname -r 2>/dev/null || echo unknown)"
echo "  uname -r: ${running}"
case "${running}" in
	7.3.0-std)
		echo "  OK: clean STD release."
		;;
	7.3.0-std-dirty)
		echo "  OK with caveat: dirty suffix; verify dirt is expected STD only."
		;;
	*-dirty|*+*)
		note_fail "uname '${running}' carries a dirty/plus suffix (expect 7.3.0-std)."
		;;
	"${TARGET_VER}")
		# Explicit-target self-match is weak: running equals the requested VER
		# only because the caller passed the booted (non-canonical) release.
		# Fail closed and direct the caller to the canonical default.
		note_fail "running release '${running}' matches explicit target ${TARGET_VER} but is not canonical 7.3.0-std[-dirty]; confirm STD entry was booted (self-match is weak, default ${DEFAULT_VER} avoids this)."
		;;
	*)
		note_fail "uname '${running}' is not 7.3.0-std (wrong entry booted or non-STD kernel)."
		;;
esac

# 2. sysctl kernel.std_running (no sudo; anchored `kernel.std_running = 0/1` match).
echo "--- sysctl std_running ---"
if sysctl_out="$(sysctl kernel.std_running 2>&1)"; then
	echo "  ${sysctl_out}"
	if printf '%s' "${sysctl_out}" | grep -Eq '^kernel\.std_running *= *1$'; then
		echo "  OK: master switch 1 (steering, default)."
	elif printf '%s' "${sysctl_out}" | grep -Eq '^kernel\.std_running *= *0$'; then
		echo "  OK: master switch 0 (steering off; boot override std_running=0/1)."
	else
		note_fail "unexpected sysctl output: ${sysctl_out}"
	fi
else
	note_fail "sysctl kernel.std_running failed (non-STD kernel?): ${sysctl_out}"
fi

# 3. cat std_running (no sudo).
echo "--- cat std_running ---"
if running_val="$(cat /proc/sys/kernel/std_running 2>&1)"; then
	echo "  /proc/sys/kernel/std_running: ${running_val}"
	if [ "${running_val}" = "1" ]; then
		echo "  OK: master switch 1 (steering)."
	elif [ "${running_val}" = "0" ]; then
		echo "  OK: master switch 0 (steering off)."
	else
		note_fail "unexpected std_running value: ${running_val}"
	fi
else
	note_fail "cannot read /proc/sys/kernel/std_running (non-STD kernel?): ${running_val}"
fi

# 4. cat std_stats bordered table (no sudo; read-only 0444 mode checked via stat, no chmod).
# Write probe intentionally omitted to stay read-only: -EROFS on write is
# source-documented (proc_std_stats returns -EROFS when dir != 0), not live-probed.
echo "--- cat std_stats ---"
if stats_out="$(cat /proc/sys/kernel/std_stats 2>&1)"; then
	echo "${stats_out}" | head -n 10 | sed 's/^/  /'
	border_count="$(printf '%s\n' "${stats_out}" | grep -c -- '^+.*+$' || true)"
	pipe_count="$(printf '%s\n' "${stats_out}" | grep -F -c -- '|' || true)"
	line_count="$(printf '%s\n' "${stats_out}" | wc -l | tr -d ' ' || true)"
	case "${border_count}" in ''|*[!0-9]*) border_count=0 ;; esac
	case "${pipe_count}" in ''|*[!0-9]*) pipe_count=0 ;; esac
	case "${line_count}" in ''|*[!0-9]*) line_count=0 ;; esac
	header_line="$(printf '%s\n' "${stats_out}" | grep -F -- '|' | grep -E -- 'fastpath.*steered.*fallback' | head -n 1 || true)"
	header_pipes="$(printf '%s' "${header_line}" | tr -cd '|' | wc -c | tr -d ' ' || true)"
	case "${header_pipes}" in ''|*[!0-9]*) header_pipes=0 ;; esac
	# Strict 3-column gate: every '|' row must delimit exactly 3 columns
	# (4 pipes); any wider CAKE-style row fails. Non-empty means bad width.
	bad_width="$(printf '%s\n' "${stats_out}" | grep -F -- '|' | awk -F'|' '{print NF-1}' | grep -Ev -- '^4$' || true)"
	# CAKE extras must be absent (portable word-boundary; \b is GNU-only).
	forbidden_hits="$(printf '%s' "${stats_out}" | grep -E -- '(^|[^A-Za-z0-9_])(sparse|bulk|decaying|host_load|enforced|denied|starve_bypass)([^A-Za-z0-9_]|$)' || true)"
	if printf '%s\n' "${header_line}" | grep -Eq -- '^\|[[:space:]]*fastpath[[:space:]]*\|[[:space:]]*steered[[:space:]]*\|[[:space:]]*fallback[[:space:]]*\|[[:space:]]*$' && [ "${header_pipes}" -eq 4 ] && [ -z "${bad_width}" ] && [ -z "${forbidden_hits}" ] && [ "${border_count}" -ge 3 ] && [ "${pipe_count}" -ge 2 ] && [ "${line_count}" -ge 5 ]; then
		echo "  OK: bordered table with fastpath / steered / fallback in order (${border_count} borders, ${pipe_count} piped rows, ${line_count} lines)."
	else
		note_fail "std_stats lacks strict bordered 3-column table in order (need exact '| fastpath | steered | fallback |' header, every '|' row exactly 3 cols, no sparse/bulk/decaying/host_load/enforced/denied/starve_bypass, >=3 '+' borders, >=2 '|' rows, >=5 lines; got borders=${border_count} pipes=${pipe_count} lines=${line_count})."
	fi
	# Read-only mode check (stat only, never chmod): expect 0444 (`stat -c %a` reports 444).
	# Direct stat first, sudo -n fallback for hardened /proc mounts; unknown is
	# warn-only SKIP (stat unreadable), mismatch is fail-closed.
	stats_mode="unknown"
	if stats_mode_tmp="$(stat -c %a -- /proc/sys/kernel/std_stats 2>/dev/null)"; then
		stats_mode="${stats_mode_tmp}"
	elif [ "${HAVE_SUDO}" -eq 1 ] && stats_mode_tmp="$(sudo -n stat -c %a -- /proc/sys/kernel/std_stats 2>/dev/null)"; then
		stats_mode="${stats_mode_tmp}"
	fi
	if [ "${stats_mode}" = "444" ]; then
		echo "  OK: std_stats mode 0444 (read-only)."
	elif [ "${stats_mode}" = "unknown" ]; then
		echo "  Note: std_stats mode unreadable via stat (direct + sudo -n); skipping mode check." >&2
	else
		note_fail "std_stats mode ${stats_mode} is not 0444 (expected read-only)."
	fi
else
	note_fail "cannot read /proc/sys/kernel/std_stats (non-STD kernel?): ${stats_out}"
fi

# 5. dmesg negative check (sudo -n only; direct dmesg usually denied).
# Portable STD boundary: (^|[^A-Za-z0-9_])STD([^A-Za-z0-9_]|$) (\b is GNU-only).
# register_sysctl_sz/procname null catch sysctl-table registration failures.
echo "--- dmesg negative ---"
echo "  Note: never use 'grep -i std' alone (zstd/systemd/BTRFS false positives)."
STD_DMESG_PAT='std_running|std_stats|register_sysctl_sz|procname null|(^|[^A-Za-z0-9_])STD([^A-Za-z0-9_]|$)'
if [ "${HAVE_SUDO}" -eq 1 ] && sudo -n dmesg >/dev/null 2>&1; then
	std_hits="$(sudo -n dmesg 2>/dev/null | grep -E -- "${STD_DMESG_PAT}" || true)"
	if [ -z "${std_hits}" ]; then
		echo "  OK: no STD-tagged lines in dmesg."
	else
		echo "  dmesg STD-tagged lines:"
		printf '%s\n' "${std_hits}" | head -n 10 | sed 's/^/    /'
		note_fail "dmesg contains STD-tagged lines (inspect for BUG/Oops/error)."
	fi
	bug_hits="$(sudo -n dmesg 2>/dev/null | grep -i -E -- 'BUG|Oops|stack trace' || true)"
	if [ -z "${bug_hits}" ]; then
		echo "  OK: no BUG/Oops/stack-trace lines."
	else
		echo "  dmesg BUG/Oops lines (warn-only unless tied to STD):"
		printf '%s\n' "${bug_hits}" | head -n 10 | sed 's/^/    /'
		echo "  WARNING: kernel BUG/Oops present (not necessarily STD)." >&2
	fi
else
	echo "  SKIP: sudo -n dmesg unavailable (fail-closed); rerun the sudo block manually."
	printf '%s\n' "  Manual: sudo -n dmesg | grep -E -- '${STD_DMESG_PAT}' (expect empty)."
fi

# 6. taskset smoke (no sudo; $$ is bash PID, in fish use $fish_pid).
echo "--- taskset smoke ---"
if taskset -c 0 sleep 0 2>&1; then
	echo "  OK: taskset -c 0 sleep 0 exited 0."
else
	note_fail "taskset -c 0 sleep 0 failed."
fi
# Bash $$ below; fish users run `taskset -p $fish_pid` instead.
if taskset_out="$(taskset -p $$ 2>&1)"; then
	echo "  ${taskset_out}"
	echo "  OK: taskset affinity readable (1-2 CPU systems pass through unchanged)."
else
	note_fail "taskset -p failed: ${taskset_out}"
fi

# 7. stat initrd >=50M (direct + sudo -n).
# Candidates cover kernel-install machine-id layout (BOOT_DIR/<machine-id>/<ver>/initrd
# where <machine-id> is /etc/machine-id; glob `*` covers the machine-id dir)
# plus the legacy flat layout (BOOT_DIR/initramfs-<ver>.img).
echo "--- initrd size ---"
INSTALLED_INITRD=""
for cand in "${BOOT_DIR}/"*"/${TARGET_VER}/initrd" "${BOOT_DIR}/initramfs-${TARGET_VER}.img"; do
	if boot_test_file "${cand}"; then
		INSTALLED_INITRD="${cand}"
		break
	fi
done
if [ -z "${INSTALLED_INITRD}" ]; then
	note_fail "no initrd found for ${TARGET_VER} under ${BOOT_DIR} (missing-initrd)."
else
	INITRD_SIZE="$(boot_stat_size "${INSTALLED_INITRD}")"
	case "${INITRD_SIZE}" in
		''|*[!0-9]*) INITRD_SIZE=0 ;;
	esac
	echo "  initrd: ${INSTALLED_INITRD} (${INITRD_SIZE} bytes)"
	if [ "${INITRD_SIZE}" -ge 52428800 ]; then
		echo "  OK: initrd >=50M."
	else
		note_fail "initrd size ${INITRD_SIZE} <50M (degraded; do NOT boot, rebuild manually)."
	fi
fi

# 8. modules >=1000 (direct + sudo -n fallback).
echo "--- modules ---"
mod_count=0
if [ -d "/lib/modules/${TARGET_VER}" ]; then
	mod_count="$(find -- "/lib/modules/${TARGET_VER}" -name '*.ko*' 2>/dev/null | wc -l | tr -d ' ')"
elif [ "${HAVE_SUDO}" -eq 1 ]; then
	mod_count="$(sudo -n find -- "/lib/modules/${TARGET_VER}" -name '*.ko*' 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
fi
case "${mod_count}" in
	''|*[!0-9]*) mod_count=0 ;;
esac
echo "  modules: ${mod_count} .ko files under /lib/modules/${TARGET_VER}"
if [ ! -d "/lib/modules/${TARGET_VER}" ] && { [ "${HAVE_SUDO}" -eq 0 ] || ! sudo -n test -d "/lib/modules/${TARGET_VER}" 2>/dev/null; }; then
	note_fail "module directory /lib/modules/${TARGET_VER} absent."
elif [ "${mod_count}" -ge 1000 ]; then
	echo "  OK: modules >=1000."
else
	note_fail "module count ${mod_count} <1000 (degraded install)."
fi

# 9. Limine STD+ver confirm (4 candidates, canonical `/STD kernel (ver)` same-line; legacy `:STD ver` accepted for compat; BLS never satisfies).
echo "--- Limine ---"
LIMINE_CONF=""
for cand in "${BOOT_DIR}/limine.conf" "${BOOT_DIR}/limine/limine.conf" "${BOOT_DIR}/EFI/BOOT/limine.conf" "${BOOT_DIR}/boot/limine.conf"; do
	if boot_test_file "${cand}"; then
		LIMINE_CONF="${cand}"
		break
	fi
done
if [ -z "${LIMINE_CONF}" ]; then
	note_fail "no limine.conf under ${BOOT_DIR} (4 candidates checked)."
else
	echo "  limine.conf: ${LIMINE_CONF}"
	if boot_grep_same_line "/STD kernel" "(${TARGET_VER})" "${LIMINE_CONF}"; then
		echo "  OK: Limine entry present (/STD kernel + ${TARGET_VER} on the same line; BLS never satisfies)."
	elif boot_grep_same_line ":STD" "${TARGET_VER}" "${LIMINE_CONF}"; then
		echo "  OK: Limine entry present (legacy :STD + ${TARGET_VER} compat; BLS never satisfies)."
	else
		note_fail "Limine entry lacks /STD kernel+${TARGET_VER} on the same line in ${LIMINE_CONF} (sync before reboot; BLS never satisfies)."
	fi
fi

# 10. modinfo nvidia (sudo -n, find fallback).
echo "--- modinfo nvidia ---"
ko_path=""
if [ "${HAVE_SUDO}" -eq 1 ] && sudo -n modinfo -k "${TARGET_VER}" -F filename nvidia >/dev/null 2>&1; then
	ko_path="$(sudo -n modinfo -k "${TARGET_VER}" -F filename nvidia 2>/dev/null || true)"
	echo "  OK: modinfo nvidia.ko: ${ko_path}"
else
	if [ "${HAVE_SUDO}" -eq 1 ]; then
		ko_path="$(sudo -n find -- "/lib/modules/${TARGET_VER}" -name 'nvidia.ko*' 2>/dev/null | head -n 1 || true)"
	else
		ko_path="$(find -- "/lib/modules/${TARGET_VER}" -name 'nvidia.ko*' 2>/dev/null | head -n 1 || true)"
	fi
	if [ -n "${ko_path}" ]; then
		echo "  OK (find fallback): ${ko_path}"
	else
		note_fail "nvidia.ko not found for ${TARGET_VER} (modinfo+find)."
	fi
fi

# 11. dkms status (no sudo; requires same-line `nvidia`, `<ver>`, `<arch>`, `installed`).
echo "--- dkms status ---"
DKMS_ARCH="$(uname -m 2>/dev/null || echo x86_64)"
if command -v dkms >/dev/null 2>&1; then
	if dkms status 2>/dev/null | grep -F -- "${TARGET_VER}" | grep -F -- "${DKMS_ARCH}" | grep -F -qi -- "nvidia"; then
		dkms status 2>/dev/null | grep -F -- "${TARGET_VER}" | grep -F -- "${DKMS_ARCH}" | grep -F -i -- "nvidia" | head -n 5 | sed 's/^/  /'
		if dkms status 2>/dev/null | grep -F -- "${TARGET_VER}" | grep -F -- "${DKMS_ARCH}" | grep -F -i -- "nvidia" | grep -F -qi -- "installed"; then
			echo "  OK: dkms lists nvidia for ${TARGET_VER} as installed (${DKMS_ARCH})."
		else
			note_fail "dkms nvidia entry for ${TARGET_VER} is not installed on ${DKMS_ARCH} (built/added/failed)."
		fi
	else
		note_fail "dkms status has no nvidia ${DKMS_ARCH} entry for ${TARGET_VER}."
	fi
else
	echo "  SKIP: dkms tool not found."
fi

echo "--- summary ---"
if [ "${FAIL_COUNT}" -eq 0 ]; then
	echo "Verify complete (read-only, no changes made). No reboot performed."
	exit 0
else
	echo "Verify found ${FAIL_COUNT} anomalous check(s) (read-only, no changes made). No reboot performed." >&2
	exit 1
fi
