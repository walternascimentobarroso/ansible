FROM python:3.13-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-client \
    && pip install --no-cache-dir ansible proxmoxer requests \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /ansible