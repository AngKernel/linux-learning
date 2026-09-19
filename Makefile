# 顶层：把命令转发给 modules/ 下每个模块
KSRC_ROOT ?= /home/chen/code/linux-lab/src
KVER      ?= 6.18
export KSRC_ROOT KVER

MODULES := $(wildcard modules/*/Makefile)
MODDIRS := $(patsubst %/Makefile,%,$(MODULES))

.PHONY: all clean matrix list
all clean matrix:
	@for m in $(MODDIRS); do \
		echo "--- $$m ($@)"; \
		$(MAKE) --no-print-directory -C $$m $@ || exit 1; \
	done

list:
	@echo "模块: $(MODDIRS)"
	@echo "内核: $(wildcard $(KSRC_ROOT)/linux-*)"
