# SELinux policy module build for tillandsias in-VM services.
#
# Usage (inside the Fedora 44 WSL2 instance):
#   make
# Or to build one module:
#   make tillandsias_headless.pp
#
# Requires: dnf install selinux-policy-devel checkpolicy

MODULES  = tillandsias_headless tillandsias_vault
SHAREDIR = /usr/share/selinux/devel

.PHONY: all clean

all: $(addsuffix .pp,$(MODULES))

%.pp: %.te %.fc
	$(MAKE) -f $(SHAREDIR)/Makefile $@

clean:
	rm -f *.pp *.mod *.tmp
