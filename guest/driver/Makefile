# cosim_nic kernel module -- cross-compile against Guest kernel headers
#
# Usage:
#   make KDIR=/path/to/kernel/build
#   make KDIR=/path/to/kernel/build CROSS_COMPILE=x86_64-linux-gnu-

obj-m := cosim_nic.o

KDIR  ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

.PHONY: all clean
