/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Smart Task Distributor (STD) wakeup helper.
 *
 * STD looks at the CPU picked at wakeup and may move the task
 * toward idle capacity. A tiny fixed predictor votes for fair
 * tasks. Real-time tasks move only to an idle CPU. Deadline
 * tasks stay when laxity is low. Idle tasks never move. The new
 * CPU always comes from the allowed mask and the old pick is kept
 * when nothing fits. Tasks for SCX stay with SCX. Steering rests
 * on tiny systems. Counts show in a small vertical table.
 */
#ifndef _KERNEL_SCHED_STD_H
#define _KERNEL_SCHED_STD_H

#include <linux/sched.h>
#include <linux/types.h>

#define STD_HIST_LEN	64
#define STD_NN_HID	16

#ifdef CONFIG_SMART_TASK_DISTRIBUTOR
/*
 * Master switch for wakeup moves. It starts at 1 so moves apply
 * right away. A value of 0 keeps the first pick at near-zero cost.
 * Values stay within 0 and 1 through sysctl minmax and through the
 * std_running boot option which takes only plain 0 or 1.
 */
extern int std_running;
/*
 * Predictor identity and its decision mark. The identity is a
 * read-only constant. The mark is tunable through sysctl and through
 * the std_nn_thresh boot option. The s32 vote is weighed against the
 * mark and higher marks move less often.
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
