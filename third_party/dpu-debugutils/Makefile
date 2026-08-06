SUBDIRS := pcie_debug reg_display
INSTALL_DIR := /usr/local/bin

.PHONY: all $(SUBDIRS) install clean

all: $(SUBDIRS)

$(SUBDIRS):
	@$(MAKE) -s -C $@

install: all
	@install -d $(INSTALL_DIR)
	@for d in $(SUBDIRS); do						\
		install -m 755 $$d/bin/* $(INSTALL_DIR);	\
		echo "Installed $$d to $(INSTALL_DIR)"; \
	done

clean:
	@for d in $(SUBDIRS); do		\
		$(MAKE) -s -C $$d clean;	\
	done
