#!/bin/sh
# Container entry point: runs the CLI with the arguments given to docker run.
# ssh stops with "No user exists for uid" when docker run --user picks a uid the image
# has no passwd entry for, so such a uid gets one through nss_wrapper, with /tmp as home.
if ! getent passwd "$(id -u)" >/dev/null 2>&1; then
    cp /etc/passwd /tmp/passwd
    echo "synth-user:x:$(id -u):$(id -g):vcfops-synth:/tmp:/usr/sbin/nologin" >> /tmp/passwd
    export LD_PRELOAD=libnss_wrapper.so NSS_WRAPPER_PASSWD=/tmp/passwd NSS_WRAPPER_GROUP=/etc/group HOME=/tmp
fi
exec pwsh -NoLogo -NoProfile -NonInteractive -File /opt/vcfops-synth/bin/vcfops-synth.ps1 "$@"
