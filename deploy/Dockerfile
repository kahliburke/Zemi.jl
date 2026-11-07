# A knowledge base's shared service (zemi --shared) as a container image, beside install.sh: Julia,
# the package with its environment and the site's compiled, and MuPDF's mutool. compose.yaml runs it
# with Qdrant, Ollama and Caddy. From the checkout:
#
#   docker build -f deploy/Dockerfile -t zemi .
#
# The config, the data and Julia's later installs are volumes (see compose.yaml). Agents are not in
# it: an image built FROM this one installs the group's own for the zemi user.
FROM ubuntu:26.04

ARG JULIA_VERSION=1.13.3
ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends ca-certificates curl git openssl socat mupdf-tools poppler-utils >/dev/null \
 && rm -rf /var/lib/apt/lists/*
RUN set -e; \
    case "$TARGETARCH" in amd64) dir=x64 arch=x86_64 ;; arm64) dir=aarch64 arch=aarch64 ;; \
        *) echo "No Julia for $TARGETARCH" >&2; exit 1 ;; esac; \
    file=julia-$JULIA_VERSION-linux-$arch.tar.gz; \
    curl -fsSLO https://julialang-s3.julialang.org/bin/linux/$dir/${JULIA_VERSION%.*}/$file; \
    curl -fsSL https://julialang-s3.julialang.org/bin/checksums/julia-$JULIA_VERSION.sha256 | grep " $file\$" | sha256sum -c --quiet; \
    tar -xzf $file -C /opt; rm $file; \
    ln -s /opt/julia-$JULIA_VERSION/bin/julia /usr/local/bin/julia

# The service's user, with a fixed id so files mounted from the host can be made its own. The folders
# compose.yaml mounts volumes on are made here, so the volumes start out the user's.
RUN useradd --uid 10001 --create-home --home-dir /srv/zemi --shell /usr/sbin/nologin zemi \
 && install -d -o zemi -g zemi /opt/julia-depot /srv/zemi/.julia /srv/zemi/.config /srv/zemi/.config/zemi \
        /srv/zemi/data /srv/zemi/caddy
COPY --chown=zemi:zemi . /srv/zemi/Zemi.jl
USER zemi
WORKDIR /srv/zemi/Zemi.jl

# The packages and their compiled code, the site's too, in a depot of the image's own.
RUN JULIA_DEPOT_PATH=/opt/julia-depot julia -e 'using Pkg; Pkg.Registry.add("General")' \
 && JULIA_DEPOT_PATH=/opt/julia-depot julia --project=app -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()' \
 && JULIA_DEPOT_PATH=/opt/julia-depot julia --project=docs -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'

# What the service installs later goes in the depot on its volume, before the image's.
ENV JULIA_DEPOT_PATH=/srv/zemi/.julia:/opt/julia-depot: \
    ZEMI_CONFIG=/srv/zemi/.config/zemi/config.toml \
    ZEMI_REVISE=0 \
    PATH=/srv/zemi/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# The entrypoint makes the mounted config folder the user's, then runs as that user.
USER root
ENTRYPOINT ["/srv/zemi/Zemi.jl/deploy/docker-entrypoint.sh"]
