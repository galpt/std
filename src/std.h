/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Smart Task Distributor (STD) routing shim.
 *
 * STD sits above the deadline class and steers wakeup placement
 * without adding a new scheduling class. Fair and idle tasks prefer
 * housekeeping CPUs while deadline and real-time tasks prefer
 * non-housekeeping CPUs. Steering is a best-effort soft hint, never
 * a hard partition: spreading is attempted without guarantee.
 * Affinity is honored with fallback to the class-selected CPU.
 * Extensible tasks defer to SCX; core check is rq-wide and may
 * over-skip. Small systems stay off.
 *
 * TODO(hard-50-50): strict-halves grouping is design-tracked only,
 * see docs/hard-50-50-todo.md. No logic change yet; soft hint stays.
 */
#ifndef _KERNEL_SCHED_STD_H
#define _KERNEL_SCHED_STD_H

#include <linux/sched.h>

#ifdef CONFIG_SMART_TASK_DISTRIBUTOR
extern int std_running;
int std_select_cpu(struct task_struct *p, int cpu);
#else
static inline int std_select_cpu(struct task_struct *p, int cpu)
{
	return cpu;
}
#endif /* CONFIG_SMART_TASK_DISTRIBUTOR */

#endif /* _KERNEL_SCHED_STD_H */
