// SPDX-License-Identifier: GPL-2.0
/*
 * Smart Task Distributor (STD) routing shim.
 *
 * STD adjusts the CPU selected at wakeup toward idle capacity.
 * A tiny fixed-point predictor guides fair movement; real-time
 * movement requires an idle destination, deadline movement
 * observes a laxity veto, and idle tasks remain in place.
 * Affinity derives from mask intersection, falling back to the
 * class-selected CPU. Stop tasks stay untouched, extensible
 * tasks remain with SCX, and steering pauses below three online
 * CPUs. Pinned, migrate-disabled and core-scheduled tasks pass
 * through; the core check is rq-wide and may over-skip.
 * Scanning prefers a fully idle core, then any idle CPU, then
 * a spread fallback without auxiliary masks, using integer
 * arithmetic alone on the wakeup path.
 */
#include <linux/cpu.h>
#include <linux/cpumask_api.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/percpu.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/sysctl.h>

#include "sched.h"
#include "std.h"

/*
 * Per-CPU routing tallies. Counting locally keeps wakeup accounting
 * scalable; totals summed at readout remain approximate. Fastpath
 * tallies wakeups staying on the current CPU, steered tallies
 * relocations, and fallback tallies wakeups retaining the caller
 * choice for want of a usable destination. nn_keep and nn_migrate
 * tally predictor keep and migrate verdicts, while split_core
 * tallies placements sharing a core with a busy sibling.
 */
DEFINE_PER_CPU(unsigned long, std_fastpath);
DEFINE_PER_CPU(unsigned long, std_steered);
DEFINE_PER_CPU(unsigned long, std_fallback);
DEFINE_PER_CPU(unsigned long, std_nn_keep);
DEFINE_PER_CPU(unsigned long, std_nn_migrate);
DEFINE_PER_CPU(unsigned long, std_split_core);

/*
 * Predictor identity, read-only. Revision advances whenever weights,
 * shapes or threshold meaning shift placement behavior.
 */
const int std_nn_version = 1;

/*
 * Predictor threshold, tunable. Output above this s32 mark requests
 * migration; output at or below requests retention. Raising the
 * mark steadies placement. Default zero balances the deterministic
 * weights around a neutral midpoint.
 */
int std_nn_thresh;

/*
 * Master switch for STD steering. Active by default, so placement
 * refinement starts immediately. Writes clamp to 0-1 through
 * sysctl minmax: 1 steers wakeups, 0 retains class choices
 * at near-zero cost.
 */
int std_running = 1;

/*
 * Boot-time switch: std_running= assigns the initial steering state,
 * 0 retaining class choices and 1 refining them. Parsed early via
 * __setup, letting one image serve embedded and server targets.
 * Only plain 0 or 1 parses; other spellings leave the default.
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
 * Boot-time threshold: std_nn_thresh=<s32>. Parsed early via __setup
 * as plain base-10; malformed or out-of-range input leaves
 * the built-in default in place.
 */
static int __init setup_std_nn_thresh(char *str)
{
	int val;

	if (!str)
		return 0;

	if (kstrtoint(str, 10, &val))
		return 0;

	WRITE_ONCE(std_nn_thresh, val);
	return 1;
}
__setup("std_nn_thresh=", setup_std_nn_thresh);

/*
 * Deterministic s8 weights for the compact 64->16->1 predictor.
 * Closed-form patterns generate each coefficient on demand, sparing
 * a kilobyte table while holding zero mean within s8 range.
 * Evaluation uses integer addition and multiplication alone, in
 * preallocated state and non-sleeping context on wakeup.
 */
static inline s8 std_nn_w1(int h, int i)
{
	return (s8)(((h * 31 + i * 17 + 11) % 25) - 12);
}

static inline s8 std_nn_b1(int h)
{
	return (s8)(((h * 13 + 7) % 17) - 8);
}

static inline s8 std_nn_w2(int h)
{
	return (s8)(((h * 19 + 3) % 15) - 7);
}

/*
 * Compact predictor: 64 u8 history entries feed 16 hidden s32 units
 * through ReLU into one s32 verdict weighed against std_nn_thresh,
 * requesting migration when positive and retention otherwise, built from
 * integer addition and multiplication in preallocated non-sleeping context.
 */
int std_nn_predict(const u8 hist[STD_HIST_LEN])
{
	int h, i;
	s32 out = 0;

	for (h = 0; h < STD_NN_HID; h++) {
		s32 acc = (s32)std_nn_b1(h);

		for (i = 0; i < STD_HIST_LEN; i++)
			acc += (s32)hist[i] * (s32)std_nn_w1(h, i);
		if (acc < 0)
			acc = 0;
		out += acc * (s32)std_nn_w2(h);
	}

	return out > READ_ONCE(std_nn_thresh);
}

/*
 * Append the current CPU to the per-task history ring. Retains the
 * recent STD_HIST_LEN wake CPUs as u8 entries beside a u8 cursor.
 * Sampling follows prediction, so the ring carries past placements
 * alone into the next verdict.
 */
void std_tick_hist(struct task_struct *p, int cpu)
{
	u8 idx = (u8)(p->std_tick % STD_HIST_LEN);

	p->std_hist[idx] = (u8)(cpu & 0xff);
	p->std_tick++;
}

/*
 * Reset per-task history at fork. Invoked from __sched_fork, giving
 * newborn tasks and the boot idle task a zeroed ring.
 */
void std_init_hist(struct task_struct *p)
{
	memset(p->std_hist, 0, sizeof(p->std_hist));
	p->std_tick = 0;
}

/*
 * Render @val with SI-1000 suffixes ""/K/M/B/T/P/E, where B denotes
 * billions (1e9 under table convention, not power-of-two). The helper
 * runs in non-sleeping readout context. Zero renders as "0"; values
 * below 1000 render literally, larger magnitudes shrink by repeated
 * 64-bit division until compact, showing one decimal while scaled
 * below 10 (remainder over 100) and integers otherwise, entirely
 * with integer arithmetic and never on the wakeup path.
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
		rem = scaled % 1000;
		scaled /= 1000;
		unit++;
	}

	if (scaled < 10)
		scnprintf(buf, sz, "%llu.%llu%s",
			  scaled, rem / 100, units[unit]);
	else
		scnprintf(buf, sz, "%llu%s", scaled, units[unit]);
}

#ifdef CONFIG_SYSCTL
#define STD_NR_STATS	7
/*
 * Read-only readout behind kernel.std_stats. Per-CPU fastpath, steered,
 * fallback, nn_keep, nn_migrate and split_core sums join const
 * nn_version inside a bordered vertical metric|value table sized
 * to content, one row per metric ordered as fastpath, steered,
 * fallback, nn_keep, nn_migrate, split_core, nn_version. Totals
 * stay approximate without global ordering; std_format_scaled
 * shapes values for legibility without touching wakeup.
 */
static int proc_std_stats(const struct ctl_table *table, int dir,
			  void *buf, size_t *lenp, loff_t *ppos)
{
	static const char * const metrics[] = {
		"fastpath", "steered", "fallback", "nn_keep",
		"nn_migrate", "split_core", "nn_version"
	};
	static const char * const hdr_metric = "metric";
	static const char * const hdr_value = "value";
	char scaled[STD_NR_STATS][32];
	unsigned long sums[STD_NR_STATS] = { 0 };
	size_t w0, w1, wsum;
	char *kbuf;
	size_t need, off = 0;
	int i, cpu;
	ssize_t ret;

	/* Reject writes; the counters are read-only. */
	if (dir)
		return -EROFS;

	for_each_possible_cpu(cpu) {
		sums[0] += per_cpu(std_fastpath, cpu);
		sums[1] += per_cpu(std_steered, cpu);
		sums[2] += per_cpu(std_fallback, cpu);
		sums[3] += per_cpu(std_nn_keep, cpu);
		sums[4] += per_cpu(std_nn_migrate, cpu);
		sums[5] += per_cpu(std_split_core, cpu);
	}
	sums[6] = (unsigned long)READ_ONCE(std_nn_version);

	/* Format all values first, then size columns. */
	for (i = 0; i < STD_NR_STATS; i++)
		std_format_scaled(sums[i], scaled[i], sizeof(scaled[i]));

	w0 = strlen(hdr_metric);
	w1 = strlen(hdr_value);
	for (i = 0; i < STD_NR_STATS; i++) {
		size_t mlen = strlen(metrics[i]);
		size_t vlen = strlen(scaled[i]);

		if (mlen > w0)
			w0 = mlen;
		if (vlen > w1)
			w1 = vlen;
	}
	wsum = w0 + w1;

	/* Top + header + middle + rows + bottom plus NUL. */
	need = (wsum + 8) * (STD_NR_STATS + 4) + 1;
	kbuf = kmalloc(need, GFP_KERNEL);
	if (!kbuf)
		return -ENOMEM;

	/* Top border: +---+---+ */
	kbuf[off++] = '+';
	for (i = 0; i < (int)w0 + 2; i++)
		kbuf[off++] = '-';
	kbuf[off++] = '+';
	for (i = 0; i < (int)w1 + 2; i++)
		kbuf[off++] = '-';
	kbuf[off++] = '+';
	kbuf[off++] = '\n';

	/* Header row, left-aligned. */
	off += scnprintf(kbuf + off, need - off, "| %-*s | %-*s |\n",
			 (int)w0, hdr_metric, (int)w1, hdr_value);

	/* Middle border. */
	kbuf[off++] = '+';
	for (i = 0; i < (int)w0 + 2; i++)
		kbuf[off++] = '-';
	kbuf[off++] = '+';
	for (i = 0; i < (int)w1 + 2; i++)
		kbuf[off++] = '-';
	kbuf[off++] = '+';
	kbuf[off++] = '\n';

	/* Value rows in metric order. */
	for (i = 0; i < STD_NR_STATS; i++)
		off += scnprintf(kbuf + off, need - off, "| %-*s | %*s |\n",
				 (int)w0, metrics[i], (int)w1, scaled[i]);

	/* Bottom border. */
	kbuf[off++] = '+';
	for (i = 0; i < (int)w0 + 2; i++)
		kbuf[off++] = '-';
	kbuf[off++] = '+';
	for (i = 0; i < (int)w1 + 2; i++)
		kbuf[off++] = '-';
	kbuf[off++] = '+';
	kbuf[off++] = '\n';

	ret = memory_read_from_buffer(buf, *lenp, ppos, kbuf, off);
	kfree(kbuf);
	if (ret < 0)
		return ret;
	*lenp = ret;
	return 0;
}

/*
 * Publish kernel.std_running (0-1) and kernel.std_nn_thresh as
 * writable controls with kernel.std_stats as a read-only vertical
 * table, clamping the switch with minmax for defense in depth.
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
		.procname	= "std_nn_thresh",
		.data		= &std_nn_thresh,
		.maxlen		= sizeof(int),
		.mode		= 0644,
		.proc_handler	= proc_dointvec,
	},
	{
		.procname	= "std_stats",
		.mode		= 0444,
		.proc_handler	= proc_std_stats,
	},
};

/*
 * Register STD controls late, keeping kernel.std_running visible to
 * startup scripts and tuners after boot through the init variant
 * recording table name and size for validation.
 */
static int __init std_sysctl_init(void)
{
	register_sysctl_init("kernel", std_sysctls);
	return 0;
}
late_initcall(std_sysctl_init);
#endif /* CONFIG_SYSCTL */

/*
 * Test whether @cpu shares its core with a busy sibling. A live
 * non-idle sibling marks the candidate as core-splitting. Sibling
 * lookup prefers cpu_smt_mask under CONFIG_SCHED_SMT, otherwise
 * topology_sibling_cpumask, skipping NULL defensively while a
 * singleton mask passes trivially. Offline siblings stay ignored
 * rather than vetoing, within non-sleeping preallocated context.
 */
static bool std_cpu_splits_core(int cpu)
{
	const struct cpumask *smt;
	int sib;

#ifdef CONFIG_SCHED_SMT
	smt = cpu_smt_mask(cpu);
#else
	smt = topology_sibling_cpumask(cpu);
#endif
	if (!smt)
		return false;
	for_each_cpu(sib, smt) {
		if (sib == cpu)
			continue;
		if (!cpu_active(sib))
			continue;
		if (!available_idle_cpu(sib))
			return true;
	}
	return false;
}

/*
 * Scan the task allowed mask toward whole-core idleness. Tier one
 * prefers a fully idle core with every active sibling idle through
 * cpu_smt_mask or topology_sibling_cpumask, skipping NULL while a
 * singleton passes trivially and offline siblings stay ignored
 * rather than vetoing. Tier two accepts any active idle CPU in the
 * mask; tier three spreads via cpumask_any_distribute then linear
 * search, reusing caller masks alone. Absent an active allowed CPU,
 * return nr_cpu_ids, checking cpu_active and available_idle_cpu
 * with integer logic in preallocated non-sleeping context.
 */
static unsigned int std_pick_opportunistic(struct task_struct *p, int cpu)
{
	unsigned int c, sib;

	(void)cpu;
	/* Tier 1: whole idle core first (all siblings idle). */
	for_each_cpu(c, p->cpus_ptr) {
		const struct cpumask *smt;
		bool all_idle = true;

		if (c >= nr_cpu_ids || !cpu_active(c) ||
		    !available_idle_cpu(c))
			continue;
#ifdef CONFIG_SCHED_SMT
		smt = cpu_smt_mask(c);
#else
		smt = topology_sibling_cpumask(c);
#endif
		/* Defensive NULL skip; a singleton mask trivially passes. */
		if (!smt)
			continue;
		for_each_cpu(sib, smt) {
			if (sib == c)
				continue;
			/* Offline siblings never run: ignore, not a veto. */
			if (!cpu_active(sib))
				continue;
			if (!available_idle_cpu(sib)) {
				all_idle = false;
				break;
			}
		}
		if (all_idle)
			return c;
	}
	/* Without CONFIG_SCHED_SMT the tier-1 mask is a singleton, so tier 1 */
	/* trivially matches every active idle CPU and collapses to tier 2.    */
	/* Tier 2: any active idle CPU in the mask. */
	for_each_cpu(c, p->cpus_ptr) {
		if (c < nr_cpu_ids && cpu_active(c) &&
		    available_idle_cpu(c))
			return c;
	}

	c = cpumask_any_distribute(p->cpus_ptr);
	if (c < nr_cpu_ids && cpu_active(c))
		return c;
	for_each_cpu(c, p->cpus_ptr) {
		if (c < nr_cpu_ids && cpu_active(c))
			return c;
	}

	return nr_cpu_ids;
}

/*
 * Laxity veto for deadline tasks. Remaining laxity below the margin
 * forbids migration, computed as deadline minus now minus runtime
 * from a racy runqueue clock whose staleness only retains placement.
 * Non-positive runtime or elapsed deadline likewise retains; the
 * margin is two milliseconds expressed in nanoseconds.
 */
static bool std_dl_veto(struct task_struct *p, int cpu)
{
	u64 now = cpu_rq(cpu)->clock;
	s64 lax;

	if ((s64)p->dl.runtime <= 0)
		return true;
	if (p->dl.deadline <= now)
		return true;
	lax = (s64)(p->dl.deadline - now) - p->dl.runtime;
	return lax < 2000000LL;
}

/*
 * Steer a wakeup toward idle capacity with a compact predictor.
 *
 * Guards progress in code order: std_running, small-system pause
 * below three online CPUs, stop, pinned single-CPU tasks, migrating
 * tasks, rq-wide core check that may over-skip, then extensible
 * tasks remaining with SCX. Past the guards, deadline tasks respect
 * a laxity veto before consulting the predictor; real-time tasks
 * accept only idle destinations; fair tasks consult the predictor;
 * idle tasks remain in place. Predictor verdicts tally through
 * nn_keep and nn_migrate, placements through fastpath, steered and
 * fallback, and core-sharing picks through split_core. History
 * advances after prediction, preserving past placements alone,
 * using integer arithmetic in preallocated non-sleeping context.
 */
int std_select_cpu(struct task_struct *p, int cpu)
{
	unsigned int dest;
	bool want_migrate;

	if (!READ_ONCE(std_running))
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

	/* Idle tasks never migrate. */
	if (idle_policy(p->policy)) {
		this_cpu_inc(std_fastpath);
		return cpu;
	}

	/* Deadline tasks honor a laxity veto, else follow the predictor. */
	if (task_has_dl_policy(p)) {
		if (std_dl_veto(p, cpu)) {
			this_cpu_inc(std_fallback);
			return cpu;
		}
		want_migrate = std_nn_predict(p->std_hist);
		if (want_migrate)
			this_cpu_inc(std_nn_migrate);
		else
			this_cpu_inc(std_nn_keep);
		std_tick_hist(p, cpu);
		if (!want_migrate) {
			this_cpu_inc(std_fastpath);
			return cpu;
		}
		dest = std_pick_opportunistic(p, cpu);
		if (dest >= nr_cpu_ids || !cpu_active(dest)) {
			this_cpu_inc(std_fallback);
			return cpu;
		}
		if (std_cpu_splits_core((int)dest))
			this_cpu_inc(std_split_core);
		if ((int)dest == cpu) {
			this_cpu_inc(std_fastpath);
			return cpu;
		}
		this_cpu_inc(std_steered);
		return (int)dest;
	}

	/* RT tasks move only to an idle destination. */
	if (task_has_rt_policy(p)) {
		want_migrate = std_nn_predict(p->std_hist);
		if (want_migrate)
			this_cpu_inc(std_nn_migrate);
		else
			this_cpu_inc(std_nn_keep);
		std_tick_hist(p, cpu);
		if (!want_migrate) {
			this_cpu_inc(std_fastpath);
			return cpu;
		}
		dest = std_pick_opportunistic(p, cpu);
		if (dest >= nr_cpu_ids || !cpu_active(dest) ||
		    !available_idle_cpu(dest)) {
			this_cpu_inc(std_fallback);
			return cpu;
		}
		if (std_cpu_splits_core((int)dest))
			this_cpu_inc(std_split_core);
		if ((int)dest == cpu) {
			this_cpu_inc(std_fastpath);
			return cpu;
		}
		this_cpu_inc(std_steered);
		return (int)dest;
	}

	/* Fair tasks follow the predictor opportunistically. */
	if (fair_policy(p->policy)) {
		want_migrate = std_nn_predict(p->std_hist);
		if (want_migrate)
			this_cpu_inc(std_nn_migrate);
		else
			this_cpu_inc(std_nn_keep);
		std_tick_hist(p, cpu);
		if (!want_migrate) {
			this_cpu_inc(std_fastpath);
			return cpu;
		}
		dest = std_pick_opportunistic(p, cpu);
		if (dest >= nr_cpu_ids || !cpu_active(dest)) {
			this_cpu_inc(std_fallback);
			return cpu;
		}
		if (std_cpu_splits_core((int)dest))
			this_cpu_inc(std_split_core);
		if ((int)dest == cpu) {
			this_cpu_inc(std_fastpath);
			return cpu;
		}
		this_cpu_inc(std_steered);
		return (int)dest;
	}

	return cpu;
}
