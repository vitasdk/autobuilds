ARG BASE_IMAGE=vitasdk/vitasdk:latest
FROM ${BASE_IMAGE}

ARG USER=vitasdk
ENV HOME=/home/$USER

# Install sudo and create a non-root development user
RUN apk add --no-cache sudo && \
    adduser -D -u 1000 $USER && \
    echo "$USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/$USER && \
    chmod 0440 /etc/sudoers.d/$USER && \
    chown -R $USER:$USER /usr/local/vitasdk /workspace

USER $USER
WORKDIR $HOME

CMD ["/bin/bash"]
