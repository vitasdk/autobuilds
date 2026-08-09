FROM alpine:latest

# Install build tools and runtime dependencies for Vita homebrew development
RUN apk add --no-cache \
    bash \
    curl \
    wget \
    tar \
    xz \
    bzip2 \
    gzip \
    make \
    cmake \
    ninja \
    pkgconf \
    git \
    python3 \
    py3-pip \
    fakeroot \
    libarchive-tools \
    file

ARG TARGETARCH

# Copy release inputs and install the matching host bootstrap archive
COPY inputs/ /tmp/inputs/

RUN set -eu; \
    if [ "$TARGETARCH" = "amd64" ]; then \
        TRIPLET="x86_64-linux-gnu"; \
    elif [ "$TARGETARCH" = "arm64" ]; then \
        TRIPLET="aarch64-linux-gnu"; \
    else \
        echo "Unsupported architecture: $TARGETARCH" >&2; \
        exit 1; \
    fi; \
    mkdir -p /usr/local/vitasdk; \
    tar -xjf "/tmp/inputs/vitasdk-bootstrap-${TRIPLET}.tar.bz2" -C /usr/local/vitasdk; \
    rm -rf /tmp/inputs

ENV VITASDK=/usr/local/vitasdk
ENV PATH=$VITASDK/bin:$PATH

WORKDIR /workspace

CMD ["/bin/bash"]
