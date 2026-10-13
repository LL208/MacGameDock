# MacGameDeck — anteprima 0.4.2

Applicazione Swift/SwiftUI per Apple Silicon, macOS 13+. Nome dello schema e cartella del progetto: **MacGameDock**, per mantenere le impostazioni Xcode esistenti. Apri `Package.swift` in Xcode → MacGameDock / My Mac → ⌘R. La app compilata è `MacGameDeck.app`, accanto alla cartella del progetto. Il runtime Steam/.NET è incluso; Wine non è redistribuito.

## Correzione 0.4.2

Il profilo/libreria memorizzato non viene più mostrato come sessione pronta per i download. Account Steam distingue il profilo riconosciuto dalla sessione salvata dello stesso account. Se manca, usa Abilita download automatici per un accesso QR iniziale oppure importa una sessione precedente. La conferma del login richiede il salvataggio effettivo di account.config; se manca o non si può scrivere, l’operazione viene interrotta con un errore esplicito. I test coprono identità ricevuta senza credenziali, conservazione dopo pausa e riutilizzo alla riapertura.

## Correzione 0.4.1

Risolta la ricerca del motore Steam nelle risorse: supporta sia i bundle piatti SwiftPM/Finder sia quelli Xcode con `Contents/Resources/Resources`. Aggiunti test per entrambe le strutture e per le risorse effettive del pacchetto.

## Novità

- Sessione Steam ricordata tra download e riaperture, anche se il download viene messo in pausa dopo il login.
- Nessuna lettura del Portachiavi all'avvio o per ogni download.
- Scelta **Mac nativa / Windows con Wine** prima del download, secondo le versioni disponibili. Se Mac è disponibile viene preselezionato, ma puoi scegliere Windows.
- Libreria **Steam Families**, con badge, filtro Famiglia e proprietari nella cache.
- Schermata **Download** con icona del gioco, coda persistente, pausa, ripresa, annullamento, priorità, progresso, velocità e tempo residuo indicativo.
- Schermata **Versioni e statistiche stimate**, con requisiti pubblicati, RAM del Mac, margine indicativo per Wine e impostazioni iniziali suggerite.

## Accesso senza QR ripetuti

Per chi arriva dalla versione 0.3: Account Steam → **Importa sessione della versione precedente**. Questa operazione facoltativa può chiedere lo sblocco del Portachiavi una volta. In alternativa effettua un login QR una volta. Da quel momento viene riutilizzata la nuova sessione locale. **Ricollega con QR** forza invece una nuova autenticazione, per cambiare account o rinnovare una sessione revocata.

La sessione è salvata in `Account/steam-session.json` sotto la cartella dati, con file 0600 e cartella 0700: accessibile al tuo utente macOS, senza dialoghi del Portachiavi. Non è cifrata separatamente dal disco; è una scelta per evitare richieste nelle build di sviluppo firmate ad hoc. Non contiene la password, ma il token Steam è una credenziale. La cartella dati non deve essere condivisa o caricata insieme ai sorgenti. I binari e gli archivi forniti non contengono sessioni.

Ogni operazione copia temporaneamente la sessione in una cartella privata del helper, poi la elimina. Il token viene conservato appena Steam conferma l'accesso, anche prima del completamento del catalogo o download. Scollega elimina la nuova sessione locale e il catalogo dell'account; la vecchia voce del Portachiavi non viene letta automaticamente. Non è garantita la validità perpetua: revoca o scadenza lato Steam richiedono un nuovo accesso.

## Scelta della versione e avvio

Premi Installa: l'app verifica versioni/requisiti dello store e mostra la scelta. Se la rete dello store non risponde, usa le piattaforme già ricevute dal catalogo e segnala che mancano i requisiti. Le versioni Mac vengono scaricate in `Containers/Steam/APPID/macOS` e avviate come `.app` o eseguibile nativo, senza Wine. Un port Mac può essere Intel e richiedere Rosetta; la presenza di una versione Mac non certifica compatibilità con M1/macOS attuale. I depot Mac vengono richiesti a 64 bit.

Windows usa `Containers/Steam/APPID/prefix/drive_c/Program Files/MacGameDeck/Games/APPID`. Il runtime CrossOver/Wine già installato viene rilevato automaticamente; puoi selezionarne uno alternativo in Il tuo Mac. I metadati Steam determinano l'eseguibile. La preparazione crea un prefix per gioco, verifica l'inizializzazione e installa le dipendenze `Run Process` supportate sotto `%INSTALLDIR%`. Script del registro o dipendenze esterne non supportate fermano la preparazione. Percorsi esterni e collegamenti simbolici di avvio sono rifiutati.

Steamworks, DRM, multiplayer, achievement, cloud e altri servizi del client non sono forniti da questa anteprima. Alcuni giochi possono richiedere ancora il client Windows per funzionare. Epic/GOG mantengono rilevamento/importazione delle installazioni locali: download autonomi non ancora implementati. Nessun titolo è certificato, incluso Nasty Zombies.

## Famiglia Steam

Il helper autenticato legge `GetFamilyGroupForUser` e `GetSharedLibraryApps`, unisce i giochi ammessi dalla famiglia alle licenze personali e conserva la provenienza. Aggiorna libreria Steam carica anche la famiglia. Se Steam non restituisce i metadati necessari, il catalogo precedente è preservato. La sola visibilità non concede una licenza di download: l'installatore attuale verifica i depot dell'account e può rifiutare titoli condivisi, anche se visibili. Il supporto al download di licenze condivise e l'avvio Steamworks richiedono ulteriore integrazione.

Riferimenti: [Steam Families](https://partner.steamgames.com/doc/features/families?language=english), [FAQ Steam Families](https://help.steampowered.com/en/faqs/view/054C-3167-DD7F-49D4).

## Coda, pausa e ripresa

Un download alla volta. Aggiungi più giochi dalla libreria; la coda avanza automaticamente dopo completamento, errore o pausa del precedente. Pausa interrompe il trasferimento, conserva i file e la sessione. Riprendi riavvia il helper e valida i file già scaricati; non riscarica automaticamente tutto. Se è in corso un installer Windows, la pausa attende la fine di quel passaggio per evitare di interrompere una dipendenza a metà.

La coda è salvata atomicamente in `downloads.json`. Alla riapertura i trasferimenti pendenti vengono mostrati in pausa: premi Riprendi sul gioco o Riprendi coda. I lavori sono associati all'account che li ha creati. Cambiare account non trasferisce le autorizzazioni dei vecchi lavori. Pausa coda mette in pausa anche gli elementi in attesa. Il pulsante Scarica prima dà priorità a un elemento in attesa; non interrompe quello attivo. Annulla conserva i file parziali. Non sono ancora implementati limite di banda, aggiornamenti automatici, cancellazione dei file o coda di altri store.

Velocità/ETA si riferiscono al flusso di byte verificati dal helper e possono variare durante decompressione, validazione e preparazione; non sono un contatore esatto del solo traffico di rete. Le icone provengono dalla CDN Steam, con fallback alla copertina e al simbolo locale.

## Statistiche prudenti

Le informazioni dello store includono piattaforme e requisiti minimi RAM/GPU/DirectX quando presenti. La stima di memoria usa il minimo pubblicato + 2 GB indicativi per Windows/Wine. Confronta questo valore con la RAM fisica e lascia un margine per macOS/altre app. Risoluzione e qualità suggerite sono punti di partenza generici, non applicati automaticamente.

Non viene inventata una previsione numerica degli FPS: servono benchmark dello stesso gioco, chip, versione e backend grafico. La compatibilità e le prestazioni effettive restano da verificare. Nasty Zombies è il primo caso scelto dall'utente: [pagina Steam](https://store.steampowered.com/app/2851700/Nasty_Zombies/).

## Build, dati e verifiche

Dati: `~/Library/Application Support/MacGameDock/`. `library.json`, `downloads.json`, `Account/`, `Containers/`, `Prefixes/`, `Logs/`, `Tools/`. Ogni avvio Wine sostituisce il log della voce. Rimuovere un gioco conserva file e salvataggi. Le scansioni non sovrascrivono i container gestiti. La cache precedente resta leggibile. Per prove isolate imposta `MACGAMEDOCK_DATA_DIRECTORY` su un percorso assoluto.

Build app: `./scripts/build-app.sh`. Output predefinito `dist/MacGameDeck.app`; variabili `MACGAMEDOCK_BUILD_DIR`, `MACGAMEDOCK_APP_OUTPUT`. Firma ad hoc, senza Developer ID o notarizzazione. L'app non usa App Sandbox.

34 test XCTest passati su Apple Silicon/Xcode 26.3, inclusi riutilizzo della sessione senza QR con processi simulati, pausa dopo il login, cleanup delle sessioni temporanee, permessi privati, account errato, coda seriale e persistente, selezione Mac, dati famiglia, requisiti e migrazione. Il helper C# compila; binario e .NET 9.0.20 sono inclusi. Login/download Steam autenticati, famiglia reale e avvio giochi non esercitati dall'agente. La prova Wine dall'ambiente di sviluppo isolato incontra il limite `server_mach_port`: l'app deve essere provata normalmente sul Mac.

Motore: [DepotDownloader 3.4.0](https://github.com/SteamRE/DepotDownloader/releases/tag/DepotDownloader_3.4.0), [SteamKit](https://github.com/SteamRE/SteamKit), componenti comunitari. GPLv2 e sorgenti corrispondenti inclusi in `Helpers/SteamDownloader/Source`. `integration.patch` descrive le modifiche; `patch-upstream.py` le applica al tag originale o riconosce i sorgenti già modificati. Ricostruzione helper: `Helpers/SteamDownloader/build-helper.sh`, richiede .NET SDK 9 (variabile `MACGAMEDECK_DOTNET`). Microsoft runtime con LICENSE/ThirdPartyNotices separati. Nessun binario CrossOver redistribuito.

## 0.5.0 — Controller, attività e Workshop

- Pagina Controller: rilevamento GameController di macOS, ricerca wireless, batteria quando disponibile e test in tempo reale di pulsanti, grilletti, D-pad e levette. Il collegamento apre le impostazioni controller di macOS per la rimappatura. Nessun driver viene installato. Il supporto nei giochi Windows dipende da Wine; non include un equivalente di Steam Input.
- Ore locali: `playtime.json` conserva il tempo dei processi avviati direttamente, con checkpoint ogni 15 secondi e a fine processo. Le app native vengono monitorate tramite NSRunningApplication. Sono ore di processo, non tempo attivo davanti al gioco; non si sincronizzano con Steam. Il conteggio richiede MacGameDeck aperto e non segue launcher esterni o processi figli che sopravvivono al processo Wine monitorato. In caso di arresto improvviso si possono perdere gli ultimi 15 secondi; alla riapertura non viene conteggiato il tempo offline.
- Menu del gioco → Workshop, mod e trofei: browser Steam incorporato con dati web temporanei. L'autenticazione del motore di download non viene esposta al browser; le pagine private possono richiedere accesso web separato.
- Workshop: link/ID di un singolo elemento, verifica dell'app proprietaria e tipo prima del download tramite sessione Steam salvata. Collezioni e contenuti non scaricabili non supportati. File in `Workshop/<appid>/<itemid>/<download-uuid>`; cartelle parziali conservate. Le mod non si iscrivono automaticamente al Workshop, non ricevono aggiornamenti automatici e non entrano nella coda dei giochi. È possibile copiare il download in una nuova sottocartella della cartella mod scelta dall'utente, senza sovrascritture, con rifiuto di symlink. Non estrae archivi, non installa loader e non garantisce l'attivazione: formato, dipendenze e percorso richiesti variano tra giochi. Il gioco deve essere chiuso durante l'installazione.
- Trofei: pagina ufficiale delle statistiche dell'account Steam per il gioco. Lo sblocco e la sincronizzazione ufficiali richiedono che il gioco comunichi con Steamworks; il launcher non simula obiettivi, non modifica i dati Steam e non promette trofei nell'avvio diretto con Wine senza servizi Steam.

Riferimenti: [GameController Apple](https://developer.apple.com/documentation/gamecontroller), [trofei Steamworks](https://partner.steamgames.com/doc/features/achievements), [Workshop Steamworks](https://partner.steamgames.com/doc/features/workshop/implementation).

## 0.6.0 — Avvio con il client Steam ufficiale

Il pulsante **Gioca con Steam** avvia ora i giochi Steam installati tramite il client ufficiale (`-silent -applaunch <appid>`), anziché avviare direttamente l'eseguibile. Per Windows, MacGameDeck prepara Steam nel medesimo prefix Wine del gioco, scaricando l'installer da Valve quando serve; per macOS usa il client Steam già installato. Il gioco comunica con le implementazioni Steamworks del client: questo è il percorso necessario per registrare su Steam gli obiettivi ottenuti durante una partita. Non vengono modificati gli obiettivi, iniettate DLL o simulate condizioni di sblocco.

Il downloader scrive una ricevuta `client-receipt.json` solo dopo il download completo di un'app (non dei contenuti Workshop), con AppID, piattaforma, build e manifest dei depot scaricati. Il primo avvio di installazioni precedenti recupera la ricevuta verificando i file con il downloader. MacGameDeck registra quei depot nel client e collega la cartella esistente in `steamapps/common/MacGameDeck-<appid>`; non duplica il gioco. Una volta registrata, la copia appartiene anche alla gestione del client ufficiale: Steam può verificarla, aggiornarla o riscaricare file necessari. Non vengono sostituiti manifest o cartelle di altre installazioni. Se esiste un'altra copia, il menu **Avvia installazione Steam esistente** invia l'avvio al client senza modificarla. Se il client era già aperto durante la prima registrazione, può essere necessario riavviarlo una volta per caricare il nuovo manifest.

La sessione del downloader non è una sessione del client ufficiale. Il client può richiedere una prima autenticazione Steam Guard nel container e poi ricordarla con la propria funzione di accesso. I container separati possono richiedere la configurazione del client separatamente. MacGameDeck non esporta o ricopia i token del client. Prima di avviare, controlla l'account `MostRecent` di `loginusers.vdf` quando disponibile e segnala un account diverso; questo controllo non certifica una sessione online. **Accesso Steam per i trofei** apre il client del container per completare login o cambiare account.

**Avvio diretto · trofei non garantiti** resta un'opzione esplicita nel menu delle installazioni gestite. Il tempo del processo del client Steam non viene conteggiato come tempo del gioco: il contatore locale della 0.5.0 riguarda gli avvii diretti monitorati da MacGameDeck; con l'avvio ufficiale il conteggio Steam è gestito dal client.

Validazione: 43 test automatici, build del helper .NET e avvio del runtime incluso, build Swift release e verifica della firma ad hoc. Non è stata effettuata una prova reale di autenticazione del client nel container, di avvio di Nasty Zombies o di un trofeo sbloccato e sincronizzato. Il percorso è sperimentale: compatibilità Wine/Steam, DRM, supporto del gioco, account/licenza e stato della rete restano determinanti. Una richiesta di avvio riuscita non viene mostrata come conferma di trofei sincronizzati.

Riferimenti: [requisiti SteamAPI_Init e avvio tramite Steam](https://partner.steamgames.com/doc/api/steam_api), [registrazione dei trofei dal gioco](https://partner.steamgames.com/doc/features/achievements), [opzione Steam -silent](https://help.steampowered.com/en/faqs/view/0188-6BB7-D467-08E1).
