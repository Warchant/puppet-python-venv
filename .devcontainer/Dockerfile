# version from the gen3 device
FROM ruby:3.1.5

# Set working directory
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates
RUN curl -LsSf https://astral.sh/uv/install.sh | sh


# install gems
RUN gem install puppet --version '~> 7.0' && \
    gem install puppet-lint && \
    gem install puppetlabs_spec_helper && \
    gem install metadata-json-lint && \
    gem install yaml-lint && \
    gem install hiera-eyaml && \
    gem install r10k && \
    gem install pdk


# Configure git (needed for pre-commit hooks)
RUN git config --global --add safe.directory /app


# run pre-commit puppet:

# docker build -t tezt .
# docker run -it --rm -v .:/app -w /app tezt bash
# uvx pre-commit run --all-files -c .pre-commit-config-puppet.yaml
