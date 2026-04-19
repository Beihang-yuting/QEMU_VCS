# Build eth_tap_bridge
COSIM_ROOT := $(shell realpath ..)
COMMON     := $(COSIM_ROOT)/bridge/common
ETH        := $(COSIM_ROOT)/bridge/eth

CC      ?= gcc
CFLAGS  = -std=c11 -Wall -Wextra -O2 -I$(COMMON) -I$(ETH) -D_GNU_SOURCE
LDFLAGS = -lrt -lpthread

SRCS = eth_tap_bridge.c \
       $(ETH)/eth_port.c \
       $(COMMON)/eth_shm.c \
       $(COMMON)/link_model.c

all: eth_tap_bridge

eth_tap_bridge: $(SRCS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

clean:
	rm -f eth_tap_bridge

.PHONY: all clean
