# vpn-node-setup

Оптимизатор VPN-нод под Xray / Remnawave: ядро **XanMod LTS + BBRv3**, полный системный и сетевой тюнинг, MSS clamp и встроенная диагностика. Цель — выжать пропускную способность и стабильность из ноды-релея.

## Установка

```bash
curl -fL https://raw.githubusercontent.com/SpofyJet/node/main/vpn-node-setup.sh | sudo bash
```

После установки ядра **нужен ребут**.

## Требования

- **Debian 12/13** (bookworm/trixie) или **Ubuntu 24.04+** (noble/plucky/…)
- ⚠️ **НЕ поддерживаются Ubuntu 22.04 (jammy) и 20.04 (focal)** — XanMod не публикует для них ядра (404 на `deb.xanmod.org`). Скрипт это проверяет и выходит рано с понятным сообщением.
- root
- ребут после установки (смена ядра)

## Что делает

- **Ядро XanMod LTS + BBRv3** — современный TCP congestion control.
- **sysctl-тюнинг и hardening** — сетевой стек, буферы, conntrack (tier-aware: параметры под размер ноды).
- **MSS clamp** через nftables — против PMTU-blackhole на туннелях.
- **RPS / softirq-тюнинг** — распределение обработки пакетов по ядрам (корректная cpumask при любом числе CPU).
- **NIC offload-тюнинг** — gro/gso/tso и сопутствующее.
- **Диагностика** (`node-diagnostic`) — анализ узких мест с опциональным авто-применением правок.

## Режимы запуска

```bash
sudo bash vpn-node-setup.sh                  # (по умолчанию) полная оптимизация
sudo bash vpn-node-setup.sh --diagnose       # только диагностика
sudo bash vpn-node-setup.sh --upgrade        # обновить себя до свежей версии
sudo bash vpn-node-setup.sh --rollback       # откат (ядро/конфиг) на предыдущий снапшот
```

Пресеты диагностики: `--diagnose-quick`, `--diagnose-apply`, `--diagnose-no-net`, `--diagnose-dry-run`. Всё после `--` уходит напрямую в `node-diagnostic` (например `--diagnose -- -q -a -v`).

## Параметры (env при установке)

| Переменная | Дефолт | Назначение |
|---|---|---|
| `SETUP_REQUIRE_SIG` | `0` | требовать проверку minisign-подписи скрипта |
| `SETUP_MINISIGN_PUBKEY` | — | публичный ключ minisign для верификации |
| `SETUP_SIG_FINGERPRINT` | — | ожидаемый fingerprint подписи |
| `XANMOD_GPG_KEY_ID` | `86F7D09EE734E623` | GPG-ключ репозитория XanMod |
| `OLD_QLEN` | `1000` | исходная txqueuelen для отчёта/отката |

## Координация с shieldnode

Если на ноде стоит и `shieldnode`, sysctl применяется послойно по лексикографике:

```
80-vpn-node-tuning.conf   (база, этот скрипт)
90-shieldnode.conf        (security-оверрайды shieldnode)
99-z-*                    (ad-hoc правки оператора)
```

`nf_conntrack_tcp_timeout_established` оба скрипта пишут **7200** — значение детерминировано при любой комбинации установки.

## Версия

Текущая: **v5.3.4**. История изменений — в шапке `vpn-node-setup.sh` и в разделе Releases.
