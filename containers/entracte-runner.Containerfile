FROM node:22-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    MISE_YES=1 \
    PATH="/root/.local/bin:/usr/local/bin:/usr/bin:/bin"

ARG CODEX_NPM_SPEC="@openai/codex@0.128.0"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      bash \
      build-essential \
      ca-certificates \
      curl \
      git \
      openssh-client \
      python3 \
      python3-pip \
      python3-venv \
      unzip \
      xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN curl https://mise.run | sh \
    && ln -sf /root/.local/bin/mise /usr/local/bin/mise

RUN npm install -g "${CODEX_NPM_SPEC}"

WORKDIR /workspace/entracte/elixir

CMD ["bash", "-lc", "mise trust && mise install && mise exec -- mix setup && exec mise exec -- mix symphony.start"]
