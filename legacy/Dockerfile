FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:1 \
    VNC_PORT=5901 \
    NOVNC_PORT=6080 \
    VNC_RESOLUTION=1280x800 \
    VNC_DEPTH=24 \
    USER=debianuser \
    HOME=/home/debianuser

# Установка пакетов
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Среда рабочего стола XFCE (лёгкая)
    xfce4 \
    xfce4-goodies \
    xfce4-terminal \
    # VNC сервер
    tigervnc-standalone-server \
    tigervnc-common \
    # noVNC (доступ через браузер)
    novnc \
    websockify \
    # Утилиты
    dbus-x11 \
    x11-utils \
    x11-xserver-utils \
    sudo \
    curl \
    wget \
    nano \
    vim \
    git \
    htop \
    firefox-esr \
    fonts-liberation \
    fonts-dejavu \
    locales \
    procps \
    net-tools \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Настройка локали
RUN echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# Создание пользователя (без root)
# Пароль для входа не задаётся: доступ к sudo - через NOPASSWD ниже
RUN useradd -m -s /bin/bash ${USER} \
    && usermod -aG sudo ${USER} \
    && echo "${USER} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Настройка VNC (пароль создаётся при старте контейнера из переменной VNC_PASSWORD, см. scripts/start.sh)
RUN mkdir -p ${HOME}/.vnc \
    && chown -R ${USER}:${USER} ${HOME}/.vnc

# Конфигурация XFCE (убираем лишние окна при старте)
RUN mkdir -p ${HOME}/.config/xfce4 \
    && chown -R ${USER}:${USER} ${HOME}/.config

COPY --chown=${USER}:${USER} config/xstartup ${HOME}/.vnc/xstartup
COPY --chown=${USER}:${USER} scripts/start.sh /start.sh
RUN chmod +x ${HOME}/.vnc/xstartup /start.sh

EXPOSE ${VNC_PORT} ${NOVNC_PORT}

USER ${USER}
WORKDIR ${HOME}

CMD ["/start.sh"]
