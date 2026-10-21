#!/bin/bash
set -e

echo "========================================="
echo "  Debian Desktop (XFCE) - Docker/K8s    "
echo "========================================="

# Пароль VNC берётся только из переменной окружения (.env / K8s Secret)
if [ -z "$VNC_PASSWORD" ]; then
    echo "ОШИБКА: переменная VNC_PASSWORD не задана" >&2
    exit 1
fi
echo "Устанавливаем VNC пароль..."
mkdir -p ~/.vnc
echo "$VNC_PASSWORD" | vncpasswd -f > ~/.vnc/passwd
chmod 600 ~/.vnc/passwd

# Завершаем старые VNC сессии если есть
vncserver -kill :1 2>/dev/null || true
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true

echo "Запускаем VNC сервер на дисплее :1 (порт $VNC_PORT)..."
vncserver :1 \
    -geometry "${VNC_RESOLUTION:-1280x800}" \
    -depth "${VNC_DEPTH:-24}" \
    -localhost no \
    -SecurityTypes VncAuth \
    -rfbauth ~/.vnc/passwd

echo "Запускаем noVNC (веб-доступ через браузер) на порту $NOVNC_PORT..."
websockify \
    --web /usr/share/novnc \
    --wrap-mode=ignore \
    $NOVNC_PORT \
    localhost:$VNC_PORT &

echo ""
echo "========================================="
echo "  Доступ к рабочему столу:"
echo ""
echo "  Браузер (noVNC):  http://localhost:$NOVNC_PORT/vnc.html"
echo "  VNC клиент:       localhost:$VNC_PORT"
echo "========================================="
echo ""

# Ждём завершения VNC сервера (держим контейнер живым)
vncserver -list
tail -f ~/.vnc/*.log 2>/dev/null || wait
