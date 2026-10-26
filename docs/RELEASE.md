# Локальные сборки и будущий выпуск

Текущая поставка: YEETKIX 1.0, build 8, macOS 14+, ARM64. Приложение собирается локально. Сертификаты Developer ID, нотариализация и сервер обновлений пока не настроены. Архитектура Intel не собирается. Исходники опубликованы отдельно от подписанного выпуска.

## Локальная поставка

```sh
swift run -debug-info-format none LumaChecks
swift scripts/check-updates.swift
bash scripts/package-release.sh
codesign --verify --deep --strict build/Yeetkix.app
hdiutil verify build/Yeetkix-1.0-macOS-arm64.dmg
(cd build && shasum -a 256 -c Yeetkix-1.0-macOS-arm64.sha256)
```

ZIP содержит только `.app`. DMG содержит `.app` и ссылку на Applications. Sparkle копируется с сохранением вложенных исполняемых файлов и символических ссылок; его лицензия включена в Resources приложения. Локальная подпись ad hoc не является Developer ID и не подтверждает прохождение Gatekeeper/нотаризации.

## Будущая конфигурация обновлений

Sparkle 2.10.1 закреплён в SwiftPM. Без обоих параметров ниже updater не запускается; автоматические проверки, загрузки и отправка профиля по умолчанию выключены.

- `YEETKIX_UPDATE_FEED`: будущий HTTPS URL appcast без учётных данных.
- `YEETKIX_UPDATE_PUBLIC_KEY`: публичный Ed25519 ключ, base64, ровно 32 байта после декодирования.
- `YEETKIX_VERSION` и `YEETKIX_BUILD`: версия и возрастающий номер сборки.

Для реального выпуска ключ создаётся официальным `generate_keys` и хранится в Keychain. Закрытый ключ не попадает в репозиторий или приложение. Создание ключа для настоящего канала сейчас не выполнялось. `check-updates.swift` создаёт одноразовый seed во временной папке, подписывает искусственные данные инструментом Sparkle, проверяет подпись через CryptoKit и отклонение изменённых данных; затем удаляет только эту папку.

`scripts/generate-appcast.sh <выделенная-папка-архивов>` создаёт локальный appcast. Нужен `YEETKIX_UPDATE_DOWNLOAD_PREFIX` (HTTPS). Можно указать `YEETKIX_ED_KEY_FILE`, иначе официальный инструмент ищет ключ в Keychain. Скрипт ничего не загружает на сервер. Ему следует передавать отдельную папку релизов, поскольку Sparkle управляет архивами внутри неё. Ключи и этот канал для локальной поставки не требуются.

Настоящий цикл «старая версия → опубликованный подписанный архив → установка новой версии» проверяется после выбора канала. Его нельзя считать проверенным по одному локальному тесту подписи.

## Подпись и нотариализация позже

`scripts/notarize-release.sh` принимает существующие в Keychain `YEETKIX_SIGNING_IDENTITY` (Developer ID Application) и `YEETKIX_NOTARY_PROFILE` (профиль notarytool). Работает с отдельной копией в build/signed.*, подписывает компоненты Sparkle изнутри наружу, приложение, проверяет подписи, отправляет архив в Apple, stapler и Gatekeeper проверяют принятый результат. Исходная локальная сборка сохраняется. Скрипт сейчас не запускался: сертификата нет, пользователь отложил этот этап.

Публикации в App Store, покупки домена и регистрации товарного знака в этих сценариях нет.

Официальные источники: [подключение и выпуск Sparkle](https://sparkle-project.org/documentation/), [программное подключение](https://sparkle-project.org/documentation/programmatic-setup/), [управление резервными копиями Apple](https://support.apple.com/en-us/108809), [Docker image rm](https://docs.docker.com/reference/cli/docker/image/rm/), [Docker container rm](https://docs.docker.com/reference/cli/docker/container/rm/), [Docker builder prune](https://docs.docker.com/reference/cli/docker/builder/prune/).
