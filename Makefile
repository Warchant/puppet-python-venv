.PHONY: help
help:
	@echo "Available targets:"
	@echo "  deps         - Install Ruby dependencies via bundle install"
	@echo "  test         - Run unit tests with PDK"
	@echo "  lint         - Run puppet-lint with auto-fix"
	@echo "  validate     - Validate module with PDK"
	@echo "  clean        - Clean PDK cache and temporary files"
	@echo "  pre-commit   - Run pre-commit hooks on all files"
	@echo "  deps-legacy  - Install gems globally (legacy method)"

.PHONY: check
check: lint validate test


.PHONY: test
test:
	pdk test unit --puppet-version=7

.PHONY: deps
deps:
	bundle install

.PHONY: deps-legacy
deps-legacy:
	gem install puppet --version '~> 7.0' && \
	gem install puppet-lint && \
	gem install puppetlabs_spec_helper && \
	gem install metadata-json-lint && \
	gem install yaml-lint && \
	gem install hiera-eyaml && \
	gem install r10k && \
	gem install pdk

.PHONY: lint
lint:
	bundle exec puppet-lint --fix --no-autoloader_layout-check lib/

.PHONY: validate
validate:
	pdk validate --puppet-version=7 -a

.PHONY: clean
clean:
	pdk clean

.PHONY: pre-commit
pre-commit:
	pre-commit run --all-files

.PHONY: pre-commit-puppet
pre-commit-puppet:
	pre-commit run --all-files -c .pre-commit-config-puppet.yaml
