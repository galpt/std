#!/bin/bash
# STD uninstaller for vanilla-arch 7.3.
# Self-contained: verifies reverse series, reverts in reverse order,
# removes scoped artifacts and handles boot entries.
# Supports --dry-run/--status/--remove, --yes, --prune-boot and --boot-dir.
# Parse $BOOT_DIR/limine.conf (4 candidates) to check boot entry.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PATCH_DIR="${WORKSPACE_ROOT}/patches/vanilla-arch/7.3"
SERIES_FILE="${PATCH_DIR}/series"
DEFAULT_TREE="${WORKSPACE_ROOT}/linux-fresh-7.3"
# shellcheck disable=SC2034 # retained for parity with install.sh (upstream pin documented)
KERNEL_URL="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"

DRY_RUN=0
ASSUME_YES=0
PRUNE_BOOT=0
REMOVE_MODE=0
STATUS_MODE=0
KERNEL_DIR=""
BOOT_DIR="${BOOT_DIR:-/boot}"
LOG_FILE="$(mktemp /tmp/std-uninstall-XXXXXX.log)"

usage() {
	echo "Usage: $0 [--dry-run] [--yes] [--prune-boot] [--boot-dir DIR] [--remove] [--status] [KERNEL_DIR]"
	echo "  --dry-run   Verify reverse dry-run, git reverse check and checkpatch only"
	echo "  --yes       Skip confirmation prompt"
	echo "  --prune-boot  List boot entries only (requires --yes)"
	echo "  --boot-dir DIR  Boot directory, default ${BOOT_DIR}"
	echo "  --remove    Delete installed boot artifacts for the target release (allowlisted; refuses running kernel; requires --yes)"
	echo "  --status    Read-only status report (never mutates)"
	echo "  KERNEL_DIR  Target tree, default ${DEFAULT_TREE}"
}

while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run)
			DRY_RUN=1
			shift
			;;
		--yes)
			ASSUME_YES=1
			shift
			;;
		--prune-boot)
			PRUNE_BOOT=1
			shift
			;;
		--remove)
			REMOVE_MODE=1
			shift
			;;
		--status)
			STATUS_MODE=1
			shift
			;;
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
			# End of options: remainder is positional only (KERNEL_DIR).
			shift
			while [ $# -gt 0 ]; do
				if [ -n "${KERNEL_DIR}" ]; then
					echo "Too many positional args" >&2
					usage >&2
					exit 2
				fi
				KERNEL_DIR="$1"
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
			if [ -n "${KERNEL_DIR}" ]; then
				echo "Too many positional args" >&2
				usage >&2
				exit 2
			fi
			KERNEL_DIR="$1"
			shift
			;;
	esac
done

if [ -z "${KERNEL_DIR}" ]; then
	KERNEL_DIR="${DEFAULT_TREE}"
fi

# Confinement: canonicalize dirs and refuse root, empty, same or nested dirs.
# realpath -m (missing-ok) is intentional: it supports mocked --boot-dir paths
# that may not exist yet. Canonicalizes symlinks before same/nested checks.
# Safety comes from the refuse-root/same/nested guards below, not from
# existence checks, so -m does not weaken confinement.
# Refuse empty/root BOOT_DIR before canonicalization (realpath -m would map
# "" to PWD and hide an empty --boot-dir), then canonicalize and refuse again.
# Mirrors scripts/verify-std.sh: install and verify share one rule.
case "${BOOT_DIR}" in
	""|"/"|"//") echo "Refusing unsafe BOOT_DIR: ${BOOT_DIR}" >&2; exit 1 ;;
esac
if command -v realpath >/dev/null 2>&1; then
	KERNEL_DIR="$(realpath -m -- "${KERNEL_DIR}")"
	BOOT_DIR="$(realpath -m -- "${BOOT_DIR}")"
else
	KERNEL_DIR="$(readlink -f -- "${KERNEL_DIR}" 2>/dev/null || printf '%s' "${KERNEL_DIR}")"
	BOOT_DIR="$(readlink -f -- "${BOOT_DIR}" 2>/dev/null || printf '%s' "${BOOT_DIR}")"
fi
case "${KERNEL_DIR}" in
	""|"/"|"//") echo "Refusing unsafe KERNEL_DIR: ${KERNEL_DIR}" >&2; exit 1 ;;
esac
case "${BOOT_DIR}" in
	""|"/"|"//") echo "Refusing unsafe BOOT_DIR: ${BOOT_DIR}" >&2; exit 1 ;;
esac
if [ "${KERNEL_DIR}" = "${BOOT_DIR}" ]; then
	echo "KERNEL_DIR and BOOT_DIR must differ" >&2
	exit 1
fi
case "${KERNEL_DIR}/" in
	"${BOOT_DIR}/"*) echo "Refusing nested KERNEL_DIR under BOOT_DIR" >&2; exit 1 ;;
esac
case "${BOOT_DIR}/" in
	"${KERNEL_DIR}/"*) echo "Refusing nested BOOT_DIR under KERNEL_DIR" >&2; exit 1 ;;
esac

# Allowlisted release/token check: ^[A-Za-z0-9_][A-Za-z0-9._+-]*$ (no slash, no glob, no empty, no leading dash/dot; explicit dot-only guard rejects "." and ".." directory traversal).
# Newline/tab/space/control pre-reject before grep: grep -E ^...$ matches per line,
# so an embedded newline ("ok\nbad") would otherwise pass on the first line.
# The shell case below fails closed on any char outside the allowlist (covers
# space, tab, newline and controls) plus a leading-class check, then grep
# re-validates the full token as defense in depth.
# Mirrors scripts/verify-std.sh: install and verify share one rule.
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

# Limine 4-candidate parity with install.sh (direct + sudo -n).
# Candidates: limine.conf, limine/limine.conf, EFI/BOOT/limine.conf, boot/limine.conf.
# find_limine_conf prints the first readable candidate; list_limine_confs prints all.
# has_std_ver reports 0 when canonical `/STD kernel (ver)` or legacy `:STD <ver>`
# shares the SAME line with the exact ver in the same conf (piped grep;
# file-level co-occurrence alone does NOT satisfy; BLS never satisfies Limine).
# sudo -n only, never bare sudo.
boot_grep_same_line() {
	# Same-line check via pipe: line must contain BOTH pat1 and pat2 (exact ver).
	# File-level co-occurrence in different lines does NOT satisfy Limine
	# (title line is `/STD kernel (ver)` canonical, `:STD <ver>` legacy compat). Uses fixed strings (-F) with `--`.
	# Exact ver: canonical requires "(ver)" with parens (prevents 7.3.0-std matching 7.3.0-std-dirty);
	# legacy ":STD ver" requires token-boundary (ver not followed by [A-Za-z0-9._+-]).
	# Mirrors scripts/verify-std.sh: install and verify share one rule.
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
			if [ "${HAVE_SUDO:-0}" -eq 1 ] && sudo -n grep -F -- "${pat1}" "${file}" 2>/dev/null | grep -F -q -- "${exact}"; then
				return 0
			fi
			return 1
			;;
		":STD"*)
			if [ -f "${file}" ] && awk -v ver="${pat2}" 'index($0, ":STD")>0 { p=index($0, ":STD"); rest=substr($0, p+4); sub(/^[ \t]+/, "", rest); if (substr(rest,1,length(ver))==ver) { after=substr(rest, length(ver)+1, 1); if (after=="" || after !~ /[A-Za-z0-9._+\-]/) { found=1; exit 0 } } } END { exit !found }' "${file}" 2>/dev/null; then
				return 0
			fi
			if [ "${HAVE_SUDO:-0}" -eq 1 ] && sudo -n awk -v ver="${pat2}" 'index($0, ":STD")>0 { p=index($0, ":STD"); rest=substr($0, p+4); sub(/^[ \t]+/, "", rest); if (substr(rest,1,length(ver))==ver) { after=substr(rest, length(ver)+1, 1); if (after=="" || after !~ /[A-Za-z0-9._+\-]/) { found=1; exit 0 } } } END { exit !found }' "${file}" 2>/dev/null; then
				return 0
			fi
			return 1
			;;
		*)
			if [ -f "${file}" ] && grep -F -- "${pat1}" "${file}" 2>/dev/null | grep -F -q -- "${pat2}"; then
				return 0
			fi
			if [ "${HAVE_SUDO:-0}" -eq 1 ] && sudo -n grep -F -- "${pat1}" "${file}" 2>/dev/null | grep -F -q -- "${pat2}"; then
				return 0
			fi
			return 1
			;;
	esac
}

has_std_ver() {
	_conf="$1"
	_ver="$2"
	if boot_grep_same_line "/STD kernel" "(${_ver})" "${_conf}"; then
		return 0
	fi
	boot_grep_same_line ":STD" "${_ver}" "${_conf}"
}

find_limine_conf() {
	for cand in "${BOOT_DIR}/limine.conf" "${BOOT_DIR}/limine/limine.conf" "${BOOT_DIR}/EFI/BOOT/limine.conf" "${BOOT_DIR}/boot/limine.conf"; do
		if [ -f "${cand}" ]; then
			printf '%s' "${cand}"
			return 0
		fi
		if [ "${HAVE_SUDO:-0}" -eq 1 ] && sudo -n test -f "${cand}" 2>/dev/null; then
			printf '%s' "${cand}"
			return 0
		fi
	done
	return 1
}

list_limine_confs() {
	for cand in "${BOOT_DIR}/limine.conf" "${BOOT_DIR}/limine/limine.conf" "${BOOT_DIR}/EFI/BOOT/limine.conf" "${BOOT_DIR}/boot/limine.conf"; do
		if [ -f "${cand}" ]; then
			printf '%s\n' "${cand}"
		elif [ "${HAVE_SUDO:-0}" -eq 1 ] && sudo -n test -f "${cand}" 2>/dev/null; then
			printf '%s\n' "${cand}"
		fi
	done
}

# Expected STD dirt allowlist (status parity with install.sh).
# Membership allowlist: any subset of the 6 tracked STD modifications + any
# subset of the 3 untracked STD sources is expected (subset acceptance);
# patch/build leftovers (*.orig/*.rej, kernel/sched/std.o, .std.o.cmd)
# are ignored; anything else reports as extra dirt (read-only here).
# Read-only; git only, never sudo, never mutates.
# shellcheck disable=SC2034 # TREE_DIRT retained for parity with install.sh (external/status consumers)
TREE_DIRT="unknown"

is_expected_modified() {
	case "$1" in
		Documentation/admin-guide/kernel-parameters.txt|include/linux/sched.h|kernel/Kconfig.preempt|kernel/sched/Makefile|kernel/sched/sched.h|kernel/sched/core.c)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

is_expected_untracked() {
	case "$1" in
		Documentation/scheduler/sched-std.rst|kernel/sched/std.c|kernel/sched/std.h)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

is_ignored_dirt() {
	case "$1" in
		*.orig|*.rej)
			return 0
			;;
		kernel/sched/std.o|kernel/sched/.std.o.cmd)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

# Classify working-tree dirt against the allowlist (read-only, no sudo).
# Prints one `  dirt: ...` line plus any `  extra: ...` lines.
# Sets TREE_DIRT to clean|expected|extra|unknown. Returns 0 unless extra.
classify_tree_dirt() {
	TREE_DIRT="unknown"
	if ! command -v git >/dev/null 2>&1 || [ ! -d "${KERNEL_DIR}/.git" ]; then
		echo "  dirt: unknown (no git inventory; skipping allowlist check)"
		TREE_DIRT="unknown"
		return 0
	fi
	dirt_porcelain=""
	if ! dirt_porcelain="$(git -C "${KERNEL_DIR}" --no-optional-locks status --porcelain 2>/dev/null)"; then
		echo "  dirt: git status failed; falling back to diff-index + ls-files (tracked + untracked)." >&2
		tracked_fallback="$(git -C "${KERNEL_DIR}" diff-index --name-only HEAD 2>/dev/null || true)"
		untracked_fallback="$(git -C "${KERNEL_DIR}" ls-files --others --exclude-standard 2>/dev/null || true)"
		dirt_porcelain=""
		while IFS= read -r p; do
			[ -z "${p}" ] && continue
			dirt_porcelain="${dirt_porcelain} M ${p}
"
		done <<<"${tracked_fallback}"
		while IFS= read -r p; do
			[ -z "${p}" ] && continue
			dirt_porcelain="${dirt_porcelain}?? ${p}
"
		done <<<"${untracked_fallback}"
		if [ -z "${dirt_porcelain}" ]; then
			echo "  dirt: unknown (git fallback empty/failed; skipping allowlist check)"
			TREE_DIRT="unknown"
			return 0
		fi
	fi
	extra_list=""
	counted=0
	while IFS= read -r line; do
		[ -z "${line}" ] && continue
		xy="$(printf '%s' "${line}" | cut -c1-2)"
		fpath="$(printf '%s' "${line}" | cut -c4-)"
		case "${fpath}" in
			*" -> "*)
				extra_list="${extra_list}${line}
"
				continue
				;;
		esac
		case "${fpath}" in
			'"'*'"')
				fpath="$(printf '%s' "${fpath}" | sed 's/^"//; s/"$//')"
				;;
		esac
		[ -z "${fpath}" ] && continue
		if is_ignored_dirt "${fpath}"; then
			continue
		fi
		counted=$((counted + 1))
		case "${xy}" in
			"??")
				if is_expected_untracked "${fpath}"; then
					continue
				fi
				extra_list="${extra_list}${line}
"
				;;
			*)
				if is_expected_modified "${fpath}"; then
					case "${xy}" in
						*M*) continue ;;
					esac
					extra_list="${extra_list}${line}
"
				elif is_expected_untracked "${fpath}"; then
					case "${xy}" in
						*A*) continue ;;
					esac
					extra_list="${extra_list}${line}
"
				else
					extra_list="${extra_list}${line}
"
				fi
				;;
		esac
	done <<<"${dirt_porcelain}"
	if [ -n "${extra_list}" ]; then
		TREE_DIRT="extra"
		echo "  dirt: extra dirt beyond STD allowlist (fail-closed):"
		while IFS= read -r eline; do
			[ -z "${eline}" ] && continue
			echo "  extra: ${eline}"
		done <<<"${extra_list}"
		echo "  allowlist: up to 6M (Documentation/admin-guide/kernel-parameters.txt, include/linux/sched.h, kernel/Kconfig.preempt, kernel/sched/Makefile, kernel/sched/sched.h, kernel/sched/core.c) + up to 3U (Documentation/scheduler/sched-std.rst, kernel/sched/std.c, kernel/sched/std.h); any subset is expected; ignored: *.orig, *.rej, kernel/sched/std.o, kernel/sched/.std.o.cmd"
		return 1
	fi
	if [ "${counted}" -eq 0 ]; then
		TREE_DIRT="clean"
		echo "  dirt: clean (no non-ignored changes)"
		return 0
	fi
	TREE_DIRT="expected"
	echo "  dirt: expected STD dirt only (membership allowlist up to 6M+3U, any subset; ignored artifacts excluded)"
	return 0
}

# Log all output to /tmp/std-uninstall-*.log while keeping stdout.
# mktemp creates 0600 files; prune only via `rm -f /tmp/std-*` (files only,
# never rm -rf /tmp). No preflight artifact is world-readable by design.
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "Log: ${LOG_FILE}"
echo "Target: ${KERNEL_DIR}"
echo "Boot: ${BOOT_DIR}"

HAVE_SUDO=0

probe_privilege() {
	HAVE_SUDO=0
	if sudo -n true 2>/dev/null; then
		HAVE_SUDO=1
		echo "Privilege: sudo -n available (fail-closed checks enabled)."
	else
		HAVE_SUDO=0
		echo "Note: sudo -n unavailable; privileged checks are skipped (fail-closed)." >&2
	fi
}

# Read-only status: target release, running kernel, allowlisted artifacts.
uninstall_status() {
	krel="unknown"
	if [ -f "${KERNEL_DIR}/Makefile" ]; then
		krel="$(make -C "${KERNEL_DIR}" -s kernelrelease 2>/dev/null || echo "unknown")"
	fi
	echo "Status (read-only, no changes made):"
	echo "  target: ${KERNEL_DIR}"
	echo "  boot: ${BOOT_DIR}"
	echo "  kernelrelease: ${krel}"
	echo "  running: $(uname -r 2>/dev/null || echo unknown)"
	probe_privilege
	if [ "${krel}" != "unknown" ] && [ -n "${krel}" ]; then
		for cand in "${BOOT_DIR}/vmlinuz-${krel}" "${BOOT_DIR}/System.map-${krel}" "${BOOT_DIR}/initramfs-${krel}.img"; do
			if [ -f "${cand}" ]; then
				echo "  present: ${cand}"
			elif [ "${HAVE_SUDO}" -eq 1 ] && sudo -n test -f "${cand}" 2>/dev/null; then
				echo "  present (root-only): ${cand}"
			else
				echo "  missing: ${cand}"
			fi
		done
		if [ -d "/lib/modules/${krel}" ]; then
			echo "  present: /lib/modules/${krel}"
		elif [ "${HAVE_SUDO}" -eq 1 ] && sudo -n test -d "/lib/modules/${krel}" 2>/dev/null; then
			echo "  present (root-only): /lib/modules/${krel}"
		else
			echo "  missing: /lib/modules/${krel}"
		fi
		# Accepted releases: 7.3.0-std (clean) and 7.3.0-std-dirty with expected STD dirt.
		# List stale dirty siblings without deleting (prune via --remove).
		case "${krel}" in
			7.3.0-std-dirty)
				echo "  naming: ${krel} accepted with expected STD dirt only (membership allowlist up to 6M+3U, any subset); extra/unknown dirt or *+ still fails install verification."
				;;
			*-dirty|*+)
				echo "  naming: ${krel} carries a dirty/plus suffix; install verification fails (only 7.3.0-std-dirty with expected dirt verifies)."
				;;
			7.3.0-std)
				stale_ver="${krel}-dirty"
				for cand in "${BOOT_DIR}/vmlinuz-${stale_ver}" "${BOOT_DIR}/System.map-${stale_ver}" "${BOOT_DIR}/initramfs-${stale_ver}.img"; do
					if [ -f "${cand}" ]; then
						echo "  stale dirty artifact: ${cand} (prune via --remove --yes; see README Version migration)"
					elif [ "${HAVE_SUDO}" -eq 1 ] && sudo -n test -f "${cand}" 2>/dev/null; then
						echo "  stale dirty artifact (root-only): ${cand} (prune via --remove --yes)"
					fi
				done
				if [ -d "/lib/modules/${stale_ver}" ] || { [ "${HAVE_SUDO}" -eq 1 ] && sudo -n test -d "/lib/modules/${stale_ver}" 2>/dev/null; }; then
					echo "  stale dirty modules: /lib/modules/${stale_ver} (prune via --remove --yes)"
				fi
				;;
		esac
	fi
	# Expected-dirt allowlist (read-only parity with install.sh;
	# git only, never sudo, never mutates).
	classify_tree_dirt || true
	: "${TREE_DIRT}" # consumed for parity with install.sh verification gate
	limine_found=""
	for limine_cand in "${BOOT_DIR}/limine.conf" "${BOOT_DIR}/limine/limine.conf" "${BOOT_DIR}/EFI/BOOT/limine.conf" "${BOOT_DIR}/boot/limine.conf"; do
		if [ -f "${limine_cand}" ]; then
			echo "  limine.conf: present (${limine_cand})"
			limine_found=1
		elif [ "${HAVE_SUDO}" -eq 1 ] && sudo -n test -f "${limine_cand}" 2>/dev/null; then
			echo "  limine.conf: present (root-only, ${limine_cand})"
			limine_found=1
		fi
	done
	if [ -z "${limine_found}" ]; then
		echo "  limine.conf: absent (4 candidates under ${BOOT_DIR} checked)"
	fi
	echo "Status complete (read-only, no changes made)."
}

# Limine standalone STD removal with backup and rollback.
# Stanza delete of /STD kernel (ver) plus legacy/orphan dedupe, per candidate.
# Retains tool phase for nested //std only (no tool for standalone stanza).
# Removes nested //std (//std + kernel-id=std), legacy EOF (# STD + :STD +
# UPPERCASE), orphan uppercase PROTOCOL:/CMDLINE: pairs, and the /STD kernel
# stanza matching ver. Primary removal is the STD stanza delete. Backup timestamped via sudo -n cp -a, b2sum pre/post,
# same-line absence verify (canonical /STD kernel (ver) and legacy :STD ver
# must both be absent), rollback on fail. Keeps 4-candidate search, is_safe_ver,
# BOOT_DIR confinement, sudo -n only. DRY_RUN/STATUS never mutate. Preserves
# default_entry.
remove_limine_entry() {
	target_ver="$1"
	limine_list="$(list_limine_confs || true)"
	if [ -z "${limine_list}" ]; then
		echo "No limine.conf under ${BOOT_DIR} (4 candidates checked); skipping Limine removal."
		return 0
	fi
	if [ "${DRY_RUN}" -eq 1 ] || [ "${STATUS_MODE}" -eq 1 ]; then
		echo "Read-only mode: would remove Limine STD entry for ${target_ver} (no changes)."
		return 0
	fi
	if ! is_safe_ver "${target_ver}"; then
		echo "Refusing unsafe release for Limine removal: ${target_ver}" >&2
		return 1
	fi
	if [ "${HAVE_SUDO:-0}" -ne 1 ]; then
		echo "WARNING: no sudo -n; cannot clean Limine entry for ${target_ver} (fail-closed). Remove STD block manually from 4 candidates under ${BOOT_DIR}." >&2
		return 0
	fi
	# Back up every existing candidate before any mutation.
	while IFS= read -r limine_conf; do
		[ -z "${limine_conf}" ] && continue
		case "${limine_conf}" in
			"${BOOT_DIR}/limine.conf"|"${BOOT_DIR}/limine/limine.conf"|"${BOOT_DIR}/EFI/BOOT/limine.conf"|"${BOOT_DIR}/boot/limine.conf")
				;;
			*)
				echo "Skipping unexpected Limine path ${limine_conf}." >&2
				continue
			;;
		esac
		backup="${limine_conf}.std-backup-$(date +%Y%m%d%H%M%S)"
		echo "Backing up ${limine_conf} -> ${backup}..."
		if ! sudo -n cp -a -- "${limine_conf}" "${backup}"; then
			echo "WARNING: Limine backup failed for ${limine_conf}; aborting Limine removal (fail-closed)." >&2
			return 0
		fi
		if command -v b2sum >/dev/null 2>&1; then
			b2sum -- "${limine_conf}" 2>/dev/null | awk '{print "Limine conf b2sum (pre): " $1}' || sudo -n b2sum -- "${limine_conf}" 2>/dev/null | awk '{print "Limine conf b2sum (pre, root-only): " $1}' || true
		fi
	done <<<"${limine_list}"
	# Tool phase for nested //std only when scoped to the real /boot.
	# For mocked BOOT_DIR, skip the tool (it would touch live /boot) and rely
	# on the filtered stanza delete below, which also handles nested.
	if [ "${BOOT_DIR}" = "/boot" ] && command -v limine-entry-tool >/dev/null 2>&1 && sudo -n limine-entry-tool --help 2>&1 | grep -Eq -- '--remove'; then
		echo "Removing nested STD entry via tool (nested //std only)..."
		if sudo -n limine-entry-tool --remove-kernel std 2>&1 | tee -a "${LOG_FILE}"; then
			:
		else
			echo "WARNING: tool remove for nested std failed; continuing to filtered stanza delete." >&2
		fi
	else
		echo "Skipping tool phase for nested std (mocked BOOT_DIR or no tool; filtered stanza delete handles nested)."
	fi
	# Filtered stanza delete: remove /STD kernel (ver) plus legacy/orphan dedupe, per candidate.
	filter_failed=0
	while IFS= read -r limine_conf; do
		[ -z "${limine_conf}" ] && continue
		case "${limine_conf}" in
			"${BOOT_DIR}/limine.conf"|"${BOOT_DIR}/limine/limine.conf"|"${BOOT_DIR}/EFI/BOOT/limine.conf"|"${BOOT_DIR}/boot/limine.conf")
				;;
			*)
				continue
			;;
		esac
		# shellcheck disable=SC2012 # ls picks the newest backup (system-generated names); no ownership parsing, so find offers no benefit.
		backup="$(ls -t -- "${limine_conf}.std-backup-"* 2>/dev/null | head -n 1 || true)"
		if [ -z "${backup}" ]; then
			backup="${limine_conf}.std-backup-$(date +%Y%m%d%H%M%S)"
			echo "Backing up ${limine_conf} -> ${backup}..."
			if ! sudo -n cp -a -- "${limine_conf}" "${backup}"; then
				echo "WARNING: Limine backup failed for ${limine_conf}; skipping filtered delete for this candidate." >&2
				filter_failed=1
				continue
			fi
		fi
		echo "Filtering STD entry for ${target_ver} from ${limine_conf} (stanza delete + legacy/orphan dedupe)..."
		tmpfile="$(mktemp /tmp/std-limine-XXXXXX)"
		tmpfilt="${tmpfile}.filtered"
		if [ -f "${limine_conf}" ]; then
			if ! cat -- "${limine_conf}" >"${tmpfile}" 2>/dev/null; then
				echo "WARNING: cannot read ${limine_conf}; restoring backup." >&2
				sudo -n cp -a -- "${backup}" "${limine_conf}" || echo "WARNING: Limine rollback failed; restore ${backup} manually." >&2
				rm -f -- "${tmpfile}" "${tmpfilt}" 2>/dev/null || true
				filter_failed=1
				continue
			fi
		else
			# shellcheck disable=SC2024 # sudo applies to cat (root read); redirect is user-owned tmpfile by design
			if ! sudo -n cat -- "${limine_conf}" >"${tmpfile}" 2>/dev/null; then
				echo "WARNING: cannot read ${limine_conf} via sudo -n; restoring backup." >&2
				sudo -n cp -a -- "${backup}" "${limine_conf}" || true
				rm -f -- "${tmpfile}" "${tmpfilt}" 2>/dev/null || true
				filter_failed=1
				continue
			fi
		fi
		default_pre="$(grep -E -- '^default_entry:' "${tmpfile}" 2>/dev/null || true)"
		if ! awk -v ver="${target_ver}" ' /^[[:space:]]*\/\/std([[:space:]]|$)/ { skip_nested=1; next } skip_nested && /^[[:space:]]*$/ { skip_nested=0; print; next } skip_nested && /^\// { skip_nested=0 } skip_nested { if ($0 ~ /^[[:space:]]*(cmdline|CMDLINE):/) { skip_nested=0 } next } /^# STD([[:space:]]|$)/ { next } /^:STD([[:space:]]|$)/ { next } /^[[:space:]]*(PROTOCOL|KERNEL_PATH|MODULE_PATH|CMDLINE):/ { next } /^\/STD kernel([[:space:]]|\(|$)/ { if (index($0, "(" ver ")") > 0) { skip_std=1; next } } skip_std && /^[[:space:]]+(protocol|kernel_path|module_path|cmdline|comment):/ { next } skip_std && /^[[:space:]]*(PROTOCOL|KERNEL_PATH|MODULE_PATH|CMDLINE):/ { next } skip_std && /^[[:space:]]*$/ { skip_std=0; print; next } skip_std && /^\// { skip_std=0 } skip_std { skip_std=0 } { print } ' "${tmpfile}" >"${tmpfilt}" 2>/dev/null; then
			echo "WARNING: cannot filter ${limine_conf}; restoring backup." >&2
			sudo -n cp -a -- "${backup}" "${limine_conf}" || echo "WARNING: Limine rollback failed; restore ${backup} manually." >&2
			rm -f -- "${tmpfile}" "${tmpfilt}" 2>/dev/null || true
			filter_failed=1
			continue
		fi
		default_post="$(grep -E -- '^default_entry:' "${tmpfilt}" 2>/dev/null || true)"
		if [ "${default_pre}" != "${default_post}" ]; then
			echo "WARNING: default_entry changed during Limine removal; rolling back ${backup}." >&2
			sudo -n cp -a -- "${backup}" "${limine_conf}" || echo "WARNING: Limine rollback failed; restore ${backup} manually." >&2
			rm -f -- "${tmpfile}" "${tmpfilt}" 2>/dev/null || true
			filter_failed=1
			continue
		fi
		if ! sudo -n cp -a -- "${tmpfilt}" "${limine_conf}"; then
			echo "WARNING: Limine filtered write failed for ${limine_conf}; rolling back ${backup}." >&2
			sudo -n cp -a -- "${backup}" "${limine_conf}" || echo "WARNING: Limine rollback failed; restore ${backup} manually." >&2
			rm -f -- "${tmpfile}" "${tmpfilt}" 2>/dev/null || true
			filter_failed=1
			continue
		fi
		rm -f -- "${tmpfile}" "${tmpfilt}" 2>/dev/null || true
		# Removal verify (same-line absence): both canonical and legacy must be absent. BLS never satisfies.
		if boot_grep_same_line "/STD kernel" "(${target_ver})" "${limine_conf}" || boot_grep_same_line ":STD" "${target_ver}" "${limine_conf}"; then
			echo "WARNING: Limine verify failed for STD+ver ${target_ver} in ${limine_conf}; rolling back ${backup}." >&2
			sudo -n cp -a -- "${backup}" "${limine_conf}" || echo "WARNING: Limine rollback failed; restore ${backup} manually." >&2
			filter_failed=1
			continue
		fi
		if command -v b2sum >/dev/null 2>&1; then
			sudo -n b2sum -- "${limine_conf}" 2>/dev/null | awk '{print "Limine conf b2sum (post): " $1}' || b2sum -- "${limine_conf}" 2>/dev/null | awk '{print "Limine conf b2sum (post): " $1}' || true
		fi
		echo "Limine STD entry removed for ${target_ver} in ${limine_conf} (stanza delete + dedupe, backup at ${backup})."
	done <<<"${limine_list}"
	if [ "${filter_failed}" -ne 0 ]; then
		return 0
	fi
	echo "Limine STD entry removed for ${target_ver} (stanza delete + dedupe, backups under ${BOOT_DIR})."
	return 0
}

# Allowlisted boot-artifact removal for the target release.
# Refuses to remove the running kernel. Never in --dry-run/--status.
# Requires --yes (two-key guard) for any real deletion.
# Coverage (allowlisted only): boot artifacts (vmlinuz/System.map/initramfs),
# BLS entries (loader/entries/*ver*), Limine STD-block (4 candidates, backup),
# modules dir (/lib/modules/ver), DKMS entries (-k ver), dirty-sibling
# (ver-dirty boot/BLS/modules when target is clean), GRUB orphan refresh.
do_remove() {
	target_ver="$1"
	if [ -z "${target_ver}" ] || [ "${target_ver}" = "unknown" ]; then
		echo "Cannot --remove: unknown kernelrelease." >&2
		return 1
	fi
	case "${target_ver}" in
		*"/"*|*".."*|-*)
			echo "Refusing unsafe release for --remove: ${target_ver}" >&2
			return 1
			;;
	esac
	if ! is_safe_ver "${target_ver}"; then
		echo "Refusing unsafe release for --remove (allowlist ^[A-Za-z0-9_][A-Za-z0-9._+-]*\$): ${target_ver}" >&2
		return 1
	fi
	running=""
	if ! running="$(uname -r 2>/dev/null)"; then
		echo "Cannot determine running kernel (uname -r failed); refusing --remove (fail-closed)." >&2
		return 1
	fi
	if [ -z "${running}" ]; then
		echo "Cannot determine running kernel (empty); refusing --remove (fail-closed)." >&2
		return 1
	fi
	if [ "${running}" = "${target_ver}" ]; then
		echo "Refusing to remove running kernel ${running}." >&2
		return 1
	fi
	if [ "${DRY_RUN}" -eq 1 ] || [ "${STATUS_MODE}" -eq 1 ]; then
		echo "Read-only mode: would remove allowlisted artifacts for ${target_ver} (no deletion)."
		return 0
	fi
	if [ "${ASSUME_YES}" -ne 1 ]; then
		echo "--remove requires --yes for deletion (two-key guard)." >&2
		return 1
	fi
	if [ "${HAVE_SUDO}" -ne 1 ]; then
		echo "Cannot --remove without sudo -n (fail-closed)." >&2
		return 1
	fi
	# Allowlisted files under BOOT_DIR (exact names only).
	for cand in "${BOOT_DIR}/vmlinuz-${target_ver}" "${BOOT_DIR}/System.map-${target_ver}" "${BOOT_DIR}/initramfs-${target_ver}.img"; do
		case "${cand}" in
			"${BOOT_DIR}/vmlinuz-"*|"${BOOT_DIR}/System.map-"*|"${BOOT_DIR}/initramfs-"*)
				if sudo -n test -f "${cand}" 2>/dev/null || [ -f "${cand}" ]; then
					echo "Removing ${cand}..."
					sudo -n rm -f -- "${cand}" || echo "WARNING: failed to remove ${cand}." >&2
				else
					echo "Absent (skip): ${cand}"
				fi
				;;
			*) echo "Skipping unexpected path ${cand}." >&2 ;;
		esac
	done
	# Allowlisted BLS entries containing the target release.
	bls_dir="${BOOT_DIR}/loader/entries"
	if [ -d "${bls_dir}" ] || sudo -n test -d "${bls_dir}" 2>/dev/null; then
		entries="$(sudo -n find -- "${bls_dir}" -maxdepth 1 -type f -name "*${target_ver}*" 2>/dev/null || find -- "${bls_dir}" -maxdepth 1 -type f -name "*${target_ver}*" 2>/dev/null || true)"
		if [ -n "${entries}" ]; then
			while IFS= read -r ent; do
				[ -z "${ent}" ] && continue
				case "${ent}" in
					"${bls_dir}/"*)
						echo "Removing BLS entry ${ent}..."
						sudo -n rm -f -- "${ent}" || echo "WARNING: failed to remove ${ent}." >&2
						;;
					*) echo "Skipping unexpected BLS path ${ent}." >&2 ;;
				esac
			done <<<"${entries}"
		else
			echo "No BLS entries for ${target_ver} in ${bls_dir}."
		fi
	fi
	# Limine STD-block removal (automated with backup; fail-closed on sudo -n/backup).
	remove_limine_entry "${target_ver}" || return 1
	# Allowlisted modules dir (exact path only, no nesting, allowlisted ver).
	mod_dir="/lib/modules/${target_ver}"
	case "${target_ver}" in
		*"/"*|*".."*|-*|"")
			echo "Refusing unsafe modules path (bad version): ${mod_dir}" >&2
			return 1
			;;
	esac
	if ! is_safe_ver "${target_ver}"; then
		echo "Refusing unsafe modules path (allowlist): ${mod_dir}" >&2
		return 1
	fi
	case "${mod_dir}" in
		"/lib/modules/${target_ver}")
			;;
		*)
			echo "Refusing unsafe modules path: ${mod_dir}" >&2
			return 1
			;;
	esac
	if [ "${mod_dir}" = "/lib/modules" ] || [ "${mod_dir}" = "/lib/modules/" ]; then
		echo "Refusing unsafe modules path (bare): ${mod_dir}" >&2
		return 1
	fi
	if sudo -n test -d "${mod_dir}" 2>/dev/null; then
		echo "Removing ${mod_dir}..."
		sudo -n rm -rf -- "${mod_dir}" || echo "WARNING: failed to remove ${mod_dir}." >&2
	else
		echo "Absent (skip): ${mod_dir}"
	fi
	# Best-effort DKMS removal for the target kernel (warn-only).
	if command -v dkms >/dev/null 2>&1; then
		stale="$(dkms status 2>/dev/null | grep -F -- "${target_ver}" || true)"
		if [ -n "${stale}" ]; then
			while IFS= read -r line; do
				[ -z "${line}" ] && continue
				modver="$(printf '%s' "${line}" | awk -F'[, :]' '{print $1}')"
				mod="$(printf '%s' "${modver}" | cut -d/ -f1)"
				ver="$(printf '%s' "${modver}" | cut -d/ -f2-)"
				if [ -z "${mod}" ] || [ -z "${ver}" ]; then
					continue
				fi
				if ! is_safe_ver "${mod}" || ! is_safe_ver "${ver}"; then
					echo "Skipping unsafe dkms module/version: ${mod}/${ver}" >&2
					continue
				fi
				echo "dkms remove ${mod}/${ver} -k ${target_ver}..."
				sudo -n dkms remove -m "${mod}" -v "${ver}" -k "${target_ver}" 2>&1 || echo "WARNING: dkms remove failed for ${mod}/${ver}." >&2
			done <<<"${stale}"
		fi
	fi
	# Migration: clean 7.3.0-std supersedes old 7.3.0-std-dirty artifacts.
	# When the current target is clean, also prune the stale -dirty sibling
	# (same allowlist, same running-kernel guard, same --yes two-key guard).
	case "${target_ver}" in
		*-dirty|*+)
			;;
		*)
			stale_ver="${target_ver}-dirty"
			if is_safe_ver "${stale_ver}" && [ "${running}" != "${stale_ver}" ]; then
				for cand in "${BOOT_DIR}/vmlinuz-${stale_ver}" "${BOOT_DIR}/System.map-${stale_ver}" "${BOOT_DIR}/initramfs-${stale_ver}.img"; do
					case "${cand}" in
						"${BOOT_DIR}/vmlinuz-"*|"${BOOT_DIR}/System.map-"*|"${BOOT_DIR}/initramfs-"*)
							if sudo -n test -f "${cand}" 2>/dev/null || [ -f "${cand}" ]; then
								echo "Removing stale dirty artifact ${cand}..."
								sudo -n rm -f -- "${cand}" || echo "WARNING: failed to remove ${cand}." >&2
							fi
							;;
						*) echo "Skipping unexpected stale path ${cand}." >&2 ;;
					esac
				done
				bls_dir="${BOOT_DIR}/loader/entries"
				if [ -d "${bls_dir}" ] || sudo -n test -d "${bls_dir}" 2>/dev/null; then
					stale_entries="$(sudo -n find -- "${bls_dir}" -maxdepth 1 -type f -name "*${stale_ver}*" 2>/dev/null || find -- "${bls_dir}" -maxdepth 1 -type f -name "*${stale_ver}*" 2>/dev/null || true)"
					if [ -n "${stale_entries}" ]; then
						while IFS= read -r ent; do
							[ -z "${ent}" ] && continue
							case "${ent}" in
								"${bls_dir}/"*)
									echo "Removing stale BLS entry ${ent}..."
									sudo -n rm -f -- "${ent}" || echo "WARNING: failed to remove ${ent}." >&2
									;;
								*) echo "Skipping unexpected stale BLS path ${ent}." >&2 ;;
							esac
						done <<<"${stale_entries}"
					fi
				fi
				stale_mod="/lib/modules/${stale_ver}"
				if sudo -n test -d "${stale_mod}" 2>/dev/null; then
					echo "Removing stale dirty modules ${stale_mod}..."
					sudo -n rm -rf -- "${stale_mod}" || echo "WARNING: failed to remove ${stale_mod}." >&2
				fi
			fi
			;;
	esac
	# GRUB orphan refresh: regenerate grub.cfg under BOOT_DIR so the removed
	# kernel drops out (warn-only; backup + verify absence; never fails remove).
	# No auto-rollback by design (unlike Limine): a failed verify keeps the
	# mkconfig output and the backup for manual restore via `sudo -n cp -a backup cfg`.
	# grub-mkconfig -o targets the BOOT_DIR-scoped cfg, so mocked runs only
	# touch the mock path (unlike Limine tree/update which would hit live /boot).
	grub_cfg=""
	for cand in "${BOOT_DIR}/grub/grub.cfg" "${BOOT_DIR}/grub2/grub.cfg"; do
		if [ -f "${cand}" ] || sudo -n test -f "${cand}" 2>/dev/null; then
			grub_cfg="${cand}"
			break
		fi
	done
	if [ -n "${grub_cfg}" ]; then
		GRUB_MKCONFIG=""
		if command -v grub-mkconfig >/dev/null 2>&1; then
			GRUB_MKCONFIG="grub-mkconfig"
		elif command -v grub2-mkconfig >/dev/null 2>&1; then
			GRUB_MKCONFIG="grub2-mkconfig"
		fi
		if [ -z "${GRUB_MKCONFIG}" ]; then
			echo "WARNING: grub-mkconfig/grub2-mkconfig not found; GRUB cfg may still reference ${target_ver} (orphan)." >&2
		elif [ "${HAVE_SUDO:-0}" -ne 1 ]; then
			echo "WARNING: no sudo -n; cannot refresh GRUB cfg ${grub_cfg} (may retain orphan entry for ${target_ver})." >&2
		else
			grub_backup="${grub_cfg}.std-backup-$(date +%Y%m%d%H%M%S)"
			if sudo -n cp -a -- "${grub_cfg}" "${grub_backup}" 2>/dev/null; then
				if sudo -n "${GRUB_MKCONFIG}" -o "${grub_cfg}" 2>&1 | tee -a "${LOG_FILE}"; then
					if sudo -n grep -F -q -- "${target_ver}" "${grub_cfg}" 2>/dev/null || grep -F -q -- "${target_ver}" "${grub_cfg}" 2>/dev/null; then
						echo "WARNING: GRUB cfg ${grub_cfg} still references ${target_ver} after refresh; backup at ${grub_backup}." >&2
					else
						echo "GRUB cfg refreshed for removal of ${target_ver} (${GRUB_MKCONFIG})."
					fi
				else
					echo "WARNING: ${GRUB_MKCONFIG} failed after removal; backup at ${grub_backup}." >&2
				fi
			else
				echo "WARNING: GRUB backup failed; skipping GRUB refresh (fail-closed)." >&2
			fi
		fi
	fi
	echo "Remove complete for ${target_ver} (allowlisted only)."
}

reject_v74() {
	# Local-tree only: no ls-remote probe (unanchored refs/tags/v7.4 would match
	# v7.4.x and brick the future). Enforce v7.3 on the local tree.
	if [ -f "${KERNEL_DIR}/Makefile" ]; then
		if grep -q -- "^VERSION *= *7" "${KERNEL_DIR}/Makefile" && grep -q -- "^PATCHLEVEL *= *4" "${KERNEL_DIR}/Makefile"; then
			echo "Kernel tree is v7.4, expected v7.3. Rejecting v7.4." >&2
			exit 1
		fi
	fi
	if command -v git >/dev/null 2>&1 && [ -d "${KERNEL_DIR}/.git" ]; then
		if git -C "${KERNEL_DIR}" describe --tags 2>/dev/null | grep -F -q -- "v7.4"; then
			echo "Kernel tree describes v7.4, expected v7.3. Rejecting v7.4." >&2
			exit 1
		fi
	fi
}

reject_rc() {
	# Local-tree only: v7.3 final ships empty EXTRAVERSION, so any -rc
	# candidate must not install. No ls-remote probe. Enforce final on
	# the local tree.
	if [ -f "${KERNEL_DIR}/Makefile" ]; then
		if grep -q -- "^EXTRAVERSION *=.*-rc" "${KERNEL_DIR}/Makefile"; then
			echo "Kernel tree is a release candidate (EXTRAVERSION -rc), expected v7.3 final. Rejecting rc." >&2
			exit 1
		fi
	fi
	if command -v git >/dev/null 2>&1 && [ -d "${KERNEL_DIR}/.git" ]; then
		if git -C "${KERNEL_DIR}" describe --tags 2>/dev/null | grep -F -q -- "rc"; then
			echo "Kernel tree describes a release candidate (rc), expected v7.3 final. Rejecting rc." >&2
			exit 1
		fi
	fi
}

# --status is read-only and never mutates (tolerates missing tree).
if [ "${STATUS_MODE}" -eq 1 ]; then
	uninstall_status
	exit 0
fi

if [ ! -d "${KERNEL_DIR}" ]; then
	echo "Kernel tree not found: ${KERNEL_DIR}" >&2
	exit 1
fi

reject_v74
reject_rc

if [ ! -f "${SERIES_FILE}" ]; then
	echo "Series file not found: ${SERIES_FILE}" >&2
	exit 1
fi

# Build reverse list from series file.
MAP_FILE="$(mktemp /tmp/std-uninstall-map-XXXXXX)"
trap 'rm -f -- "${MAP_FILE}"' EXIT
grep -v -- '^#' "${SERIES_FILE}" | grep -v -- '^$' | tac > "${MAP_FILE}" || true

# Preflight checks use reverse patch dry-run plus reverse git apply
# check plus checkpatch. Batch mode keeps patch from prompting, so
# a revert that no longer applies fails fast instead of hanging.
# Failures accumulate and abort before anything is reverted.
FAILED=0
while IFS= read -r patch; do
	[ -z "${patch}" ] && continue
	case "${patch}" in
		*"/"*|*".."*|-*)
			echo "Unsafe series entry: ${patch}" >&2
			FAILED=1
			continue
			;;
	esac
	PATCH_FILE="${PATCH_DIR}/${patch}"
	if [ ! -f "${PATCH_FILE}" ]; then
		echo "Missing patch: ${PATCH_FILE}" >&2
		FAILED=1
		continue
	fi
	echo "Checking reverse ${patch}..."
	if ! patch -p1 -R -N -F 0 --batch --dry-run -d "${KERNEL_DIR}" < "${PATCH_FILE}" >/dev/null; then
		echo "Reverse dry-run failed for ${patch} (may already be reverted)" >&2
		FAILED=1
	fi
	if command -v git >/dev/null 2>&1; then
		if ! GIT_OUT="$(git -C "${KERNEL_DIR}" apply --reverse --check -- "${PATCH_FILE}" 2>&1)"; then
			echo "git apply reverse check failed for ${patch}:" >&2
			echo "${GIT_OUT}" >&2
			FAILED=1
		fi
	fi
	CHECKPATCH="${KERNEL_DIR}/scripts/checkpatch.pl"
	if [ -f "${CHECKPATCH}" ] && command -v perl >/dev/null 2>&1; then
		# stdin (- < file) avoids git_is_single_file file-mode: a tracked
		# patch passed as argv would diff -u /dev/null and flag patch
		# formatting as errors. --ignore FILE_PATH_CHANGES scoped to 0003/0005
		# (0003 adds kernel/sched/std.c/std.h and 0005 adds sched-std.rst by design; MAINTAINERS update N/A).
		CHECKPATCH_IGNORE=""
		case "${patch}" in
			0003-*|0005-*) CHECKPATCH_IGNORE="--ignore FILE_PATH_CHANGES" ;;
		esac
		# shellcheck disable=SC2086 # CHECKPATCH_IGNORE is empty or one allowlisted flag.
		if ! perl "${CHECKPATCH}" --strict --no-tree ${CHECKPATCH_IGNORE} - < "${PATCH_FILE}" >/dev/null 2>&1; then
			echo "checkpatch --strict failed for ${patch}" >&2
			# shellcheck disable=SC2086 # See above.
			perl "${CHECKPATCH}" --strict --no-tree ${CHECKPATCH_IGNORE} - < "${PATCH_FILE}" 2>&1 | head -n 20 >&2 || true
			FAILED=1
		fi
	fi
done < "${MAP_FILE}"

if [ "${FAILED}" -ne 0 ]; then
	echo "Preflight found issues. Nothing was reverted." >&2
	exit 1
fi

# --dry-run wins over revert, removal and listing.
if [ "${DRY_RUN}" -eq 1 ]; then
	echo "Reverse dry-run OK. No changes made."
	exit 0
fi

# Two-key guard: --prune-boot requires --yes.
if [ "${PRUNE_BOOT}" -eq 1 ] && [ "${ASSUME_YES}" -ne 1 ]; then
	echo "--prune-boot requires --yes for boot listing." >&2
	exit 1
fi

if [ "${ASSUME_YES}" -ne 1 ]; then
	printf "Revert STD patches from %s? [y/N] " "${KERNEL_DIR}"
	if ! read -r ans; then
		echo "Aborted (no input)." >&2
		exit 1
	fi
	case "${ans}" in
		y|Y|yes|YES)
			;;
		*)
			echo "Aborted."
			exit 1
			;;
	esac
fi

FAILED=0
while IFS= read -r patch; do
	[ -z "${patch}" ] && continue
	case "${patch}" in
		*"/"*|*".."*|-*)
			echo "Unsafe series entry: ${patch}" >&2
			FAILED=1
			continue
			;;
	esac
	echo "Reverting ${patch}..."
	if ! patch -p1 -R -N -F 0 --batch -d "${KERNEL_DIR}" < "${PATCH_DIR}/${patch}"; then
		echo "Revert failed for ${patch}" >&2
		FAILED=1
	fi
done < "${MAP_FILE}"

if [ "${FAILED}" -ne 0 ]; then
	echo "STD uninstall failed for one or more patches." >&2
	exit 1
fi

# Scoped removal: only STD-added sources, stale build objects and patch artifacts.
# Never removes the whole tree.
for f in "${KERNEL_DIR}/kernel/sched/std.c" "${KERNEL_DIR}/kernel/sched/std.h"; do
	if [ -f "${f}" ]; then
		echo "Removing scoped file ${f}..."
		rm -f -- "${f}"
	fi
done
for f in "${KERNEL_DIR}/kernel/sched/std.o" "${KERNEL_DIR}/kernel/sched/.std.o.cmd"; do
	if [ -f "${f}" ]; then
		echo "Removing stale object ${f}..."
		rm -f -- "${f}"
	fi
done
if [ -d "${KERNEL_DIR}/kernel/sched" ]; then
	find -- "${KERNEL_DIR}/kernel/sched" -maxdepth 1 -type f \( -name '*.orig' -o -name '*.rej' \) -delete 2>/dev/null || true
fi
find -- "${KERNEL_DIR}" -maxdepth 4 -type f \( -name '*.orig' -o -name '*.rej' \) -delete 2>/dev/null || true

# Optional allowlisted boot-artifact removal (refuses running kernel).
if [ "${REMOVE_MODE}" -eq 1 ]; then
	REMOVE_VER="$(make -C "${KERNEL_DIR}" -s kernelrelease 2>/dev/null || echo "unknown")"
	probe_privilege
	if ! do_remove "${REMOVE_VER}"; then
		exit 1
	fi
fi

# Check Limine entry by parsing boot config (direct + sudo -n) with BLS fallback.
# /boot is typically root-only, so try direct read first (supports mocked
# BOOT_DIR), then sudo -n fallback. BLS entries under loader/entries come from
# kernel-install and do not boot Limine by themselves.
# When --remove was used, remove_limine_entry already attempted automated
# cleanup with backup; any remainder needs manual restore from that backup.
# 4-candidate parity with install.sh. STD+ver parity: an entry counts only
# when BOTH "STD" and the exact ver share the SAME line (`:STD <ver>` via
# piped grep; file-level co-occurrence alone does NOT satisfy; BLS never satisfies Limine).
FINAL_KREL="$(make -C "${KERNEL_DIR}" -s kernelrelease 2>/dev/null || echo "unknown")"
case "${FINAL_KREL}" in
	""|"unknown") FINAL_KREL_SAFE=0 ;;
	*)
		if is_safe_ver "${FINAL_KREL}"; then
			FINAL_KREL_SAFE=1
		else
			FINAL_KREL_SAFE=0
		fi
		;;
esac
limine_checked=0
for LIMINE_CONF in "${BOOT_DIR}/limine.conf" "${BOOT_DIR}/limine/limine.conf" "${BOOT_DIR}/EFI/BOOT/limine.conf" "${BOOT_DIR}/boot/limine.conf"; do
	limine_readable=0
	if [ -f "${LIMINE_CONF}" ]; then
		limine_readable=1
	elif [ "${HAVE_SUDO:-0}" -eq 1 ] && sudo -n test -f "${LIMINE_CONF}" 2>/dev/null; then
		limine_readable=1
	fi
	if [ "${limine_readable}" -eq 1 ]; then
		limine_checked=1
		echo "Checking Limine entry in ${LIMINE_CONF} (STD+ver)..."
		if [ "${FINAL_KREL_SAFE}" -eq 1 ] && has_std_ver "${LIMINE_CONF}" "${FINAL_KREL}"; then
			if [ "${REMOVE_MODE}" -eq 1 ]; then
				echo "WARNING: STD+ver entry (${FINAL_KREL}) still present in ${LIMINE_CONF} after automated removal; restore from *.std-backup-* or remove STD block manually." >&2
			else
				echo "STD+ver entry (${FINAL_KREL}) still present in ${LIMINE_CONF} (rerun with --remove --yes to clean with backup)."
			fi
		elif [ "${FINAL_KREL_SAFE}" -eq 1 ]; then
			echo "No STD+ver entry (${FINAL_KREL}) in ${LIMINE_CONF}."
		elif grep -F -q -- "STD" "${LIMINE_CONF}" 2>/dev/null || { [ "${HAVE_SUDO:-0}" -eq 1 ] && sudo -n grep -F -q -- "STD" "${LIMINE_CONF}" 2>/dev/null; }; then
			if [ "${REMOVE_MODE}" -eq 1 ]; then
				echo "WARNING: STD entry still present in ${LIMINE_CONF} after automated removal; restore from *.std-backup-* or remove STD block manually." >&2
			else
				echo "STD entry still present in ${LIMINE_CONF} (rerun with --remove --yes to clean with backup)."
			fi
		else
			echo "No STD entry in ${LIMINE_CONF}."
		fi
	fi
done
if [ "${limine_checked}" -eq 0 ]; then
	echo "Cannot read limine.conf under ${BOOT_DIR} (4 candidates checked, direct + sudo -n failed), skipping Limine check (need root to inspect ${BOOT_DIR})." >&2
fi
BLS_DIR="${BOOT_DIR}/loader/entries"
bls_readable=0
if [ -d "${BLS_DIR}" ]; then
	bls_readable=1
elif [ "${HAVE_SUDO:-0}" -eq 1 ] && sudo -n test -d "${BLS_DIR}" 2>/dev/null; then
	bls_readable=1
fi
if [ "${bls_readable}" -eq 1 ]; then
	# STD+ver parity: BLS counts only when BOTH STD and the exact ver are found.
	bls_has_std=1
	bls_has_ver=1
	if grep -F -q -r -- "STD" "${BLS_DIR}" 2>/dev/null || { [ "${HAVE_SUDO:-0}" -eq 1 ] && sudo -n grep -F -q -r -- "STD" "${BLS_DIR}" 2>/dev/null; }; then
		bls_has_std=0
	fi
	if [ "${FINAL_KREL_SAFE:-0}" -eq 1 ]; then
		if grep -F -q -r -- "${FINAL_KREL}" "${BLS_DIR}" 2>/dev/null || { [ "${HAVE_SUDO:-0}" -eq 1 ] && sudo -n grep -F -q -r -- "${FINAL_KREL}" "${BLS_DIR}" 2>/dev/null; }; then
			bls_has_ver=0
		fi
		if [ "${bls_has_std}" -eq 0 ] && [ "${bls_has_ver}" -eq 0 ]; then
			if [ "${REMOVE_MODE}" -eq 1 ]; then
				echo "WARNING: STD+ver string (${FINAL_KREL}) still present in ${BLS_DIR} after automated removal; remove stale BLS entries manually if needed." >&2
			else
				echo "Note: STD+ver string (${FINAL_KREL}) still present in ${BLS_DIR} (rerun with --remove --yes to clean)."
			fi
		else
			echo "No STD+ver BLS entry (${FINAL_KREL}) in ${BLS_DIR}."
		fi
	elif grep -F -q -r -- "STD" "${BLS_DIR}" 2>/dev/null || { [ "${HAVE_SUDO:-0}" -eq 1 ] && sudo -n grep -F -q -r -- "STD" "${BLS_DIR}" 2>/dev/null; }; then
		if [ "${REMOVE_MODE}" -eq 1 ]; then
			echo "WARNING: STD string still present in ${BLS_DIR} after automated removal; remove stale BLS entries manually if needed." >&2
		else
			echo "Note: STD string still present in ${BLS_DIR} (rerun with --remove --yes to clean)."
		fi
	else
		echo "No STD BLS entry in ${BLS_DIR}."
	fi
else
	echo "No BLS dir ${BLS_DIR} readable (direct + sudo -n failed), skipping BLS check."
fi

# Optional boot listing, gated by two keys and never in dry-run.
if [ "${PRUNE_BOOT}" -eq 1 ]; then
	echo "Listing boot entries in ${BOOT_DIR} (list only, no deletion)..."
	if [ -d "${BOOT_DIR}" ]; then
		if ! sudo -n ls -- "${BOOT_DIR}" >/dev/null 2>&1; then
			echo "Cannot list ${BOOT_DIR} with sudo -n, skipping check." >&2
		else
			echo "Boot entries in ${BOOT_DIR}:"
			sudo -n ls -1 -- "${BOOT_DIR}" 2>/dev/null || true
			echo "List complete (scoped, keeps current entry)."
		fi
	else
		echo "Boot dir ${BOOT_DIR} not found, skipping check."
	fi
fi

echo "STD uninstall complete."
echo "Log: ${LOG_FILE}"
