/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Smart Task Distributor (STD) routing shim.
 *
 * Steers wakeup placement above the deadline class with no new
 * scheduling class. Fair and idle tasks prefer housekeeping CPUs
 * while deadline and real-time tasks prefer non-housekeeping CPUs
 * with Cake-style deficit sharing. Per-task flows are hashed into a
 * per-CPU 1024-entry 8-way table and charged quantums derived from
 * base_quantum_ns with per-tin shifts. Cross-group picks are denied
 * only when an in-group allowed CPU exists, otherwise the original
 * CPU is kept. Affinity is honored with fallback to the
 * class-selected CPU. Extensible tasks defer to SCX; core check is
 * rq-wide and may over-skip. Small systems with fewer than three
 * online CPUs stay off. Without HK_TYPE_DOMAIN isolation all CPUs
 * are housekeeping and the class CPU is kept.
 */
#ifndef _KERNEL_SCHED_STD_H
#define _KERNEL_SCHED_STD_H

#include <linux/sched.h>

/* Flow table geometry: 128 sets x 8 ways = 1024 flows. */
#define STD_FLOWS	1024
#define STD_WAYS	8
#define STD_SETS	(STD_FLOWS / STD_WAYS)

/* Cap for per-flow deficit credits (bounds growth, shifts only). */
#define STD_HOST_LOAD_MAX	1000000UL

/* Max traffic identifiers (indexes std_div_shift[8]). */
#define STD_TIN_MAX	8

/*
 * Cake-style traffic identifiers. SPARSE covers fair/idle wakeups,
 * BULK covers deadline/real-time wakeups; IMMINENT/HIGH are urgent
 * DL/RT subsets that bypass enforcement to avoid starvation. SPARE
 * tins are reserved for future classes and use larger shifts.
 */
enum std_tin {
	STD_TIN_IDLE		= 0,
	STD_TIN_FAIR		= 1,
	STD_TIN_DL		= 2,
	STD_TIN_RT		= 3,
	STD_TIN_DL_IMMINENT	= 4,
	STD_TIN_RT_HIGH		= 5,
	STD_TIN_SPARE6		= 6,
	STD_TIN_SPARE7		= 7,
};

#ifdef CONFIG_SMART_TASK_DISTRIBUTOR
/*
 * Master switch: 1 enables deficit enforcement (default), 0 disables
 * steering (near-zero cost). Clamped 0-1 via sysctl minmax and
 * std_running= boot param (plain 0 or 1 only).
 */
extern int std_running;
int std_select_cpu(struct task_struct *p, int cpu);
#else
static inline int std_select_cpu(struct task_struct *p, int cpu)
{
	return cpu;
}
#endif /* CONFIG_SMART_TASK_DISTRIBUTOR */

#endif /* _KERNEL_SCHED_STD_H */
