# vpn-node-setup

Оптимизатор VPN-нод под Xray / Remnawave. Ставит ядро **XanMod LTS с BBRv3**, прогоняет полный системный и сетевой тюнинг, вешает MSS clamp и умеет диагностировать узкие места. Цель — выжать максимум пропускной способности и стабильности из ноды-релея.

---

## Быстрый старт

```bash
curl -fL https://raw.githubusercontent.com/SpofyJet/node/main/vpn-node-setup.sh | sudo bash
```

После установки ядра **нужна перезагрузка**.

## Требования

| | |
|---|---|
| ОС | Debian 12/13 (bookworm/trixie) · Ubuntu 24.04+ (noble/plucky/…) |
| Права | root |
| После установки | reboot (смена ядра) |

> ⚠️ **Ubuntu 22.04 (jammy) и 20.04 (focal) не поддерживаются** — XanMod не публикует для них ядра (404 на `deb.xanmod.org`). Скрипт проверяет это и выходит рано с понятным сообщением.

## Возможности

- **Ядро XanMod LTS + BBRv3** — современный congestion control из коробки.
- **Системный sysctl-тюнинг** — сетевой стек, буферы, conntrack (tier-aware: параметры подбираются под размер ноды).
- **MSS clamp** через nftables — против PMTU-blackhole на туннелях.
- **RPS / softirq-тюнинг** — раскладка обработки пакетов по ядрам с корректной cpumask при любом числе CPU.
- **NIC offload** — настройка gro/gso/tso и сопутствующего.
- **Диагностика** — анализатор узких мест с опциональным авто-применением правок.
- **Self-update / откат** — обновление и возврат на предыдущий снапшот ядра/конфига.

## Режимы запуска

```bash
sudo bash vpn-node-setup.sh                # (по умолчанию) полная оптимизация
sudo bash vpn-node-setup.sh --diagnose     # только диагностика
sudo bash vpn-node-setup.sh --upgrade      # обновить себя до свежей версии
sudo bash vpn-node-setup.sh --rollback     # откат ядра/конфига на предыдущий снапшот
```

Пресеты диагностики: `--diagnose-quick`, `--diagnose-apply`, `--diagnose-no-net`, `--diagnose-dry-run`. Всё после `--` уходит напрямую в диагностический модуль (например `--diagnose -- -q -a -v`).

## Параметры (env при установке)

| Переменная | Дефолт | Назначение |
|---|---|---|
| `SETUP_REQUIRE_SIG` | `0` | требовать проверку minisign-подписи скрипта |
| `SETUP_MINISIGN_PUBKEY` | — | публичный ключ minisign для верификации |
| `SETUP_SIG_FINGERPRINT` | — | ожидаемый fingerprint подписи |
| `XANMOD_GPG_KEY_ID` | `86F7D09EE734E623` | GPG-ключ репозитория XanMod |
| `OLD_QLEN` | `1000` | исходная txqueuelen (для отчёта/отката) |

## Версия

**v5.3.5** · история изменений — в шапке `vpn-node-setup.sh` и в разделе Releases.
