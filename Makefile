SHELL := /bin/bash

SCRIPTS := sbin/install.sh sbin/uninstall.sh bin/create-ebs-volume bin/ebs-autoscale \
           shared/utils.sh scripts/e2e.sh
SPECS := spec/*.sh

.PHONY: all
all: lint-sh test-sh

.PHONY: lint-sh
lint-sh:
	shellcheck -x $(SCRIPTS) $(SPECS)

.PHONY: test-sh
test-sh:
	shellspec

.PHONY: e2e
e2e:
	EBS_AUTOSCALE_E2E=1 bash scripts/e2e.sh

.PHONY: install
install:
	sh sbin/install.sh $(ARGS)

.PHONY: clean
clean:
	rm -rf report coverage
