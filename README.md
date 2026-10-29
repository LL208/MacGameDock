# MacGameDeck — anteprima 0.13.0

Launcher Swift/SwiftUI per Mac Apple Silicon, macOS 13+. Apri **MacGameDock.xcodeproj**, scegli **MacGameDeck / My Mac** e premi ⌘R. Il progetto genera MacGameDeck.app; Package.swift include i test della logica.

## Esperienza quotidiana

- Home **Continua a giocare**, preferiti, ricerca, raccolte personali e giochi nascosti. Ordinamento per titolo, ultima partita, ore Steam o aggiunta recente.
- Premi il titolo per aprire la pagina del gioco: installazione/avvio, attività, trofei, salvataggi, Workshop e manutenzione. Le informazioni dell’installazione si aggiornano quando termina il download.
- Compatibilità distinta fra versione da provare, processo avviato e funzionamento confermato dall’utente. Un processo avviato non certifica una partita funzionante.
- Avvio con indicazione dei passaggi e annullamento della preparazione. Gli errori cloud offrono Riprova oppure Gioca con i salvataggi locali.
- Impostazioni centralizzate: tema di sistema/scuro/chiaro, interfaccia più grande, ripresa dei download all’apertura e pausa durante il gioco.

## Installazione e download

Steam usa la sessione salvata senza QR a ogni operazione e senza lettura del Portachiavi all’avvio. Revoche o scadenze effettive richiedono un nuovo accesso. L’account viene verificato per ogni operazione. Le credenziali sono nella cartella dati privata, con permessi 0600/0700: non includere quella cartella nei sorgenti o nei report.

La versione Mac o Windows viene scelta prima del download. La disponibilità di un port Mac non certifica il funzionamento su Apple Silicon: i giochi nativi che richiedono Steamworks originale non sono ancora supportati dal percorso autonomo.

La coda ha pausa, ripresa, priorità, annullamento, progresso e cronologia. I file parziali restano disponibili; rimuovere una voce non disinstalla il gioco. È disponibile un limite aggregato dei blocchi scaricati da Steam (1/5/10/25 MiB/s), applicato alla prossima partenza/ripresa. La misura è indicativa e non comprende separatamente header HTTP, pacchetti del motore o trasferimenti cloud. Il completamento mostra un avviso nell’app con Gioca.

Puoi scegliere una cartella o un SSD esterno per i nuovi giochi; ogni lavoro conserva la destinazione. Un disco scollegato genera un errore, senza ricreare la sua cartella su un altro volume. Nella pagina di un gioco gestito puoi verificarne i file e riparare i componenti, oppure trasferire il container in una destinazione vuota: la copia viene verificata per hash, inclusi i collegamenti Wine, e l’originale resta conservato. Il trasferimento con mod registrate è sospeso finché non è supportato il loro aggiornamento dei percorsi.

**Disinstalla** sposta i file del gioco in Uninstalled/UUID/Game, conservando il prefix Windows e la voce del catalogo. Non elimina definitivamente dati e non libera spazio finché non rimuovi manualmente il backup. Le installazioni esterne non vengono disinstallate dall’app. **Rimuovi dalla libreria** è un’operazione distinta che conserva tutti i file.

## Steam Cloud

L’elenco si carica entrando nella pagina Cloud. Prima dell’avvio vengono confrontati hash e date per i salvataggi Auto-Cloud dichiarati: copia cloud più recente scaricata in staging e verificata; locale più recente conservata. Date uguali con dati diversi o percorsi ambigui sospendono l’avvio. Le copie sostituite sono salvate in Cloud/Backups.

La 0.10.0 aggiunge l’invio dopo la partita dei file Auto-Cloud modificati, con snapshot verificato, confronto con la versione remota vista prima dell’avvio e rilettura del server. I nuovi file vengono individuati solo nei percorsi e pattern dichiarati dal gioco. Se un altro dispositivo ha cambiato lo stesso file, la sincronizzazione si ferma: non viene scelta una copia automaticamente solo perché ha una data maggiore. Le rimozioni non vengono propagate.

Gli invii non completati restano in Cloud/Pending e vengono riprovati all’apertura, al prossimo avvio del gioco o con **Sincronizza ora**. I backup delle copie inviate restano in Cloud/Uploads. Per un conflitto puoi scegliere esplicitamente la copia Mac o Steam: prima della risoluzione viene salvata la copia remota e, se sostituita, anche quella locale.

**Ambito e verifica:** Auto-Cloud con percorsi supportati; il cloud tramite sole Steam API, percorsi trasformati e trasferimenti cifrati non sono supportati. La prova reale su Cruelty Squad ha letto cinque file, verificato un backup da 542 byte e completato il ciclo di batch/rilettura con un contenuto identico già presente: Steam lo ha deduplicato. Questa prova non certifica il trasferimento HTTP di nuovi progressi ottenuti in una partita; tale percorso è coperto da test con servizio simulato e resta da verificare con una partita reale.

## Ore e trofei Steam

La pagina gioco distingue tempo locale, ore lette da Steam, data dell’ultima lettura e numero di trofei ancora in attesa di conferma. Aggiorna ore e trofei rilegge il server. Le ore locali non vengono sommate a quelle Steam.

Nei giochi Windows compatibili il ponte Steam API rileva gli eventi, mostra notifiche native e conserva un journal degli invii non confermati. La partita viene segnalata a Steam solo mentre il processo monitorato è attivo; le ore vengono rilette alla chiusura. Non vengono aggiunte retroattivamente ore offline. Lo sblocco di un nuovo trofeo e il popup in fullscreen richiedono ancora verifica reale per gioco. I dati già presenti su Steam sono stati letti su account reale.

La sostituzione delle DLL Steam API è reversibile e conserva gli originali. Non sono promessi DRM, anti-cheat, multiplayer o Steam Input equivalenti al client ufficiale.

## Workshop e controller

Ricerca e download del Workshop sono nativi. Dopo la copia nella cartella scelta dall’utente, la mod compare nell’elenco persistente: Mostra file, Disattiva e Riattiva. La disattivazione sposta la cartella fuori dal gioco e la riattivazione rifiuta di sovrascrivere cartelle esistenti. Loader, dipendenze, aggiornamenti e ordine di caricamento non sono automatizzati; la presenza dei file non certifica che la mod sia caricata dal gioco.

La 0.11.0 apre una modalità Big Picture a schermo intero: libreria, pagina gioco, installazione, download, account/QR e presenza, trofei, cloud, Workshop, mod, impostazioni e log sono navigabili dal controller. Ricerca e scelta delle cartelle hanno tastiera e browser interni. A/✕ conferma, B/○ torna indietro, X/□ cerca, Y/△ preferito, L1/R1 cambia sezione, L2/R2 cambia pagina, Menu torna alla Home. Dal gioco, tenere Menu per 1,2 secondi riporta la finestra in primo piano, senza terminare il gioco. Le normali pressioni del controller in background non navigano nell’app.

La modalità desktop resta disponibile nelle impostazioni; dal desktop si rientra con «Modalità controller». GameController di macOS gestisce rilevamento e batteria. Le icone provengono dal profilo del controller attivo e cambiano passando fra i dispositivi riconosciuti da macOS (PlayStation, Xbox e altri profili compatibili). «Inverti Conferma e Indietro» è persistente e scambia anche i relativi suggerimenti, senza cambiare i comandi interni al gioco. Abbinamento Bluetooth, permessi macOS, Steam Guard sul telefono e rimappatura di sistema richiedono le rispettive interfacce. Controller virtuale e profili di input per gioco restano da implementare. I test automatici verificano ripetizione, focus, cronologia e conferme; la prova con un controller fisico resta distinta dalla navigazione tramite tastiera.

## Motore Windows e compatibilità

WineCX FOSS 24.0.7_7 e DXMT 0.80 vengono scaricati automaticamente da release upstream con dimensioni e SHA-256 fissati, insieme alle librerie macOS di supporto. Non servono le app Steam, CrossOver, Wine o Homebrew. Servono account/licenze Valve e Rosetta 2 per i componenti x86 su Apple Silicon.

Il controllo del motore include gli export Metal reali e il bootstrap Windows in un prefix di prova. I vecchi container vengono aggiornati con backup dei registri e dei moduli Wine, preservando le DLL Microsoft native. Le dipendenze Steam supportate e Visual C++ vengono preparate automaticamente.

DXMT copre DirectX 10/11: non include D3DMetal proprietario e non garantisce i titoli DX12-only. Sektori è arrivato al menu su questo M1 il 22 ottobre 2026; ciò non certifica tutti i giochi. Le stime dei requisiti restano generiche e non applicano profili grafici né inventano FPS.

## Verifiche e limiti della distribuzione

Build dell’app verificata in Xcode. La suite della logica è eseguita in una copia di test senza le sole viste SwiftUI: l’ambiente shell di Codex non esegue il plugin SwiftUIMacros della SDK Xcode 27. Le viste vengono invece compilate da Xcode e la pagina gioco è stata confermata visibile dall’utente in una libreria isolata. La suite attuale conta 108 test: 103 passati, 5 saltati e nessun fallimento. I test aggiunti coprono conflitti/cloud offline, invio e conferma con servizio simulato, preferenze persistenti, trasferimenti verificati e attivazione delle mod senza sovrascritture. Il runner C# verifica protocollo, account e limite aggregato di banda senza rete.

La build è firmata ad hoc, senza notarizzazione o aggiornamento automatico dell’app. `scripts/build-app.sh` produce una build SwiftPM dove il compilatore supporta i plugin della SDK; qui usare il progetto Xcode.

Le integrazioni Epic/GOG complete, aggiornamenti automatici dei giochi, profili grafici verificati, FPS misurati e modalità divano non sono ancora implementati. Vedi [stato degli interventi](docs/implementation-status-0.10.md). La [cronologia precedente](docs/history-through-0.9.7.md) è conservata separatamente per evitare descrizioni contraddittorie del comportamento attuale.

Dati: ~/Library/Application Support/MacGameDock/. Per prove isolate: MACGAMEDOCK_DATA_DIRECTORY con percorso assoluto. Log ed esportazioni oscurano i token riconosciuti; non esportare sessioni o salvataggi senza verificarne il contenuto.

## Componenti e sorgenti

DepotDownloader 3.4.0 / SteamKit2 e le modifiche corrispondenti sono in Helpers/SteamDownloader/Source. integration.patch si applica al tag originale; patch-upstream.py riconosce i sorgenti già modificati senza invertirli. Il runtime .NET e le relative licenze sono nelle risorse. GSE è GPL; licenza, hash e archivio dei sorgenti sono inclusi. Wine e DXMT hanno note/licenze in Resources/RuntimeNotices.

Riferimenti: [Steam Cloud](https://partner.steamgames.com/doc/features/cloud), [SteamKit](https://github.com/SteamRE/SteamKit), [GameNative Auto-Cloud](https://github.com/utkarshdalal/GameNative/blob/master/app/src/main/java/app/gamenative/service/SteamAutoCloud.kt).

## Novità 0.12.0 · interfaccia e artwork

Big Picture usa copertine verticali, uno sfondo e un logo del gioco selezionato, griglia adattiva e barra delle sezioni. Il pulsante Modalità PC in alto torna a mouse e tastiera; dal desktop il pulsante Big Picture riapre l’interfaccia controller. La scorciatoia comune è **⌘⇧B**; sui controller estesi il pulsante View/Share alterna le modalità mentre l’app è in primo piano. La scelta resta salvata tra gli avvii.

**SteamGridDB:** inserisci la tua chiave API in Impostazioni → Copertine e sfondi. Puoi ottenerla da https://www.steamgriddb.com/profile/preferences/api . La chiave viene conservata nella cartella privata Credentials con permessi 0600 e non viene inviata ai server delle immagini. Non includerla nei report o nei sorgenti. Anche Big Picture permette di inserirla con una tastiera mascherata (⇧ cambia maiuscole/minuscole).

Per i giochi Steam la ricerca usa l’App ID; per gli altri store viene accettata solo una corrispondenza univoca del titolo normalizzato. Copertine, sfondi e loghi vengono scelti automaticamente fra gli asset statici, escludendo i risultati marcati NSFW o humor. Le immagini e gli autori sono memorizzati localmente; la cache gestita è limitata a 256 MiB e aggiornata dopo sette giorni. Il fallback usa gli artwork Steam; in assenza di immagini mostra un segnaposto. La connessione a SteamGridDB non è necessaria per avviare un gioco.

### Riordino Home e Libreria · 0.12.1

Le sezioni compaiono soltanto nella barra superiore. Ricerca, selezione dei giochi installati, preferiti, store, ordinamento, raccolte e importazione hanno un’area dedicata sopra le copertine. La griglia centrale contiene esclusivamente giochi; i comandi di paginazione sono separati in fondo. Le frecce del controller passano tra tab, filtri, giochi e pagine rispettando la larghezza delle rispettive righe.

## Dettaglio del gioco · 0.13.0

La pagina di ogni titolo, sia desktop sia Big Picture, mostra descrizione breve/estesa, generi, sviluppatore, modalità dichiarate dallo store e conteggio dei giocatori online su Steam con ora della lettura. I dati vengono caricati all’ingresso; ogni fonte fallisce indipendentemente dalle altre. Le informazioni dello store sono conservate sul Mac per l’uso offline.

La sezione **I tuoi trofei** si aggiorna automaticamente, con progresso, icone e anteprima dei trofei ottenuti. La cache è distinta per account e gioco; i trofei nascosti mantengono titolo e descrizione protetti finché non sono ottenuti. La lettura non modifica DLL o salvataggi. Gioca resta in primo piano, mentre organizzazione e manutenzione sono raccolte nelle opzioni di gestione.

Il numero online è quello di Steam e non rappresenta il limite di giocatori per partita. Lo store raggruppa schermo condiviso e split-screen: l’app lo indica esplicitamente. Il massimo di giocatori locali non viene inventato se non è disponibile. Per titoli senza App ID Steam queste informazioni e i trofei Steam restano non disponibili. Riferimento: https://partner.steamgames.com/doc/webapi/ISteamUserStats .
