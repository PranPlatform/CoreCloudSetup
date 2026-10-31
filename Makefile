CONFIG ?= config/account.json
TEMPLATES := $(wildcard templates/*/*.yaml)

.PHONY: help lint validate deploy teardown

help: ## Show available targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

lint: ## Lint all templates with cfn-lint (pip install cfn-lint)
	cfn-lint $(TEMPLATES)
	bash -n scripts/*.sh scripts/lib/*.sh

validate: ## Validate all templates with the CloudFormation API (needs AWS credentials)
	@for t in $(TEMPLATES); do \
		echo "validating $$t"; \
		aws cloudformation validate-template --region $$(jq -r .region $(CONFIG)) \
			--template-body file://$$t >/dev/null || exit 1; \
	done

deploy: ## Deploy all stacks (STACKS="network-nat ..." to limit)
	scripts/deploy.sh $(CONFIG) $(STACKS)

teardown: ## Delete all stacks (STACKS="network-nat ..." to limit)
	scripts/teardown.sh $(CONFIG) $(STACKS)
