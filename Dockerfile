# vcfops-synth: synthetic estate, history and Day-2 content for VCF Operations.
#
#   docker build -t vcfops-synth .
#   docker run --rm -v "$PWD/config:/config" -v "$PWD/data:/data" -e VCFOPS_PASSWORD vcfops-synth plan

ARG POWERSHELL_TAG=7.5-ubuntu-24.04
FROM mcr.microsoft.com/powershell:${POWERSHELL_TAG}

ARG IMPORTEXCEL_VERSION=[7.8.0,8.0.0)
ARG VERSION=dev
ARG REVISION=unknown

LABEL org.opencontainers.image.title="vcfops-synth" \
      org.opencontainers.image.description="Synthetic estate, history and Day-2 content for VCF Operations, built from RVTools exports" \
      org.opencontainers.image.source="https://github.com/msherian/vcfops-synth" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"

# tzdata: the base image has no time zone database, and history follows the lab's local business hours.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tzdata \
 && rm -rf /var/lib/apt/lists/*

# Modules go in the all-users scope so the unprivileged runtime user can load them.
RUN pwsh -NoLogo -NoProfile -Command " \
        \$ErrorActionPreference = 'Stop'; \
        Install-PSResource -Name ImportExcel -Version '${IMPORTEXCEL_VERSION}' -Scope AllUsers -TrustRepository -Quiet" \
 && groupadd --system synth \
 && useradd --system --gid synth --home-dir /home/synth --create-home synth \
 && mkdir -p /config /data \
 && chown synth:synth /config /data

WORKDIR /opt/vcfops-synth
COPY src ./src
COPY bin ./bin
COPY config/lab.example.json ./config/lab.example.json

ENV VCFOPS_SYNTH_CONFIG=/config/lab.json \
    POWERSHELL_TELEMETRY_OPTOUT=1 \
    POWERSHELL_UPDATECHECK=Off

USER synth
VOLUME ["/config", "/data"]
ENTRYPOINT ["pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-File", "/opt/vcfops-synth/bin/vcfops-synth.ps1"]
CMD ["help"]
