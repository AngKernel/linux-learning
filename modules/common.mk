# 被各模块 Makefile 在"独立调用"模式下 include（kbuild 二次解析时不会走到这里）
KSRC_ROOT ?= /home/chen/code/linux-lab/src
KVER      ?= 6.18
KDIR      ?= $(KSRC_ROOT)/linux-$(KVER)
MOD_DIR   := $(CURDIR)

.PHONY: all clean matrix
all:
	$(MAKE) -C $(KDIR) M=$(MOD_DIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(MOD_DIR) clean

# 同一份代码在所有已 checkout 的版本上编一遍。
# 编不过的地方就是内核 API 的变动点 —— 这本身就是一手素材。
# 前提：每个版本至少 make modules_prepare 过一次（kbuild.sh 会做）。
matrix:
	@for d in $(KSRC_ROOT)/linux-*; do \
		[ -f "$$d/Makefile" ] || continue; \
		log=/tmp/matrix-$$(basename $$d)-$(notdir $(MOD_DIR)).log; \
		printf '  %-24s ' "$$(basename $$d)"; \
		if $(MAKE) -s -C "$$d" M=$(MOD_DIR) modules >"$$log" 2>&1; then \
			echo "OK"; \
		else \
			echo "FAIL   -> $$log"; \
		fi; \
		$(MAKE) -s -C "$$d" M=$(MOD_DIR) clean >/dev/null 2>&1 || true; \
	done
