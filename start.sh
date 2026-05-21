# 1. Update and install standard base compilation packages + runtime elements
apk add --no-cache \                                            build-base \
    python3 \                                                   python3-dev \
    libffi-dev \                                                openssl-dev \
    git \
    openssh-client \
    gnupg
