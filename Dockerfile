FROM node:24-bookworm-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends bash ca-certificates git ripgrep \
  && rm -rf /var/lib/apt/lists/* /var/cache/apt/*

# Pinned. --ignore-scripts: no install-time code runs.
RUN npm install -g --ignore-scripts --omit=dev @earendil-works/pi-coding-agent@1.4.0 \
  && npm cache clean --force

WORKDIR /workspace
ENTRYPOINT ["pi"]
