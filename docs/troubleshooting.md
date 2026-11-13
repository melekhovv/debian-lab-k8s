# Troubleshooting

[README](../README.md)

Начинайте со сбора состояния. Ниже read-only команды; они не выполнялись при подготовке документации. Логи перед публикацией нужно обезличить. Диагностика может обращаться к чувствительным данным — не публикуйте полные конфиги и архивы.

```powershell
minikube status
kubectl config current-context
kubectl get pods,deployments,services -n debian-lab -o wide
kubectl get events -n debian-lab --sort-by=.metadata.creationTimestamp
Get-NetTCPConnection -State Listen -LocalPort 3000,3001,3002,3003 -ErrorAction SilentlyContinue
```

| Симптом | Диагностика | Следующее действие |
|---|---|---|
| Docker недоступен | `docker info`, режим Linux containers | Проверить Docker Desktop; не делать factory reset |
| Pending | `kubectl describe pod -n debian-lab <pod>`: Events, requests, доступные ресурсы | Разобрать причину; изменение ресурсов/кластера согласовать |
| ImagePullBackOff | Events, доступ к registry, точный digest | Проверить сеть и registry; не заменять digest на latest |
| OOMKilled | `describe pod`: Last State, limits; `kubectl top pods -n debian-lab`, если есть metrics-server | Зафиксировать нагрузку; изменение памяти и рестарт планировать отдельно |
| Порт 3000–3003 занят | OwningProcess из `Get-NetTCPConnection`, затем `Get-Process -Id <PID>` | Найти владельца; закрывать только свой подтверждённый процесс или менять локальный порт |
| GUI перестал открываться | Процесс запуска, Service endpoints, логи Pod | Проверить port-forward; повторный запуск меняет состояние и не является диагностикой |
| Pod Running, но `/zabbix` не работает | Статусы nginx/Apache/БД/Zabbix, наличие frontend и его логов | Различить отсутствие установки, ошибку proxy и ошибку приложения |
| Клиенты не связаны после пересоздания Pod | Текущие Pod UID/IP, адреса и маршруты, таблица 100 и правила ноды | Сравнить с topology; повторную настройку сети согласовать при конфликте правил |
| GUI есть, но сеть не работает | Проверить отдельно учебные IP, маршруты и forwarding | GUI через Service не подтверждает учебный маршрут |
| Сервисы отсутствуют | `test -x /etc/init.d/<service>` внутри нужного Pod | Это допустимый skip скрипта; установка не автоматизирована |
| Restore/import failed | Итог start, наличие копии на Windows, ошибки tar/rsync, совместимость образа | Сохранить исходные архивы, не применять `-Force` и не удалять кластер |
| Save-state отказывает без маркера | Проверить `/run/lab-restored`, историю start/restore | Не обходить защиту: сначала установить причину отсутствия маркера |
| Stale audio/display sockets | Логи и результат `pactl info` от пользователя abc | Start содержит принудительный перезапуск GUI; учитывать потерю текущей сессии |

## Уточняющие команды

Замените `<pod>` реальным именем из `kubectl get pods`; `<service>` — одним из ожидаемых сервисов. Угловые скобки являются обозначением, не готовой командой.

```text
kubectl describe pod -n debian-lab <pod>
kubectl logs -n debian-lab <pod> --tail=100
kubectl exec -n debian-lab <pod> -- ip -4 addr show
kubectl exec -n debian-lab <pod> -- ip -4 route show
kubectl exec -n debian-lab <pod> -- service <service> status
docker exec minikube ip rule show
docker exec minikube ip route show table 100
docker exec minikube iptables -t raw -S LAB-NOTRACK
```

Пустые `kubectl logs` не доказывают отсутствие ошибок: приложения внутри webtop могут писать в файловые логи. Отсутствие `kubectl top` при отсутствии metrics-server не означает сбой лаборатории.

## Когда остановиться

Не выполнять вслепую `minikube delete`, сброс Docker Desktop, flush iptables или массовое удаление маршрутов. При ошибке backup/restore сохранить исходные архивы и остановить дальнейшие изменения до разбора. Изменение базового образа может быть несовместимо с восстановлением слоя прежнего образа.
