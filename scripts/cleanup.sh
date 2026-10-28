#!/bin/bash
# STD cleanup for patch artifacts.
# Removes .orig and .rej leftovers from patch operations.
# Supports --dry-run to list only and --yes for noninteractive use.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_TREE="${WORKSPACE_ROOT}/linux-fresh-7.3"

DRY_RUN=0
ASSUME_YES=0
STATUS_MODE=0
KERNEL_DIR=""

usage() {
	echo "Usage: $0 [--dry-run] [--yes] [--status] [KERNEL_DIR]"
	echo "  --dry-run  List artifacts only"
	echo "  --yes      Skip confirmation prompt"
	echo "  --status   Read-only status report (never deletes; same as --dry-run)"
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
if command -v realpath >/dev/null 2>&1; then
	KERNEL_DIR="$(realpath -m -- "${KERNEL_DIR}")"
else
	KERNEL_DIR="$(readlink -f -- "${KERNEL_DIR}" 2>/dev/null || printf '%s' "${KERNEL_DIR}")"
fi
case "${KERNEL_DIR}" in
	""|"/") echo "Refusing unsafe KERNEL_DIR: ${KERNEL_DIR}" >&2; exit 1 ;;
esac

if [ ! -d "${KERNEL_DIR}" ]; then
	echo "Kernel tree not found: ${KERNEL_DIR}" >&2
	exit 1
fi

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
	echo "No artifacts found."
	exit 0
fi

if [ -n "${FOUND}" ]; then
	echo "${FOUND}"
fi
if [ -n "${STALE_OBJS}" ]; then
	echo "Stale STD objects:"
	echo "${STALE_OBJS}"
fi

if [ "${DRY_RUN}" -eq 1 ] || [ "${STATUS_MODE}" -eq 1 ]; then
	if [ "${STATUS_MODE}" -eq 1 ]; then
		echo "Status (read-only, no files removed)."
	else
		echo "Dry-run: no files removed."
	fi
	exit 0
fi

if [ "${ASSUME_YES}" -ne 1 ]; then
	printf "Remove listed artifacts? [y/N] "
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
echo "Cleanup complete."
