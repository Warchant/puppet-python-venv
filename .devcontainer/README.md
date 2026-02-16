# Puppet Module Development Container

This development container provides a complete environment for developing and testing Puppet modules.

## Features

- **Ruby 3.1.5** with Puppet 7.0
- **Development Tools**: puppet-lint, PDK, r10k, metadata-json-lint, yaml-lint
- **Pre-commit hooks** for code quality
- **Python 3** with UV package manager for additional tooling
- **VS Code extensions** for Puppet, YAML, and general development

## Getting Started

1. Open this repository in VS Code
2. When prompted, click "Reopen in Container" or run the command "Dev Containers: Reopen in Container"
3. The container will build and set up the development environment automatically
4. Pre-commit hooks will be installed during the setup process

## Available Commands

### Puppet Development
- `puppet parser validate <file>` - Validate Puppet syntax
- `puppet-lint --fix .` - Auto-fix linting issues
- `pdk validate` - Validate the entire module
- `pdk test unit` - Run unit tests
- `r10k puppetfile check` - Validate Puppetfile

### Code Quality
- `pre-commit run --all-files` - Run all pre-commit hooks
- `pre-commit run --all-files -c .pre-commit-config-puppet.yaml` - Run Puppet-specific hooks
- `metadata-json-lint metadata.json` - Validate metadata.json

### Development Workflow
1. Make your changes to Puppet manifests, templates, or other files
2. Run `puppet-lint --fix .` to auto-fix common issues
3. Run `pdk validate` to ensure module validity
4. Run `pre-commit run --all-files` to check all code quality rules
5. Commit your changes (pre-commit hooks will run automatically)

## Container Features

- **Git integration** - Pre-configured for safe directory access
- **Shell aliases** - Convenient shortcuts for common commands
- **Persistent gem cache** - Faster container rebuilds with volume mount
- **Development tools** - vim, nano, less, bash-completion

## Troubleshooting

If you encounter issues:

1. **Container won't build**: Check Docker is running and you have sufficient disk space
2. **Pre-commit issues**: Run `pre-commit clean` and `pre-commit install` manually
3. **Permission issues**: The container runs as root by default for simplicity
4. **Puppet validation fails**: Check syntax with `puppet parser validate` on individual files

## Manual Container Usage

If you prefer to use Docker directly:

```bash
# Build the container
docker build -t puppet-dev .

# Run interactively
docker run -it --rm -v .:/app -w /app puppet-dev bash

# Run pre-commit checks
docker run --rm -v .:/app -w /app puppet-dev uvx pre-commit run --all-files -c .pre-commit-config-puppet.yaml
```
