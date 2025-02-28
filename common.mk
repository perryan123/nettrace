LIBBPF		?= /usr/include/bpf
COMPONENT	:= $(ROOT)/component
COMMON_SHARED	:= $(ROOT)/shared/pkt_utils.c $(COMPONENT)/net_utils.c	\
		   $(COMPONENT)/arg_parse.c $(COMPONENT)/sys_utils.c	\
		   $(ROOT)/shared/bpf_utils.c

CFLAGS		+= -I./ -I$(ROOT)/shared/bpf/
BPF_CFLAGS	= $(CFLAGS) -I$(LIBBPF) -Wno-unused-function
HOST_CFLAGS	= \
		-lbpf -lelf -lz -g -O2 -static $(CFLAGS) \
		-Wno-deprecated-declarations \
		-I$(ROOT)/shared/ -I$(ROOT)/component

REMOTE_ROOT	:= https://raw.githubusercontent.com/xmmgithub/nettrace-eBPF/master/
export REMOTE_ROOT

include $(ROOT)/script/arch.mk

HEADERS		:= $(if $(KERNEL),$(KERNEL),/lib/modules/$(shell uname -r)/build/)
NOSTDINC_FLAGS	+= -nostdinc -isystem $(shell $(CC) -print-file-name=include)
export HEADERS

USERINCLUDE	:= \
		-I$(HEADERS)/arch/$(SRCARCH)/include/uapi \
		-I$(HEADERS)/arch/$(SRCARCH)/include/generated/uapi \
		-I$(HEADERS)/include/uapi \
		-I$(HEADERS)/include/generated/uapi \
		-include $(HEADERS)/include/linux/kconfig.h

LINUXINCLUDE	:= \
		-I$(HEADERS)/arch/$(SRCARCH)/include \
		-I$(HEADERS)/arch/$(SRCARCH)/include/generated \
		-I$(HEADERS)/include \
		$(USERINCLUDE)

KERNEL_CFLAGS	+= $(NOSTDINC_FLAGS) $(LINUXINCLUDE) \
		-D__KERNEL__ -D__ASM_SYSREG_H -Wno-unused-value -Wno-pointer-sign \
		-Wno-compare-distinct-pointer-types \
		-Wno-gnu-variable-sized-type-not-at-end \
		-Wno-address-of-packed-member -Wno-tautological-compare \
		-Wno-unknown-warning-option -Wno-frame-address

cmd_download	= @if [ ! -f $(1) ]; then wget -O $(1) $(REMOTE_ROOT)/$(2); fi

ifdef KERN_VER
	CFLAGS		+= -DKERN_VER=$(KERN_VER)
endif

ifdef COMPAT
ifeq ($(wildcard $(HEADERS)),)
$(error kernel headers not exist in COMPAT mdoe, please install it)
endif
	kheaders_cmd	:= ln -s vmlinux_header.h kheaders.h
	CFLAGS		+= -DCOMPAT_MODE
	BPF_CFLAGS	+= $(KERNEL_CFLAGS)
else
	kheaders_cmd	:= ln -s ../shared/bpf/vmlinux.h kheaders.h
endif

ifndef BPFTOOL
ifneq ("$(shell bpftool gen help 2>&1 | grep skeleton)","")
	BPFTOOL		:= bpftool
else
	BPFTOOL		:= $(ROOT)/script/bpftool
endif
endif

kheaders.h:
	$(call kheaders_cmd)

progs/%.o: progs/%.c $(BPF_EXTRA_DEP)
	clang -O2 -c -g -S -Wall -Wno-pointer-sign -Wno-unused-value	\
	-Wno-incompatible-pointer-types-discards-qualifiers		\
	-fno-asynchronous-unwind-tables					\
	$< -emit-llvm -Wno-unknown-attributes $(BPF_CFLAGS) -Xclang	\
	-disable-llvm-passes -o - | 					\
	opt -O2 -mtriple=bpf-pc-linux | 				\
	llvm-dis |							\
	llc -march=bpf -filetype=obj -o $@
	@file $@ | grep debug_info > /dev/null || (rm $@ && exit 1)

%.skel.h: %.o
	$(BPFTOOL) gen skeleton $< $(SKEL_FLAGS) > $@

$(bpf_progs): %: %.skel.h
	@:

bpf: $(bpf_progs) $(bpf_progs_ext)

$(progs): %: %.c bpf
	@if [ -n "$(prog-$@)" ]; then				\
		echo gcc $(prog-$@) -o $@ $(HOST_CFLAGS);	\
		gcc $(prog-$@) -o $@ $(HOST_CFLAGS);		\
	else							\
		echo gcc $< -o $@ $(HOST_CFLAGS);		\
		gcc $< -o $@ $(HOST_CFLAGS);			\
	fi
