#!/bin/bash
# STD installer for vanilla-arch 7.3.
# Self-contained: clones fresh v7.3 if needed, verifies series,
# applies in order, builds, installs and checks Limine entry.
# Supports --dry-run/--status/--install-deps/--strict-nvidia/--allow-degraded-initramfs/--allow-dirty-suppress/--fresh/--reinstall-nvidia/--write-modprobe/--strict-boot-artifacts/--write-bls/--remove, --yes, --prune-boot, --boot-dir.
# Parse $BOOT_DIR/limine.conf to check boot entry.
# --prune-boot lists boot entries only, never deletes.
# Intentional STD fork (won't-fix fidelity deltas, kept by design):
# fail-closed sudo -n only (never bare sudo / EUID==0 upgrade), clone reuse
# with --fresh opt-in (never always-fresh), keep .git (never rm -rf .git),
# manual cp + sha256/b2sum boot-artifact assurance (never bare make install
# for boot), NVIDIA DKMS opt-in (never auto-rebuild), Limine 4-candidate /
# filtered-fallback format under BOOT_DIR, GRUB mkconfig refresh (never
# custom grub.cfg write), --remove allowlisted + refuses running kernel.
# All mutating paths are BOOT_DIR-scoped, allowlisted, with backup/rollback.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PATCH_DIR="${WORKSPACE_ROOT}/patches/vanilla-arch/7.3"
SERIES_FILE="${PATCH_DIR}/series"
DEFAULT_TREE="${WORKSPACE_ROOT}/linux-fresh-7.3"
KERNEL_URL="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"

DRY_RUN=0
ASSUME_YES=0
PRUNE_BOOT=0
INSTALL_DEPS=0
STATUS_MODE=0
STRICT_NVIDIA=0
ALLOW_DEGRADED_INITRAMFS=0
ALLOW_DIRTY_SUPPRESS=0
FRESH=0
REINSTALL_NVIDIA=0
WRITE_MODPROBE=0
STRICT_BOOT_ARTIFACTS=0
WRITE_BLS=0
REMOVE_MODE=0
KERNEL_DIR=""
BOOT_DIR="${BOOT_DIR:-/boot}"
LOG_FILE="$(mktemp /tmp/std-install-XXXXXX.log)"

usage() {
	echo "Usage: $0 [--dry-run] [--yes] [--prune-boot] [--boot-dir DIR] [--install-deps] [--status] [--strict-nvidia] [--allow-degraded-initramfs] [--allow-dirty-suppress] [--fresh] [--reinstall-nvidia] [--write-modprobe] [--strict-boot-artifacts] [--write-bls] [--remove] [KERNEL_DIR]"
	echo "  --dry-run   Verify via patch dry-run, git apply check and checkpatch only"
	echo "  --yes       Skip confirmation prompt"
	echo "  --prune-boot  List boot entries only (requires --yes)"
	echo "  --boot-dir DIR  Boot directory, default ${BOOT_DIR}"
	echo "  --install-deps  Install missing build deps via distro package manager, Arch-first (requires --yes; never in --dry-run/--status)"
	echo "  --status    Read-only status report (never mutates)"
	echo "  --strict-nvidia  Treat NVIDIA DKMS warnings as fatal"
	echo "  --allow-degraded-initramfs  Warn instead of failing on degraded initramfs"
	echo "  --allow-dirty-suppress  Opt-in dirty-suffix suppression: sets CONFIG_LOCALVERSION_AUTO=n + LOCALVERSION=\"\" to force 7.3.0-std on a dirty tree (default off; without it only 7.3.0-std-dirty with expected dirt verifies, other *-dirty/*+ fails)"
	echo "  --fresh     Re-clone fresh v7.3 to KERNEL_DIR (requires --yes; preview only in --dry-run/--status)"
	echo "  --reinstall-nvidia  Opt-in NVIDIA DKMS rebuild for the target kernel (default: skip rebuild with hint; never in --dry-run/--status)"
	echo "  --write-modprobe  Opt-in write of /etc/modprobe.d/std-nvidia.conf from inherited modeset opts (requires --yes; never in --dry-run/--status)"
	echo "  --strict-boot-artifacts  Treat boot-artifact copy/checksum failures as fatal (default: warn-only)"
	echo "  --write-bls  Opt-in write of BLS entry under loader/entries (requires --yes; never in --dry-run/--status)"
	echo "  --remove    Delete installed boot artifacts for the target release via uninstall.sh shim (allowlisted; refuses running kernel; requires --yes; preview only in --dry-run/--status)"
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
		--install-deps)
			INSTALL_DEPS=1
			shift
			;;
		--status)
			STATUS_MODE=1
			shift
			;;
		--strict-nvidia)
			STRICT_NVIDIA=1
			shift
			;;
		--allow-degraded-initramfs)
			ALLOW_DEGRADED_INITRAMFS=1
			shift
			;;
		--allow-dirty-suppress)
			ALLOW_DIRTY_SUPPRESS=1
			shift
			;;
		--fresh)
			FRESH=1
			shift
			;;
		--reinstall-nvidia)
			REINSTALL_NVIDIA=1
			shift
			;;
		--write-modprobe)
			WRITE_MODPROBE=1
			shift
			;;
		--strict-boot-artifacts)
			STRICT_BOOT_ARTIFACTS=1
			shift
			;;
		--write-bls)
			WRITE_BLS=1
			shift
			;;
		--remove)
			REMOVE_MODE=1
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
if command -v realpath >/dev/null 2>&1; then
	KERNEL_DIR="$(realpath -m -- "${KERNEL_DIR}")"
	BOOT_DIR="$(realpath -m -- "${BOOT_DIR}")"
else
	KERNEL_DIR="$(readlink -f -- "${KERNEL_DIR}" 2>/dev/null || printf '%s' "${KERNEL_DIR}")"
	BOOT_DIR="$(readlink -f -- "${BOOT_DIR}" 2>/dev/null || printf '%s' "${BOOT_DIR}")"
fi
case "${KERNEL_DIR}" in
	""|"/") echo "Refusing unsafe KERNEL_DIR: ${KERNEL_DIR}" >&2; exit 1 ;;
esac
case "${BOOT_DIR}" in
	""|"/") echo "Refusing unsafe BOOT_DIR: ${BOOT_DIR}" >&2; exit 1 ;;
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

# Clean naming contract: default preserves CONFIG_LOCALVERSION_AUTO=y so
# expected STD dirt yields 7.3.0-std-dirty and verifies OK, while extra/
# unknown dirt and *+ suffixes fail verification (fail-closed).
# Opt-in --allow-dirty-suppress exports LOCALVERSION="" (empty, not unset)
# so scripts/setlocalversion suppresses the suffix once AUTO=n is pinned.
# Must precede any `make -s kernelrelease`. Never auto-boots; sudo stays -n.
if [ "${ALLOW_DIRTY_SUPPRESS}" -eq 1 ]; then
	export LOCALVERSION=""
	echo "Dirty suppression: ON (--allow-dirty-suppress; LOCALVERSION=\"\" + AUTO=n)."
else
	unset LOCALVERSION || true
fi

# Allowlisted release/token check: ^[A-Za-z0-9._][A-Za-z0-9._+-]*$ (no slash, no glob, no empty, no leading dash).
is_safe_ver() {
	printf '%s' "${1:-}" | grep -Eq '^[A-Za-z0-9._][A-Za-z0-9._+-]*$'
}

# Log all output to /tmp/std-install-*.log while keeping stdout.
# mktemp creates 0600 files; prune only via `rm -f /tmp/std-*` (files only,
# never rm -rf /tmp). No preflight artifact is world-readable by design.
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "Log: ${LOG_FILE}"
echo "Target: ${KERNEL_DIR}"
echo "Patches: ${PATCH_DIR}"
echo "Boot: ${BOOT_DIR}"

# ---- Slice 1: privilege probe, dependency check, NVIDIA detection ----
# All helpers are read-only unless explicitly installing with sudo -n.
# sudo stays fail-closed: only `sudo -n` is ever used, never bare sudo.
# PATH: privileged exec resolves via sudo secure_path; never export PATH.
HAVE_SUDO=0
HAVE_NVIDIA_HW=0
NVIDIA_MOD_LOADED=0

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

# Detect build deps: bc/flex/bison/python3/libelf/openssl/pahole.
# Multi-distro package map, Arch-first (pacman, apt-get, dnf, zypper).
# Warns by default. Installs via `sudo -n` only when
# --install-deps --yes are both given, and never in --dry-run/--status.
check_deps() {
	missing_cmds=""
	missing_pkgs=""
	if ! command -v bc >/dev/null 2>&1; then
		missing_cmds="${missing_cmds}bc "
		missing_pkgs="${missing_pkgs}bc "
	fi
	if ! command -v flex >/dev/null 2>&1; then
		missing_cmds="${missing_cmds}flex "
		missing_pkgs="${missing_pkgs}flex "
	fi
	if ! command -v bison >/dev/null 2>&1; then
		missing_cmds="${missing_cmds}bison "
		missing_pkgs="${missing_pkgs}bison "
	fi
	if ! command -v python3 >/dev/null 2>&1; then
		missing_cmds="${missing_cmds}python3 "
		missing_pkgs="${missing_pkgs}python "
	fi
	if ! command -v openssl >/dev/null 2>&1; then
		missing_cmds="${missing_cmds}openssl "
		missing_pkgs="${missing_pkgs}openssl "
	fi
	if ! command -v pahole >/dev/null 2>&1; then
		missing_cmds="${missing_cmds}pahole "
		missing_pkgs="${missing_pkgs}pahole "
	fi
	# libelf: header, runtime, or pacman record all count as present.
	if [ ! -f "/usr/include/libelf.h" ] && [ ! -f "/usr/include/libelf/libelf.h" ]; then
		if command -v pacman >/dev/null 2>&1; then
			if ! pacman -Q libelf >/dev/null 2>&1; then
				missing_cmds="${missing_cmds}libelf "
				missing_pkgs="${missing_pkgs}libelf "
			fi
		elif ! ldconfig -p 2>/dev/null | grep -q "libelf"; then
			missing_cmds="${missing_cmds}libelf "
			missing_pkgs="${missing_pkgs}libelf "
		fi
	fi
	if [ -z "${missing_cmds}" ]; then
		echo "Dependencies OK (bc/flex/bison/python3/libelf/openssl/pahole present)."
		return 0
	fi
	echo "WARNING: missing build dependencies: ${missing_cmds}" >&2
	if [ "${DRY_RUN}" -eq 1 ] || [ "${STATUS_MODE}" -eq 1 ]; then
		echo "Read-only mode (--dry-run/--status): not installing (no mutation)." >&2
		return 0
	fi
	if [ "${INSTALL_DEPS}" -eq 1 ]; then
		if [ "${ASSUME_YES}" -ne 1 ]; then
			echo "--install-deps requires --yes (two-key guard)." >&2
			return 1
		fi
		if [ "${HAVE_SUDO}" -ne 1 ]; then
			echo "Cannot install deps without sudo -n; install manually (Arch-first): sudo -n pacman -S --needed ${missing_pkgs}" >&2
			return 0
		fi
		# Arch-first distro map: translate the Arch pkg list per manager.
		# Unquoted ${missing_pkgs}/${distro_pkgs} below is intentional word-splitting
		# (one arg per package); each token is Arch allowlisted, never a path.
		if command -v pacman >/dev/null 2>&1; then
			echo "Installing missing deps via sudo -n pacman -S --needed: ${missing_pkgs}"
			# shellcheck disable=SC2086
			if ! sudo -n pacman -S --needed --noconfirm ${missing_pkgs}; then
				echo "Dependency install failed (sudo -n pacman -S)." >&2
				return 1
			fi
			return 0
		fi
		distro_pkgs=""
		for tok in ${missing_pkgs}; do
			case "${tok}" in
				python) distro_tok="python3" ;;
				pahole) distro_tok="dwarves" ;;
				libelf) distro_tok="libelf-dev" ;;
				*) distro_tok="${tok}" ;;
			esac
			# Fedora/RHEL + openSUSE use different libelf/dwarves names; fix up below.
			distro_pkgs="${distro_pkgs}${distro_tok} "
		done
		if command -v apt-get >/dev/null 2>&1; then
			echo "Installing missing deps via sudo -n apt-get install: ${distro_pkgs}(Arch: ${missing_pkgs})"
			if ! sudo -n apt-get update 2>&1 | tee -a "${LOG_FILE}"; then
				echo "WARNING: apt-get update failed (continuing to install attempt)." >&2
			fi
			# shellcheck disable=SC2086
			if ! sudo -n apt-get install -y ${distro_pkgs} 2>&1 | tee -a "${LOG_FILE}"; then
				echo "Dependency install failed (sudo -n apt-get install)." >&2
				return 1
			fi
			return 0
		fi
		if command -v dnf >/dev/null 2>&1; then
			dnf_pkgs="$(printf '%s' "${distro_pkgs}" | sed 's/libelf-dev/elfutils-libelf-devel/g')"
			echo "Installing missing deps via sudo -n dnf install: ${dnf_pkgs}(Arch: ${missing_pkgs})"
			# shellcheck disable=SC2086
			if ! sudo -n dnf install -y ${dnf_pkgs} 2>&1 | tee -a "${LOG_FILE}"; then
				echo "Dependency install failed (sudo -n dnf install)." >&2
				return 1
			fi
			return 0
		fi
		if command -v zypper >/dev/null 2>&1; then
			zypper_pkgs="$(printf '%s' "${distro_pkgs}" | sed 's/libelf-dev/libelf-devel/g')"
			echo "Installing missing deps via sudo -n zypper install: ${zypper_pkgs}(Arch: ${missing_pkgs})"
			# shellcheck disable=SC2086
			if ! sudo -n zypper install -y ${zypper_pkgs} 2>&1 | tee -a "${LOG_FILE}"; then
				echo "Dependency install failed (sudo -n zypper install)." >&2
				return 1
			fi
			return 0
		fi
		echo "No supported package manager found (pacman/apt-get/dnf/zypper); install manually: ${missing_pkgs} (Debian: ${distro_pkgs})" >&2
		return 0
	fi
	echo "Continuing without them; rerun with --yes --install-deps to auto-install (Arch-first: pacman, apt-get, dnf, zypper), or: sudo -n pacman -S --needed ${missing_pkgs}" >&2
	return 0
}

# Detect NVIDIA hardware (PCI 10de) and loaded nvidia module.
detect_nvidia() {
	HAVE_NVIDIA_HW=0
	NVIDIA_MOD_LOADED=0
	if command -v lspci >/dev/null 2>&1; then
		if lspci -n 2>/dev/null | grep -q -i "10de" || lspci 2>/dev/null | grep -q -i "nvidia"; then
			HAVE_NVIDIA_HW=1
		fi
	else
		echo "Note: lspci not found; skipping PCI NVIDIA probe."
	fi
	if command -v lsmod >/dev/null 2>&1; then
		if lsmod 2>/dev/null | grep -q "^nvidia"; then
			NVIDIA_MOD_LOADED=1
		fi
	else
		echo "Note: lsmod not found; skipping nvidia module probe."
	fi
	echo "NVIDIA hardware: ${HAVE_NVIDIA_HW} (1=PCI 10de present), module loaded: ${NVIDIA_MOD_LOADED}."
}

# DKMS completion/discovery hint (read-only; never mutates).
# Suggests `dkms status` plus shell completion via `compgen`.
dkms_hint() {
	echo "Hint: list DKMS modules with 'dkms status'; shell completion via 'compgen -W \"\$(dkms status 2>/dev/null)\"' or 'compgen -c dkms'." >&2
	if command -v compgen >/dev/null 2>&1 || bash -c 'compgen -c dkms' >/dev/null 2>&1; then
		compgen_list="$(bash -c 'compgen -c dkms' 2>/dev/null | sort -u | head -n 5 || true)"
		if [ -n "${compgen_list}" ]; then
			echo "compgen dkms commands (preview):" >&2
			echo "${compgen_list}" >&2
		fi
	fi
	if command -v dkms >/dev/null 2>&1; then
		echo "dkms status (preview):" >&2
		dkms status 2>/dev/null | head -n 10 >&2 || true
	fi
}

# Check NVIDIA DKMS source availability (read-only).
check_nvidia_src() {
	src_state="absent"
	if ls -d /var/lib/dkms/nvidia* >/dev/null 2>&1; then
		src_state="present (/var/lib/dkms/nvidia*)"
	fi
	pkg_state="none"
	if command -v pacman >/dev/null 2>&1; then
		if pacman -Q nvidia-open-dkms >/dev/null 2>&1; then
			pkg_state="nvidia-open-dkms"
		elif pacman -Q nvidia-dkms >/dev/null 2>&1; then
			pkg_state="nvidia-dkms"
		fi
	else
		pkg_state="unknown (no pacman)"
	fi
	dkms_state="unknown"
	if command -v dkms >/dev/null 2>&1; then
		dkms_state="$(dkms status 2>/dev/null | grep -i "nvidia" || echo "no nvidia entries")"
	fi
	echo "NVIDIA DKMS src: ${src_state}; pkg: ${pkg_state}; dkms: ${dkms_state}"
	if [ "${REINSTALL_NVIDIA:-0}" -eq 1 ]; then
		echo "  reinstall-nvidia: ON (DKMS rebuild opt-in for target kernel)"
	else
		echo "  reinstall-nvidia: off (DKMS rebuild skipped unless --reinstall-nvidia; rerun with the flag to rebuild)"
	fi
	if [ "${HAVE_NVIDIA_HW}" -eq 1 ] || [ "${NVIDIA_MOD_LOADED}" -eq 1 ]; then
		case "${src_state}/${pkg_state}" in
			"absent/none"|"absent/unknown"*)
				if [ "${STRICT_NVIDIA}" -eq 1 ]; then
					echo "ERROR: NVIDIA present but no DKMS source found (--strict-nvidia)." >&2
					dkms_hint
					return 1
				fi
				echo "WARNING: NVIDIA present but no DKMS source found; DKMS rebuild will be skipped (fatal only with --strict-nvidia)." >&2
				dkms_hint
				;;
		esac
	fi
	# Consumed here; DKMS hard-fail policy itself lives in Slice 2.
	: "${ALLOW_DEGRADED_INITRAMFS:=0}"
}

# Read-only boot/kernel status (never mutates; sudo -n reads only).
report_status() {
	krel="unknown"
	if [ -f "${KERNEL_DIR}/Makefile" ]; then
		krel="$(make -C "${KERNEL_DIR}" -s kernelrelease 2>/dev/null || echo "unknown")"
	fi
	echo "Status (read-only, no changes made):"
	echo "  target: ${KERNEL_DIR}"
	echo "  boot: ${BOOT_DIR}"
	echo "  kernelrelease: ${krel}"
	echo "  running: $(uname -r 2>/dev/null || echo unknown)"
	# Clean naming contract (read-only preview; never mutates .config).
	if [ -f "${KERNEL_DIR}/.config" ]; then
		pin_val="$(grep -E '^CONFIG_LOCALVERSION=' "${KERNEL_DIR}/.config" 2>/dev/null || echo "unset")"
		if grep -q '^CONFIG_LOCALVERSION_AUTO=y' "${KERNEL_DIR}/.config" 2>/dev/null; then
			auto_state="y (preserved)"
		elif grep -q '^# CONFIG_LOCALVERSION_AUTO is not set' "${KERNEL_DIR}/.config" 2>/dev/null; then
			auto_state="n (suppressed)"
		else
			auto_state="unknown"
		fi
		echo "  localversion: ${pin_val}; AUTO=${auto_state}"
	else
		echo "  localversion: no .config (defconfig will pin -std)"
	fi
	if [ "${ALLOW_DIRTY_SUPPRESS}" -eq 1 ]; then
		echo "  dirty-suppress: ON (LOCALVERSION=\"\" + AUTO=n forces 7.3.0-std on dirty tree)"
	else
		echo "  dirty-suppress: off (expected STD dirt verifies as 7.3.0-std-dirty; extra/unknown dirt and *+ suffixes fail install verification)"
	fi
	case "${krel}" in
		7.3.0-std-dirty)
			if [ "${ALLOW_DIRTY_SUPPRESS}" -eq 1 ]; then
				echo "  naming: ${krel} carries a dirty suffix even with suppression preview; install would fail unless suppression pins AUTO=n." >&2
			else
				echo "  naming: ${krel} accepted when dirt is expected STD only (membership allowlist up to 5M+2U, any subset); extra/unknown dirt or *+ still fails (see dirt line below)."
			fi
			;;
		*-dirty|*+)
			if [ "${ALLOW_DIRTY_SUPPRESS}" -eq 1 ]; then
				echo "  naming: ${krel} carries a dirty suffix even with suppression preview; install would fail unless suppression pins AUTO=n." >&2
			else
				echo "  naming: ${krel} carries a dirty/plus suffix; install verification fails (only 7.3.0-std-dirty with expected dirt verifies; prune via uninstall --remove)." >&2
			fi
			;;
		7.3.0-std)
			echo "  naming: clean contract OK (7.3.0-std)."
			;;
		*)
			echo "  naming: ${krel} (expected 7.3.0-std on a clean v7.3 tree with -std pin, or 7.3.0-std-dirty with expected STD dirt)."
			;;
	esac
	# Expected-dirt allowlist (read-only; git only, never sudo, never mutates).
	classify_tree_dirt || true
	probe_privilege
	check_deps || true
	detect_nvidia
	check_nvidia_src || true
	# Boot artifacts: direct read first (supports mocked BOOT_DIR),
	# sudo -n fallback for root-only /boot. No mutation.
	for cand in "${BOOT_DIR}/vmlinuz-${krel}" "${BOOT_DIR}/System.map-${krel}" "${BOOT_DIR}/initramfs-${krel}.img"; do
		if [ -f "${cand}" ]; then
			echo "  present: ${cand}"
		elif [ "${HAVE_SUDO}" -eq 1 ] && sudo -n test -f "${cand}" 2>/dev/null; then
			echo "  present (root-only): ${cand}"
		else
			echo "  missing: ${cand}"
		fi
	done
	limine_found=""
	for limine_cand in "${BOOT_DIR}/limine.conf" "${BOOT_DIR}/limine/limine.conf" "${BOOT_DIR}/EFI/BOOT/limine.conf" "${BOOT_DIR}/boot/limine.conf"; do
		if [ -f "${limine_cand}" ]; then
			echo "  limine.conf: present (${limine_cand})"
			limine_found=1
			break
		elif [ "${HAVE_SUDO}" -eq 1 ] && sudo -n test -f "${limine_cand}" 2>/dev/null; then
			echo "  limine.conf: present (root-only, ${limine_cand})"
			limine_found=1
			break
		fi
	done
	if [ -z "${limine_found}" ]; then
		echo "  limine.conf: absent (4 candidates under ${BOOT_DIR} checked)"
	fi
	bls_dir="${BOOT_DIR}/loader/entries"
	if [ -d "${bls_dir}" ]; then
		echo "  BLS dir: present (${bls_dir})"
	elif [ "${HAVE_SUDO}" -eq 1 ] && sudo -n test -d "${bls_dir}" 2>/dev/null; then
		echo "  BLS dir: present (root-only)"
	else
		echo "  BLS dir: absent"
	fi
	# Read-only initramfs/size/module hints (never fail, never rebuild).
	cand="${BOOT_DIR}/initramfs-${krel}.img"
	if [ -f "${cand}" ]; then
		sz="$(stat -c %s -- "${cand}" 2>/dev/null || echo 0)"
		echo "  initramfs: ${cand} (${sz} bytes)"
		if [ "${sz}" -gt 0 ] && [ "${sz}" -lt 52428800 ]; then
			echo "  initramfs: suspiciously small (<50M) — compare against stock." >&2
		fi
	elif [ "${HAVE_SUDO}" -eq 1 ] && sudo -n test -f "${cand}" 2>/dev/null; then
		sz="$(sudo -n stat -c %s -- "${cand}" 2>/dev/null || echo 0)"
		echo "  initramfs: ${cand} (${sz} bytes, root-only)"
	else
		echo "  initramfs: missing ${cand}"
	fi
	if [ -d "/lib/modules/${krel}" ]; then
		cnt="$(find "/lib/modules/${krel}" -name '*.ko*' 2>/dev/null | wc -l | tr -d ' ')"
		echo "  modules: ${cnt} .ko files under /lib/modules/${krel}"
		if [ "${cnt}" -gt 0 ] && [ "${cnt}" -lt 1000 ]; then
			echo "  modules: count <1000 suggests degraded install." >&2
		fi
	else
		echo "  modules: /lib/modules/${krel} absent"
	fi
	inherit_modeset || true
	audit_modprobe_modeset || true
	if [ "${FRESH:-0}" -eq 1 ]; then
		echo "  fresh: would re-clone fresh v7.3 to ${KERNEL_DIR} (--fresh preview only, no changes)."
	fi
	if [ "${WRITE_MODPROBE:-0}" -eq 1 ]; then
		echo "  write-modprobe: ON preview (would write /etc/modprobe.d/std-nvidia.conf; requires --yes; no changes in status)."
	fi
	if [ "${WRITE_BLS:-0}" -eq 1 ]; then
		echo "  write-bls: ON preview (would write BLS entry under ${BOOT_DIR}/loader/entries; requires --yes; no changes in status)."
	fi
	if [ "${STRICT_BOOT_ARTIFACTS:-0}" -eq 1 ]; then
		echo "  strict-boot-artifacts: ON (boot-artifact copy/checksum failures are fatal)."
	fi
	echo "Status complete (read-only, no changes made)."
}

# ---- Slice 2: DKMS lifecycle + boot artifact assurance ----
# Warn by default; fatal only with --strict-nvidia.
nvidia_fail() {
	msg="$1"
	if [ "${STRICT_NVIDIA}" -eq 1 ]; then
		echo "ERROR: ${msg} (--strict-nvidia)." >&2
		return 1
	fi
	echo "WARNING: ${msg} (non-fatal; use --strict-nvidia to fail)." >&2
	return 0
}

# Remove stale NVIDIA DKMS state for the target kernel before install.
# Scoped to the target -k ver; never touches other kernels.
dkms_pre() {
	target_ver="$1"
	if [ -z "${target_ver}" ] || [ "${target_ver}" = "unknown" ]; then
		echo "dkms_pre: unknown target version, skipping."
		return 0
	fi
	if ! is_safe_ver "${target_ver}"; then
		echo "dkms_pre: refusing unsafe target version: ${target_ver}" >&2
		return 1
	fi
	if ! command -v dkms >/dev/null 2>&1; then
		echo "dkms_pre: dkms not found, skipping stale cleanup."
		return 0
	fi
	if [ "${HAVE_SUDO}" -ne 1 ]; then
		echo "dkms_pre: no sudo -n, skipping stale DKMS cleanup (fail-closed)." >&2
		return 0
	fi
	stale="$(dkms status 2>/dev/null | grep -F -- "${target_ver}" | grep -i "nvidia" || true)"
	if [ -z "${stale}" ]; then
		echo "dkms_pre: no stale NVIDIA entries for ${target_ver}."
		return 0
	fi
	echo "dkms_pre: stale NVIDIA entries for ${target_ver}:"
	echo "${stale}"
	# Herestring loop (no pipe subshell) so --strict-nvidia fatal propagates.
	dkms_pre_rc=0
	# shellcheck disable=SC2162
	while read -r line; do
		# Format: "<module>/<version>, <kver>, <arch>: <state>"
		[ -z "${line}" ] && continue
		modver="$(printf '%s' "${line}" | awk -F'[, :]' '{print $1}')"
		mod="$(printf '%s' "${modver}" | cut -d/ -f1)"
		ver="$(printf '%s' "${modver}" | cut -d/ -f2-)"
		if [ -z "${mod}" ] || [ -z "${ver}" ]; then
			continue
		fi
		if ! is_safe_ver "${mod}" || ! is_safe_ver "${ver}"; then
			echo "dkms_pre: refusing unsafe module/version: ${mod}/${ver}" >&2
			dkms_pre_rc=1
			continue
		fi
		echo "dkms_pre: removing stale ${mod}/${ver} for -k ${target_ver}..."
		if ! sudo -n dkms remove -m "${mod}" -v "${ver}" -k "${target_ver}" 2>&1 | tee -a "${LOG_FILE}"; then
			nvidia_fail "dkms_pre remove failed for ${mod}/${ver} -k ${target_ver}" || dkms_pre_rc=1
		fi
	done <<<"${stale}"
	return "${dkms_pre_rc}"
}

# Ensure vmlinuz + System.map exist in BOOT_DIR with sha256 (+b2sum) verification.
# Copies from the built tree via sudo -n; verifies dest checksum matches src.
# Warn-only by default; fatal with --strict-boot-artifacts.
ensure_boot_artifacts() {
	target_ver="$1"
	if [ -z "${target_ver}" ] || [ "${target_ver}" = "unknown" ]; then
		echo "ensure_boot_artifacts: unknown version, skipping." >&2
		return 0
	fi
	if ! is_safe_ver "${target_ver}"; then
		echo "ensure_boot_artifacts: refusing unsafe target version: ${target_ver}" >&2
		return 1
	fi
	if [ "${DRY_RUN}" -eq 1 ] || [ "${STATUS_MODE}" -eq 1 ]; then
		echo "ensure_boot_artifacts: read-only mode, would verify vmlinuz-${target_ver}/System.map-${target_ver} (no copy)."
		return 0
	fi
	artifact_rc=0
	artifact_note() {
		msg="$1"
		if [ "${STRICT_BOOT_ARTIFACTS:-0}" -eq 1 ]; then
			echo "ERROR: ${msg} (--strict-boot-artifacts)." >&2
			artifact_rc=1
		else
			echo "WARNING: ${msg} (non-fatal; use --strict-boot-artifacts to fail)." >&2
		fi
	}
	verify_checksums() {
		src="$1"
		dest="$2"
		label="$3"
		src_sum="$(sha256sum -- "${src}" 2>/dev/null | awk '{print $1}')"
		echo "ensure_boot_artifacts: installing ${src} -> ${dest} (sha256 ${src_sum})."
		if [ "${HAVE_SUDO}" -ne 1 ]; then
			artifact_note "no sudo -n; cannot copy ${label} (fail-closed)"
			return 0
		fi
		# vfat fallback: cp -a first; on any cp -a failure (vfat/ESP cannot
		# preserve ownership/mode: Operation not permitted, Invalid argument,
		# Function not implemented, or preserve errors) retry once with
		# cp --no-preserve=ownership,mode mentioning ownership. sha256+b2sum
		# verification is identical on both paths; strict mode still fails
		# via artifact_note.
		cp_err="$(mktemp /tmp/std-cp-XXXXXX)"
		if ! sudo -n cp -a -- "${src}" "${dest}" 2>"${cp_err}"; then
			cp_msg="$(cat -- "${cp_err}" 2>/dev/null || true)"
			echo "${cp_msg}" >&2 || true
			if printf '%s' "${cp_msg}" | grep -qi "Operation not permitted\|Invalid argument\|Function not implemented\|preserv"; then
				echo "vfat fallback: cp -a failed for ${label} (ownership/mode preserve: ${cp_msg:-unknown error}); retrying cp --no-preserve=ownership,mode..."
				if ! sudo -n cp --no-preserve=ownership,mode -- "${src}" "${dest}" 2>&1 | tee -a "${LOG_FILE}"; then
					rm -f -- "${cp_err}" 2>/dev/null || true
					artifact_note "${label} copy failed for ${target_ver} (cp -a + vfat fallback)"
					return 0
				fi
				echo "vfat fallback: copy succeeded for ${label} without ownership/mode preservation."
			else
				echo "cp -a failed for ${label} (unmatched error; retrying without ownership/mode preserve once): ${cp_msg:-unknown error}..."
				if ! sudo -n cp --no-preserve=ownership,mode -- "${src}" "${dest}" 2>&1 | tee -a "${LOG_FILE}"; then
					rm -f -- "${cp_err}" 2>/dev/null || true
					artifact_note "${label} copy failed for ${target_ver} (cp -a + no-preserve fallback)"
					return 0
				fi
				echo "fallback: copy succeeded for ${label} without ownership/mode preservation."
			fi
		fi
		rm -f -- "${cp_err}" 2>/dev/null || true
		dest_sum="$(sudo -n sha256sum -- "${dest}" 2>/dev/null | awk '{print $1}')"
		if [ -n "${src_sum}" ] && [ "${src_sum}" = "${dest_sum}" ]; then
			echo "Verified ${label}-${target_ver} sha256 ${dest_sum}."
		else
			artifact_note "${label} sha256 mismatch src=${src_sum} dest=${dest_sum}"
			return 0
		fi
		if command -v b2sum >/dev/null 2>&1; then
			src_b2="$(b2sum -- "${src}" 2>/dev/null | awk '{print $1}')"
			dest_b2="$(sudo -n b2sum -- "${dest}" 2>/dev/null | awk '{print $1}')"
			if [ -n "${src_b2}" ] && [ "${src_b2}" = "${dest_b2}" ]; then
				echo "Verified ${label}-${target_ver} b2sum ${dest_b2}."
			else
				artifact_note "${label} b2sum mismatch src=${src_b2} dest=${dest_b2}"
			fi
		else
			echo "Note: b2sum not found; sha256 verification only for ${label}-${target_ver}."
		fi
	}
	src_img=""
	for cand in "${KERNEL_DIR}/arch/x86/boot/bzImage" "${KERNEL_DIR}/arch/x86_64/boot/bzImage"; do
		if [ -f "${cand}" ]; then
			src_img="${cand}"
			break
		fi
	done
	src_map="${KERNEL_DIR}/System.map"
	if [ -z "${src_img}" ]; then
		artifact_note "no bzImage found under ${KERNEL_DIR}/arch/x86/boot; skipping vmlinuz copy"
	else
		dest_img="${BOOT_DIR}/vmlinuz-${target_ver}"
		verify_checksums "${src_img}" "${dest_img}" "vmlinuz"
	fi
	if [ ! -f "${src_map}" ]; then
		artifact_note "no System.map in ${KERNEL_DIR}; skipping copy"
	else
		dest_map="${BOOT_DIR}/System.map-${target_ver}"
		verify_checksums "${src_map}" "${dest_map}" "System.map"
	fi
	if [ "${artifact_rc}" -ne 0 ]; then
		echo "ensure_boot_artifacts: FAILED for ${target_ver} (--strict-boot-artifacts)." >&2
		return 1
	fi
}

# Rebuild NVIDIA DKMS for the new kernel, depmod, verify nvidia.ko.
# Opt-in: only rebuilds when --reinstall-nvidia is given; otherwise skips
# with a hint (warn-only). Never mutates in --dry-run/--status (preview only).
# Uses sudo -n only; compgen hint guides DKMS discovery on failure.
# Guarantee (opt-in): stale remove (dkms_pre, scoped to -k ver) already ran
# before modules_install; here autoinstall -k, explicit install -f fallback,
# depmod -a, and modinfo/find verify run in order. inherit_modeset + audit
# are kept (Slice 3/maybe_write_modprobe) and never mutated without --write-modprobe.
dkms_post() {
	target_ver="$1"
	if [ -z "${target_ver}" ] || [ "${target_ver}" = "unknown" ]; then
		echo "dkms_post: unknown version, skipping." >&2
		return 0
	fi
	if ! is_safe_ver "${target_ver}"; then
		echo "dkms_post: refusing unsafe target version: ${target_ver}" >&2
		return 1
	fi
	if [ "${DRY_RUN}" -eq 1 ] || [ "${STATUS_MODE}" -eq 1 ]; then
		echo "dkms_post: read-only mode, would rebuild NVIDIA DKMS for -k ${target_ver} with --reinstall-nvidia (no changes)."
		return 0
	fi
	if ! command -v dkms >/dev/null 2>&1; then
		if [ "${HAVE_NVIDIA_HW}" -eq 1 ] || [ "${NVIDIA_MOD_LOADED}" -eq 1 ]; then
			nvidia_fail "dkms not found; cannot rebuild NVIDIA for ${target_ver}" || return 1
			dkms_hint
		else
			echo "dkms_post: no dkms tool and no NVIDIA detected, skipping."
		fi
		return 0
	fi
	if [ "${HAVE_NVIDIA_HW}" -ne 1 ] && [ "${NVIDIA_MOD_LOADED}" -ne 1 ]; then
		echo "dkms_post: no NVIDIA hardware/module detected, skipping autoinstall."
		return 0
	fi
	if [ "${REINSTALL_NVIDIA:-0}" -ne 1 ]; then
		echo "dkms_post: NVIDIA detected but --reinstall-nvidia not given; skipping rebuild (opt-in). Rerun with --reinstall-nvidia to rebuild for -k ${target_ver}." >&2
		dkms_hint
		return 0
	fi
	if [ "${HAVE_SUDO}" -ne 1 ]; then
		nvidia_fail "dkms_post: no sudo -n, cannot rebuild NVIDIA for ${target_ver}" || return 1
		dkms_hint
		return 0
	fi
	echo "dkms_post: rebuilding NVIDIA DKMS for -k ${target_ver} (--reinstall-nvidia opt-in)..."
	echo "dkms_post: stale entries already cleaned via dkms_pre for -k ${target_ver}; running autoinstall/install -f + depmod + modinfo/find verify."
	if sudo -n dkms autoinstall -k "${target_ver}" 2>&1 | tee -a "${LOG_FILE}"; then
		echo "dkms autoinstall succeeded for ${target_ver}."
	else
		echo "dkms autoinstall reported issues for ${target_ver}; trying explicit install -f..." >&2
		# Best-effort explicit rebuild for each installed nvidia source
		# (nvidia, nvidia-open, and variants; unanchored past the prefix so
		# -open/-dkms sources are not missed).
		nvidia_mods="$(dkms status 2>/dev/null | grep -i "^nvidia" | awk -F'[/,]' '{print $1}' | sed 's/:.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' | sort -u || true)"
		nvidia_vers="$(dkms status 2>/dev/null | grep -i "^nvidia" | awk -F'[/,]' '{print $2}' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort -u || true)"
		# shellcheck disable=SC2162
		if [ -n "${nvidia_mods}" ] && [ -n "${nvidia_vers}" ]; then
			dkms_post_rc=0
			while read -r mod; do
				[ -z "${mod}" ] && continue
				while read -r ver; do
					[ -z "${ver}" ] && continue
					if ! is_safe_ver "${mod}" || ! is_safe_ver "${ver}"; then
						echo "dkms_post: refusing unsafe nvidia module/version: ${mod}/${ver}" >&2
						dkms_post_rc=1
						continue
					fi
					# Only pair versions that actually exist for this module.
					if ! dkms status 2>/dev/null | grep -F -- "${mod}/${ver}" >/dev/null 2>&1; then
						continue
					fi
					echo "dkms_post: install -m ${mod} -v ${ver} -k ${target_ver}..."
					if ! sudo -n dkms install -m "${mod}" -v "${ver}" -k "${target_ver}" -f 2>&1 | tee -a "${LOG_FILE}"; then
						nvidia_fail "dkms install failed for ${mod}/${ver} -k ${target_ver}" || dkms_post_rc=1
					fi
				done <<<"${nvidia_vers}"
			done <<<"${nvidia_mods}"
			if [ "${dkms_post_rc}" -ne 0 ]; then
				return 1
			fi
		else
			nvidia_fail "dkms autoinstall failed for ${target_ver} and no nvidia source versions found" || return 1
			dkms_hint
		fi
	fi
	if ! sudo -n depmod -a "${target_ver}" 2>&1 | tee -a "${LOG_FILE}"; then
		nvidia_fail "depmod -a ${target_ver} failed after DKMS" || return 1
		dkms_hint
	fi
	# Verify nvidia.ko via modinfo then find fallback (sudo -n, read-only).
	ko_path=""
	if sudo -n modinfo -k "${target_ver}" -F filename nvidia >/dev/null 2>&1; then
		ko_path="$(sudo -n modinfo -k "${target_ver}" -F filename nvidia 2>/dev/null || true)"
		echo "dkms_post: verified nvidia.ko via modinfo: ${ko_path}"
	else
		ko_path="$(sudo -n find -- "/lib/modules/${target_ver}" -name 'nvidia.ko*' 2>/dev/null | head -n 1 || true)"
		if [ -n "${ko_path}" ]; then
			echo "dkms_post: verified nvidia.ko via find: ${ko_path}"
		else
			nvidia_fail "nvidia.ko not found for ${target_ver} (modinfo+find)" || return 1
			dkms_hint
		fi
	fi
}

# ---- Slice 3: initramfs build, health gate, modeset, bootloader matrix ----
# Inherit NVIDIA modeset options from the running kernel cmdline so the
# new entry preserves display behavior. Hardware-keyed default when NVIDIA
# is present but /proc/cmdline carries no token. Read-only.
inherit_modeset() {
	MODESET_OPTS=""
	if [ -f "/proc/cmdline" ]; then
		# Collect known NVIDIA modeset/preserve tokens if present.
		MODESET_OPTS="$(tr ' ' '\n' < /proc/cmdline 2>/dev/null | grep -E "^(nvidia-drm\.modeset=|nvidia_drm\.modeset=|nvidia\.NVreg_PreserveVideoMemoryAllocations=|nvidia_drm\.fbdev=)" | tr '\n' ' ' || true)"
		# Trim trailing space.
		MODESET_OPTS="$(printf '%s' "${MODESET_OPTS}" | sed 's/ *$//')"
	fi
	if [ -z "${MODESET_OPTS}" ]; then
		if [ "${HAVE_NVIDIA_HW:-0}" -eq 1 ] || [ "${NVIDIA_MOD_LOADED:-0}" -eq 1 ]; then
			MODESET_OPTS="nvidia-drm.modeset=1"
			echo "No inherited modeset opts; NVIDIA detected, using hardware-keyed default: ${MODESET_OPTS}"
			return 0
		fi
	fi
	if [ -n "${MODESET_OPTS}" ]; then
		echo "Inherited modeset opts: ${MODESET_OPTS}"
	else
		echo "No NVIDIA modeset opts in /proc/cmdline to inherit."
	fi
}

# Re-validate inherited modeset opts against the allowlist (fail-closed;
# /proc/cmdline is external input; grep pre-filter is not a guarantee).
validate_modeset_opts() {
	for tok in ${MODESET_OPTS:-}; do
		case "${tok}" in
			nvidia-drm.modeset=0|nvidia-drm.modeset=1|nvidia_drm.modeset=0|nvidia_drm.modeset=1|nvidia.NVreg_PreserveVideoMemoryAllocations=0|nvidia.NVreg_PreserveVideoMemoryAllocations=1|nvidia_drm.fbdev=0|nvidia_drm.fbdev=1) ;;
			*) echo "refusing unsafe modeset token: ${tok}" >&2; return 1 ;;
		esac
	done
}

# Audit modprobe.d for NVIDIA modeset persistence (read-only; never mutates).
# Checks /etc/modprobe.d, /lib/modprobe.d, /usr/lib/modprobe.d for
# nvidia-drm modeset tokens. Direct read first, sudo -n fallback.
audit_modprobe_modeset() {
	echo "Modprobe audit (read-only): checking nvidia-drm modeset persistence..."
	found_modprobe=0
	for confdir in "/etc/modprobe.d" "/lib/modprobe.d" "/usr/lib/modprobe.d"; do
		if [ -d "${confdir}" ]; then
			entries="$(grep -r -H -- "nvidia" "${confdir}" 2>/dev/null | grep -E "modeset|NVreg_Preserve|fbdev" || true)"
			if [ -n "${entries}" ]; then
				echo "  modprobe: ${confdir}:"
				echo "${entries}" | head -n 10 | sed 's/^/    /'
				found_modprobe=1
			fi
		elif [ "${HAVE_SUDO:-0}" -eq 1 ] && sudo -n test -d "${confdir}" 2>/dev/null; then
			entries="$(sudo -n grep -r -H -- "nvidia" "${confdir}" 2>/dev/null | grep -E "modeset|NVreg_Preserve|fbdev" || true)"
			if [ -n "${entries}" ]; then
				echo "  modprobe (root-only): ${confdir}:"
				echo "${entries}" | head -n 10 | sed 's/^/    /'
				found_modprobe=1
			fi
		fi
	done
	if [ "${found_modprobe}" -eq 0 ]; then
		if [ -n "${MODESET_OPTS:-}" ]; then
			echo "  modprobe: no persisted nvidia modeset found; cmdline/inherited opts: ${MODESET_OPTS} (use --write-modprobe to persist opt-in)."
		else
			echo "  modprobe: no persisted nvidia modeset found and no inherited opts to persist."
		fi
	else
		echo "  modprobe: persisted entries found (see above); compare with inherited: ${MODESET_OPTS:-none}."
	fi
}

# Opt-in persistence of inherited modeset opts to /etc/modprobe.d/std-nvidia.conf.
# Requires --write-modprobe + --yes; preview only in --dry-run/--status.
# Allowlisted path only; sudo -n only; validates tokens before writing.
maybe_write_modprobe() {
	if [ "${WRITE_MODPROBE:-0}" -ne 1 ]; then
		return 0
	fi
	if [ -z "${MODESET_OPTS:-}" ]; then
		inherit_modeset || true
	fi
	if [ -z "${MODESET_OPTS:-}" ]; then
		echo "write-modprobe: no modeset opts to persist (no HW/inheritance); skipping."
		return 0
	fi
	if [ "${DRY_RUN}" -eq 1 ] || [ "${STATUS_MODE}" -eq 1 ]; then
		echo "Read-only mode: would write /etc/modprobe.d/std-nvidia.conf with '${MODESET_OPTS}' (no changes)."
		return 0
	fi
	if [ "${ASSUME_YES}" -ne 1 ]; then
		echo "--write-modprobe requires --yes (two-key guard)." >&2
		return 1
	fi
	# Validate every token against the allowlisted modeset pattern.
	for tok in ${MODESET_OPTS}; do
		case "${tok}" in
			nvidia-drm.modeset=0|nvidia-drm.modeset=1|nvidia_drm.modeset=0|nvidia_drm.modeset=1|nvidia.NVreg_PreserveVideoMemoryAllocations=0|nvidia.NVreg_PreserveVideoMemoryAllocations=1|nvidia_drm.fbdev=0|nvidia_drm.fbdev=1)
				;;
			*)
				echo "write-modprobe: refusing unsafe modeset token: ${tok}" >&2
				return 1
				;;
		esac
	done
	if [ "${HAVE_SUDO:-0}" -ne 1 ]; then
		echo "WARNING: no sudo -n; cannot write /etc/modprobe.d/std-nvidia.conf (fail-closed). Add manually: options nvidia-drm modeset=1" >&2
		return 0
	fi
	modprobe_conf="/etc/modprobe.d/std-nvidia.conf"
	# Derive options line: nvidia-drm.modeset style tokens map to modprobe `options`.
	opts_line=""
	for tok in ${MODESET_OPTS}; do
		case "${tok}" in
			nvidia-drm.modeset=*|nvidia_drm.modeset=*)
				val="${tok#*=}"
				opts_line="${opts_line}modeset=${val} "
				;;
			nvidia.NVreg_PreserveVideoMemoryAllocations=*)
				val="${tok#*=}"
				opts_line="${opts_line}NVreg_PreserveVideoMemoryAllocations=${val} "
				;;
			nvidia_drm.fbdev=*)
				val="${tok#*=}"
				opts_line="${opts_line}fbdev=${val} "
				;;
		esac
	done
	opts_line="$(printf '%s' "${opts_line}" | sed 's/ *$//')"
	if [ -z "${opts_line}" ]; then
		echo "write-modprobe: no mappable modprobe options in '${MODESET_OPTS}'; skipping."
		return 0
	fi
	if sudo -n test -f "${modprobe_conf}" 2>/dev/null || [ -f "${modprobe_conf}" ]; then
		backup="${modprobe_conf}.std-backup-$(date +%Y%m%d%H%M%S)"
		echo "Backing up ${modprobe_conf} -> ${backup}..."
		if ! sudo -n cp -a -- "${modprobe_conf}" "${backup}"; then
			echo "WARNING: modprobe backup failed; aborting write (fail-closed)." >&2
			return 0
		fi
	fi
	echo "Writing ${modprobe_conf} with: options nvidia-drm ${opts_line} (from '${MODESET_OPTS}')..."
	if printf '%s\n' "# Generated by STD install.sh (--write-modprobe): ${MODESET_OPTS}" "options nvidia-drm ${opts_line}" | sudo -n tee -- "${modprobe_conf}" >/dev/null 2>&1; then
		if sudo -n grep -F -q -- "${opts_line}" "${modprobe_conf}" 2>/dev/null; then
			echo "Modprobe entry verified in ${modprobe_conf}."
			return 0
		fi
		echo "WARNING: modprobe verify failed for ${modprobe_conf}." >&2
	else
		echo "WARNING: modprobe write failed for ${modprobe_conf} (fail-closed)." >&2
	fi
	return 0
}

# Read helper: direct read first (supports mocked BOOT_DIR), sudo -n fallback.
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

boot_grep() {
	pattern="$1"
	file="$2"
	if [ -f "${file}" ] && grep -F -q -- "${pattern}" "${file}" 2>/dev/null; then
		return 0
	fi
	if [ "${HAVE_SUDO}" -eq 1 ] && sudo -n grep -F -q -- "${pattern}" "${file}" 2>/dev/null; then
		return 0
	fi
	return 1
}

# Build the initramfs for the target kernel.
# Prefers `mkinitcpio -k -g`, falls back to dracut, then update-initramfs.
# Never in dry-run/status. Uses sudo -n only; mocked BOOT_DIR skips
# update-initramfs (it would touch live /boot).
build_initramfs() {
	target_ver="$1"
	if [ -z "${target_ver}" ] || [ "${target_ver}" = "unknown" ]; then
		echo "build_initramfs: unknown version, skipping." >&2
		return 0
	fi
	if ! is_safe_ver "${target_ver}"; then
		echo "build_initramfs: refusing unsafe target version: ${target_ver}" >&2
		return 1
	fi
	if [ "${DRY_RUN}" -eq 1 ] || [ "${STATUS_MODE}" -eq 1 ]; then
		echo "build_initramfs: read-only mode, would build initramfs-${target_ver}.img via mkinitcpio/dracut/update-initramfs (no changes)."
		return 0
	fi
	dest_img="${BOOT_DIR}/initramfs-${target_ver}.img"
	if [ "${HAVE_SUDO}" -ne 1 ]; then
		echo "WARNING: no sudo -n; cannot build initramfs (fail-closed). Verify manually." >&2
		return 0
	fi
	if command -v mkinitcpio >/dev/null 2>&1; then
		# Preset detection (log-only; build keeps explicit -k/-g, never -P).
		# Lists /etc/mkinitcpio.d/*.preset so a preset/-k mismatch is visible
		# before the build; dracut/update-initramfs remain fallbacks below.
		preset_list=""
		# shellcheck disable=SC2012 # ls is log-only preset preview (system-controlled
		# /etc/mkinitcpio.d/*.preset names); no parsing of ownership/mode, so find offers no benefit.
		if ls /etc/mkinitcpio.d/*.preset >/dev/null 2>&1; then
			preset_list="$(ls /etc/mkinitcpio.d/*.preset 2>/dev/null | tr '\n' ' ')"
		elif [ "${HAVE_SUDO:-0}" -eq 1 ] && sudo -n sh -c 'ls /etc/mkinitcpio.d/*.preset' >/dev/null 2>&1; then
			preset_list="$(sudo -n sh -c 'ls /etc/mkinitcpio.d/*.preset' 2>/dev/null | tr '\n' ' ')"
		fi
		if [ -n "${preset_list}" ]; then
			echo "build_initramfs: mkinitcpio presets detected: ${preset_list}(using explicit -k ${target_ver} -g ${dest_img}, not -P; preset kept for reference only)."
		else
			echo "build_initramfs: no mkinitcpio presets under /etc/mkinitcpio.d (using explicit -k ${target_ver} -g ${dest_img})."
		fi
		echo "build_initramfs: sudo -n mkinitcpio -k ${target_ver} -g ${dest_img}..."
		if sudo -n mkinitcpio -k "${target_ver}" -g "${dest_img}" 2>&1 | tee -a "${LOG_FILE}"; then
			echo "mkinitcpio succeeded for ${target_ver}."
			return 0
		fi
		echo "mkinitcpio failed for ${target_ver}; trying dracut fallback..." >&2
	fi
	if command -v dracut >/dev/null 2>&1; then
		echo "build_initramfs: sudo -n dracut --force --kver ${target_ver} ${dest_img}..."
		if sudo -n dracut --force --kver "${target_ver}" -- "${dest_img}" 2>&1 | tee -a "${LOG_FILE}"; then
			echo "dracut succeeded for ${target_ver}."
			return 0
		fi
		echo "WARNING: dracut also failed for ${target_ver}; trying update-initramfs fallback..." >&2
	fi
	if command -v update-initramfs >/dev/null 2>&1; then
		if [ "${BOOT_DIR}" != "/boot" ]; then
			echo "build_initramfs: skipping update-initramfs for mocked BOOT_DIR ${BOOT_DIR} (would touch live /boot)." >&2
			return 0
		fi
		echo "build_initramfs: sudo -n update-initramfs -c -k ${target_ver}..."
		if sudo -n update-initramfs -c -k "${target_ver}" 2>&1 | tee -a "${LOG_FILE}"; then
			echo "update-initramfs succeeded for ${target_ver}."
			# Debian layout writes /boot/initrd.img-<ver>; copy to STD dest if needed.
			debian_src="/boot/initrd.img-${target_ver}"
			if [ "${dest_img}" != "${debian_src}" ] && sudo -n test -f "${debian_src}" 2>/dev/null; then
				echo "build_initramfs: copying ${debian_src} -> ${dest_img}..."
				if sudo -n cp -a -- "${debian_src}" "${dest_img}"; then
					echo "update-initramfs artifact copied to ${dest_img}."
					return 0
				fi
				echo "WARNING: update-initramfs copy to ${dest_img} failed." >&2
				return 0
			fi
			return 0
		fi
		echo "WARNING: update-initramfs also failed for ${target_ver}." >&2
		return 0
	fi
	if ! command -v mkinitcpio >/dev/null 2>&1 && ! command -v dracut >/dev/null 2>&1 && ! command -v update-initramfs >/dev/null 2>&1; then
		echo "WARNING: neither mkinitcpio, dracut, nor update-initramfs found; cannot build initramfs." >&2
	fi
	return 0
}

# Fail-hard initramfs health gate. Splits hard vs soft log signatures:
# hard = "ERROR: module not found", "No modules were added",
# "errors were encountered during the build" (always fail-closed);
# soft = narrow "_addedmodules[]: bad array subscript" only (a generic
# "bad array subscript" without _addedmodules is ignored). A lone soft
# (no hard, no size/modules/missing degradation) is demoted to WARNING
# only when the installed initrd is present with size>=50M, module
# count>=1000, and a builder success marker (mkinitcpio/dracut/
# update-initramfs succeeded for ver) is in the log; otherwise the soft
# also fails. Fails unless --allow-degraded-initramfs. Reasons use
# distinct hard vs soft tokens.
check_initramfs_health() {
	target_ver="$1"
	if ! is_safe_ver "${target_ver}"; then
		echo "check_initramfs_health: refusing unsafe target version: ${target_ver}" >&2
		return 1
	fi
	degraded=0
	reasons=""
	hard_found=0
	soft_found=0
	if grep -F -q "ERROR: module not found" "${LOG_FILE}" 2>/dev/null; then
		hard_found=1
		degraded=1
		reasons="${reasons}hard-log[module-not-found] "
	fi
	if grep -F -q "No modules were added" "${LOG_FILE}" 2>/dev/null; then
		hard_found=1
		degraded=1
		reasons="${reasons}hard-log[no-modules] "
	fi
	if grep -F -q "errors were encountered during the build" "${LOG_FILE}" 2>/dev/null; then
		hard_found=1
		degraded=1
		reasons="${reasons}hard-log[build-errors] "
	fi
	# Narrow soft: only _addedmodules bad-array counts (ignore generic).
	if grep -E -q "_addedmodules.*bad array subscript" "${LOG_FILE}" 2>/dev/null; then
		soft_found=1
	fi
	INSTALLED_INITRD=""
	for cand in "${BOOT_DIR}/"*"/${target_ver}/initrd" "${BOOT_DIR}/initramfs-${target_ver}.img"; do
		if boot_test_file "${cand}"; then
			INSTALLED_INITRD="${cand}"
			break
		fi
	done
	INITRD_SIZE=0
	INITRD_PRESENT=0
	if [ -n "${INSTALLED_INITRD}" ]; then
		if [ -f "${INSTALLED_INITRD}" ]; then
			INITRD_SIZE="$(stat -c %s -- "${INSTALLED_INITRD}" 2>/dev/null || echo 0)"
		else
			INITRD_SIZE="$(sudo -n stat -c %s -- "${INSTALLED_INITRD}" 2>/dev/null || echo 0)"
		fi
		echo "Installed initrd: ${INSTALLED_INITRD} (${INITRD_SIZE} bytes)"
		# Fail-hard gate: 0-byte initrd is degraded (intentional fail-closed).
		# The >0 guard is kept only for informational status previews; here
		# any size <50M (including 0) flags degraded.
		case "${INITRD_SIZE}" in
			''|*[!0-9]*) INITRD_SIZE=0 ;;
		esac
		if [ "${INITRD_SIZE}" -lt 52428800 ]; then
			degraded=1
			reasons="${reasons}size<50M(${INITRD_SIZE}) "
		else
			INITRD_PRESENT=1
		fi
	else
		echo "No installed initrd found for ${target_ver} under ${BOOT_DIR}; treating as degraded (fail-closed)." >&2
		degraded=1
		reasons="${reasons}missing-initrd "
	fi
	# Module count: installed modules for the target kernel.
	mod_count=0
	if [ -d "/lib/modules/${target_ver}" ]; then
		# Count .ko files (direct) or fall back to sudo -n find.
		mod_count="$(find -- "/lib/modules/${target_ver}" -name '*.ko*' 2>/dev/null | wc -l | tr -d ' ')"
	elif [ "${HAVE_SUDO}" -eq 1 ]; then
		mod_count="$(sudo -n find -- "/lib/modules/${target_ver}" -name '*.ko*' 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
	fi
	# Normalize non-numeric.
	case "${mod_count}" in
		''|*[!0-9]*) mod_count=0 ;;
	esac
	echo "Module count for ${target_ver}: ${mod_count}"
	# Fail-hard gate: 0 modules is degraded (fail-closed). The >0 guard is
	# kept only for informational status previews; here any count <1000
	# (including 0) flags degraded.
	if [ "${mod_count}" -lt 1000 ]; then
		degraded=1
		reasons="${reasons}modules<1000(${mod_count}) "
	fi
	# Builder success marker for lone-soft demotion (explicit -k/-g,
	# dracut --force --kver, or update-initramfs -c -k for this ver).
	initramfs_success=0
	if grep -F -q "mkinitcpio succeeded for ${target_ver}." "${LOG_FILE}" 2>/dev/null; then
		initramfs_success=1
	elif grep -F -q "dracut succeeded for ${target_ver}." "${LOG_FILE}" 2>/dev/null; then
		initramfs_success=1
	elif grep -F -q "update-initramfs succeeded for ${target_ver}." "${LOG_FILE}" 2>/dev/null; then
		initramfs_success=1
	fi
	# Lone-soft demotion: no hard, soft present, otherwise healthy
	# (initrd present + size>=50M + modules>=1000 + success marker).
	if [ "${soft_found}" -eq 1 ]; then
		if [ "${hard_found}" -eq 0 ] && [ "${INITRD_PRESENT}" -eq 1 ] && [ "${mod_count}" -ge 1000 ] && [ "${initramfs_success}" -eq 1 ] && [ "${degraded}" -eq 0 ]; then
			echo "WARNING: lone soft _addedmodules bad-array demoted (initrd ${INITRD_SIZE} bytes, ${mod_count} modules, builder success for ${target_ver}); continuing." >&2
			echo "Initramfs health gate: OK (soft-demoted) for ${target_ver}."
			return 0
		fi
		degraded=1
		reasons="${reasons}soft-log[_addedmodules-bad-array] "
	fi
	if [ "${degraded}" -eq 0 ]; then
		echo "Initramfs health gate: OK for ${target_ver}."
		return 0
	fi
	cat >&2 <<EOF
Initramfs health gate FAILED for ${target_ver} (${reasons}).
Hard signatures (fail-closed): missing btrfs/overlay modules
("ERROR: module not found"), "No modules were added",
"errors were encountered during the build". Soft signature (demotable
only when lone + healthy): "_addedmodules[]: bad array subscript".
Also fail on <50M image, missing initrd, or <1000 modules.
Do NOT boot the degraded image. Rebuild manually, e.g.:
  sudo -n mkinitcpio -k ${target_ver} -g /boot/initramfs-${target_ver}.img
or rerun kernel-install for ${target_ver}, then re-check sizes before reboot.
EOF
	# Root-cause hint for the mkinitcpio bad-array signature (no auto-fix).
	# _addedmodules[]: bad array subscript means the internal _addedmodules
	# array was indexed while empty: autodetect/HOOKS found no modules for
	# -k ${target_ver} (empty /lib/modules/${target_ver}, preset/-k mismatch,
	# or missing block/filesystems HOOKS). No auto-fix is attempted; inspect
	# the preset (/etc/mkinitcpio.d/*.preset), HOOKS/MODULES, and the
	# modules_install count above, then rebuild manually and re-check sizes.
	if [ "${soft_found}" -eq 1 ]; then
		cat >&2 <<EOF
Root cause (bad array subscript): mkinitcpio indexed an empty _addedmodules[]
for -k ${target_ver} with explicit -g ${BOOT_DIR}/initramfs-${target_ver}.img.
Likely causes: preset/-k mismatch (see preset detection log above), empty
/lib/modules/${target_ver} (see modules_install verification), or HOOKS
missing block/filesystems. Check /etc/mkinitcpio.d/*.preset and HOOKS/MODULES,
rebuild manually (no auto-fix), then re-check sizes before reboot.
EOF
	fi
	if [ "${ALLOW_DEGRADED_INITRAMFS}" -eq 1 ]; then
		echo "WARNING: continuing with degraded initramfs (--allow-degraded-initramfs)." >&2
		return 0
	fi
	echo "ERROR: refusing to continue with degraded initramfs (use --allow-degraded-initramfs to override)." >&2
	return 1
}

# Limine: 4-candidate conf search under BOOT_DIR (direct + sudo -n).
# Candidates: limine.conf, limine/limine.conf, EFI/BOOT/limine.conf, boot/limine.conf.
find_limine_conf() {
	for cand in "${BOOT_DIR}/limine.conf" "${BOOT_DIR}/limine/limine.conf" "${BOOT_DIR}/EFI/BOOT/limine.conf" "${BOOT_DIR}/boot/limine.conf"; do
		if boot_test_file "${cand}"; then
			printf '%s' "${cand}"
			return 0
		fi
	done
	return 1
}

# Limine: backup conf, add-kernel + tree if tool exists, verify, rollback.
# 4-candidate search; prefers limine-entry-tool, falls back to limine-update
# and to a filtered append (STD block with ver + modeset opts), always with
# backup + rollback. Wires MODESET_OPTS into the verify step.
# Guarantee: an entry counts as present only when BOTH "STD" and the exact
# target ver are found; a BLS entry never satisfies (or skips) Limine, so the
# entry is created even when BLS exists. BOOT_DIR-scoped 4 candidates only.
update_limine() {
	target_ver="$1"
	if ! is_safe_ver "${target_ver}"; then
		echo "update_limine: refusing unsafe target version: ${target_ver}" >&2
		return 1
	fi
	if ! LIMINE_CONF="$(find_limine_conf)"; then
		echo "No limine.conf under ${BOOT_DIR} (4 candidates checked); skipping Limine matrix (need root to inspect ${BOOT_DIR} if root-only)." >&2
		return 0
	fi
	echo "Checking Limine entry in ${LIMINE_CONF} (4-candidate search under ${BOOT_DIR})..."
	echo "Limine guarantee: BLS presence never skips Limine (Limine boots from limine.conf, not loader/entries)."
	if boot_grep "STD" "${LIMINE_CONF}" && boot_grep "${target_ver}" "${LIMINE_CONF}"; then
		echo "Limine entry already present (STD + ${target_ver} verified)."
		return 0
	fi
	if [ "${DRY_RUN}" -eq 1 ] || [ "${STATUS_MODE}" -eq 1 ]; then
		echo "Read-only mode: would sync Limine entry for ${target_ver} via limine-entry-tool/limine-update/filtered fallback (no changes)."
		return 0
	fi
	if [ "${HAVE_SUDO}" -ne 1 ]; then
		if [ -n "${MODESET_OPTS:-}" ]; then
			modeset_hint="Include modeset opts in the new entry cmdline: ${MODESET_OPTS}"
		else
			modeset_hint="If NVIDIA is present, include nvidia-drm.modeset=1 in the new entry cmdline."
		fi
		cat <<EOF
WARNING: STD kernel ${target_ver} not listed in ${LIMINE_CONF} (no sudo -n; fail-closed).
kernel-install creates a BLS entry, but Limine boots from limine.conf.
Sync manually, e.g.:
  sudo -n limine-entry-tool --add-kernel std <vmlinuz-${target_ver}> <initramfs-${target_ver}>
  sudo -n limine-entry-tool --tree
  (or: sudo -n limine-update)
${modeset_hint}
See README Verify for details. Do NOT reboot without a Limine entry.
EOF
		return 0
	fi
	backup="${LIMINE_CONF}.std-backup-$(date +%Y%m%d%H%M%S)"
	echo "Backing up ${LIMINE_CONF} -> ${backup}..."
	if ! sudo -n cp -a -- "${LIMINE_CONF}" "${backup}"; then
		echo "WARNING: Limine backup failed; aborting Limine update (fail-closed)." >&2
		return 0
	fi
	if command -v b2sum >/dev/null 2>&1; then
		if [ -f "${LIMINE_CONF}" ]; then
			b2sum -- "${LIMINE_CONF}" 2>/dev/null | awk '{print "Limine conf b2sum (pre): " $1}' || true
		else
			sudo -n b2sum -- "${LIMINE_CONF}" 2>/dev/null | awk '{print "Limine conf b2sum (pre, root-only): " $1}' || true
		fi
	fi
	inherit_modeset
	if [ -n "${MODESET_OPTS:-}" ] && ! validate_modeset_opts; then
		echo "WARNING: unsafe modeset opts refused; omitting CMDLINE modeset." >&2
		MODESET_OPTS=""
	fi
	if [ -n "${MODESET_OPTS:-}" ]; then
		echo "Wiring modeset opts into Limine verify: ${MODESET_OPTS}"
	fi
	# Tool-driven path: limine-entry-tool add-kernel + tree (or limine-update).
	tool_ok=0
	if command -v limine-entry-tool >/dev/null 2>&1; then
		echo "Updating Limine: add-kernel std + tree..."
		if sudo -n limine-entry-tool --add-kernel std "${BOOT_DIR}/vmlinuz-${target_ver}" "${BOOT_DIR}/initramfs-${target_ver}.img" 2>&1 | tee -a "${LOG_FILE}"; then
			if [ "${BOOT_DIR}" = "/boot" ]; then
				if sudo -n limine-entry-tool --tree 2>&1 | tee -a "${LOG_FILE}"; then
					:
				else
					echo "WARNING: limine-entry-tool --tree failed; trying limine-update..." >&2
					if command -v limine-update >/dev/null 2>&1; then
						sudo -n limine-update 2>&1 | tee -a "${LOG_FILE}" || echo "WARNING: limine-update failed after tree failure." >&2
					fi
				fi
			else
				echo "Skipping bootloader tree refresh for mocked BOOT_DIR ${BOOT_DIR} (would touch live /boot)."
			fi
			if boot_grep "STD" "${LIMINE_CONF}" && boot_grep "${target_ver}" "${LIMINE_CONF}"; then
				echo "Limine entry verified for ${target_ver} (tool-driven, STD + ver)."
				tool_ok=1
			else
				echo "WARNING: Limine tool path did not yield STD + ${target_ver}; trying filtered fallback." >&2
			fi
		else
			echo "WARNING: limine-entry-tool --add-kernel failed; trying filtered fallback." >&2
		fi
	elif command -v limine-update >/dev/null 2>&1; then
		echo "limine-entry-tool not found; trying limine-update refresh (no add-kernel)..."
		if [ "${BOOT_DIR}" = "/boot" ]; then
			sudo -n limine-update 2>&1 | tee -a "${LOG_FILE}" || echo "WARNING: limine-update failed." >&2
		else
			echo "Skipping limine-update for mocked BOOT_DIR ${BOOT_DIR} (would touch live /boot)."
		fi
		if boot_grep "STD" "${LIMINE_CONF}" && boot_grep "${target_ver}" "${LIMINE_CONF}"; then
			echo "Limine entry verified for ${target_ver} (limine-update, STD + ver)."
			tool_ok=1
		else
			echo "WARNING: limine-update did not yield STD + ${target_ver}; trying filtered fallback." >&2
		fi
	else
		if [ -n "${MODESET_OPTS:-}" ]; then
			modeset_hint="Include modeset opts in the new entry cmdline: ${MODESET_OPTS}"
		else
			modeset_hint="If NVIDIA is present, include nvidia-drm.modeset=1 in the new entry cmdline."
		fi
		cat <<EOF
WARNING: STD kernel ${target_ver} not listed in ${LIMINE_CONF}.
kernel-install creates a BLS entry, but Limine boots from limine.conf.
No limine-entry-tool/limine-update found; trying filtered fallback below.
Manual sync e.g.:
  sudo -n limine-entry-tool --add-kernel std <vmlinuz-${target_ver}> <initramfs-${target_ver}>
  sudo -n limine-entry-tool --tree
  (or: sudo -n limine-update)
${modeset_hint}
EOF
	fi
	if [ "${tool_ok}" -eq 1 ]; then
		return 0
	fi
	# Filtered fallback: append a clearly-marked STD block (ver + modeset opts).
	echo "Limine filtered fallback: appending STD block for ${target_ver} to ${LIMINE_CONF}..."
	tmpfile="$(mktemp /tmp/std-limine-XXXXXX)"
	tmpappend="${tmpfile}.append"
	if [ -f "${LIMINE_CONF}" ]; then
		if ! cat -- "${LIMINE_CONF}" >"${tmpfile}" 2>/dev/null; then
			echo "WARNING: cannot read ${LIMINE_CONF}; rolling back ${backup}." >&2
			sudo -n cp -a -- "${backup}" "${LIMINE_CONF}" || echo "WARNING: Limine rollback failed; restore ${backup} manually." >&2
			rm -f -- "${tmpfile}" "${tmpappend}" 2>/dev/null || true
			return 0
		fi
	else
		# shellcheck disable=SC2024 # sudo -n applies to cat (root read); redirect targets user-owned tmpfile by design
		if ! sudo -n cat -- "${LIMINE_CONF}" >"${tmpfile}" 2>/dev/null; then
			echo "WARNING: cannot read ${LIMINE_CONF} via sudo -n; rolling back ${backup}." >&2
			sudo -n cp -a -- "${backup}" "${LIMINE_CONF}" || true
			rm -f -- "${tmpfile}" "${tmpappend}" 2>/dev/null || true
			return 0
		fi
	fi
	{
		echo ""
		echo "# STD ${target_ver} (generated by install.sh filtered fallback; remove with uninstall.sh --remove)"
		echo ":STD ${target_ver}"
		echo "    PROTOCOL: linux"
		echo "    KERNEL_PATH: boot:///vmlinuz-${target_ver}"
		echo "    MODULE_PATH: boot:///initramfs-${target_ver}.img"
		if [ -n "${MODESET_OPTS:-}" ]; then
			echo "    CMDLINE: ${MODESET_OPTS}"
		else
			# No inherited/hardware-keyed modeset opts: leave CMDLINE empty
			# rather than injecting a spurious NVIDIA token on non-NVIDIA hosts.
			echo "    CMDLINE:"
		fi
	} >"${tmpappend}" 2>/dev/null || true
	if ! cat -- "${tmpappend}" >>"${tmpfile}" 2>/dev/null; then
		echo "WARNING: cannot stage Limine fallback; rolling back ${backup}." >&2
		sudo -n cp -a -- "${backup}" "${LIMINE_CONF}" || echo "WARNING: Limine rollback failed; restore ${backup} manually." >&2
		rm -f -- "${tmpfile}" "${tmpappend}" 2>/dev/null || true
		return 0
	fi
	if ! sudo -n cp -a -- "${tmpfile}" "${LIMINE_CONF}"; then
		echo "WARNING: Limine filtered write failed; rolling back ${backup}." >&2
		sudo -n cp -a -- "${backup}" "${LIMINE_CONF}" || echo "WARNING: Limine rollback failed; restore ${backup} manually." >&2
		rm -f -- "${tmpfile}" "${tmpappend}" 2>/dev/null || true
		return 0
	fi
	rm -f -- "${tmpfile}" "${tmpappend}" 2>/dev/null || true
	if [ "${BOOT_DIR}" = "/boot" ]; then
		if command -v limine-entry-tool >/dev/null 2>&1; then
			sudo -n limine-entry-tool --tree 2>&1 | tee -a "${LOG_FILE}" || echo "WARNING: limine-entry-tool --tree failed after filter." >&2
		elif command -v limine-update >/dev/null 2>&1; then
			sudo -n limine-update 2>&1 | tee -a "${LOG_FILE}" || echo "WARNING: limine-update failed after filter." >&2
		fi
	else
		echo "Skipping bootloader tree refresh for mocked BOOT_DIR ${BOOT_DIR} (would touch live /boot)."
	fi
	if boot_grep "STD" "${LIMINE_CONF}" && boot_grep "${target_ver}" "${LIMINE_CONF}"; then
		echo "Limine entry verified for ${target_ver} (filtered fallback, STD + ver)."
		if command -v b2sum >/dev/null 2>&1; then
			sudo -n b2sum -- "${LIMINE_CONF}" 2>/dev/null | awk '{print "Limine conf b2sum (post): " $1}' || b2sum -- "${LIMINE_CONF}" 2>/dev/null | awk '{print "Limine conf b2sum (post): " $1}' || true
		fi
		return 0
	fi
	echo "WARNING: Limine verify failed for ${target_ver}; rolling back ${backup}." >&2
	sudo -n cp -a -- "${backup}" "${LIMINE_CONF}" || echo "WARNING: Limine rollback failed; restore ${backup} manually." >&2
	return 0
}

# GRUB: backup grub.cfg, grub-mkconfig/grub2-mkconfig, verify KERNEL_VER present.
update_grub() {
	target_ver="$1"
	grub_cfg=""
	for cand in "${BOOT_DIR}/grub/grub.cfg" "${BOOT_DIR}/grub2/grub.cfg"; do
		if boot_test_file "${cand}"; then
			grub_cfg="${cand}"
			break
		fi
	done
	if [ -z "${grub_cfg}" ]; then
		echo "No GRUB config under ${BOOT_DIR}; skipping GRUB matrix."
		return 0
	fi
	echo "Checking GRUB entry in ${grub_cfg}..."
	if boot_grep "${target_ver}" "${grub_cfg}"; then
		echo "GRUB entry already present."
		return 0
	fi
	if [ "${DRY_RUN}" -eq 1 ] || [ "${STATUS_MODE}" -eq 1 ]; then
		echo "Read-only mode: would run grub-mkconfig/grub2-mkconfig for ${target_ver} (no changes)."
		return 0
	fi
	GRUB_MKCONFIG=""
	if command -v grub-mkconfig >/dev/null 2>&1; then
		GRUB_MKCONFIG="grub-mkconfig"
	elif command -v grub2-mkconfig >/dev/null 2>&1; then
		GRUB_MKCONFIG="grub2-mkconfig"
	else
		echo "WARNING: grub-mkconfig/grub2-mkconfig not found; cannot refresh GRUB for ${target_ver}." >&2
		return 0
	fi
	if [ "${HAVE_SUDO}" -ne 1 ]; then
		echo "WARNING: no sudo -n; cannot refresh GRUB (fail-closed)." >&2
		return 0
	fi
	backup="${grub_cfg}.std-backup-$(date +%Y%m%d%H%M%S)"
	echo "Backing up ${grub_cfg} -> ${backup}..."
	# GRUB is warn-only with backup preserved for manual restore (no auto-rollback
	# by design, unlike Limine): mkconfig output is distro-owned, so a failed
	# verify never auto-restores; restore manually via `sudo -n cp -a backup cfg`.
	if ! sudo -n cp -a -- "${grub_cfg}" "${backup}"; then
		echo "WARNING: GRUB backup failed; aborting GRUB update." >&2
		return 0
	fi
	if sudo -n "${GRUB_MKCONFIG}" -o "${grub_cfg}" 2>&1 | tee -a "${LOG_FILE}"; then
		if boot_grep "${target_ver}" "${grub_cfg}"; then
			echo "GRUB entry verified for ${target_ver}."
			return 0
		fi
		echo "WARNING: GRUB verify failed for ${target_ver}; backup at ${backup}." >&2
	else
		echo "WARNING: ${GRUB_MKCONFIG} failed; backup at ${backup}." >&2
	fi
	return 0
}

# BLS: kernel-install created entries under loader/entries; verify only
# unless --write-bls is given (opt-in write with --yes; preview in read-only).
verify_bls() {
	target_ver="$1"
	BLS_DIR="${BOOT_DIR}/loader/entries"
	found=0
	if [ -d "${BLS_DIR}" ]; then
		if grep -F -q -r -- "${target_ver}" "${BLS_DIR}" 2>/dev/null; then
			found=1
		elif [ "${HAVE_SUDO}" -eq 1 ] && sudo -n grep -F -q -r -- "${target_ver}" "${BLS_DIR}" 2>/dev/null; then
			found=1
		fi
		if [ "${found}" -eq 1 ]; then
			echo "BLS entry for ${target_ver} present in ${BLS_DIR} (kernel-install)."
		else
			echo "WARNING: no BLS entry for ${target_ver} in ${BLS_DIR}; kernel-install may have failed (rerun with --write-bls to create opt-in entry)." >&2
		fi
	elif [ "${HAVE_SUDO}" -eq 1 ] && sudo -n test -d "${BLS_DIR}" 2>/dev/null; then
		if sudo -n grep -F -q -r -- "${target_ver}" "${BLS_DIR}" 2>/dev/null; then
			echo "BLS entry for ${target_ver} present in ${BLS_DIR} (kernel-install)."
		else
			echo "WARNING: no BLS entry for ${target_ver} in ${BLS_DIR}; kernel-install may have failed (rerun with --write-bls to create opt-in entry)." >&2
		fi
	else
		echo "No BLS dir ${BLS_DIR} readable, skipping BLS check."
	fi
}

# Opt-in BLS entry writer: creates loader/entries/std-<ver>.conf via sudo -n.
# Requires --write-bls + --yes; preview only in --dry-run/--status.
# Allowlisted path only (BLS_DIR under BOOT_DIR, ver allowlisted).
write_bls_entry() {
	target_ver="$1"
	if [ "${WRITE_BLS:-0}" -ne 1 ]; then
		return 0
	fi
	if ! is_safe_ver "${target_ver}"; then
		echo "write_bls_entry: refusing unsafe target version: ${target_ver}" >&2
		return 1
	fi
	BLS_DIR="${BOOT_DIR}/loader/entries"
	BLS_FILE="${BLS_DIR}/std-${target_ver}.conf"
	case "${BLS_FILE}" in
		"${BOOT_DIR}/loader/entries/std-"*)
			;;
		*)
			echo "write_bls_entry: refusing unexpected BLS path: ${BLS_FILE}" >&2
			return 1
			;;
	esac
	if [ "${DRY_RUN}" -eq 1 ] || [ "${STATUS_MODE}" -eq 1 ]; then
		echo "Read-only mode: would write BLS entry ${BLS_FILE} for ${target_ver} (no changes)."
		return 0
	fi
	if [ "${ASSUME_YES}" -ne 1 ]; then
		echo "--write-bls requires --yes (two-key guard)." >&2
		return 1
	fi
	if [ -z "${MODESET_OPTS:-}" ]; then
		inherit_modeset || true
	fi
	if [ -n "${MODESET_OPTS:-}" ] && ! validate_modeset_opts; then
		echo "write_bls_entry: refusing unsafe modeset opts: ${MODESET_OPTS}" >&2
		return 1
	fi
	if [ "${HAVE_SUDO}" -ne 1 ]; then
		echo "WARNING: no sudo -n; cannot write BLS entry ${BLS_FILE} (fail-closed)." >&2
		return 0
	fi
	if ! sudo -n test -d "${BLS_DIR}" 2>/dev/null && [ ! -d "${BLS_DIR}" ]; then
		echo "WARNING: BLS dir ${BLS_DIR} absent; cannot write entry (fail-closed)." >&2
		return 0
	fi
	tmpbls="$(mktemp /tmp/std-bls-XXXXXX)"
	{
		echo "title STD ${target_ver}"
		echo "version ${target_ver}"
		echo "linux /vmlinuz-${target_ver}"
		echo "initrd /initramfs-${target_ver}.img"
		if [ -n "${MODESET_OPTS:-}" ]; then
			echo "options ${MODESET_OPTS}"
		else
			# No inherited/hardware-keyed modeset opts: keep options empty
			# rather than injecting a spurious NVIDIA token on non-NVIDIA hosts.
			echo "options"
		fi
	} >"${tmpbls}" 2>/dev/null || true
	echo "Writing BLS entry ${BLS_FILE}..."
	if ! sudo -n cp -a -- "${tmpbls}" "${BLS_FILE}"; then
		echo "WARNING: BLS write failed for ${BLS_FILE}." >&2
		rm -f -- "${tmpbls}" 2>/dev/null || true
		return 0
	fi
	rm -f -- "${tmpbls}" 2>/dev/null || true
	if sudo -n grep -F -q -- "${target_ver}" "${BLS_FILE}" 2>/dev/null || grep -F -q -- "${target_ver}" "${BLS_FILE}" 2>/dev/null; then
		echo "BLS entry verified for ${target_ver} at ${BLS_FILE}."
	else
		echo "WARNING: BLS verify failed for ${BLS_FILE}." >&2
	fi
}

# Assert inherited/hardware-keyed modeset opts are wired into boot entries.
# Warn-only by default; fatal with --strict-nvidia. Read-only (no writes).
verify_modeset_wired() {
	target_ver="$1"
	if [ -z "${MODESET_OPTS:-}" ]; then
		inherit_modeset || true
	fi
	if [ -z "${MODESET_OPTS:-}" ]; then
		echo "Modeset verify: no NVIDIA modeset opts to assert (no HW, no inheritance)."
		return 0
	fi
	if ! is_safe_ver "${target_ver}"; then
		echo "verify_modeset_wired: refusing unsafe target version: ${target_ver}" >&2
		return 1
	fi
	if ! validate_modeset_opts; then
		echo "verify_modeset_wired: refusing unsafe modeset opts: ${MODESET_OPTS}" >&2
		return 1
	fi
	first_tok="$(printf '%s' "${MODESET_OPTS}" | awk '{print $1}')"
	if [ -z "${first_tok}" ]; then
		echo "Modeset verify: empty token, skipping."
		return 0
	fi
	echo "Modeset verify: asserting '${first_tok}' (from '${MODESET_OPTS}') in boot entries for ${target_ver}..."
	wired=0
	for limine_conf in "${BOOT_DIR}/limine.conf" "${BOOT_DIR}/limine/limine.conf" "${BOOT_DIR}/EFI/BOOT/limine.conf" "${BOOT_DIR}/boot/limine.conf"; do
		if boot_test_file "${limine_conf}"; then
			if boot_grep "${first_tok}" "${limine_conf}"; then
				echo "Modeset verify: Limine entry contains ${first_tok} in ${limine_conf}."
				wired=1
			else
				echo "Modeset verify: Limine entry lacks ${first_tok} in ${limine_conf}." >&2
			fi
		fi
	done
	bls_dir="${BOOT_DIR}/loader/entries"
	if [ -d "${bls_dir}" ]; then
		if grep -F -q -r -- "${first_tok}" "${bls_dir}" 2>/dev/null; then
			echo "Modeset verify: BLS entry contains ${first_tok}."
			wired=1
		else
			echo "Modeset verify: BLS entries lack ${first_tok}." >&2
		fi
	elif [ "${HAVE_SUDO}" -eq 1 ] && sudo -n test -d "${bls_dir}" 2>/dev/null; then
		if sudo -n grep -F -q -r -- "${first_tok}" "${bls_dir}" 2>/dev/null; then
			echo "Modeset verify: BLS entry contains ${first_tok} (root-only)."
			wired=1
		else
			echo "Modeset verify: BLS entries lack ${first_tok} (root-only check)." >&2
		fi
	fi
	for grub_cand in "${BOOT_DIR}/grub/grub.cfg" "${BOOT_DIR}/grub2/grub.cfg"; do
		if boot_test_file "${grub_cand}"; then
			if boot_grep "${first_tok}" "${grub_cand}"; then
				echo "Modeset verify: GRUB entry contains ${first_tok} in ${grub_cand}."
				wired=1
			else
				echo "Modeset verify: ${grub_cand} lacks ${first_tok}." >&2
			fi
		fi
	done
	if [ "${wired}" -eq 1 ]; then
		echo "Modeset verify: OK for ${target_ver} (${first_tok} wired)."
		return 0
	fi
	nvidia_fail "modeset opts [${MODESET_OPTS}] not wired into Limine/BLS/GRUB for ${target_ver}; add '${first_tok}' to the new entry cmdline" || return 1
	return 0
}

# Clean naming helpers: pin -std, preserve AUTO=y by default, opt-in
# suppression (AUTO=n + LOCALVERSION="") behind --allow-dirty-suppress.
# No src/patches logic changes; .config only. sudo never used here.
pin_localversion() {
	if [ ! -f "${KERNEL_DIR}/.config" ]; then
		echo "pin_localversion: no .config to pin." >&2
		return 1
	fi
	if [ -x "${KERNEL_DIR}/scripts/config" ]; then
		"${KERNEL_DIR}/scripts/config" --file "${KERNEL_DIR}/.config" --set-str CONFIG_LOCALVERSION "-std" || true
		if [ "${ALLOW_DIRTY_SUPPRESS}" -eq 1 ]; then
			"${KERNEL_DIR}/scripts/config" --file "${KERNEL_DIR}/.config" --disable CONFIG_LOCALVERSION_AUTO || true
			export LOCALVERSION=""
			echo "Pinned CONFIG_LOCALVERSION=\"-std\" with AUTO=n + LOCALVERSION=\"\" (dirty suppression ON)."
		else
			"${KERNEL_DIR}/scripts/config" --file "${KERNEL_DIR}/.config" --enable CONFIG_LOCALVERSION_AUTO || true
			unset LOCALVERSION || true
			echo "Pinned CONFIG_LOCALVERSION=\"-std\" with AUTO=y preserved (dirty suppression off)."
		fi
	else
		if grep -q '^CONFIG_LOCALVERSION=' "${KERNEL_DIR}/.config"; then
			sed -i 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-std"/' "${KERNEL_DIR}/.config"
		else
			printf '%s\n' 'CONFIG_LOCALVERSION="-std"' >> "${KERNEL_DIR}/.config"
		fi
		if [ "${ALLOW_DIRTY_SUPPRESS}" -eq 1 ]; then
			if grep -q '^CONFIG_LOCALVERSION_AUTO=y' "${KERNEL_DIR}/.config"; then
				sed -i 's/^CONFIG_LOCALVERSION_AUTO=y/# CONFIG_LOCALVERSION_AUTO is not set/' "${KERNEL_DIR}/.config"
			elif ! grep -q 'CONFIG_LOCALVERSION_AUTO' "${KERNEL_DIR}/.config"; then
				printf '%s\n' '# CONFIG_LOCALVERSION_AUTO is not set' >> "${KERNEL_DIR}/.config"
			fi
			export LOCALVERSION=""
			echo "Pinned CONFIG_LOCALVERSION=\"-std\" with AUTO=n + LOCALVERSION=\"\" (dirty suppression ON, sed fallback)."
		else
			if grep -q '^# CONFIG_LOCALVERSION_AUTO is not set' "${KERNEL_DIR}/.config"; then
				sed -i 's/^# CONFIG_LOCALVERSION_AUTO is not set/CONFIG_LOCALVERSION_AUTO=y/' "${KERNEL_DIR}/.config"
			elif ! grep -q 'CONFIG_LOCALVERSION_AUTO' "${KERNEL_DIR}/.config"; then
				printf '%s\n' 'CONFIG_LOCALVERSION_AUTO=y' >> "${KERNEL_DIR}/.config"
			fi
			unset LOCALVERSION || true
			echo "Pinned CONFIG_LOCALVERSION=\"-std\" with AUTO=y preserved (sed fallback)."
		fi
	fi
}

# Expected STD dirt allowlist (fail-closed on extra dirt).
# Membership allowlist: any subset of the 5 tracked STD files + any subset
# of the 2 untracked STD sources is expected (subset acceptance, not an
# exact 7-file count). Patch/build leftovers are ignored, never counted.
# Anything else is extra dirt and fails install verification.
# Read-only; git only, never sudo, never mutates.
TREE_DIRT="unknown"

is_expected_modified() {
	case "$1" in
		Documentation/admin-guide/kernel-parameters.txt|kernel/Kconfig.preempt|kernel/sched/Makefile|kernel/sched/sched.h|kernel/sched/core.c)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

is_expected_untracked() {
	case "$1" in
		kernel/sched/std.c|kernel/sched/std.h)
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
# Membership allowlist (any subset accepted): up to 5 tracked STD
# modifications + up to 2 untracked STD sources; ignored artifacts excluded;
# extra fails.
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
		echo "  allowlist: up to 5M (Documentation/admin-guide/kernel-parameters.txt, kernel/Kconfig.preempt, kernel/sched/Makefile, kernel/sched/sched.h, kernel/sched/core.c) + up to 2U (kernel/sched/std.c, kernel/sched/std.h); any subset is expected; ignored: *.orig, *.rej, kernel/sched/std.o, kernel/sched/.std.o.cmd"
		return 1
	fi
	if [ "${counted}" -eq 0 ]; then
		TREE_DIRT="clean"
		echo "  dirt: clean (no non-ignored changes)"
		return 0
	fi
	TREE_DIRT="expected"
	echo "  dirt: expected STD dirt only (membership allowlist up to 5M+2U, any subset; ignored artifacts excluded)"
	return 0
}

# Fail on *-dirty (or *+) except 7.3.0-std-dirty with expected STD dirt.
# Accepts 7.3.0-std (clean) and 7.3.0-std-dirty when TREE_DIRT==expected;
# fail-closed on extra/unknown dirt, on *+ suffixes, and on bare 7.3.0-dirty.
# Verifies -std pin, AUTO state matches the flag, tag prerequisite (v7.3),
# expected-dirt membership allowlist (any subset up to 5M+2U, ignored artifacts excluded, extra fails),
# and the clean contract (clean tree must yield exactly 7.3.0-std).
# Called after olddefconfig + `make -s kernelrelease`; never auto-boots.
# Live `make -s kernelrelease` is the source of truth; include/config/kernel.release
# is a stale build artifact (regenerated by make prepare) and is never trusted.
verify_kernelrelease() {
	ver="$1"
	if [ -z "${ver}" ] || [ "${ver}" = "unknown" ]; then
		echo "ERROR: unknown kernelrelease; cannot verify clean naming." >&2
		return 1
	fi
	if ! is_safe_ver "${ver}"; then
		echo "ERROR: refusing unsafe kernelrelease: ${ver}" >&2
		return 1
	fi
	if [ "${ver}" = "7.3.0-dirty" ]; then
		echo "ERROR: kernelrelease collides with vanilla 7.3.0-dirty; expected -std suffix." >&2
		echo "Check CONFIG_LOCALVERSION in ${KERNEL_DIR}/.config." >&2
		return 1
	fi
	# Pin check: .config must carry -std.
	if [ -f "${KERNEL_DIR}/.config" ]; then
		if ! grep -q '^CONFIG_LOCALVERSION="-std"' "${KERNEL_DIR}/.config"; then
			echo "ERROR: CONFIG_LOCALVERSION is not \"-std\" for ${ver}; check ${KERNEL_DIR}/.config." >&2
			return 1
		fi
		if [ "${ALLOW_DIRTY_SUPPRESS}" -eq 1 ]; then
			if grep -q '^CONFIG_LOCALVERSION_AUTO=y' "${KERNEL_DIR}/.config"; then
				echo "ERROR: suppression requested but CONFIG_LOCALVERSION_AUTO is still y for ${ver}." >&2
				return 1
			fi
		else
			if ! grep -q '^CONFIG_LOCALVERSION_AUTO=y' "${KERNEL_DIR}/.config"; then
				echo "ERROR: CONFIG_LOCALVERSION_AUTO is not y for ${ver} (preserve AUTO=y unless --allow-dirty-suppress)." >&2
				return 1
			fi
		fi
	fi
	# Tag prerequisite: local tree must describe v7.3 (clone --branch v7.3).
	if command -v git >/dev/null 2>&1 && [ -d "${KERNEL_DIR}/.git" ]; then
		if ! git -C "${KERNEL_DIR}" describe --tags 2>/dev/null | grep -q -- "v7.3"; then
			echo "WARNING: tree does not describe v7.3; clean contract expects a v7.3 checkout (clone --branch v7.3)." >&2
		fi
	fi
	# Expected-dirt membership allowlist: any subset up to 5M + 2U accepted,
	# ignored artifacts (*.orig/*.rej, kernel/sched/std.o, kernel/sched/.std.o.cmd) excluded,
	# anything else fails (fail-closed). Runs before the *-dirty gate so
	# extra dirt reports first; bare 7.3.0-dirty stays rejected above.
	if command -v git >/dev/null 2>&1 && [ -d "${KERNEL_DIR}/.git" ]; then
		if ! classify_tree_dirt; then
			echo "ERROR: unexpected tree dirt beyond STD allowlist for ${ver}; commit or revert extra changes, then rerun." >&2
			return 1
		fi
	else
		TREE_DIRT="unknown"
	fi
	case "${ver}" in
		*-dirty|*+)
			if [ "${ALLOW_DIRTY_SUPPRESS}" -eq 1 ]; then
				echo "ERROR: kernelrelease ${ver} still carries a dirty suffix despite --allow-dirty-suppress (AUTO=n + LOCALVERSION=\"\" should yield 7.3.0-std)." >&2
				return 1
			fi
			if [ "${ver}" = "7.3.0-std-dirty" ] && [ "${TREE_DIRT}" = "expected" ]; then
				echo "Expected-dirt verification: ${ver} OK (STD membership allowlist dirt up to 5M+2U, any subset, yields -dirty by design)."
				return 0
			fi
			cat >&2 <<EOF
ERROR: kernelrelease ${ver} carries a dirty suffix (fail-closed, dirt=${TREE_DIRT}).
Clean contract: a clean v7.3 tree with CONFIG_LOCALVERSION="-std" and AUTO=y yields exactly 7.3.0-std.
Expected STD dirt only (membership allowlist up to 5M+2U, any subset) yields 7.3.0-std-dirty and verifies OK; extra/unknown dirt and *+ suffixes fail.
To proceed: commit STD inside ${KERNEL_DIR} for a clean tree, or rerun with explicit --allow-dirty-suppress (AUTO=n + LOCALVERSION="") to force 7.3.0-std.
Prune old *-dirty boot/modules artifacts afterwards via: scripts/uninstall.sh --remove --yes [KERNEL_DIR].
EOF
			return 1
			;;
	esac
	# Clean-tree check: when dirt classification is clean, release must be
	# exactly 7.3.0-std. Expected 7.3.0-std-dirty already returned OK above;
	# remaining expected dirt falls through to the generic OK below;
	# unknown skips the check.
	if [ "${TREE_DIRT}" = "clean" ]; then
		if [ "${ver}" != "7.3.0-std" ]; then
			echo "ERROR: clean tree yields ${ver}, expected exactly 7.3.0-std (pin -std + AUTO state mismatch?)." >&2
			return 1
		fi
		echo "Clean-tree verification: ${ver} OK (7.3.0-std)."
		return 0
	fi
	if [ "${TREE_DIRT}" = "expected" ]; then
		echo "Expected-dirt verification: ${ver} carries only STD membership allowlist dirt (any subset up to 5M+2U)."
	fi
	echo "Kernel release verification: ${ver} OK (pin -std, AUTO checked, tag v7.3)."
	return 0
}

reject_v74() {
	# Local-tree only: clone pins --branch v7.3, so a future upstream v7.4 tag
	# must not brick runs. No ls-remote probe (unanchored refs/tags/v7.4 would
	# match v7.4.x and brick the future). Enforce v7.3 on the local tree.
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

# --remove shims to uninstall.sh (allowlisted, refuses running kernel).
# Preview only in --dry-run/--status (no deletion); otherwise requires --yes.
# Delegates to scripts/uninstall.sh --remove with the same target/boot dirs.
if [ "${REMOVE_MODE}" -eq 1 ]; then
	UNINSTALLER="${SCRIPT_DIR}/uninstall.sh"
	if [ ! -f "${UNINSTALLER}" ]; then
		echo "Cannot --remove: uninstaller not found: ${UNINSTALLER}" >&2
		exit 1
	fi
	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "Remove preview (read-only, no deletion) via uninstall.sh shim..."
		if [ "${ASSUME_YES}" -eq 1 ]; then
			exec bash -- "${UNINSTALLER}" --remove --dry-run --yes --boot-dir "${BOOT_DIR}" "${KERNEL_DIR}"
		else
			exec bash -- "${UNINSTALLER}" --remove --dry-run --boot-dir "${BOOT_DIR}" "${KERNEL_DIR}"
		fi
	elif [ "${STATUS_MODE}" -eq 1 ]; then
		echo "Remove status preview (read-only, no deletion) via uninstall.sh shim..."
		if [ "${ASSUME_YES}" -eq 1 ]; then
			exec bash -- "${UNINSTALLER}" --remove --status --yes --boot-dir "${BOOT_DIR}" "${KERNEL_DIR}"
		else
			exec bash -- "${UNINSTALLER}" --remove --status --boot-dir "${BOOT_DIR}" "${KERNEL_DIR}"
		fi
	else
		if [ "${ASSUME_YES}" -ne 1 ]; then
			echo "--remove requires --yes for deletion (two-key guard)." >&2
			exit 1
		fi
		echo "Delegating --remove to ${UNINSTALLER} for ${KERNEL_DIR} (boot ${BOOT_DIR})..."
		exec bash -- "${UNINSTALLER}" --remove --yes --boot-dir "${BOOT_DIR}" "${KERNEL_DIR}"
	fi
fi

# --status is read-only and wins over clone/apply/build/install.
# It never mutates: no clone, no pacman, no DKMS, no boot writes.
if [ "${STATUS_MODE}" -eq 1 ]; then
	report_status
	exit 0
fi

# Slice 1 preflight: privilege, deps, NVIDIA (read-only unless --install-deps).
probe_privilege
if ! check_deps; then
	exit 1
fi
detect_nvidia
check_nvidia_src || true

if [ ! -d "${KERNEL_DIR}" ]; then
	if [ "${DRY_RUN}" -eq 1 ]; then
		if [ "${FRESH}" -eq 1 ]; then
			echo "Would re-clone fresh v7.3 to ${KERNEL_DIR} (--fresh dry-run, no changes)."
		else
			echo "Would clone fresh v7.3 to ${KERNEL_DIR} (dry-run, no changes)."
		fi
		echo "Dry-run OK. No changes made."
		exit 0
	fi
	echo "Kernel tree not found, cloning fresh v7.3..."
	reject_v74
	reject_rc
	git clone --branch v7.3 --depth 1 "${KERNEL_URL}" "${KERNEL_DIR}"
elif [ "${FRESH}" -eq 1 ]; then
	# --fresh forces a clean re-clone (two-key guard; preview only in read-only modes).
	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "Would re-clone fresh v7.3 to ${KERNEL_DIR} (--fresh dry-run, no changes; existing tree left intact for preflight preview)."
		reject_v74
		reject_rc
	else
		if [ "${ASSUME_YES}" -ne 1 ]; then
			echo "--fresh requires --yes for re-clone (two-key guard)." >&2
			exit 1
		fi
		# Tree-sanity guard: refuse --fresh unless KERNEL_DIR looks like a
		# kernel tree (Makefile or .git present) or is empty/missing (fresh
		# clone path). Prevents rm -rf on an arbitrary path.
		if [ -d "${KERNEL_DIR}" ]; then
			if [ -f "${KERNEL_DIR}/Makefile" ] || [ -d "${KERNEL_DIR}/.git" ]; then
				:
			elif [ -z "$(ls -A -- "${KERNEL_DIR}" 2>/dev/null || true)" ]; then
				echo "--fresh: ${KERNEL_DIR} is empty; proceeding with fresh clone."
			else
				echo "Refusing --fresh: ${KERNEL_DIR} does not look like a kernel tree (no Makefile, no .git) and is not empty." >&2
				exit 1
			fi
		fi
		echo "Removing existing tree for --fresh re-clone: ${KERNEL_DIR}..."
		# Ownership guard: sudo builds leave KDIR root-owned; bare rm -rf
		# as non-root would fail partway. Fail closed with hint.
		if [ ! -w "${KERNEL_DIR}" ]; then
			echo "Refusing --fresh: ${KERNEL_DIR} is not writable (root-owned after sudo builds); fix ownership first, e.g.: sudo -n chown -R \"$(id -un):$(id -gn)\" -- \"${KERNEL_DIR}\" (or sudo -n rm -rf -- \"${KERNEL_DIR}\" manually), then rerun." >&2
			exit 1
		fi
		rm -rf -- "${KERNEL_DIR}"
		echo "Cloning fresh v7.3 to ${KERNEL_DIR} (--fresh)..."
		reject_v74
		reject_rc
		git clone --branch v7.3 --depth 1 "${KERNEL_URL}" "${KERNEL_DIR}"
		reject_v74
		reject_rc
	fi
else
	reject_v74
	reject_rc
fi

if [ ! -d "${KERNEL_DIR}" ]; then
	echo "Kernel tree not found: ${KERNEL_DIR}" >&2
	exit 1
fi

if [ ! -f "${SERIES_FILE}" ]; then
	echo "Series file not found: ${SERIES_FILE}" >&2
	exit 1
fi

# Preflight checks use patch dry-run plus git apply check plus checkpatch.
# Keeps 1-2 CPU systems and taskset affinity safe by construction.
FAILED=0
while IFS= read -r patch; do
	[ -z "${patch}" ] && continue
	case "${patch}" in
		\#*) continue ;;
	esac
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
	echo "Checking ${patch}..."
	if ! patch -p1 -N -F 0 --batch --dry-run -d "${KERNEL_DIR}" < "${PATCH_FILE}" >/dev/null; then
		echo "Dry-run failed for ${patch} (may already be applied)" >&2
		FAILED=1
	fi
	if command -v git >/dev/null 2>&1; then
		if ! GIT_OUT="$(git -C "${KERNEL_DIR}" apply --check -- "${PATCH_FILE}" 2>&1)"; then
			echo "git apply check failed for ${patch}:" >&2
			echo "${GIT_OUT}" >&2
			FAILED=1
		fi
	fi
	CHECKPATCH="${KERNEL_DIR}/scripts/checkpatch.pl"
	if [ -f "${CHECKPATCH}" ] && command -v perl >/dev/null 2>&1; then
		# stdin (- < file) avoids git_is_single_file file-mode: a tracked
		# patch passed as argv would diff -u /dev/null and flag patch
		# formatting as errors. --ignore FILE_PATH_CHANGES scoped to 0003 only
		# (0003 adds kernel/sched/std.c/std.h by design; MAINTAINERS update N/A).
		CHECKPATCH_IGNORE=""
		case "${patch}" in
			0003-*) CHECKPATCH_IGNORE="--ignore FILE_PATH_CHANGES" ;;
		esac
		# shellcheck disable=SC2086 # CHECKPATCH_IGNORE is empty or one allowlisted flag.
		if ! perl "${CHECKPATCH}" --strict --no-tree ${CHECKPATCH_IGNORE} - < "${PATCH_FILE}" >/dev/null 2>&1; then
			echo "checkpatch --strict failed for ${patch}" >&2
			# shellcheck disable=SC2086 # See above.
			perl "${CHECKPATCH}" --strict --no-tree ${CHECKPATCH_IGNORE} - < "${PATCH_FILE}" 2>&1 | head -n 20 >&2 || true
			FAILED=1
		fi
	else
		echo "checkpatch.pl not found, skipping strict check for ${patch}"
	fi
done < "${SERIES_FILE}"

if [ "${FAILED}" -ne 0 ]; then
	echo "Preflight found issues. Use cleanup or uninstall first." >&2
	exit 1
fi

# --dry-run wins over apply, build, install and listing.
if [ "${DRY_RUN}" -eq 1 ]; then
	# Read-only naming preview (no .config mutation, no build).
	if [ -f "${KERNEL_DIR}/Makefile" ]; then
		DRY_KREL="$(make -C "${KERNEL_DIR}" -s kernelrelease 2>/dev/null || echo "unknown")"
		echo "Dry-run kernelrelease preview: ${DRY_KREL} (LOCALVERSION pin + AUTO check happen at install; no changes made)."
		case "${DRY_KREL}" in
			7.3.0-std-dirty)
				if [ "${ALLOW_DIRTY_SUPPRESS}" -eq 1 ]; then
					echo "Dry-run: ${DRY_KREL} carries a dirty suffix; install will pin AUTO=n + LOCALVERSION=\"\" to force 7.3.0-std."
				else
					echo "Dry-run: ${DRY_KREL} verifies OK when dirt is expected STD only (membership allowlist up to 5M+2U, any subset); extra/unknown dirt or *+ still fails install verification."
				fi
				;;
			*-dirty|*+)
				if [ "${ALLOW_DIRTY_SUPPRESS}" -eq 1 ]; then
					echo "Dry-run: ${DRY_KREL} carries a dirty suffix; install will pin AUTO=n + LOCALVERSION=\"\" to force 7.3.0-std."
				else
					echo "Dry-run: ${DRY_KREL} carries a dirty/plus suffix; install verification will fail (only 7.3.0-std-dirty with expected dirt verifies)." >&2
				fi
				;;
			7.3.0-std)
				echo "Dry-run: clean contract preview OK (7.3.0-std)."
				;;
		esac
	fi
	# Read-only dirt preview (git only, never sudo, never mutates).
	classify_tree_dirt || true
	echo "Dry-run OK. No changes made."
	exit 0
fi

# Two-key guard: --prune-boot requires --yes.
if [ "${PRUNE_BOOT}" -eq 1 ] && [ "${ASSUME_YES}" -ne 1 ]; then
	echo "--prune-boot requires --yes for boot listing." >&2
	exit 1
fi

if [ "${ASSUME_YES}" -ne 1 ]; then
	printf "Apply STD patches to %s? [y/N] " "${KERNEL_DIR}"
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
		\#*) continue ;;
	esac
	case "${patch}" in
		*"/"*|*".."*|-*)
			echo "Unsafe series entry: ${patch}" >&2
			FAILED=1
			continue
			;;
	esac
	echo "Applying ${patch}..."
	if ! patch -p1 -N -F 0 --batch -d "${KERNEL_DIR}" < "${PATCH_DIR}/${patch}"; then
		echo "Apply failed for ${patch}" >&2
		FAILED=1
	fi
done < "${SERIES_FILE}"

if [ "${FAILED}" -ne 0 ]; then
	echo "STD install failed for one or more patches." >&2
	exit 1
fi

# Build: always overwrite .config from running kernel, pin LOCALVERSION,
# parallel make, install with sudo -n (never mrproper post-write: it would
# delete the just-written .config; `make clean` only before the full build).
# Config inheritance order (.config only, no src/patches changes; existing
# .config is backed up to .config.std-backup then overwritten, never preserved):
# 1) /proc/config.gz via zcat (running kernel, hardware-matched)
# 2) BOOT_DIR/config-$(uname -r) then /boot/config-$(uname -r) (direct read,
#    then sudo -n cat for root-only; uname -r sanitized, fail-closed on unsafe)
# 3) defconfig fallback.
# olddefconfig runs after any source; config source is logged.
# MODULES/BTRFS/OVERLAY audit warns when the resolved .config lacks them.
CONFIG_SOURCE="none"
if [ -f "${KERNEL_DIR}/.config" ]; then
	echo "Backing up existing .config -> ${KERNEL_DIR}/.config.std-backup (will be overwritten from running kernel) ..."
	if ! cp -a -- "${KERNEL_DIR}/.config" "${KERNEL_DIR}/.config.std-backup"; then
		echo "ERROR: .config backup failed; aborting (fail-closed) before overwrite." >&2
		exit 1
	fi
fi
INHERITED_CONFIG=0
RUNNING_REL="$(uname -r 2>/dev/null || true)"
if [ -f "/proc/config.gz" ] && command -v zcat >/dev/null 2>&1; then
	echo "Inheriting config from /proc/config.gz (running kernel)..."
	if zcat -- /proc/config.gz >"${KERNEL_DIR}/.config" 2>/dev/null; then
		CONFIG_SOURCE="/proc/config.gz (running kernel via zcat)"
		INHERITED_CONFIG=1
	else
		echo "WARNING: failed to inherit /proc/config.gz; trying ${BOOT_DIR}/config-${RUNNING_REL:-unknown} (fallback live /boot)." >&2
		rm -f -- "${KERNEL_DIR}/.config" 2>/dev/null || true
	fi
fi
if [ "${INHERITED_CONFIG}" -eq 0 ] && [ -n "${RUNNING_REL:-}" ]; then
	case "${RUNNING_REL}" in
		*"/"*|*".."*|"")
			echo "WARNING: refusing unsafe uname -r for config inheritance: ${RUNNING_REL}." >&2
			;;
		*)
			# Respect BOOT_DIR when mocked (tests use a fake BOOT_DIR);
			# fallback to live /boot for the running-kernel config.
			# Live runs keep BOOT_DIR==/boot so the primary is unchanged.
			BOOT_CONFIG_TRIED=""
			for BOOT_CONFIG in "${BOOT_DIR}/config-${RUNNING_REL}" "/boot/config-${RUNNING_REL}"; do
				if [ "${BOOT_CONFIG}" = "${BOOT_CONFIG_TRIED}" ]; then
					continue
				fi
				BOOT_CONFIG_TRIED="${BOOT_CONFIG}"
				if [ "${INHERITED_CONFIG}" -eq 1 ]; then
					break
				fi
			if [ -f "${BOOT_CONFIG}" ]; then
				echo "Inheriting config from ${BOOT_CONFIG} (direct read)..."
				if cat -- "${BOOT_CONFIG}" >"${KERNEL_DIR}/.config" 2>/dev/null; then
					CONFIG_SOURCE="${BOOT_CONFIG} (direct read)"
					INHERITED_CONFIG=1
				else
					echo "WARNING: direct read failed for ${BOOT_CONFIG}; trying sudo -n cat." >&2
					rm -f -- "${KERNEL_DIR}/.config" 2>/dev/null || true
				fi
			fi
			if [ "${INHERITED_CONFIG}" -eq 0 ]; then
				if [ "${HAVE_SUDO:-0}" -eq 1 ] && sudo -n test -f "${BOOT_CONFIG}" 2>/dev/null; then
					echo "Inheriting config from ${BOOT_CONFIG} via sudo -n cat (root-only)..."
					# shellcheck disable=SC2024 # sudo -n applies to cat (root read); redirect targets tree-owned .config by design
					if sudo -n cat -- "${BOOT_CONFIG}" >"${KERNEL_DIR}/.config" 2>/dev/null; then
						CONFIG_SOURCE="${BOOT_CONFIG} (sudo -n cat)"
						INHERITED_CONFIG=1
					else
						echo "WARNING: sudo -n cat failed for ${BOOT_CONFIG}." >&2
						rm -f -- "${KERNEL_DIR}/.config" 2>/dev/null || true
					fi
				else
					echo "No ${BOOT_CONFIG} readable (direct + sudo -n failed); trying next candidate."
				fi
			fi
			done
			if [ "${INHERITED_CONFIG}" -eq 0 ]; then
				echo "No BOOT_DIR/live config readable for ${RUNNING_REL}; using defconfig fallback."
			fi
			;;
	esac
fi
if [ "${INHERITED_CONFIG}" -eq 1 ]; then
	echo "Inherited config source: ${CONFIG_SOURCE}; running olddefconfig to sync..."
	if ! make -C "${KERNEL_DIR}" olddefconfig; then
		echo "olddefconfig failed after config inheritance" >&2
		exit 1
	fi
else
	echo "No inherited config available; using defconfig fallback..."
	if ! make -C "${KERNEL_DIR}" defconfig; then
		echo "defconfig failed" >&2
		exit 1
	fi
	CONFIG_SOURCE="defconfig (fallback, no inheritance source readable)"
	if ! make -C "${KERNEL_DIR}" olddefconfig; then
		echo "olddefconfig failed after defconfig fallback" >&2
		exit 1
	fi
fi
echo "Config source: ${CONFIG_SOURCE}"
# Audit MODULES/BTRFS/OVERLAY in the resolved .config (warn-only; degraded
# initramfs gate fails later unless --allow-degraded-initramfs).
if [ -f "${KERNEL_DIR}/.config" ]; then
	for cfg_opt in CONFIG_MODULES CONFIG_BTRFS_FS CONFIG_OVERLAY_FS; do
		if grep -q "^${cfg_opt}=[ym]" "${KERNEL_DIR}/.config" 2>/dev/null; then
			echo "Config audit: ${cfg_opt} enabled."
		else
			echo "WARNING: ${cfg_opt} not enabled in ${KERNEL_DIR}/.config (source: ${CONFIG_SOURCE}); mkinitcpio may report missing btrfs/overlay modules." >&2
		fi
	done
fi

# Pin LOCALVERSION so STD builds do not collide with vanilla 7.3.0-dirty.
# Vanilla defconfig leaves CONFIG_LOCALVERSION="" with AUTO=y, which yields
# 7.3.0-dirty on any dirty v7.3 tree. STD pins "-std" and preserves AUTO=y
# by default so a clean v7.3 tree yields exactly 7.3.0-std while expected
# STD dirt yields 7.3.0-std-dirty and verifies OK (extra/unknown dirt and
# *+ suffixes fail verification fail-closed).
# Opt-in --allow-dirty-suppress pins AUTO=n + LOCALVERSION="" to force
# 7.3.0-std on a dirty tree. Backup above keeps the pre-pin .config.
# NOTE: `make kernelrelease` is a no-sync-config target (it reads the stale
# include/config/auto.conf), so `make prepare` must run after olddefconfig
# before any kernelrelease verification; otherwise the pin would not be
# reflected and verification would pass/fail on stale data.
if [ -f "${KERNEL_DIR}/.config" ]; then
	if ! pin_localversion; then
		echo "LOCALVERSION pin failed" >&2
		exit 1
	fi
	if ! make -C "${KERNEL_DIR}" olddefconfig; then
		echo "olddefconfig failed after LOCALVERSION pin" >&2
		exit 1
	fi
	if ! make -C "${KERNEL_DIR}" prepare; then
		echo "make prepare failed after LOCALVERSION pin (cannot sync auto.conf for kernelrelease)" >&2
		exit 1
	fi
fi
KERNEL_VER_EARLY="$(make -C "${KERNEL_DIR}" -s kernelrelease 2>/dev/null || echo "unknown")"
echo "Kernel release: ${KERNEL_VER_EARLY}"
if ! verify_kernelrelease "${KERNEL_VER_EARLY}"; then
	exit 1
fi

JOBS="$(nproc 2>/dev/null || echo 4)"
# JOBS=nproc (unbounded) is intentional: full cold build after `make clean`.
# `make clean` keeps .config (never mrproper/distclean). DEBUG_INFO/BTF bloat
# (2.3G, 6480 .ko) is inherited from the running config, not forced by STD;
# constrain manually via `env MAKEFLAGS=-jN` if needed (no auto-cap by design).
# Fresh object state for the overwritten .config (never mrproper: it would
# delete the just-written .config; `make clean` keeps .config).
if ! make -C "${KERNEL_DIR}" clean; then
	echo "make clean failed" >&2
	exit 1
fi
if ! make -j"${JOBS}" -C "${KERNEL_DIR}"; then
	echo "Build failed" >&2
	exit 1
fi
# Slice 2: stale DKMS cleanup for the target ver before module install.
dkms_pre "${KERNEL_VER_EARLY}" || exit 1
if ! sudo -n make -C "${KERNEL_DIR}" modules_install; then
	echo "modules_install failed (sudo -n)" >&2
	exit 1
fi
# modules_install verification: count installed .ko (direct + sudo -n fallback).
# Warn-only here (<1000 suggests degraded install); the fail-hard health gate
# (check_initramfs_health) re-checks the same count and fails unless
# --allow-degraded-initramfs. Direct read first supports mocked runs; sudo -n
# covers root-only /lib/modules.
if ! is_safe_ver "${KERNEL_VER_EARLY}"; then
	echo "modules_install verification: refusing unsafe version: ${KERNEL_VER_EARLY}" >&2
else
	MOD_COUNT_POST=0
	if [ -d "/lib/modules/${KERNEL_VER_EARLY}" ]; then
		MOD_COUNT_POST="$(find -- "/lib/modules/${KERNEL_VER_EARLY}" -name '*.ko*' 2>/dev/null | wc -l | tr -d ' ')"
	elif [ "${HAVE_SUDO:-0}" -eq 1 ]; then
		MOD_COUNT_POST="$(sudo -n find -- "/lib/modules/${KERNEL_VER_EARLY}" -name '*.ko*' 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
	fi
	case "${MOD_COUNT_POST}" in
		''|*[!0-9]*) MOD_COUNT_POST=0 ;;
	esac
	echo "modules_install verification: ${MOD_COUNT_POST} .ko files under /lib/modules/${KERNEL_VER_EARLY}"
	if [ "${MOD_COUNT_POST}" -gt 0 ] && [ "${MOD_COUNT_POST}" -lt 1000 ]; then
		echo "WARNING: modules_install verification: count <1000 (${MOD_COUNT_POST}) suggests degraded install; health gate will flag modules<1000." >&2
	elif [ "${MOD_COUNT_POST}" -eq 0 ]; then
		echo "WARNING: modules_install verification: no .ko files found under /lib/modules/${KERNEL_VER_EARLY}; health gate will treat as degraded." >&2
	fi
fi
# Single-depmod fast path: dkms_post runs its own depmod -a after a DKMS
# rebuild, which supersedes this one (covers base + DKMS modules). When a
# rebuild is pending, defer here so only the post-DKMS depmod runs;
# otherwise run depmod now. No behavior break: at least one depmod always
# runs on success paths; failure paths abort via exit 1.
DKMS_REBUILD_PENDING=0
if command -v dkms >/dev/null 2>&1 && [ "${HAVE_SUDO:-0}" -eq 1 ] && [ "${REINSTALL_NVIDIA:-0}" -eq 1 ]; then
	if [ "${HAVE_NVIDIA_HW:-0}" -eq 1 ] || [ "${NVIDIA_MOD_LOADED:-0}" -eq 1 ]; then
		DKMS_REBUILD_PENDING=1
	fi
fi
if [ "${DKMS_REBUILD_PENDING}" -eq 1 ]; then
	echo "Deferring depmod -a ${KERNEL_VER_EARLY} after modules_install; dkms_post will depmod after DKMS rebuild (single depmod)."
else
	if ! sudo -n depmod -a "${KERNEL_VER_EARLY}" 2>&1 | tee -a "${LOG_FILE}"; then
		echo "WARNING: depmod -a ${KERNEL_VER_EARLY} failed after modules_install." >&2
	fi
fi
if ! sudo -n make -C "${KERNEL_DIR}" install; then
	echo "install failed (sudo -n)" >&2
	exit 1
fi

# Slice 2 (kept): assure boot artifacts, then rebuild + verify NVIDIA DKMS.
# ensure_boot_artifacts is warn-only by default, fatal with --strict-boot-artifacts.
KERNEL_VER="$(make -C "${KERNEL_DIR}" -s kernelrelease 2>/dev/null || echo "7.3.0-std")"
echo "Installed kernel release: ${KERNEL_VER}"
if ! verify_kernelrelease "${KERNEL_VER}"; then
	exit 1
fi
if ! ensure_boot_artifacts "${KERNEL_VER}"; then
	exit 1
fi
if ! dkms_post "${KERNEL_VER}"; then
	exit 1
fi

# Slice 3: explicit initramfs build + fail-hard health gate.
# `make install` exits 0 even on degraded images (missing btrfs/overlay,
# "bad array subscript", "No modules were added", ~36M vs hundreds of MB).
build_initramfs "${KERNEL_VER}"
if ! check_initramfs_health "${KERNEL_VER}"; then
	exit 1
fi

# Slice 3: bootloader matrix (Limine 4-candidate/add-kernel/tree+limine-update/filtered fallback/verify/rollback,
# GRUB backup/mkconfig/verify, BLS kernel-install verify + opt-in --write-bls, modeset assert). Warn-only helpers
# except modeset which is fatal only with --strict-nvidia.
update_limine "${KERNEL_VER}"
update_grub "${KERNEL_VER}"
verify_bls "${KERNEL_VER}"
if ! write_bls_entry "${KERNEL_VER}"; then
	exit 1
fi
if ! verify_modeset_wired "${KERNEL_VER}"; then
	exit 1
fi
# Slice 4: modprobe.d audit (read-only) + opt-in persistence.
audit_modprobe_modeset || true
if ! maybe_write_modprobe; then
	exit 1
fi

# Optional boot listing, gated by two keys and never in dry-run.
if [ "${PRUNE_BOOT}" -eq 1 ]; then
	echo "Listing boot entries in ${BOOT_DIR} (list only, no deletion)..."
	if [ -d "${BOOT_DIR}" ]; then
		# Scoped check: list only, never deletes.
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

echo "STD install complete. Verify with checkpatch and build."
echo "Log: ${LOG_FILE}"
