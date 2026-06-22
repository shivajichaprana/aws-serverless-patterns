# Makefile for aws-serverless-patterns
#
# Thin wrapper over scripts/deploy-all.sh (Terraform actions across patterns) and
# the pytest handler suite. Scope any Terraform target to a single pattern with
# PATTERN=<name>, e.g. `make plan PATTERN=saga`.

PYTHON  ?= python3
DEPLOY  := scripts/deploy-all.sh
PATTERN ?=

# Append "--pattern <name>" only when PATTERN is set.
PATTERN_ARG := $(if $(strip $(PATTERN)),--pattern $(PATTERN),)

.DEFAULT_GOAL := help
.PHONY: help fmt fmt-check validate plan apply destroy test-deps test lint clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

fmt: ## Format all Terraform files in place
	terraform fmt -recursive

fmt-check: ## Check Terraform formatting without writing changes
	terraform fmt -recursive -check

validate: ## terraform validate every pattern (no credentials); PATTERN=<name> to scope
	$(DEPLOY) validate $(PATTERN_ARG)

plan: ## terraform plan; PATTERN=<name> to scope
	$(DEPLOY) plan $(PATTERN_ARG)

apply: ## terraform apply -auto-approve; PATTERN=<name> to scope
	$(DEPLOY) apply $(PATTERN_ARG)

destroy: ## terraform destroy -auto-approve; PATTERN=<name> to scope
	$(DEPLOY) destroy $(PATTERN_ARG)

test-deps: ## Install Python test dependencies
	$(PYTHON) -m pip install -r tests/requirements.txt

test: ## Run the Lambda handler unit tests (moto, offline)
	$(PYTHON) -m pytest -q

lint: fmt-check ## Run all static checks (Terraform fmt check)

clean: ## Remove local Terraform and Python build artifacts
	find . -type d -name '.terraform' -prune -exec rm -rf {} +
	find . -type d -name '__pycache__' -prune -exec rm -rf {} +
	find . -type f -name '*.zip' -delete
	rm -rf .pytest_cache .mypy_cache
