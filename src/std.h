/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Smart Task Distributor (STD) routing shim.
 *
 * Fair/Idle-only shim above the deadline class with no new
 * scheduling class. Fair and idle tasks prefer housekeeping CPUs
 * with SMT-aware idle selection; deadline and real-time tasks pass
 * through to the class-selected (SIS) CPU with no counters.
 * Deny cross-group only when an in-group allowed CPU
 * exists, otherwise the original CPU is kept. Affinity is honored
 * with fallback to the class-selected CPU. Extensible tasks defer
 * to SCX; core check is rq-wide and may over-skip. Small systems
 * with fewer than three online CPUs stay off. Without
 * HK_TYPE_DOMAIN isolation all CPUs are housekeeping and the class
 * CPU is kept. LLC tier removed (SIS-deference); stats are a
 * vertical 2-column metric|value table.
 */
#ifndef _KERNEL_SCHED_STD_H
#define _KERNEL_SCHED_STD_H

#include <linux/sched.h>

#ifdef CONFIG_SMART_TASK_DISTRIBUTOR
/*
 * Master switch: 1 enables steering (default), 0 disables
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
