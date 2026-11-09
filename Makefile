# Homelab — everyday commands. `make` lists them.
.DEFAULT_GOAL := help
SHELL := /bin/bash

help:            ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n",$$1,$$2}'

lint:            ## yamllint every YAML file
	yamllint -c .yamllint.yaml .

validate:        ## render + schema-check every app (what CI runs)
	./scripts/ci/validate.sh

conventions:     ## check THIS repo's rules (appset depth, nodeports, secretrefs, pinning)
	./scripts/ci/check-conventions.sh

check:           ## everything CI runs: lint + validate + conventions
	$(MAKE) lint && $(MAKE) validate && $(MAKE) conventions

render:          ## render one kustomize app dir: make render APP=kubernetes/apps/apps/wealthfolio
	@test -n "$(APP)" || { echo "usage: make render APP=<dir with kustomization.yaml>"; exit 2; }
	kubectl kustomize $(APP)

hooks:           ## install the pre-commit hooks (once per clone)
	pre-commit install --hook-type pre-commit --hook-type pre-push

diag:            ## run the read-only Argo diagnostic on the master and fetch it: make diag HOST=user@master-ip
	@test -n "$(HOST)" || { echo "usage: make diag HOST=sysadmin@192.168.68.63"; exit 2; }
	scp -q scripts/debug/argocd-diag.sh $(HOST):/tmp/argocd-diag.sh
	ssh -t $(HOST) 'sudo bash /tmp/argocd-diag.sh > /tmp/argocd-diag.txt 2>&1; echo "collected $$(wc -l < /tmp/argocd-diag.txt) lines"'
	scp -q $(HOST):/tmp/argocd-diag.txt debug/argocd-diag.txt
	@echo "→ debug/argocd-diag.txt  (now: git add debug/argocd-diag.txt && git commit -m 'debug: argocd diag' && git push)"

# No secrets targets since SOPS was retired (Nov 2026): secret VALUES live in OpenBao and never
# in git, so there is nothing here to encrypt, list or verify. Read or change one with the `bao`
# CLI (docs/platform/openbao.md). `make conventions` still checks that every secretKeyRef in a
# Deployment matches a key some ExternalSecret declares — key NAMES are in git on purpose.

.PHONY: help lint validate conventions check render hooks diag
