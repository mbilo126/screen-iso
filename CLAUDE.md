# ScreenISO

App menu bar per macOS: tiene sveglio il Mac con le attività scelte dall'utente (assertion di `caffeinate`, `SleepDisabled`) e blocca lo schermo con il blocco nativo di macOS (password o Touch ID). Attività e blocco sono indipendenti: niente spegne un'attività in automatico.

## Deviazione dallo stack standard

Swift 6 con SwiftPM, SwiftUI (`MenuBarExtra`) per l'app, Objective-C per il bundle del salvaschermo. Servono API native (IOKit, `login.framework`, ScreenSaver), quindi niente Python o React. Si compila con i soli Command Line Tools, senza Xcode.

## Struttura

- `Sources/ScreenISOCore`: logica (attività di alimentazione, blocco, registro). Nessuna dipendenza dalla UI.
- `Sources/ScreenISO`: app menu bar.
- `Saver/`: salvaschermo `.saver`, compilato con clang.
- `assets/logo.svg`: logo. `make icon` ne ricava `Resources/AppIcon.icns`, l'icona dell'app, che è committata.
- `packaging/homebrew/`: modello del cask, reso da `scripts/release.sh` e pubblicato nel tap `mbilo126/homebrew-screeniso`.
- `Tests/ScreenISOCoreTests`: test con Swift Testing (`import Testing`). XCTest non è disponibile senza Xcode.

## Comandi

`make lint`, `make format`, `make test`, `make build`, `make icon`, `make release` (pubblica: mai senza richiesta esplicita; `./scripts/release.sh --dry-run` per provare).

## Regole

- I test e gli script non devono mai bloccare lo schermo, eseguire `sudo`, cambiare impostazioni `pmset` o scrivere fuori da una cartella temporanea. Gli effetti di sistema passano da protocolli, con fake nei test.
- Nessuna schermata di blocco custom: l'autenticazione è sempre quella di macOS.
- Nessuna identità di firma disponibile: firma ad-hoc. Per questo il privilegio per `pmset disablesleep` passa da una regola sudoers mirata e non da un helper `SMAppService`.
