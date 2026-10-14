# Homelab — everyday commands. `make` lists them.
.DEFAULT_GOAL := help
SHELL := /bin/bash

help:            ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n",$$1,$$2}'

lint:            ## yamllint every YAML file
	yamllint -c .yamllint.yaml .

validate:        ## render + schema-check every app (what CI runs)
	./scripts/ci/validate.sh

validate-strict: ## same, but a plaintext *.enc.yaml fails
	STRICT_SECRETS=1 ./scripts/ci/validate.sh

render:          ## render one kustomize app dir: make render APP=kubernetes/apps/media/komf
	@test -n "$(APP)" || { echo "usage: make render APP=<dir with kustomization.yaml>"; exit 2; }
	kubectl kustomize $(APP)

hooks:           ## install the pre-commit hooks (once per clone)
	pre-commit install --hook-type pre-commit --hook-type pre-push

secrets-check:   ## list *.enc.yaml files that are NOT encrypted
	@for f in $$(find kubernetes -name '*.enc.yaml' 2>/dev/null); do grep -q '^sops:' $$f && echo "ok   $$f" || echo "PLAIN $$f"; done

.PHONY: help lint validate validate-strict render hooks secrets-check
