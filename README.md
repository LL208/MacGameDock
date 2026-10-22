# MacGameDeck — anteprima 0.9.7

Applicazione Swift/SwiftUI per Apple Silicon, macOS 13+. Cartella del progetto: **MacGameDock**; schema Xcode: **MacGameDeck**. Apri `MacGameDock.xcodeproj` in Xcode → MacGameDeck / My Mac → ⌘R. Il target macOS genera una vera app con identificativo e risorse incluse; `Package.swift` resta disponibile per i test SwiftPM. La app compilata è `MacGameDeck.app`, accanto alla cartella del progetto. Il runtime Steam/.NET è incluso. WineCX FOSS 24.0.7_7 e DXMT 0.80 vengono scaricati automaticamente da release upstream con SHA-256 fissato, nella cartella dati privata. Non occorre installare Steam, CrossOver, Wine o Homebrew. Servono ancora account/licenze e servizi Valve per i giochi Steam; l’indipendenza dal client non rende compatibili tutti i DRM o anti-cheat.

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

Windows usa `Containers/Steam/APPID/prefix/drive_c/Program Files/MacGameDeck/Games/APPID`. Il motore Wine autonomo viene scaricato e preparato automaticamente nella cartella dati. La prima preparazione del motore può richiedere alcuni minuti. I metadati Steam determinano l'eseguibile. La preparazione crea un prefix per gioco, verifica l'inizializzazione e installa le dipendenze `Run Process` supportate sotto `%INSTALLDIR%`. Script del registro o dipendenze esterne non supportate fermano la preparazione. Percorsi esterni e collegamenti simbolici di avvio sono rifiutati.

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

## 0.6.1 — Ripristino dell'avvio diretto

L'integrazione del client ufficiale introdotta nella 0.6.0 è stata rimossa: causava l'apertura di Steam e una richiesta di installazione per giochi già scaricati, tra cui Dead Estate e Cruelty Squad. **Gioca** torna al percorso diretto precedente: eseguibile del gioco, argomenti e cartella di lavoro originali, nello stesso prefix Wine. Non installa Steam, non genera manifest per il client e non richiede un account per avviare un gioco gestito già installato. Le ore restano locali, senza sincronizzazione Steam. Download, sessione salvata del downloader, controller e Workshop restano disponibili; la pagina trofei è solo consultazione.

Nessuna migrazione distruttiva: i file dei giochi, i salvataggi e le eventuali cartelle Steam create dalla 0.6.0 vengono conservati. Se Steam è ancora aperto da un avvio precedente, chiuderlo prima della prova. Gli eventuali requisiti Steam/DRM imposti dal gioco stesso restano fuori dal controllo del launcher.

Validazione 0.6.1: 39 test superati, incluso un avvio reale di un processo runtime fittizio che verifica eseguibile e argomenti del gioco Steam senza account e senza creare un client Steam. Dead Estate e Cruelty Squad non sono stati provati durante questa verifica.

## 0.6.2 — Dipendenze Steam automatiche

Corretto il falso errore “Installer della dipendenza 4.0 mancante”: gli installer erano presenti, ma gli script Steam moderni li richiamano con wrapper `.cmd` e il precedente resolver accettava solo `.exe`/`.msi`. I wrapper Steam standard vengono risolti al payload locale con i suoi argomenti silenziosi; gli script batch diversi restano eseguibili tramite `cmd`. Supportati anche `process msiexec` con MSI indicato negli argomenti e macro `%INSTALLDIR%`, controllando che i percorsi restino nella cartella del gioco.

La preparazione individua i componenti dai file installscript, mostra nomi comprensibili (DotNet, XNA, vcredist, DirectX), usa la cartella corretta per ogni installer e installa .NET prima di XNA. Se manca un pacchetto `_CommonRedist/<famiglia>/<versione>`, scarica automaticamente il gruppo richiesto dall'app Steamworks Common Redistributables 228980 usando il downloader e la sessione salvata. La cache `Tools/CommonRedist` riusa i file, include i contenuti di supporto e non sostituisce gli script o installer già presenti nel gioco. I marker vengono creati solo dopo il successo del processo; pausa, errori e retry conservano i progressi senza dichiarare pronto un gioco con preparazione fallita. Non richiede il client Steam ufficiale per questa operazione.

Verifica: 44 test superati, compreso un flusso con processi simulati per download del pacchetto mancante, errore installer, retry e non ripetizione dei passaggi completati. Verificata in sola lettura la risoluzione degli script reali sul Mac: Blood and Bacon → .NET 4.0 + XNA 4.0; Nasty Zombies → DirectX June 2010 + Visual C++ 2022 x64 e x86. In questi due casi i payload erano già presenti. Build release e firma ad hoc verificate. Gli installer Microsoft non sono stati eseguiti sui container reali durante questa verifica.

La modifica automatizza le dipendenze dichiarate negli script supportati; non certifica la compatibilità di tutti i giochi, non installa driver GPU Windows sul Mac e non introduce nuovi profili grafici. Le operazioni di registro negli installscript e i percorsi esterni non riconosciuti restano segnalati anziché eseguiti alla cieca. L'installazione dei runtime Microsoft in Wine può ancora fallire per limiti del runtime; il messaggio identifica il componente e il gioco non viene marcato pronto. Riferimento: [Steamworks Common Redistributables](https://partner.steamgames.com/doc/features/common_redist).

## 0.6.3 — Attesa dell'inizializzazione Wine e diagnosi

Il controllo immediato dei file del prefix dopo `wineboot` poteva fallire mentre Wine stava ancora scrivendo i registri. Sui container reali di Blood and Bacon e Nasty Zombies, i tre file richiesti sono ora presenti; i registri risultano scritti circa 14 secondi dopo kernel32.dll. È una spiegazione compatibile con il falso errore osservato, non una prova completa dell'avvio dei giochi.

La preparazione ora riusa un prefix che passa già la validazione. Quando serve inizializzarlo, attende fino a 60 secondi che tutti i file richiesti siano presenti, con controllo della cancellazione. Non elimina o ricrea container e salvataggi. Un timeout elenca i file ancora mancanti. La presenza di questi file verifica la struttura del prefix, non certifica la compatibilità del gioco o tutti i servizi Wine.

L'output della preparazione Wine viene raccolto in modo limitato e salvato nel log del gioco, con runtime, comando ed exit code. Nessun output di autenticazione Steam è incluso. Il pulsante **Apri log** è disponibile sui download falliti. I messaggi `nw_read_request_report` rappresentano invece errori di rete della console: da soli non identificano quale richiesta sia scaduta e non spiegano il fallimento del controllo locale dei file Wine.

Validazione: 47 test superati, inclusi creazione ritardata dei registri, timeout senza perdita dei file e cancellazione dell'attesa. Verifica dei container reali in sola lettura. Non sono stati avviati i giochi o gli installer Microsoft reali in questo passaggio.

## 0.6.4 — Preflight Steam Cloud e progetto della sincronizzazione senza GUI

Aggiunta la verifica sperimentale in sola lettura del cloud nel menu del gioco. Usa la sessione salvata e le API SteamKit2, senza avviare Steam.app o steam.exe. È stato aggiunto un planner a tre vie che riconosce conflitti e impedisce la propagazione automatica delle rimozioni. **Questa versione non sincronizza ancora salvataggi, trofei o ore con Steam.** La prova reale del helper in Codex è terminata con exit -11, senza modificare salvataggi; il preflight va verificato nell'app. 53 test automatici superati. Percorso diretto e ore locali conservati.

La scelta tecnica, il lavoro ancora necessario e i criteri di verifica su Cruelty Squad sono descritti in [docs/steam-headless-sync.md](docs/steam-headless-sync.md).

## 0.6.5 — Correzione del preflight Steam Cloud

La lettura di `EAppInfoSection.UFS` non era presente nello switch del motore e generava NotImplementedException dopo una richiesta cloud riuscita. Aggiunta la sezione `ufs` e gestito il caso senza configurazione UFS, senza far fallire la serializzazione. Gli errori del preflight ora viaggiano nel protocollo `cloud_error` con codici limitati e il tipo di eccezione, senza messaggi grezzi, URL o header. L'app distingue accesso negato, inventario parziale e problemi di servizio; il fallback non parla più di file di download o di spazio su disco.

54 test Swift superati. Verificato anche il helper .NET compilato con un test diretto, senza rete, che interroga lo stesso getter su una sezione UFS presente e su una sezione assente. Il preflight resta in sola lettura: trasferimenti dei salvataggi, ore e trofei Steam non sono ancora attivati.

## 0.7.0 — Lettura delle statistiche Steam e ripristino Auto-Cloud

Entrando in Steam Cloud l'elenco viene caricato automaticamente con nomi, date e dimensioni; Aggiorna elenco serve solo per una nuova lettura. Le voci cancellate/forgotten non sono elencate come salvataggi disponibili. L'account salvato viene riutilizzato senza lettura del Portachiavi.

Prima di Gioca, per un gioco Steam gestito e con account collegato, l'app richiede l'inventario e confronta SHA-1 e data con i file del container. Contenuto identico: nessun download. File mancante o cloud più recente: download verificato in staging e sostituzione atomica, dopo aver copiato gli originali in `Cloud/Backups/SteamID/AppID/UUID`. Una ricevuta restore.json associa i backup ai percorsi. Locale più recente: resta locale. Stessa data con contenuti diversi, orari nel futuro, errori di rete o file modificati durante il download: avvio sospeso senza sovrascritture; è disponibile Avvia con salvataggi locali. Le rimozioni non vengono propagate.

Il ripristino automatico supporta percorsi Auto-Cloud dichiarati nei metadati UFS: root comuni Windows nei profili Wine, GameInstall e root Mac, con root override/addpath semplici e pattern dichiarati. Rifiuta percorsi fuori dai pattern, symlink, profili Wine ambigui, root sconosciute e pathtransforms. I giochi che usano soltanto il cloud tramite Steam API, file cifrati o trasferimenti HTTP non sono ancora supportati dal restore diretto. Trasferimenti HTTPS non cifrati e ZIP con un singolo file sono verificati per dimensione e hash. Il helper conserva al suo interno URL e header temporanei di accesso.

Ore e conteggio dei trofei già presenti su Steam vengono letti tramite Player.GetOwnedGames e Player.GetAchievementsProgress autenticati. La libreria si aggiorna all'apertura con la sessione salvata; la scheda Trofei aggiorna i dati del singolo gioco. I dati non disponibili non sono rappresentati come zero. Il tempo dei processi registrato in MacGameDeck rimane separato. Questa modifica **non invia nuove ore o nuovi sblocchi a Steam**, non introduce un ponte Steam API e **non carica i salvataggi locali nel cloud**.

Il crash del helper nel preflight è stato riprodotto e isolato nel provider hardware SteamKit per macOS: la lettura del disco può restituire un dizionario nullo. L'app ora usa IMachineInfoProvider con un UUID stabile dell'installazione salvato in `Account/steam-machine-id` (0600), indipendente da credenziali, password e account. I client HTTP dei servizi Steam non usano un cookie jar del browser.

Validazione: 61 test passati, inclusi download prima dell'avvio diretto mediante helper simulato, backup/data, precedenza locale/cloud, conflitti, hash corrotti, modifiche locali durante il download, percorsi/pattern/symlink e root override con maiuscole differenti nei metadati reali Blue Revolver. La query autenticata reale Blue Revolver ha restituito minuti e conteggio dei trofei senza client Steam o QR. Scaricati in staging temporaneo e verificati contro SHA-1/dimensioni reali i cinque salvataggi Cruelty Squad e il salvataggio principale Blue Revolver; poi lo staging è stato eliminato. Nessun salvataggio reale dell'utente è stato sostituito durante lo sviluppo: il restore nel container resta verificato dai test automatici, non da una partita reale.

Il replay Blue Revolver presente nell'inventario non corrisponde ai pattern Auto-Cloud e non viene ripristinato in un percorso inventato. Le voci Steam API fuori dai pattern sono visibili nell'elenco, ma escluse dal restore diretto; non impediscono il ripristino dei salvataggi Auto-Cloud supportati. Se tutte le voci sono prive di mapping, l'app segnala il limite e permette l'avvio con i dati locali. Le date uguali con contenuti differenti richiedono una risoluzione, non una sovrascrittura automatica. Le richieste di trasferimento temporaneamente scadute vengono riprovate automaticamente, al massimo tre volte.

## 0.8.0 — Community nativa e Steam in gioco

Trofei, salvataggi e Workshop ora usano SwiftUI: non viene più incorporata una pagina Steam/WebKit. I trofei hanno icone, descrizioni, filtri ottenuti/da ottenere e date dal server; il cloud mostra file, dimensioni, date e presenza locale; il Workshop usa PublishedFile.QueryFiles con ricerca/paginazione, anteprime e download delle singole mod. L'attivazione delle mod conserva il flusso di selezione della cartella indicata dall'autore, perché i giochi hanno formati differenti.

Download distingue il lavoro attivo, la coda/interrotti e la cronologia. Completati e annullati passano in cronologia; rimozione e Svuota cronologia eliminano soltanto le voci, non i file del gioco. L'annullamento ferma il worker e conserva i file scaricati. Una voce attiva annullata non può essere rimossa fino alla fine effettiva del worker. Timestamp di completamento persistente, progresso, byte ricevuti/totali, velocità, pausa e priorità.

Il selettore Store è sostituito, nella sezione Steam, dal profilo con avatar e menu degli otto stati Persona. Un helper SteamKit interno mantiene la connessione: lo stato non è una preferenza grafica simulata. Riutilizza account e identificatore macchina senza Portachiavi, con LoginID diverso dai download, comandi privati, risultati atomici e chiusura quando il parent termina. Gli stati vengono conservati per account; il primo collegamento parte Offline. Non si installa né avvia il client ufficiale Steam.

Per i giochi Windows con DLL Steam API riconoscibile, prepara automaticamente il ponte GSE x86/x64 della release fissata release-2026_09_27. Le DLL originali e i file di configurazione sostituiti sono copiati in SteamBridge/Backups prima di ogni modifica; la ricevuta permette il recupero. Il menu Ripristina Steam API originale disattiva l'integrazione per quel gioco; Attiva trofei in gioco la riabilita. Native macOS, librerie non riconosciute e cartelle EasyAntiCheat/BattlEye non vengono sostituiti. Non sono inclusi client Steam, unpacker SteamStub o sblocchi DLC: unlock_all è disabilitato.

Lo schema autenticato alimenta la configurazione, con stato reale dei trofei e valori iniziali delle statistiche. I dati del ponte sono separati per account nel prefix. Un osservatore rileva soltanto cambiamenti earned di nomi conosciuti, con data della sessione, mostra un popup NSPanel senza spostare il focus e conserva un journal. Il servizio invia i bit richiesti mantenendo tutti gli sblocchi esistenti, senza reset, usa CRC fresco, verifica la risposta e rilegge il server prima di dichiarare sincronizzato. Gli eventi offline restano in attesa e vengono riprovati; le notifiche non ripetono i trofei iniziali. Il popup indica un evento ottenuto nel gioco, non una conferma già ricevuta dal server. L'invio delle ore usa GamesPlayed solo per i processi monitorati ancora vivi, con controllo PlayingBlocked senza sostituire la partita su un altro dispositivo; le ore vengono rilette alla chiusura. Non somma ore offline retroattivamente.

Verifica: 70 test Swift superati, più regressioni helper su tipi di schema testuali/numerici, mantenimento dei bit esistenti, assenza di reset e rifiuto dei nomi sconosciuti. Verificati su Steam reale profilo/avatar, 41 descrizioni/trofei di Blue Revolver con lo stato già ottenuto, una pagina Workshop Terraria di 24 elementi e il round trip StoreStats/rilettura usando esclusivamente un trofeo già ottenuto: tutti gli sblocchi e le date sono rimasti uguali. Nessun nuovo trofeo è stato assegnato durante questi test.

**Ponte in gioco sperimentale:** il test Windows isolato SetAchievement/StoreStats non è stato eseguibile nell'ambiente Codex: wineserver fallisce con Can't check in server_mach_port prima di caricare la DLL. Non è stata verificata una nuova conquista ottenuta durante una partita Wine né l'overlay in fullscreen. Non dichiarare compatibilità universale o una partita reale verificata. Il ponte introduce una sostituzione reversibile della DLL e richiede validazione per gioco; Steam multiplayer, DRM e versioni SDK possono avere limiti. Il ripristino/upload bidirezionale dei salvataggi non viene ampliato in questo passaggio.

GSE è un componente GPL, con licenza nelle risorse, hash dei due binari e archivio dei sorgenti della release in Helpers/SteamBridge. Fonte upstream: https://github.com/Detanup01/gbe_fork/tree/release-2026_09_27 . Protocollo e vincoli stats: https://partner.steamgames.com/doc/api/ISteamUserStats .

### Preparazione automatica 0.8.1
All'avvio e al ritorno nell'app vengono riletti i manifest delle librerie Steam locali. I giochi installati sono proposti con **Gioca**; un unico bundle Mac valido viene avviato direttamente. Installazioni con avvio ambiguo restano avviabili tramite lo store, senza scaricare nuovamente i file.

I container Windows vengono controllati anche prima dell'avvio: gli script Steam recuperano i redistributable mancanti, mentre Visual C++ 2015–2022 viene recuperato dai link HTTPS ufficiali Microsoft per le architetture PE presenti nel gioco. La cache evita nuovi download; una ricevuta con hash delle DLL nel singolo container viene verificata a ogni avvio. Le versioni 2015+ degli script Steam sono sostituite dal pacchetto aggiornato per evitare downgrade. L'installazione si interrompe con diagnostica se Wine o il componente falliscono. Questo automatizza i runtime supportati, ma non garantisce compatibilità con tutti i giochi, DRM o anti-cheat.

### Log e runtime 0.8.2
La pagina **Log** mostra gli eventi dell'app, le operazioni Steam, preparazione/avvio Wine e i tre log Visual C++ più recenti del container selezionato. Aggiornamento automatico, filtro, copia ed esportazione; il log dell'app ruota a 1 MB e la vista legge solo la coda dei file. Nessun output grezzo di autenticazione Steam viene registrato. Token/password riconoscibili vengono oscurati, compresi negli export.

Il codice Wine 102 corrisponde al risultato troncato dell'installer Visual C++ che rifiuta un downgrade (Windows 1638/0x80070666). La registrazione Microsoft e l'architettura/versione PE delle DLL sono verificate prima del download. Un runtime 14.44+ già presente viene riconosciuto, incluso 14.51 osservato nel container Denshattack. Il codice 102 non viene accettato per componenti mancanti o installer diversi da Visual C++. x86 non richiede `vcruntime140_1.dll`, prevista per x64.

Nei log dei trofei si distinguono monitor attivo, evento ricevuto dal gioco, popup creato/visibile nello spazio attivo e conferma Steam. **Prova notifica trofeo** è solo una prova locale della finestra: non crea eventi né sblocchi su Steam. I test del watcher usano eventi simulati e confermano deduplicazione, journal offline e richiesta del popup; la nuova cattura Windows durante una partita reale resta da verificare, perché il test Wine isolato non riesce ad avviare wineserver nell'ambiente Codex.

Riferimento Microsoft sul controllo della versione installata per evitare downgrade: https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files?view=msvc-170

### Avvio Unreal e DirectX 12 (0.8.3)
Il bootstrapper Unreal viene riconosciuto dalle risorse Windows e l'app legge il target esatto RCDATA 201 e gli argomenti RCDATA 202, preservando la directory di lavoro e gli argomenti Steam. L'eseguibile dichiarato deve essere presente nel gioco, senza traversal/symlink e con architettura coerente. Dopo la preparazione delle dipendenze viene avviato direttamente il processo del gioco: il monitor di ore/trofei non segue più soltanto il breve launcher Unreal.

L'ambiente del runtime CrossOver include i percorsi Wine, il loader e `libd3dshared` già installati, e abilita AVX Rosetta come il launcher CrossOver, rispettando un'eventuale disattivazione esplicita. Per eseguibili x64 con evidenza DirectX 12 viene selezionato D3DMetal disponibile nel runtime. Non vengono modificati CrossOver, DLL di sistema del Mac o impostazioni dei giochi non riconosciuti come DirectX 12. I messaggi Wine `err` restano attivi e il log indica eseguibile reale e profilo grafico.

Il controllo in sola lettura dell'installazione Denshattack risolve `Denshattack_Proto/Binaries/Win64/Denshattack_Proto-Win64-Shipping.exe`, conserva l'argomento `Denshattack_Proto` e rileva il renderer D3D12. Il vecchio codice 41 non permette di attribuire con certezza la causa del crash: la build corregge l'ambiente e l'avvio, ma una partita reale deve ancora confermare che l'uscita sia risolta.

## Motore autonomo 0.9.0

- La prima installazione o il primo avvio Windows prepara automaticamente WineCX FOSS 24.0.7_7 (~164 MiB), le librerie di supporto (~184 MiB) e DXMT 0.80 (~18 MiB). Il motore è condiviso, con container e salvataggi separati per gioco. Download originali HTTPS con dimensione e SHA-256 fissati; cache verificata, staging, pubblicazione atomica e recupero della cartella precedente in caso di errore. La preparazione compare nell'app con progresso e annullamento. Una volta installato non serve riscaricarlo per ogni gioco.
- CrossOver non viene cercato, copiato o avviato. Non occorre installare Wine o Homebrew. Sono conservati i pacchetti originali e le note upstream; vedi Resources/RuntimeNotices. Su Apple Silicon l'esecuzione x86 richiede Rosetta 2, componente macOS.
- Steam resta un servizio remoto: login, libreria, download, metadati, cloud e statistiche usano il helper incluso e la sessione salvata. Per le installazioni esterne viene letto il percorso ufficiale di avvio dal servizio Steam; non viene aperto `steam://` e non vengono scaricati nuovamente i payload del gioco. Sono ancora necessari account/licenze validi.
- Il passaggio dei vecchi container al motore autonomo fa un backup dei registri prima di `wineboot -u`; payload e salvataggi non vengono rimossi. Le dipendenze vengono preparate anche per gli eseguibili importati.
- DXMT copre DirectX 10/11. Sugli avvii Unreal riconosciuti con modulo D3D11, in assenza di renderer esplicito, si usa il profilo DX11. La presenza del modulo non certifica che ogni gioco accetti il fallback: shader/progetto possono richiedere DX12. Non è incluso D3DMetal proprietario; titoli DX12-only, DRM che richiedono il client originale, anti-cheat e alcuni titoli nativi restano da verificare o non supportati. Non presentare questa versione come compatibile con ogni gioco Steam.

Verificato download/hash/estrazione delle release reali e avvio di Wine `--version` dall'installazione privata; verificata su account reale la lettura dei metadati Denshattack senza client Steam. La prova non certifica il rendering o una partita Denshattack nel nuovo motore. I limiti su upload cloud e cattura dei nuovi trofei restano quelli documentati per la 0.8.x.

### Correzione 0.9.7: inizializzazione Windows e Sektori

Il motore autonomo usa WineCX FOSS 24.0.7_7, distribuito dal progetto Sikarugir, senza richiedere l’app CrossOver. Include le librerie macOS necessarie da un archivio separato verificato. Controlla gli export Metal effettivi di winemac.so e inizializza Windows in un container di prova prima di preparare i giochi: la sola presenza dei pacchetti non viene considerata una verifica di avvio.

Quando cambia il motore, salva i registri e tutti i moduli Wine da aggiornare prima di sostituirli. Le DLL Microsoft native e i salvataggi vengono conservati. La diagnosi è disponibile in Log → Motore Windows · Bootstrap. Il pulsante “Prepara e verifica motore” esegue anche la prova di inizializzazione.

Verifica del 22 ottobre 2026 su questo Mac: bootstrap del motore e aggiornamento del container Sektori terminati con codice 0; avvio con DXMT riuscito e menu del gioco confermato dall’utente. Questa prova non certifica altri giochi o la sincronizzazione Steam: durante l’avvio è stato registrato anche un timeout separato del servizio Steam Cloud.
