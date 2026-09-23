.PHONY: help
help: ## Show this help.
	@awk 'BEGIN {FS = ":.*##[[:space:]]*"} \
	  /^[[:alnum:]_-]+:.*##/ {printf "  %-24s %s\n", $$1, $$2}' \
	  $(MAKEFILE_LIST)

.PHONY: check
check: ## Run linters and static checks.
	@./tests/check_all.sh

.PHONY: test
test: ## Run test suites.
	@./tests/test_all.sh
