SHELL := /bin/bash

SCRIPTS := sbin/install.sh sbin/uninstall.sh bin/create-ebs-volume bin/ebs-autoscale \
           shared/utils.sh
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
	sh sbin/install.sh $(ARGS)

.PHONY: clean
clean:
	rm -rf report coverage
