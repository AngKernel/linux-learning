// SPDX-License-Identifier: GPL-2.0
/* 最小模块：验证工具链和 $KDIR 配好了 */
#include <linux/module.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/utsname.h>

static char *who = "world";
module_param(who, charp, 0444);
MODULE_PARM_DESC(who, "跟谁打招呼");

static int __init hello_init(void)
{
	pr_info("hello: 你好, %s (内核 %s)\n", who, init_utsname()->release);
	return 0;
}

static void __exit hello_exit(void)
{
	pr_info("hello: 再见\n");
}

module_init(hello_init);
module_exit(hello_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("hello world");
