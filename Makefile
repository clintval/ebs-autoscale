SHELL := /bin/bash

SCRIPTS := install.sh uninstall.sh bin/create-ebs-volume bin/ebs-autoscale \
           shared/utils.sh service/systemd/install.sh service/systemd/uninstall.sh
SPECS := spec/*.sh

.PHONY: all
all: lint-sh test-sh

.PHONY: lint-sh
lint-sh:
	shellcheck -x $(SCRIPTS) $(SPECS)

.PHONY: test-sh
test-sh:
	shellspec

.PHONY: install
install:
	sh install.sh $(ARGS)

.PHONY: clean
clean:
	rm -rf report coverage
