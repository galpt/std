// SPDX-License-Identifier: GPL-2.0
/*
 * Smart Task Distributor (STD) routing shim.
 *
 * Lightweight routing shim above the deadline class with no new
 * scheduling class. On wakeup it steers fair and idle tasks toward
 * housekeeping CPUs and deadline plus real-time tasks toward
 * non-housekeeping CPUs using SMT-aware idle selection. Affinity
 * is honored via cpumask intersection with fallback to the
 * class-selected CPU. Stop tasks are never intercepted, extensible
 * tasks defer to SCX, and the shim stays off on small systems with
 * fewer than three online CPUs. Pinned, migrate-disabled and
 * core-scheduled tasks pass through; the core check is rq-wide and
 * may over-skip. Without HK_TYPE_DOMAIN isolation all CPUs are
 * housekeeping, so the class-selected CPU is kept.
 */
#include <linux/cpu.h>
#include <linux/cpumask_api.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/math64.h>
#include <linux/percpu.h>
#include <linux/sched/isolation.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/sysctl.h>

#include "sched.h"
#include "std.h"

/*
 * Per-CPU routing statistics. Per-CPU counters keep the wakeup path
 * free of global atomics and allocations; totals are summed on
 * readout and are therefore approximate. Fastpath counts wakeups
 * already on the preferred CPU, steered counts moved wakeups and
 * fallback counts wakeups with no usable preferred CPU.
 */
DEFINE_PER_CPU(unsigned long, std_fastpath);
DEFINE_PER_CPU(unsigned long, std_steered);
DEFINE_PER_CPU(unsigned long, std_fallback);

/*
 * Master switch for the STD shim. Enabled by default so steering
 * is active without reboot. Writes are clamped 0-1 via
 * sysctl minmax: 1 enables steering, 0 disables steering
 * (near-zero cost).
 */
int std_running = 1;

/*
 * Boot-time switch: std_running=0 disables the shim, =1 enables
 * steering. Parsed early via __setup so embedded and server
 * images share one binary without rebuilds. Only plain 0 or 1 is
 * accepted (strict; no <bool> synonyms).
 */
static int __init setup_std_running(char *str)
{
	int val;

	if (!str)
		return 0;

	if (kstrtoint(str, 10, &val))
		return 0;

	if (val < 0 || val > 1)
		return 0;

	WRITE_ONCE(std_running, val);
	return 1;
}
__setup("std_running=", setup_std_running);

/*
 * Format @val with SI-1000 suffixes ""/K/M/B/T/P/E (B is billions,
 * 1e9, kept per table spec, not GiB/G). Pure helper with
 * no locking or allocation. Zero formats as "0"; values below 1000
 * format raw; larger values divide iteratively with do_div until the
 * scaled value fits, then print with one decimal when the scaled
 * value is below 10 (integer remainder over 100) else as an integer.
 * No floating point is used. Readout only; never on the fast path.
 */
static void std_format_scaled(u64 val, char *buf, size_t sz)
{
	static const char * const units[] = {
		"", "K", "M", "B", "T", "P", "E"
	};
	unsigned int unit = 0;
	u64 scaled = val;
	u64 rem = 0;

	if (!buf || !sz)
		return;

	if (val < 1000) {
		scnprintf(buf, sz, "%llu", val);
		return;
	}

	while (scaled >= 1000 && unit < ARRAY_SIZE(units) - 1) {
		rem = do_div(scaled, 1000);
		unit++;
	}

	if (scaled < 10)
		scnprintf(buf, sz, "%llu.%llu%s",
			  scaled, rem / 100, units[unit]);
	else
		scnprintf(buf, sz, "%llu%s", scaled, units[unit]);
}

#ifdef CONFIG_SYSCTL
#define STD_NR_STATS	3
/*
 * Read-only report for kernel.std_stats. Sums the per-CPU fastpath,
 * steered and fallback counters into a dynamic-width bordered
 * table. The sums are approximate because the counters update without
 * locking. Fastpath counts wakeups already on the preferred CPU,
 * steered counts moved wakeups and fallback counts wakeups with no
 * usable preferred CPU. Values are scaled with std_format_scaled
 * for readability (do_div only here).
 */
static int proc_std_stats(const struct ctl_table *table, int dir,
			  void *buf, size_t *lenp, loff_t *ppos)
{
	static const char * const headers[] = {
		"fastpath", "steered", "fallback"
	};
	char scaled[STD_NR_STATS][32];
	unsigned long sums[STD_NR_STATS] = { 0 };
	int *widths;
	char *kbuf;
	size_t need, off = 0;
	size_t wsum = 0;
	int i, c;
	int cpu;
	ssize_t ret;

	/* Reject writes; the counters are read-only. */
	if (dir)
		return -EROFS;

	for_each_possible_cpu(cpu) {
		sums[0] += per_cpu(std_fastpath, cpu);
		sums[1] += per_cpu(std_steered, cpu);
		sums[2] += per_cpu(std_fallback, cpu);
	}

	/* Format all values first, then size columns. */
	for (i = 0; i < STD_NR_STATS; i++)
		std_format_scaled(sums[i], scaled[i], sizeof(scaled[i]));

	widths = kmalloc_array(STD_NR_STATS, sizeof(*widths), GFP_KERNEL);
	if (!widths)
		return -ENOMEM;
	for (i = 0; i < STD_NR_STATS; i++) {
		size_t hlen = strlen(headers[i]);
		size_t vlen = strlen(scaled[i]);

		widths[i] = hlen > vlen ? hlen : vlen;
		wsum += widths[i];
	}

	/* Five lines of (wsum + cols*3 + 2) plus trailing NUL. */
	need = (wsum + STD_NR_STATS * 3 + 2) * 5 + 1;
	kbuf = kmalloc(need, GFP_KERNEL);
	if (!kbuf) {
		kfree(widths);
		return -ENOMEM;
	}

	/* Top border: +---+---+...+ */
	kbuf[off++] = '+';
	for (c = 0; c < STD_NR_STATS; c++) {
		for (i = 0; i < widths[c] + 2; i++)
			kbuf[off++] = '-';
		kbuf[off++] = '+';
	}
	kbuf[off++] = '\n';

	/* Header row, left-aligned. */
	for (c = 0; c < STD_NR_STATS; c++)
		off += scnprintf(kbuf + off, need - off, "| %-*s ",
				 widths[c], headers[c]);
	off += scnprintf(kbuf + off, need - off, "|\n");

	/* Middle border. */
	kbuf[off++] = '+';
	for (c = 0; c < STD_NR_STATS; c++) {
		for (i = 0; i < widths[c] + 2; i++)
			kbuf[off++] = '-';
		kbuf[off++] = '+';
	}
	kbuf[off++] = '\n';

	/* Value row, right-aligned scaled values. */
	for (c = 0; c < STD_NR_STATS; c++)
		off += scnprintf(kbuf + off, need - off, "| %*s ",
				 widths[c], scaled[c]);
	off += scnprintf(kbuf + off, need - off, "|\n");

	/* Bottom border. */
	kbuf[off++] = '+';
	for (c = 0; c < STD_NR_STATS; c++) {
		for (i = 0; i < widths[c] + 2; i++)
			kbuf[off++] = '-';
		kbuf[off++] = '+';
	}
	kbuf[off++] = '\n';

	ret = memory_read_from_buffer(buf, *lenp, ppos, kbuf, off);
	kfree(kbuf);
	kfree(widths);
	if (ret < 0)
		return ret;
	*lenp = ret;
	return 0;
}

/*
 * Expose kernel.std_running read-write (0-1) and kernel.std_stats
 * read-only. The running value is clamped with minmax as defense
 * in depth.
 */
static const struct ctl_table std_sysctls[] = {
	{
		.procname	= "std_running",
		.data		= &std_running,
		.maxlen		= sizeof(int),
		.mode		= 0644,
		.proc_handler	= proc_dointvec_minmax,
		.extra1		= SYSCTL_ZERO,
		.extra2		= SYSCTL_ONE,
	},
	{
		.procname	= "std_stats",
		.mode		= 0444,
		.proc_handler	= proc_std_stats,
	},
};

/*
 * Register STD sysctls late so init scripts and tuning tools see
 * kernel.std_running after boot. Uses the init variant that records
 * the table name and size for validation.
 */
static int __init std_sysctl_init(void)
{
	register_sysctl_init("kernel", std_sysctls);
	return 0;
}
late_initcall(std_sysctl_init);
#endif /* CONFIG_SYSCTL */

/*
 * SMT-aware rank within the preferred group: scan idle CPUs in
 * tiers to preserve locality while avoiding SMT and LLC contention,
 * then spread to avoid piling on the lowest CPU (HK via
 * cpumask_any_and_distribute, non-HK via distribute-like wraparound
 * scan from a cpumask_any_distribute start with no temp mask/alloc).
 * Tiers: (1) fully-idle core first (all SMT siblings idle)
 * via cpu_smt_mask (CONFIG_SCHED_SMT) with topology_sibling_cpumask
 * fallback (NULL is defensively skipped; a singleton mask trivially
 * passes), (2) LLC-different idle first anchored at the class-selected
 * CPU via cpus_share_cache (CONFIG_SMP; cpu_llc_shared_mask is the x86
 * equivalent, see ifdef below; on a single-LLC system no
 * LLC-different CPU exists, so this tier is a no-op falling through
 * to tier 3), (3) any active idle CPU in the group.
 * Returns nr_cpu_ids when no active allowed CPU exists in the group.
 * Keeps housekeeping mask, cpu_active, available_idle_cpu and nr_cpu_ids
 * fallback; no alloc, lock, float or do_div.
 */
static unsigned int std_rank(const struct cpumask *task,
			     const struct cpumask *hk, bool want_hk,
			     int anchor)
{
	unsigned int cpu, sib;
	bool anchor_valid;

	anchor_valid = anchor >= 0 && (unsigned int)anchor < nr_cpu_ids;

	/* Tier 1: fully-idle core first (all siblings idle). */
	if (want_hk) {
		for_each_cpu_and(cpu, task, hk) {
			const struct cpumask *smt;
			bool all_idle = true;

			if (!cpu_active(cpu) ||
			    !available_idle_cpu(cpu))
				continue;
#ifdef CONFIG_SCHED_SMT
			smt = cpu_smt_mask(cpu);
#else
			smt = topology_sibling_cpumask(cpu);
#endif
			/* Defensive NULL skip; a singleton mask trivially passes. */
			if (!smt)
				continue;
			for_each_cpu(sib, smt) {
				if (sib == cpu)
					continue;
				/* Offline siblings never run: ignore, do not veto. */
				if (!cpu_active(sib))
					continue;
				if (!available_idle_cpu(sib)) {
					all_idle = false;
					break;
				}
			}
			if (all_idle)
				return cpu;
		}
	} else {
		for_each_cpu_andnot(cpu, task, hk) {
			const struct cpumask *smt;
			bool all_idle = true;

			if (!cpu_active(cpu) ||
			    !available_idle_cpu(cpu))
				continue;
#ifdef CONFIG_SCHED_SMT
			smt = cpu_smt_mask(cpu);
#else
			smt = topology_sibling_cpumask(cpu);
#endif
			/* Defensive NULL skip; a singleton mask trivially passes. */
			if (!smt)
				continue;
			for_each_cpu(sib, smt) {
				if (sib == cpu)
					continue;
				/* Offline siblings never run: ignore, do not veto. */
				if (!cpu_active(sib))
					continue;
				if (!available_idle_cpu(sib)) {
					all_idle = false;
					break;
				}
			}
			if (all_idle)
				return cpu;
		}
	}
	/* Without CONFIG_SCHED_SMT the tier-1 mask is topology_sibling_cpumask; */
	/* on non-SMT builds that mask is a singleton, so tier 1 trivially     */
	/* matches every active idle CPU and collapses to the tier-3 scan.     */
#ifdef CONFIG_SMP
	/* Tier 2: LLC-different idle first, anchored at the class */
	/* CPU to spread cache pressure. Generic test is           */
	/* !cpus_share_cache(cpu, anchor). On a single-LLC system  */
	/* no LLC-different CPU exists, so this tier is a no-op    */
	/* falling through to tier 3.                              */
	if (anchor_valid) {
		if (want_hk) {
			for_each_cpu_and(cpu, task, hk) {
				if (!cpu_active(cpu) ||
				    !available_idle_cpu(cpu))
					continue;
#ifdef cpu_llc_shared_mask
				if (!cpumask_test_cpu(cpu,
						      cpu_llc_shared_mask(anchor)))
					return cpu;
#else
				if (!cpus_share_cache(cpu, anchor))
					return cpu;
#endif
			}
		} else {
			for_each_cpu_andnot(cpu, task, hk) {
				if (!cpu_active(cpu) ||
				    !available_idle_cpu(cpu))
					continue;
#ifdef cpu_llc_shared_mask
				if (!cpumask_test_cpu(cpu,
						      cpu_llc_shared_mask(anchor)))
					return cpu;
#else
				if (!cpus_share_cache(cpu, anchor))
					return cpu;
#endif
			}
		}
	}
#endif
	/* Tier 3: any active idle CPU in the group. */
	if (want_hk) {
		for_each_cpu_and(cpu, task, hk) {
			if (cpu_active(cpu) &&
			    available_idle_cpu(cpu))
				return cpu;
		}
	} else {
		for_each_cpu_andnot(cpu, task, hk) {
			if (cpu_active(cpu) &&
			    available_idle_cpu(cpu))
				return cpu;
		}
	}

	if (want_hk) {
		cpu = cpumask_any_and_distribute(task, hk);
		if (cpu < nr_cpu_ids && cpu_active(cpu))
			return cpu;
		for_each_cpu_and(cpu, task, hk) {
			if (cpu_active(cpu))
				return cpu;
		}
	} else {
		/*
		 * Non-HK spread without a temp mask or alloc. Seed a rotating
		 * start with cpumask_any_distribute, then linear-scan the group
		 * with wraparound; cpu_active-gated with nr_cpu_ids fallback.
		 */
		unsigned int start = cpumask_any_distribute(task);

		if (start >= nr_cpu_ids) {
			for_each_cpu_andnot(cpu, task, hk) {
				if (cpu_active(cpu))
					return cpu;
			}
		} else {
			for_each_cpu_andnot(cpu, task, hk) {
				if (cpu < start)
					continue;
				if (cpu_active(cpu))
					return cpu;
			}
			for_each_cpu_andnot(cpu, task, hk) {
				if (cpu >= start)
					break;
				if (cpu_active(cpu))
					return cpu;
			}
		}
	}

	return nr_cpu_ids;
}

/*
 * Pick a housekeeping CPU for fair and idle tasks. Denies the
 * cross-group CPU only when an active in-group allowed CPU exists;
 * otherwise falls back to the original CPU. Uses SMT-aware ranking;
 * fast path stays in-group. No allocation, lock, float or do_div.
 */
static int std_pick_housekeeping(struct task_struct *p, int cpu)
{
	/* Groups follow the housekeeping mask, which already encodes
	 * isolcpus and nohz_full intent and reads lock-free here.
	 */
	const struct cpumask *hk = housekeeping_cpumask(HK_TYPE_DOMAIN);
	unsigned int dest;
	unsigned int iter;
	bool has_in_group = false;

	/* Fast path: already in-group. */
	if (housekeeping_test_cpu(cpu, HK_TYPE_DOMAIN)) {
		this_cpu_inc(std_fastpath);
		return cpu;
	}

	for_each_cpu_and(iter, p->cpus_ptr, hk) {
		if (cpu_active(iter)) {
			has_in_group = true;
			break;
		}
	}
	if (!has_in_group) {
		this_cpu_inc(std_fallback);
		return cpu;
	}

	dest = std_rank(p->cpus_ptr, hk, true, cpu);
	if (dest >= nr_cpu_ids || !cpu_active(dest)) {
		this_cpu_inc(std_fallback);
		return cpu;
	}
	if ((int)dest == cpu)
		this_cpu_inc(std_fastpath);
	else
		this_cpu_inc(std_steered);
	return dest;
}

/*
 * Pick a non-housekeeping CPU for deadline and real-time tasks.
 * Denies cross-group only when an active allowed CPU outside
 * housekeeping exists; else fallback. Uses SMT-aware ranking;
 * fast path stays out-of-group. No allocation, lock, float
 * or do_div.
 */
static int std_pick_non_housekeeping(struct task_struct *p, int cpu)
{
	/* Groups follow the housekeeping mask, which already encodes
	 * isolcpus and nohz_full intent and reads lock-free here.
	 */
	const struct cpumask *hk = housekeeping_cpumask(HK_TYPE_DOMAIN);
	unsigned int dest;
	unsigned int iter;
	bool has_out_group = false;

	/* Fast path: already outside housekeeping. */
	if (!housekeeping_test_cpu(cpu, HK_TYPE_DOMAIN)) {
		this_cpu_inc(std_fastpath);
		return cpu;
	}

	for_each_cpu_andnot(iter, p->cpus_ptr, hk) {
		if (cpu_active(iter)) {
			has_out_group = true;
			break;
		}
	}
	if (!has_out_group) {
		this_cpu_inc(std_fallback);
		return cpu;
	}

	dest = std_rank(p->cpus_ptr, hk, false, cpu);
	if (dest >= nr_cpu_ids || !cpu_active(dest)) {
		this_cpu_inc(std_fallback);
		return cpu;
	}
	if ((int)dest == cpu)
		this_cpu_inc(std_fastpath);
	else
		this_cpu_inc(std_steered);
	return dest;
}

/*
 * Route a wakeup to the preferred CPU group above deadline. Stop
 * tasks are never intercepted. Pinned tasks, migrate-disabled tasks
 * and core-scheduled tasks (rq-wide check, may over-skip) pass
 * through. Extensible tasks defer to the SCX dispatch queue. Small
 * systems with fewer than three online CPUs pass through. Deadline
 * and real-time tasks prefer non-housekeeping CPUs with SMT-aware
 * selection; fair and idle tasks prefer housekeeping CPUs with
 * SMT-aware selection. Cross-group picks are denied only when an
 * in-group allowed CPU exists, otherwise the class CPU is kept.
 */
int std_select_cpu(struct task_struct *p, int cpu)
{
	if (!READ_ONCE(std_running))
		return cpu;

	/* Fast bail when no isolation: all CPUs are housekeeping. */
	if (!housekeeping_enabled(HK_TYPE_DOMAIN))
		return cpu;

	/* Stay off on 1-2 CPU systems for safe bringup. */
	if (num_online_cpus() < 3)
		return cpu;

	/* Never intercept the stop class. */
	if (p->sched_class == &stop_sched_class)
		return cpu;

	/* Pinned tasks have nowhere else to run. */
	if (p->nr_cpus_allowed == 1)
		return cpu;

	/* Migrating tasks pass through. */
	if (is_migration_disabled(p))
		return cpu;

	/*
	 * Core check is rq-wide and may over-skip: tasks on a core-scheduled
	 * runqueue must stay together. Peek at the destination runqueue:
	 * select_task_rq runs with the task pi_lock held, so this is a
	 * benign racy read that only ever skips steering.
	 */
	if (sched_core_enabled(cpu_rq(cpu)))
		return cpu;

#ifdef CONFIG_SCHED_CLASS_EXT
	/* Extensible tasks defer to the SCX dispatch queue. */
	if (p->sched_class == &ext_sched_class)
		return cpu;
#endif

	/* Deadline and real-time tasks prefer non-housekeeping CPUs. */
	if (task_has_dl_policy(p) || task_has_rt_policy(p))
		return std_pick_non_housekeeping(p, cpu);

	/* Fair and idle tasks prefer housekeeping CPUs. */
	if (fair_policy(p->policy) || idle_policy(p->policy))
		return std_pick_housekeeping(p, cpu);

	return cpu;
}
