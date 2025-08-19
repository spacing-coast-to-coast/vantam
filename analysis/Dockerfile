FROM python:3.11-slim

# Prevent interactive prompts, speed up installs
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    MPLCONFIGDIR=/tmp/matplotlib

RUN apt-get update && apt-get install -y --no-install-recommends \
      libfreetype6-dev libpng-dev g++ \
    && rm -rf /var/lib/apt/lists/*

# Core analysis deps
RUN pip install --no-cache-dir pandas matplotlib

WORKDIR /work
