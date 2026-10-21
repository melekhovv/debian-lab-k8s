# legacy — устаревший вариант проекта

Первый вариант лаборатории. В основном сценарии (`start-debian.bat`) **не используется**, сохранён для истории.

| Файл | Что это |
|---|---|
| `Dockerfile`, `config/xstartup`, `scripts/start.sh` | Самосборный Debian 12 с XFCE, TigerVNC и noVNC |
| `docker-compose.yml` | Запуск этого образа в Docker (noVNC: http://localhost:6080/vnc.html) |
| `k8s/manifests.yaml` | Манифест для него в Kubernetes (namespace `debian-desktop`) |
| `run-in-k8s.ps1`, `start-k8s.bat` | Запуск Minikube через Hyper-V и развёртывание `k8s\debian-webtop.yaml` |

## Пароль VNC

Пароль в файлах больше не хранится.

- **Docker Compose:** скопируйте `.env.example` в `.env` и задайте `VNC_PASSWORD`. Без него `docker compose up` завершится с ошибкой.
- **Kubernetes:** создайте секрет вручную (команда есть в комментарии в `k8s/manifests.yaml`):
  `kubectl create secret generic debian-desktop-secret -n debian-desktop --from-literal=vnc-password='<пароль>'`

Сборка и запуск выполняются из этого каталога: `docker compose up --build`.
