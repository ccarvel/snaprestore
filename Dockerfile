FROM debian:bookworm-slim

ARG DOCTL_VERSION=1.110.0
ARG GUM_VERSION=0.14.3

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash curl jq ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# doctl
RUN curl -fsSL \
    "https://github.com/digitalocean/doctl/releases/download/v${DOCTL_VERSION}/doctl-${DOCTL_VERSION}-linux-amd64.tar.gz" \
    | tar -xz -C /usr/local/bin/

# gum
RUN curl -fsSLO \
    "https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/gum_${GUM_VERSION}_amd64.deb" && \
    dpkg -i "gum_${GUM_VERSION}_amd64.deb" && \
    rm "gum_${GUM_VERSION}_amd64.deb"

ENV TERM=xterm-256color

WORKDIR /app
ENTRYPOINT ["bash"]
