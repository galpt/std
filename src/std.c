// SPDX-License-Identifier: GPL-2.0
/*
 * Smart Task Distributor (STD) routing shim.
 *
 * STD is a lightweight routing shim above the deadline class. It does
 * not introduce a new scheduling class. On wakeup it steers fair and
 * idle tasks toward housekeeping CPUs and deadline plus real-time
 * tasks toward non-housekeeping CPUs. The shim honors affinity via
 * cpumask intersection, leaves stop tasks untouched, defers
 * extensible tasks to SCX, and stays off on small systems with fewer
 * than three online CPUs. Pinned, migrate-disabled and core-scheduled
 * pass through; the core check is rq-wide and may over-skip.
 *
 * Steering is a best-effort soft hint, not a hard partition: the
 * preferred group is honored only when the task may run there,
 * otherwise the class-selected CPU is kept, and idle spreading is
 * attempted without guarantee.
 *
 * TODO(hard-50-50): strict-halves grouping is design-tracked only,
 * see docs/hard-50-50-todo.md. No logic change yet; soft hint stays.
 */
#include <linux/cpu.h>
#include <linux/cpumask_api.h>
#include <linux/init.h>
#include <linux/kernel.h>
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
 * readout and are therefore approximate.
 */
DEFINE_PER_CPU(unsigned long, std_fastpath);
DEFINE_PER_CPU(unsigned long, std_steered);
DEFINE_PER_CPU(unsigned long, std_fallback);

/*
 * Master switch for the STD shim. Enabled by default so the routing
 * is active without reboot. Writes are clamped to 0-1 via sysctl
 * minmax.
 */
int std_running = 1;

/*
 * Boot-time switch: std_running=0 disables the shim, =1 enables it.
 * Parsed early via __setup so embedded and server images share one
 * binary without rebuilds. Only plain 0 or 1 are accepted.
 */
static int __init setup_std_running(char *str)
{
	int val;

	if (!str)
		return 0;

	if (kstrtoint(str, 10, &val))
		return 0;

	if (val != 0 && val != 1)
		return 0;

	WRITE_ONCE(std_running, val);
	return 1;
}
__setup("std_running=", setup_std_running);

#ifdef CONFIG_SYSCTL
/*
 * Read-only report for kernel.std_stats. Sums the per-CPU fastpath,
 * steered and fallback counters into a dynamic-width bordered table.
 * The sums are approximate because the counters update without
 * locking. Fastpath counts wakeups already on the preferred CPU,
 * steered counts moved wakeups and fallback counts wakeups with no
 * usable preferred CPU.
 */
static int proc_std_stats(const struct ctl_table *table, int dir,
			  void *buf, size_t *lenp, loff_t *ppos)
{
	char num_fast[32], num_steer[32], num_fall[32];
	const char *h_fast = "fastpath";
	const char *h_steer = "steered";
	const char *h_fall = "fallback";
	unsigned long fastpath = 0, steered = 0, fallback = 0;
	int *widths;
	char *kbuf;
	size_t need, off = 0;
	int w0, w1, w2, i;
	int cpu;
	ssize_t ret;

	/* Reject writes; the counters are read-only. */
	if (dir)
		return -EROFS;

	for_each_possible_cpu(cpu) {
		fastpath += per_cpu(std_fastpath, cpu);
		steered += per_cpu(std_steered, cpu);
		fallback += per_cpu(std_fallback, cpu);
	}

	scnprintf(num_fast, sizeof(num_fast), "%lu", fastpath);
	scnprintf(num_steer, sizeof(num_steer), "%lu", steered);
	scnprintf(num_fall, sizeof(num_fall), "%lu", fallback);

	/* Measure widths: max(header, value) per column. */
	w0 = strlen(h_fast);
	if ((int)strlen(num_fast) > w0)
		w0 = strlen(num_fast);
	w1 = strlen(h_steer);
	if ((int)strlen(num_steer) > w1)
		w1 = strlen(num_steer);
	w2 = strlen(h_fall);
	if ((int)strlen(num_fall) > w2)
		w2 = strlen(num_fall);

	widths = kmalloc_array(3, sizeof(*widths), GFP_KERNEL);
	if (!widths)
		return -ENOMEM;
	widths[0] = w0;
	widths[1] = w1;
	widths[2] = w2;

	/* Five lines of (wsum + 11) plus trailing NUL. */
	need = (size_t)(widths[0] + widths[1] + widths[2] + 11) * 5 + 1;
	kbuf = kmalloc(need, GFP_KERNEL);
	if (!kbuf) {
		kfree(widths);
		return -ENOMEM;
	}

	/* Top border: +---+---+---+ */
	kbuf[off++] = '+';
	for (i = 0; i < widths[0] + 2; i++)
		kbuf[off++] = '-';
	kbuf[off++] = '+';
	for (i = 0; i < widths[1] + 2; i++)
		kbuf[off++] = '-';
	kbuf[off++] = '+';
	for (i = 0; i < widths[2] + 2; i++)
		kbuf[off++] = '-';
	kbuf[off++] = '+';
	kbuf[off++] = '\n';

	/* Header row. */
	off += scnprintf(kbuf + off, need - off, "| %-*s | %-*s | %-*s |\n",
			 widths[0], h_fast, widths[1], h_steer,
			 widths[2], h_fall);

	/* Middle border. */
	kbuf[off++] = '+';
	for (i = 0; i < widths[0] + 2; i++)
		kbuf[off++] = '-';
	kbuf[off++] = '+';
	for (i = 0; i < widths[1] + 2; i++)
		kbuf[off++] = '-';
	kbuf[off++] = '+';
	for (i = 0; i < widths[2] + 2; i++)
		kbuf[off++] = '-';
	kbuf[off++] = '+';
	kbuf[off++] = '\n';

	/* Value row, right-aligned. */
	off += scnprintf(kbuf + off, need - off, "| %*s | %*s | %*s |\n",
			 widths[0], num_fast, widths[1], num_steer,
			 widths[2], num_fall);

	/* Bottom border. */
	kbuf[off++] = '+';
	for (i = 0; i < widths[0] + 2; i++)
		kbuf[off++] = '-';
	kbuf[off++] = '+';
	for (i = 0; i < widths[1] + 2; i++)
		kbuf[off++] = '-';
	kbuf[off++] = '+';
	for (i = 0; i < widths[2] + 2; i++)
		kbuf[off++] = '-';
	kbuf[off++] = '+';
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
 * Expose kernel.std_running read-write and kernel.std_stats
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
 * Return an idle and active CPU shared by @a and @b, else nr_cpu_ids.
 * Scans from the lowest CPU; concurrent wakeups may collide there.
 * Accepted because steering is a soft hint and the lock-free scan
 * keeps the wakeup path cheap.
 */
static unsigned int std_pick_idle_in(const struct cpumask *a,
				     const struct cpumask *b)
{
	unsigned int cpu;

	for_each_cpu_and(cpu, a, b) {
		if (cpu_active(cpu) && available_idle_cpu(cpu))
			return cpu;
	}

	return nr_cpu_ids;
}

/*
 * Return an idle and active CPU in @task outside the housekeeping
 * mask @hk, else nr_cpu_ids. Mirrors std_pick_idle_in for deadline
 * and real-time tasks. Concurrent wakeups may collide on the lowest
 * idle CPU; accepted as a soft hint to keep the scan lock-free.
 */
static unsigned int std_pick_idle_not_hk(const struct cpumask *task,
					 const struct cpumask *hk)
{
	unsigned int cpu;

	for_each_cpu_andnot(cpu, task, hk) {
		if (cpu_active(cpu) && available_idle_cpu(cpu))
			return cpu;
	}

	return nr_cpu_ids;
}

/*
 * Pick a housekeeping CPU for fair and idle tasks. Intersect
 * housekeeping mask with p->cpus_ptr; empty intersection
 * falls back to the original CPU so taskset affinity is never broken.
 */
static int std_pick_housekeeping(struct task_struct *p, int cpu)
{
	const struct cpumask *hk;
	unsigned int dest;

	/*
	 * Without isolation all CPUs are housekeeping. Keep the
	 * original CPU to avoid useless moves on such systems.
	 */
	if (!housekeeping_enabled(HK_TYPE_DOMAIN))
		return cpu;

	hk = housekeeping_cpumask(HK_TYPE_DOMAIN);

	/* Fast path: already on a housekeeping CPU. */
	if (housekeeping_test_cpu(cpu, HK_TYPE_DOMAIN)) {
		this_cpu_inc(std_fastpath);
		return cpu;
	}

	/*
	 * Slow path: prefer an idle CPU in p->cpus_ptr and
	 * housekeeping, else spread the pick best-effort without
	 * guarantee. Fall back to the original CPU when the
	 * intersection is empty or unusable. Steering is a soft
	 * hint, never a hard partition.
	 */
	dest = std_pick_idle_in(p->cpus_ptr, hk);
	if (dest < nr_cpu_ids) {
		this_cpu_inc(std_steered);
		return dest;
	}

	dest = cpumask_any_and_distribute(p->cpus_ptr, hk);
	if (dest >= nr_cpu_ids || !cpu_active(dest)) {
		this_cpu_inc(std_fallback);
		return cpu;
	}

	this_cpu_inc(std_steered);
	return dest;
}

/*
 * Pick a non-housekeeping CPU for deadline and real-time tasks.
 * Intersect p->cpus_ptr with the complement of the housekeeping mask
 * via cpumask_and semantics. Empty intersection falls back to the
 * original CPU so affinity and single-domain systems stay safe.
 */
static int std_pick_non_housekeeping(struct task_struct *p, int cpu)
{
	const struct cpumask *hk;
	unsigned int dest;

	if (!housekeeping_enabled(HK_TYPE_DOMAIN))
		return cpu;

	hk = housekeeping_cpumask(HK_TYPE_DOMAIN);

	/* Fast path: already on a non-housekeeping CPU. */
	if (!housekeeping_test_cpu(cpu, HK_TYPE_DOMAIN)) {
		this_cpu_inc(std_fastpath);
		return cpu;
	}

	/*
	 * Slow path: prefer an idle CPU in p->cpus_ptr outside
	 * housekeeping, else spread the pick best-effort without
	 * guarantee. Fall back to the original CPU when the
	 * intersection is empty or unusable. Steering is a soft
	 * hint, never a hard partition. Uses a cpumask_any_distribute
	 * start symmetric to the fair path, wrapping to spread picks.
	 */
	dest = std_pick_idle_not_hk(p->cpus_ptr, hk);
	if (dest < nr_cpu_ids) {
		this_cpu_inc(std_steered);
		return dest;
	}

	/* No idle CPU usable: spread across p->cpus_ptr not in hk. */
	{
		unsigned int start = cpumask_any_distribute(p->cpus_ptr);
		unsigned int iter;

		if (start >= nr_cpu_ids)
			start = 0;

		for_each_cpu_andnot(iter, p->cpus_ptr, hk) {
			if (iter < start)
				continue;
			if (cpu_active(iter)) {
				this_cpu_inc(std_steered);
				return iter;
			}
		}
		for_each_cpu_andnot(iter, p->cpus_ptr, hk) {
			if (iter >= start)
				break;
			if (cpu_active(iter)) {
				this_cpu_inc(std_steered);
				return iter;
			}
		}
	}

	this_cpu_inc(std_fallback);
	return cpu;
}

/*
 * Route a wakeup to the preferred CPU group above deadline. Stop
 * tasks are never intercepted. Pinned tasks, migrate-disabled tasks
 * and core-scheduled tasks (rq-wide check, may over-skip) pass
 * through. Extensible tasks defer to the SCX dispatch queue. Small
 * systems with fewer than three online CPUs pass through to preserve
 * balance. Steering is a best-effort soft hint without guarantee.
 *
 * TODO(hard-50-50): future strict-halves enforcement would hook here
 * (deny cross-half picks where affinity allows); tracked in
 * docs/hard-50-50-todo.md. Current code keeps the soft hint only.
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
