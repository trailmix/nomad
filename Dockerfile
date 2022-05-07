# syntax=docker/dockerfile:1.4

ARG NOMAD_VERSION=1.3.0-rc.1
ARG ALPINE_VERSION=3.15
ARG GO_VERSION=1.17.9
ARG ROOTLESSKIT_VERSION=0.14.6

# helpers for buildkit, see xx- things
FROM --platform=$BUILDPLATFORM tonistiigi/xx@sha256:1e96844fadaa2f9aea021b2b05299bc02fe4c39a92d8e735b93e8e2b15610128 AS xx

# an alpine with git
FROM --platform=$BUILDPLATFORM alpine:${ALPINE_VERSION} AS git
RUN apk add --no-cache git

# base golang container
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine${ALPINE_VERSION} AS golatest

# add clang and ldd for cgo gcc building
FROM golatest as gobuild-base
RUN apk add --no-cache file bash clang lld pkgconfig git make
COPY --link --from=xx / /

# pull down the nomad source
FROM git AS nomad-src
ARG NOMAD_VERSION
RUN git clone https://github.com/hashicorp/nomad.git nomad \
  && cd nomad && git checkout -q v$NOMAD_VERSION

# set up dependencies
FROM gobuild-base AS nomad-base
WORKDIR /go/src/github.com/hashicorp/nomad
ARG TARGETPLATFORM
RUN set -e; xx-apk add musl-dev gcc linux-headers; \
  [ "$(xx-info arch)" != "ppc64le" ] || XX_CC_PREFER_LINKER=ld xx-clang --setup-target-triple
RUN --mount=from=nomad-src,src=/nomad,target=. \
  --mount=target=/root/.cache,type=cache \
  --mount=target=/go/pkg/mod,type=cache \
    make deps

# set up ldflags and version
FROM nomad-base AS nomad-version
ARG NOMAD_VERSION
RUN --mount=from=nomad-src,src=/nomad/,target=. \
  PKG=github.com/hashicorp/nomad; \
  GIT_COMMIT=$(git rev-parse HEAD); \
  [ "$(git status --porcelain)" != "" ] && GIT_DIRTY=+CHANGES; \
  echo "-s -w -X ${PKG}/version.Name=nomad -X ${PKG}/version.GitDescribe=${NOMAD_VERSION%-*} -X github.com/hashicorp/nomad/version.GitCommit=${GIT_COMMIT}${GIT_DIRTY}" | tee /tmp/.ldflags; \
  echo -n "${NOMAD_VERSION}" | tee /tmp/.version;

# build binary
FROM nomad-base AS nomad
WORKDIR /go/src/github.com/hashicorp/nomad
ARG TARGETPLATFORM
RUN --mount=target=. \
  --mount=target=/root/.cache,type=cache \
  --mount=from=nomad-src,src=/nomad/,target=. \
  --mount=target=/go/pkg/mod,type=cache \
  --mount=source=/tmp/.ldflags,target=/tmp/.ldflags,from=nomad-version \
    CGO_ENABLED=1 xx-go build -trimpath -ldflags "$(cat /tmp/.ldflags)" -tags 'ui' -o /usr/bin/nomad \
    && xx-verify /usr/bin/nomad

# pull down the rootlesskit source and build
FROM gobuild-base AS rootlesskit
ARG ROOTLESSKIT_VERSION
RUN git clone https://github.com/rootless-containers/rootlesskit.git /go/src/github.com/rootless-containers/rootlesskit
WORKDIR /go/src/github.com/rootless-containers/rootlesskit
ARG TARGETPLATFORM
RUN --mount=target=/root/.cache,type=cache \
  --mount=target=/go/pkg/mod,type=cache \
    git checkout -q "v$ROOTLESSKIT_VERSION" \
    && CGO_ENABLED=0 xx-go build -o /usr/bin/rootlesskit ./cmd/rootlesskit \
    && xx-verify --static /usr/bin/rootlesskit

# finally grab alpine and prepare it for rootlesskit
FROM alpine:${ALPINE_VERSION}
RUN adduser -D -u 1000 user \
  && mkdir -p /run/user/1000 /home/user/.local/tmp /home/user/.local/share/nomad \
  && chown -R user /run/user/1000 /home/user \
  && echo user:100000:65536 | tee /etc/subuid | tee /etc/subgid
COPY --link --from=rootlesskit /usr/bin/rootlesskit /usr/bin/
COPY --link --from=nomad /usr/bin/nomad /usr/bin/
USER 1000:1000
ENV HOME /home/user
ENV USER user
ENV XDG_RUNTIME_DIR=/run/user/1000
ENV TMPDIR=/home/user/.local/tmp
VOLUME /home/user/.local/share/nomad
ENTRYPOINT ["/usr/bin/nomad"]