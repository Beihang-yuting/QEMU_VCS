# Makefile
#
# Native build (x86 or ARM64):  make
# Cross-compile ARM64:          make CROSS_COMPILE=aarch64-linux-gnu-
# Cross-compile ARM64:          make ARCH=arm64
# Cross-compile x86:            make ARCH=x86_64

APP_NAME=reg_display

SRC_DIR=.
OBJS_DIR=obj
BIN_DIR=bin

# Cross-compilation support:
#   Native build (x86 or ARM64):  make
#   ARM64 cross from x86:         make CROSS_COMPILE=aarch64-linux-gnu-
#   Or:                           make ARCH=arm64
#   x86 cross from ARM64:         make CROSS_COMPILE=x86_64-linux-gnu-
#   Or:                           make ARCH=x86_64
#
# ARCH auto-detection only sets CROSS_COMPILE when explicitly provided
# on the command line, so native builds on any architecture just work.
ifeq ($(origin ARCH), command line)
  ifeq ($(ARCH),arm64)
    CROSS_COMPILE ?= aarch64-linux-gnu-
  endif
  ifeq ($(ARCH),aarch64)
    CROSS_COMPILE ?= aarch64-linux-gnu-
  endif
  ifeq ($(ARCH),x86_64)
    CROSS_COMPILE ?= x86_64-linux-gnu-
  endif
endif

ifneq ($(CROSS_COMPILE),)
  CC := $(CROSS_COMPILE)gcc
endif

CFLAGS=
CPPFLAGS=-DGIT_COMMIT_HASH=\"$(shell git rev-parse --short HEAD)\"
LIBS=

EXEC=$(BIN_DIR)/$(APP_NAME)
SRC := $(wildcard $(SRC_DIR)/*.c)
OBJS=$(SRC:$(SRC_DIR)/%.c=$(OBJS_DIR)/%.o)

MKDIR_P=mkdir -p
RM_RF=rm -rf

all: $(EXEC)
	
$(EXEC): $(OBJS)
	@echo 'Building target: $@'
	@echo 'Invoking: Cross GCC Linker'
	$(MKDIR_P) $(BIN_DIR)	
	$(CC) $(CPPFLAGS) -o "$@" $(OBJS) $(LDFLAGS) $(LIBS)
	@echo 'Finished building target: $@'
	@echo ' '
	
$(OBJS_DIR)/%.o: $(SRC_DIR)/%.c
	@echo 'Building file: $<'
	@echo 'Invoking: Cross GCC Compiler'
	$(MKDIR_P) $(OBJS_DIR)
	$(CC) $(CPPFLAGS) -O0 -g3 -Wall -c -fmessage-length=0 -o "$@" "$<" $(CFLAGS)
	@echo 'Finished building: $<'
	@echo ' '

set_permissions:
	chmod +x $(EXEC)
	
clean:
	$(RM_RF) obj *~ core .depend .*.cmd *.ko *.mod.c
	$(RM_RF) Module.markers modules.order
	$(RM_RF) .tmp_versions
	$(RM_RF) Modules.symvers
	$(RM_RF) bin
