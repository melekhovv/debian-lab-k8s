# Debian Lab Network в Kubernetes (Minikube / Docker)

Лабораторный комплекс на базе Debian Linux (сервер с XFCE Webtop + 3 клиента) в Kubernetes (Minikube).

## Расположение файлов
Проект размещен в папке:
`D:\debian-lab-k8s`

---

## Быстрый запуск

1. Запустите файл **`start-debian.bat`** (или `start-debian.ps1`).  
   Скрипт автоматически:
   - Проверяет и запускает Docker Desktop.
   - Проверяет и поднимает кластер Minikube.
   - Применяет манифесты Kubernetes из папки `k8s\`.
   - Восстанавливает сохраненное состояние контейнеров (Zabbix, Prometheus, Grafana).
   - Запускает проброс портов (Webtop на порт `3000`).

2. Откройте рабочий стол Debian в браузере:
   **http://localhost:3000**

---

## Сохранение состояния

Перед выключением или перезагрузкой компьютера запустите:
**`save-state.bat`**

Этот скрипт сохраняет измененные слои файловой системы всех 4 контейнеров (Debian Server и 3 клиента) внутри Minikube, поэтому базы данных Zabbix, контейнеры Docker, Grafana и Prometheus не будут утеряны.

---

## Остановка окружения

Запустите:
**`stop-debian.bat`** (ставит Minikube на паузу/остановку для экономии ресурсов).

---

## Структура файлов

```
D:\debian-lab-k8s\
├── start-debian.bat        # Главный запуск лабораторной среды
├── start-debian.ps1        # PowerShell-скрипт запуска и восстановления
├── save-state.bat          # Сохранение состояния всех машин
├── save-state.ps1          # PowerShell-скрипт создания бэкапов
├── stop-debian.bat         # Корректная остановка Minikube
├── k8s\
│   ├── debian-webtop.yaml  # Манифест сервера (Debian Desktop с GUI Webtop)
│   ├── debian-clients.yaml # Манифест 3 клиентских машин (debian-client-1/2/3)
│   └── manifests.yaml      # Альтернативный манифест
├── Dockerfile              # Dockerfile для сборки Debian с XFCE
└── README.md               # Документация проекта
```
