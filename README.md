# ScreenISO

App per la barra dei menu di macOS. Serve quando un processo lungo (per esempio Claude Code) deve continuare a lavorare mentre l'utente è lontano dal Mac: con un click avvia una sessione protetta che impedisce lo stop, blocca lo schermo con il blocco nativo di macOS e, allo sblocco, ripristina le impostazioni e chiude la sessione. Ogni passaggio viene scritto in un registro di audit utilizzabile come evidenza per ISO 27001.

## Cosa fa e cosa non fa

Fa:

- impedisce lo stop del Mac con le stesse assertion di `caffeinate`, scelte dall'utente;
- se richiesto, impedisce lo stop anche a coperchio chiuso con `pmset disablesleep`, e al termine rimette il valore che c'era prima;
- blocca lo schermo con la schermata di blocco di macOS, oppure avviando il salvaschermo;
- verifica che il blocco sia avvenuto davvero, altrimenti annulla la sessione;
- chiude la sessione da sola quando l'utente sblocca il Mac;
- scrive un registro append-only in formato JSON Lines.

Non fa:

- non mostra una schermata di blocco propria: password e Touch ID sono gestiti da macOS (loginwindow);
- non cambia l'impostazione "Richiedi la password subito": la controlla e indica il comando da eseguire;
- non sorveglia il processo che sta lavorando e non chiude la sessione a tempo;
- non si avvia al login.

## Requisiti

- macOS 14 o successivo (sviluppata e provata su macOS 26.6, Apple silicon).
- Per compilare: Command Line Tools con Swift 6. Xcode non serve.
- Per la modalità coperchio chiuso: un account amministratore per installare la regola sudoers.

## Build

```sh
make build
```

Produce `build/ScreenISO.app`, che contiene:

- `Contents/MacOS/ScreenISO`, compilato in release (solo arm64: senza Xcode SwiftPM non produce binari universali);
- `Contents/Info.plist` con bundle id `it.yellowtech.screeniso`, versione 0.1.0, `LSUIElement` attivo (nessuna icona nel Dock);
- `Contents/Resources/ScreenISOSaver.saver`, compilato da `Saver/build.sh`.

Lo script `scripts/bundle.sh` si ferma al primo passo che fallisce. La firma è ad-hoc: prima il salvaschermo annidato, poi l'app, infine `codesign --verify --deep --strict`.

Gli altri comandi:

```sh
make lint     # swift format lint --strict
make format   # swift format --in-place
make test     # swift test (Swift Testing)
```

Per leggere lo stato del sistema senza aprire l'interfaccia:

```sh
build/ScreenISO.app/Contents/MacOS/ScreenISO --status
```

Stampa un JSON con la politica di blocco, lo stato di `SleepDisabled`, la regola sudoers, la disponibilità della funzione di blocco e di Touch ID, se il salvaschermo è installato e se risulta selezionato. È in sola lettura.

## Installazione

Copia `build/ScreenISO.app` in `/Applications` e aprila. Si apre una finestra con il pannello e compare l'icona `lock.shield` nella barra dei menu, da cui si riapre lo stesso pannello. L'app non ha icona nel Dock: chiudere la finestra non la termina, e aprirla di nuovo dal Finder o da Spotlight rimostra la finestra. Un'app compilata in locale non ha l'attributo di quarantena, quindi Gatekeeper non la blocca; se la copi da un altro Mac, aprila la prima volta con clic destro e "Apri".

## Primo avvio

Il pannello mostra i requisiti. Il pulsante "Avvia sessione protetta" resta disattivato, con il motivo, finché ne manca uno.

1. **Password subito al blocco.** Se macOS concede un ritardo prima di chiedere la password, lo schermo bloccato potrebbe riaprirsi senza autenticazione. ScreenISO non modifica questa impostazione: copia il comando dal pannello ed eseguilo nel Terminale.

   ```sh
   sysadminctl -screenLock immediate -password -
   ```

   Il comando chiede la password dell'utente. Poi riapri il pannello: il requisito risulta conforme.

2. **Salvaschermo (facoltativo).** Serve solo per la modalità "Salvaschermo". "Installa salvaschermo" copia il `.saver` incluso nell'app in `~/Library/Screen Savers/` e apre le Impostazioni di Sistema, dove va selezionato "ScreenISO" nella sezione Altro. Su macOS 26 la scelta sta in Sfondo, dietro il pulsante "Salvaschermo…"; fino a macOS 15 c'è un pannello Salvaschermo a sé. Installarlo non basta: la modalità "Salvaschermo" avvia il salvaschermo selezionato nelle Impostazioni, qualunque sia. Finché ScreenISO non risulta selezionato, il pannello mostra un avviso con il percorso e il pulsante per aprire il pannello giusto. Dopo una nuova build dell'app, se il salvaschermo installato è diverso da quello incluso, il pannello lo segnala e offre "Aggiorna salvaschermo": sostituisce la copia installata e termina il processo `legacyScreenSaver` dell'utente, che macOS riavvia da solo con il codice nuovo.

3. **Regola sudoers (facoltativa).** Serve solo per "Resta sveglio a coperchio chiuso". "Installa regola" mostra il prompt di amministratore di macOS. "Rimuovi regola" la toglie.

## Come funziona una sessione

1. **Controlli.** La politica di blocco deve essere "subito"; se è attiva l'opzione coperchio chiuso, la regola sudoers deve essere attiva. Se un controllo fallisce non viene cambiato niente e il registro riceve `precondition_failed`.
2. **Snapshot.** Prima di ogni modifica ScreenISO salva in `~/Library/Application Support/ScreenISO/session.json` la configurazione e il valore corrente di `SleepDisabled`.
3. **Alimentazione.** Crea le assertion IOKit scelte e, se richiesto, esegue `sudo -n /usr/bin/pmset -a disablesleep 1`.
4. **Blocco.** In modalità "Schermata di blocco" chiama `SACLockScreenImmediate`. In modalità "Salvaschermo" avvia `ScreenSaverEngine`; se entro 5 secondi lo schermo non risulta bloccato, ripiega sul blocco diretto. Il blocco è confermato dalla notifica `com.apple.screenIsLocked` o dalla chiave `CGSSessionScreenIsLocked` della sessione grafica. Se non arriva nessuna conferma, tutto viene annullato e il registro riceve `lock_failed`.
5. **Sblocco.** Alla notifica `com.apple.screenIsUnlocked` ScreenISO rilascia le assertion, rimette `disablesleep` al valore dello snapshot, cancella lo snapshot e scrive `session_ended`.

Se l'app termina in modo anomalo durante una sessione, le assertion IOKit vengono rilasciate dal sistema insieme al processo, mentre `disablesleep` resta com'era. Al successivo avvio ScreenISO trova lo snapshot, ripristina `disablesleep` e scrive `session_recovered`. Se lo snapshot non è leggibile, il pannello lo segnala e offre "Scarta stato salvato": il file non viene mai scartato senza una scelta esplicita, e lo scarto viene registrato come `snapshot_discarded`.

"Esci" durante una sessione attiva chiude prima la sessione, così `disablesleep` viene ripristinato subito.

Il pannello mostra anche lo stato corrente di `SleepDisabled`: se è attivo fuori da una sessione, avvisa che lo stop è disattivato in modo permanente e indica il comando per riattivarlo.

## Registro di audit

Percorso: `~/Library/Logs/ScreenISO/audit.jsonl`. "Apri registro" lo mostra nel Finder.

Il file è in sola aggiunta, con permessi `0600`. Ogni riga è un oggetto JSON indipendente, scritto con una singola `write` in `O_APPEND` seguita da `fsync`. Le chiavi sono in ordine alfabetico, gli orari in UTC ISO 8601 con i millisecondi.

```json
{"details":{"cleanupComplete":true,"durationSeconds":3600.5,"errorCodes":"","lockedDurationSeconds":3598.2,"restoredSleepDisabled":false,"trigger":"screenUnlocked"},"event":"session_ended","sessionId":"6F9619FF-8B86-D011-B42D-00C04FC964FF","timestamp":"2027-01-15T08:00:00.250Z"}
```

Campi comuni: `timestamp`, `event`, `sessionId` (un UUID per sessione), `details`.

| Evento | Dettagli |
| --- | --- |
| `session_started` | `powerAssertions`, `keepAwakeWithLidClosed`, `lockMode`, `previousSleepDisabled`, `screenLockPolicy` |
| `screen_locked` | `lockMode`, `lockMethod` (`loginWindow`, `screenSaver`, `loginWindowFallback`) |
| `screen_unlocked` | nessuno |
| `session_ended` | `trigger` (`screenUnlocked` o `manual`), `durationSeconds`, `lockedDurationSeconds`, `restoredSleepDisabled`, `cleanupComplete`, `errorCodes` |
| `precondition_failed` | `errorCode`, `message` |
| `session_start_failed` | `stage`, `errorCode`, `message`, `rolledBack`, `rollbackErrorCodes` |
| `lock_failed` | `lockMode`, `errorCode`, `message`, `rolledBack`, `rollbackErrorCodes` |
| `session_recovered` | `snapshotStartedAt`, `keepAwakeWithLidClosed`, `restoredSleepDisabled` |
| `snapshot_discarded` | `previousErrorCode`; il `sessionId` è nuovo, perché quello originale non è leggibile |

Una sessione completa produce, in ordine, `session_started`, `screen_locked`, `screen_unlocked`, `session_ended` con lo stesso `sessionId`. `lockMethod` dice quale meccanismo ha bloccato davvero lo schermo, che può differire dalla modalità scelta.

I log operativi vanno nel log unificato di macOS con subsystem `it.yellowtech.screeniso`:

```sh
log show --last 1h --info --predicate 'subsystem == "it.yellowtech.screeniso"'
```

## Note di sicurezza

**API privata.** Il blocco diretto usa `SACLockScreenImmediate`, caricata con `dlopen` da `/System/Library/PrivateFrameworks/login.framework`. Non è documentata: un aggiornamento di macOS può rimuoverla o cambiarla. Il pannello verifica a ogni apertura che il simbolo sia risolvibile e, se non lo è, disattiva l'avvio.

**Regola sudoers.** `pmset disablesleep` richiede i privilegi di root. Poiché l'app è firmata ad-hoc, non può registrare un helper privilegiato con `SMAppService`; al suo posto c'è una regola sudoers mirata, installata in `/etc/sudoers.d/screeniso` con permessi `0440` e proprietario `root:wheel`:

```
<utente> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

Consente all'utente che l'ha installata di eseguire senza password solo quei due comandi esatti, con quegli argomenti. Non consente altri argomenti di `pmset` né altri programmi. Il nome utente viene validato prima di scrivere la regola. L'installazione passa da un unico prompt di amministratore (`osascript ... with administrator privileges`). Il testo della regola è dentro il comando stesso, senza file temporanei che un altro processo potrebbe sostituire; root lo scrive con un nome che `sudo` ignora, lo verifica con `visudo -cf` e solo allora lo rinomina.

Il pannello e `--status` controllano solo che il file della regola esista, senza invocare `sudo`: un tentativo `sudo -n` negato finisce nel log di sistema e sembrerebbe un'escalation fallita. La verifica vera (`sudo -n -l`, che non chiede password e non esegue nulla) avviene una volta, all'avvio di una sessione con l'opzione coperchio chiuso.

**Firma ad-hoc.** L'app e il salvaschermo sono firmati ad-hoc, senza identità di sviluppatore né notarizzazione. L'integrità del bundle è verificabile con `codesign --verify --deep --strict build/ScreenISO.app`, ma la firma non identifica chi l'ha prodotto: chi installa l'app deve compilarla da sé o fidarsi di chi gliel'ha data.

## Limiti noti

- **Computer use.** Con lo schermo bloccato macOS non accetta input sintetico e non permette di leggere lo schermo. Un processo che controlla il Mac tramite mouse, tastiera o screenshot non funziona durante la sessione; un processo che lavora da terminale sì.
- **Salvaschermo su macOS 26.** I salvaschermi di terze parti girano dentro il processo `legacyScreenSaver`, che ha bug noti segnalati da chi sviluppa salvaschermi. Su 26.6.2, con due display, l'host tiene in vita quattro istanze (due per display), le riavvia a ogni attivazione e ne crea altre due che rilascia allo stop: durante la sessione ne animano sei, anche se a schermo se ne vedono due. ScreenISO non fa uscire il processo (macOS lo rilancerebbe subito con un'istanza che anima senza essere a schermo): allo stop ogni istanza ferma il timer e libera le proprie risorse. Misurato su un MacBook Air M4 in una sessione di due minuti: 4,3% di un core durante il blocco, 0% prima e dopo. La modalità "Schermata di blocco" non dipende dal salvaschermo.
- **Modalità Salvaschermo.** Su macOS 26.6.2 `ScreenSaverEngine` con la password immediata porta a uno schermo che macOS segnala come bloccato (nel registro `lockMethod` è `screenSaver`). Se su un'altra versione non lo facesse, ScreenISO ripiega sul blocco diretto e il registro riporta `loginWindowFallback`.
- **Salvaschermo selezionato.** macOS non offre un'API per sapere quale salvaschermo è scelto nelle Impostazioni. ScreenISO cerca il nome del proprio bundle nell'archivio privato degli sfondi (`~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`): è un controllo indicativo, che non blocca l'avvio della sessione.
- **Assertion `-s`.** "Impedisci lo stop con alimentatore collegato" (`caffeinate -s`) ha effetto solo con l'alimentatore collegato.
- **Regola sudoers.** Provata su macOS 26.6.2: la regola passa `visudo`, viene installata in `/etc/sudoers.d/screeniso` e una sessione con l'opzione coperchio chiuso imposta `disablesleep` a 1 e lo riporta a 0 allo sblocco. Non è verificato come `osascript` si comporta in tutti i casi di annullamento del prompt: l'app riconosce l'errore AppleScript `-128` come annullamento e tratta ogni altro codice come errore.
