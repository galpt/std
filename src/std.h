/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Smart Task Distributor (STD) routing shim.
 *
 * STD refines wakeup placement chosen by the existing scheduler
 * classes. A tiny fixed-point predictor guides fair tasks toward
 * idle capacity; real-time tasks accept only idle destinations,
 * deadline tasks observe a laxity veto, and idle tasks stay put.
 * Candidates come from the task allowed mask, preferring a fully
 * idle core, then any idle CPU, then a spread fallback, always
 * respecting affinity with fallback to the class-selected CPU.
 * Extensible tasks remain with SCX; the core check is rq-wide and
 * may over-skip. Below three online CPUs steering stays off.
 * Counters appear as a vertical metric|value table with SI-1000 scaling.
 */
#ifndef _KERNEL_SCHED_STD_H
#define _KERNEL_SCHED_STD_H

#include <linux/sched.h>
#include <linux/types.h>

#define STD_HIST_LEN	64
#define STD_NN_HID	16

#ifdef CONFIG_SMART_TASK_DISTRIBUTOR
/*
 * Master switch: 1 steers wakeups by default, 0 retains class choices
 * at near-zero cost. Values clamp 0-1 through sysctl minmax and the
 * std_running= boot parameter accepting plain 0 or 1 alone.
 */
extern int std_running;
/*
 * Compact predictor identity (constant, read-only) beside its decision
 * threshold (tunable through sysctl and the std_nn_thresh= boot
 * parameter). The s32 predictor verdict weighs against this mark;
 * raising the mark steadies placement against migration.
 */
extern const int std_nn_version;
extern int std_nn_thresh;
int std_select_cpu(struct task_struct *p, int cpu);
int std_nn_predict(const u8 hist[STD_HIST_LEN]);
void std_tick_hist(struct task_struct *p, int cpu);
void std_init_hist(struct task_struct *p);
#else
static inline int std_select_cpu(struct task_struct *p, int cpu)
{
	return cpu;
}
#endif /* CONFIG_SMART_TASK_DISTRIBUTOR */

#endif /* _KERNEL_SCHED_STD_H */
