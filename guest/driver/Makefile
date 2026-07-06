# cosim_nic kernel module -- cross-compile against Guest kernel headers
#
# Usage:
#   make KDIR=/path/to/kernel/build
#   make KDIR=/path/to/kernel/build CROSS_COMPILE=x86_64-linux-gnu-

obj-m := cosim_nic.o

# Disable the GCC latent_entropy plugin for this TU: it ICEs (get_random_const)
# with gcc13 against kernel 6.6 headers when CONFIG_GCC_PLUGIN_LATENT_ENTROPY=y
# (e.g. Alpine linux-virt). Empty/no-op when the plugin is not enabled.
ccflags-y += $(DISABLE_LATENT_ENTROPY_PLUGIN)

KDIR  ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

.PHONY: all clean
