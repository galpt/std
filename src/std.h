/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Smart Task Distributor (STD) routing shim.
 *
 * STD sits above the deadline class and steers wakeup placement
 * without adding a new scheduling class. Fair tasks prefer
 * housekeeping CPUs while deadline and real-time tasks prefer
 * non-housekeeping CPUs. The shim respects affinity and stays
 * off on small systems.
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
