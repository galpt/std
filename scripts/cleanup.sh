#!/bin/bash
# STD cleanup for patch artifacts.
# Removes .orig and .rej leftovers from patch operations.
# Supports --dry-run to list only and --yes for noninteractive use.
# --deep also runs `make clean` (keeps .config; never mrproper/distclean).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_TREE="${WORKSPACE_ROOT}/linux-fresh-7.3"

DRY_RUN=0
ASSUME_YES=0
STATUS_MODE=0
DEEP_MODE=0
KERNEL_DIR=""
BOOT_DIR="${BOOT_DIR:-/boot}"

usage() {
	echo "Usage: $0 [--dry-run] [--yes] [--status] [--deep] [KERNEL_DIR]"
	echo "  --dry-run  List artifacts only"
	echo "  --yes      Skip confirmation prompt"
	echo "  --status   Read-only status report (never deletes; same as --dry-run)"
	echo "  --deep     Also run 'make clean' (keeps .config; never mrproper)"
	echo "  KERNEL_DIR Target tree, default ${DEFAULT_TREE}"
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
		--status)
			STATUS_MODE=1
			shift
			;;
		--deep)
			DEEP_MODE=1
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

# Confinement: canonicalize and refuse root or empty.
# realpath -m (missing-ok) is intentional for consistency with install/uninstall;
# safety comes from the refuse-root guard, not from existence checks.
# Canonicalizes symlinks before the refuse-root check.
if command -v realpath >/dev/null 2>&1; then
	KERNEL_DIR="$(realpath -m -- "${KERNEL_DIR}")"
else
	KERNEL_DIR="$(readlink -f -- "${KERNEL_DIR}" 2>/dev/null || printf '%s' "${KERNEL_DIR}")"
fi
case "${KERNEL_DIR}" in
	""|"/") echo "Refusing unsafe KERNEL_DIR: ${KERNEL_DIR}" >&2; exit 1 ;;
esac

# --deep confinement (additive; evaluated only with --deep so the default
# prune path keeps its exact existing behavior).
# Mirrors install/uninstall BOOT_DIR idioms: refuse empty/root before and
# after canonicalization, refuse system paths, and refuse same/nested trees.
if [ "${DEEP_MODE}" -eq 1 ]; then
	case "${BOOT_DIR}" in
		""|"/"|"//") echo "Refusing unsafe BOOT_DIR: ${BOOT_DIR}" >&2; exit 1 ;;
	esac
	if command -v realpath >/dev/null 2>&1; then
		BOOT_DIR="$(realpath -m -- "${BOOT_DIR}")"
	else
		BOOT_DIR="$(readlink -f -- "${BOOT_DIR}" 2>/dev/null || printf '%s' "${BOOT_DIR}")"
	fi
	case "${BOOT_DIR}" in
		""|"/"|"//") echo "Refusing unsafe BOOT_DIR: ${BOOT_DIR}" >&2; exit 1 ;;
	esac
	case "${KERNEL_DIR}" in
		"//"|"/boot"|"/boot/"|"/efi"|"/efi/"|"/lib/modules"|"/lib/modules/"|"/usr/lib/modules"|"/usr/lib/modules/")
			echo "Refusing unsafe KERNEL_DIR for --deep: ${KERNEL_DIR}" >&2; exit 1 ;;
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
	if [ ! -f "${KERNEL_DIR}/Makefile" ]; then
		echo "Skipping source cleanup: ${KERNEL_DIR} is not a valid kernel tree." >&2
		exit 1
	fi
	# Log --deep output to a 0600 mktemp log (mktemp creates 0600 files)
	# while keeping stdout; prune-only runs stay log-free and unchanged.
	LOG_FILE="$(mktemp /tmp/std-cleanup-XXXXXX.log)"
	echo "Log: ${LOG_FILE}"
fi

if [ ! -d "${KERNEL_DIR}" ]; then
	echo "Kernel tree not found: ${KERNEL_DIR}" >&2
	exit 1
fi

# --deep source cleanup: `make clean` only (keeps .config by design).
# Prohibition: never run `mrproper` or `distclean` here; both would delete
# the just-verified .config and defeat the reclaim-after-install purpose.
# Fail-closed privilege policy: try unprivileged first; only on failure, and
# only when `sudo -n true` succeeds, retry once via `sudo -n` (never bare
# sudo). Without passwordless sudo, abort with a manual rerun hint.
do_make_clean() {
	echo "Source size before 'make clean':"
	du -sh -- "${KERNEL_DIR}" 2>&1 | tee -a "${LOG_FILE}" || true
	if [ -f "${KERNEL_DIR}/.config" ]; then
		CONFIG_SUM_BEFORE="$(sha256sum -- "${KERNEL_DIR}/.config" 2>/dev/null | awk '{print $1}')"
		echo "Preserving .config (sha256 ${CONFIG_SUM_BEFORE})."
	else
		CONFIG_SUM_BEFORE=""
		echo "No .config in ${KERNEL_DIR} (nothing to preserve)."
	fi
	if make -C "${KERNEL_DIR}" clean 2>&1 | tee -a "${LOG_FILE}"; then
		echo "make clean succeeded (unprivileged)."
	else
		echo "make clean failed (unprivileged); checking sudo -n (fail-closed)..." >&2
		if sudo -n true 2>/dev/null; then
			echo "Retrying once via sudo -n make clean..."
			if ! sudo -n make -C "${KERNEL_DIR}" clean 2>&1 | tee -a "${LOG_FILE}"; then
				echo "sudo -n make clean failed; rerun manually: make -C ${KERNEL_DIR} clean" >&2
				return 1
			fi
			echo "make clean succeeded (sudo -n)."
		else
			echo "Cannot run make clean (permission denied and no sudo -n; fail-closed). Rerun manually: make -C ${KERNEL_DIR} clean" >&2
			return 1
		fi
	fi
	if [ ! -f "${KERNEL_DIR}/Makefile" ]; then
		echo "ERROR: Makefile missing after make clean in ${KERNEL_DIR}." >&2
		return 1
	fi
	if [ -n "${CONFIG_SUM_BEFORE}" ]; then
		if [ ! -f "${KERNEL_DIR}/.config" ]; then
			echo "ERROR: .config was removed by make clean (expected to keep it)." >&2
			return 1
		fi
		CONFIG_SUM_AFTER="$(sha256sum -- "${KERNEL_DIR}/.config" 2>/dev/null | awk '{print $1}')"
		if [ "${CONFIG_SUM_AFTER}" != "${CONFIG_SUM_BEFORE}" ]; then
			echo "ERROR: .config changed during make clean (before ${CONFIG_SUM_BEFORE}, after ${CONFIG_SUM_AFTER})." >&2
			return 1
		fi
		echo ".config preserved (sha256 ${CONFIG_SUM_AFTER})." | tee -a "${LOG_FILE}"
	else
		echo "No .config to verify (tree has none)."
	fi
	echo "Source size after 'make clean':"
	du -sh -- "${KERNEL_DIR}" 2>&1 | tee -a "${LOG_FILE}" || true
}

echo "Scanning ${KERNEL_DIR} for patch artifacts..."

FOUND="$(find -- "${KERNEL_DIR}" -maxdepth 4 -type f \( -name '*.orig' -o -name '*.rej' \) 2>/dev/null || true)"
STALE_OBJS=""
for stale in "${KERNEL_DIR}/kernel/sched/std.o" "${KERNEL_DIR}/kernel/sched/.std.o.cmd"; do
	if [ -f "${stale}" ]; then
		STALE_OBJS="${STALE_OBJS}${stale}
"
	fi
done
# Trim trailing newline.
STALE_OBJS="$(printf '%s' "${STALE_OBJS}")"

if [ -z "${FOUND}" ] && [ -z "${STALE_OBJS}" ]; then
	if [ "${DEEP_MODE}" -eq 0 ]; then
		echo "No artifacts found."
		exit 0
	fi
	echo "No patch artifacts found (continuing to --deep source cleanup)..."
fi

if [ -n "${FOUND}" ]; then
	echo "${FOUND}"
fi
if [ -n "${STALE_OBJS}" ]; then
	echo "Stale STD objects:"
	echo "${STALE_OBJS}"
fi

# --deep read-only plan (additive): with --dry-run/--status, preview the
# source cleanup without mutating. The existing read-only exit below still
# applies, so --dry-run/--status never mutate.
if [ "${DEEP_MODE}" -eq 1 ] && { [ "${DRY_RUN}" -eq 1 ] || [ "${STATUS_MODE}" -eq 1 ]; }; then
	echo "Deep clean plan (read-only, no changes made):"
	echo "  would run: make -C ${KERNEL_DIR} clean (keeps .config; never mrproper)"
	echo "  source size:"
	du -sh -- "${KERNEL_DIR}" 2>/dev/null || true
	if [ -f "${KERNEL_DIR}/Makefile" ]; then
		echo "  Makefile: present (${KERNEL_DIR}/Makefile)"
	else
		echo "  Makefile: absent (unexpected; guarded before mutation)"
	fi
	if [ -f "${KERNEL_DIR}/.config" ]; then
		echo "  .config: present (would be kept)"
	else
		echo "  .config: absent (nothing to preserve)"
	fi
	if command -v make >/dev/null 2>&1; then
		echo "  make -n clean preview (read-only):"
		make -C "${KERNEL_DIR}" -n clean 2>/dev/null || true
	fi
fi

if [ "${DRY_RUN}" -eq 1 ] || [ "${STATUS_MODE}" -eq 1 ]; then
	if [ "${STATUS_MODE}" -eq 1 ]; then
		echo "Status (read-only, no files removed)."
	else
		echo "Dry-run: no files removed."
	fi
	exit 0
fi

# Two-key guard: mutating runs need --yes or an interactive yes. With --deep
# a single combined prompt covers both the prune step and `make clean`.
if [ "${ASSUME_YES}" -ne 1 ]; then
	if [ "${DEEP_MODE}" -eq 1 ]; then
		if [ -z "${FOUND}" ] && [ -z "${STALE_OBJS}" ]; then
			printf "No patch artifacts to prune. Run 'make clean' in %s (keeps .config)? [y/N] " "${KERNEL_DIR}"
		else
			printf "Remove listed artifacts and run 'make clean' (keeps .config)? [y/N] "
		fi
	else
		printf "Remove listed artifacts? [y/N] "
	fi
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

if [ -n "${FOUND}" ]; then
	find -- "${KERNEL_DIR}" -maxdepth 4 -type f \( -name '*.orig' -o -name '*.rej' \) -delete
fi
if [ -n "${STALE_OBJS}" ]; then
	while IFS= read -r stale; do
		[ -z "${stale}" ] && continue
		case "${stale}" in
			"${KERNEL_DIR}"/kernel/sched/std.o|"${KERNEL_DIR}"/kernel/sched/.std.o.cmd)
				rm -f -- "${stale}"
				echo "Removed ${stale}"
				;;
			*)
				echo "Skipping unexpected path ${stale}" >&2
				;;
		esac
	done <<EOF
${STALE_OBJS}
EOF
fi
# Step 1 (--deep only): guarded `make clean` (keeps .config; never mrproper).
if [ "${DEEP_MODE}" -eq 1 ]; then
	if ! do_make_clean; then
		exit 1
	fi
	# Step 2 (--deep only): report-only stale hints. No automatic DKMS,
	# boot, or Limine deletion; no limine-update; never mrproper/distclean.
	echo "Stale artifact hints (report-only, nothing removed automatically):"
	echo "  dkms status  # inspect DKMS modules built for this tree"
	echo "  scripts/uninstall.sh --status ${KERNEL_DIR}  # confirm boot entries intact"
	echo "  scripts/uninstall.sh --remove --yes --prune-boot ${KERNEL_DIR}  # only when reverting the install"
	echo "No DKMS, boot, or Limine entries were touched (report-only)."
fi
echo "Cleanup complete."
