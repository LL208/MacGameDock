# Steam senza client grafico: scelta e stato dell'implementazione

La scelta per MacGameDeck è un servizio di connessione Steam interno basato su SteamKit2, condiviso tra download, cloud e attività, con avvio diretto dei giochi. Non ripristinare l'avvio tramite steam.exe/Steam.app della 0.6.0: non soddisfa il requisito e aveva regressioni di installazione. Il primo titolo di prova concordato è Cruelty Squad (1388770), che dichiara Steam Cloud e Steam Achievements sulla pagina ufficiale.

## Le tre funzioni hanno requisiti diversi

| Funzione | Durante la partita | Alla chiusura | Limite da gestire |
|---|---|---|---|
| Salvataggi Steam Auto-Cloud | Il gioco scrive i suoi file locali | Confronto e upload dei file modificati; download prima del prossimo avvio | Metadati UFS, root overrides Windows/macOS, conflitti e formati cross-platform |
| Ore su Steam | Connessione autenticata e notifica GamesPlayed riferita al processo reale monitorato | Notifica di fine partita e verifica del conteggio restituito da Steam | Non assumere che ore accumulate offline possano essere sommate retroattivamente; rispettare sessioni attive su altri dispositivi |
| Trofei | Un ponte Steamworks registra solo SetAchievement/StoreStats effettivamente chiamati dal gioco | Invio degli eventi validati, con journal offline e retry | ABI e versioni delle interfacce Steamworks del singolo gioco; la sola durata o il salvataggio non dimostrano genericamente uno sblocco |

L'API Steamworks ufficiale richiede un client che implementi le interfacce. SteamKit2 fornisce il trasporto verso i servizi Steam, ma non implementa da solo l'ABI Steamworks che il gioco Windows si aspetta. GameNative dimostra una soluzione senza GUI usando un componente compatibile (GSE/Goldberg), che produce eventi locali, e un servizio autenticato che li sincronizza. Le librerie Android di GameNative non sono un componente sostituibile direttamente nel nostro launcher macOS. Occorre portare/integrarne uno compatibile con Wine, per profili testati, preservando gli originali e il percorso di avvio diretto. Non stimare trofei, non sbloccarli in massa, non dichiarare online una sincronizzazione solo perché il gioco è terminato.

## Flusso da completare

1. Connessione persistente con la sessione salvata e un proprietario unico per le operazioni Steam; evitare helper concorrenti con lo stesso LoginID e gestire PlayedElsewhere/PlayingBlocked senza sostituire la sessione dell'altro dispositivo.
2. Preflight cloud completo, vincolato a SteamID/AppID. Mappatura dei percorsi dai metadati UFS verso le cartelle effettive del container, senza uscire dai percorsi autorizzati.
3. Confronto a tre vie (locale, cloud, baseline precedente), hash dei contenuti, backup versionato prima di ogni restore. Due copie differenti al primo collegamento sono un conflitto. Una rimozione non viene propagata automaticamente. Non usare solo l'orario dei file.
4. Download in staging, verifica hash/decompressione/cifratura quando richiesti, poi sostituzione atomica e baseline. Se il preflight fallisce, non sovrascrivere i salvataggi e offrire l'avvio offline.
5. Gioco avviato direttamente; attività Steam inviata solo mentre il processo verificato è attivo. Il processo del servizio non è tempo di gioco. Serve riconoscere anche i processi figli che sopravvivono al launcher Wine.
6. Alla chiusura: snapshot e backup, nuovo controllo della revisione remota, upload batch con verifica e gestione di quota/errori/concorrenza. Non cancellare remote saves automaticamente.
7. Ponte Steamworks per i titoli supportati: journal vincolato a account, AppID e sessione; schema/versioni delle statistiche dal server; invio dei soli eventi earned ricevuti dal gioco e conferma server prima di marcarli sincronizzati.

## Preflight iniziale (0.6.4)

- CLI `-app <appid> -deck-cloud-inventory <file>` nel motore: richiede un inventario completo a Cloud.GetAppFileChangelist e legge i metadati UFS. Esporta hash, nomi, namespace, revisione e configurazione; non scarica contenuti dei salvataggi, non esporta URL/header di accesso e non esegue upload/delete.
- Swift: lettura dell'inventario vincolata ad account e gioco, rifiuto di delta parziali/percorsi non sicuri/duplicati; confronto a tre vie per upload/download/conflict, con protezione delle rimozioni. Il planner non applica decisioni ai file.
- Menu del gioco → Workshop, cloud e trofei → Steam Cloud → Verifica Steam Cloud: preflight in sola lettura con sessione già salvata, senza avvio del client Steam.
- 53 test automatici superati; helper .NET compilato. La prova reale in Codex è terminata con un crash del helper (SIGSEGV, exit -11). Non è stata individuata la causa e non è stato ricevuto un inventario completo. Nessun save è stato modificato. Serve ripetere il preflight nell'app macOS per distinguere un problema del helper da una limitazione dell'ambiente di esecuzione.

**Non ancora implementati/attivati:** trasferimento e restore dei salvataggi, backup versionato integrato, connessione persistente e ore reali su Steam, ponte Steamworks e upload dei trofei. Questa build è un preflight, non la sincronizzazione completa richiesta. Le ore continuano a essere quelle locali già presenti nella 0.6.3. Le DLL del gioco e i suoi salvataggi non sono stati modificati.

## Criteri di accettazione su Cruelty Squad

- Il preflight restituisce account/AppID corretti e configurazione UFS interpretabile senza client grafico.
- Due progressi diversi su due dispositivi generano un conflitto e nessuna sovrascrittura prima di una scelta.
- Un trasferimento interrotto conserva entrambe le copie e il backup è ripristinabile.
- Un avanzamento effettuato nel gioco su Mac compare sul secondo dispositivo dopo un upload confermato; il percorso inverso è verificato separatamente.
- Una partita online reale cambia il tempo di gioco riportato da Steam; nessun incremento per la durata del helper, per un avvio fallito o per un periodo offline non riconciliato.
- Un obiettivo realmente ottenuto compare su Steam senza cambiare altri trofei e senza aprire/installare il client grafico.
- L'avvio diretto che funziona attualmente resta funzionante quando il servizio è offline o disattivato.

## Fonti primarie

- Steam Cloud e Auto-Cloud: https://partner.steamgames.com/doc/features/cloud
- Requisiti Steamworks e SteamAPI_Init: https://partner.steamgames.com/doc/api/steam_api
- StoreStats e obiettivi: https://partner.steamgames.com/doc/api/ISteamUserStats
- GameNative, servizio e sincronizzazione dei trofei: https://github.com/utkarshdalal/GameNative/blob/master/app/src/main/java/app/gamenative/service/SteamService.kt
- GameNative, confronto e trasferimenti AutoCloud: https://github.com/utkarshdalal/GameNative/blob/master/app/src/main/java/app/gamenative/service/SteamAutoCloud.kt
- API cloud generate SteamKit2: https://github.com/SteamRE/SteamKit/blob/master/SteamKit2/SteamKit2/Base/Generated/SteamMsgCloud.cs
- Cruelty Squad, supporto Cloud e Achievements: https://store.steampowered.com/app/1388770/Cruelty_Squad/

## Stato 0.7.0

Implementati caricamento automatico dell'elenco, download autenticato in staging, controllo dimensione/SHA-1, ripristino di percorsi Auto-Cloud dichiarati supportati e backup con ricevuta. Per richiesta dell'utente, nel restore pre-avvio la data più recente ha priorità dopo confronto dei contenuti; date uguali con contenuti diversi sono un conflitto. Il planner a tre vie resta disponibile per la futura gestione dell'upload. La pagina Trofei e il catalogo leggono minuti e conteggi reali dall'account tramite servizi Player, separati dalle ore locali.

Restano da implementare upload/baseline a fine partita, connessione persistente GamesPlayed e ponte Steamworks per nuovi trofei. SDK-cloud senza root Auto-Cloud riconoscibile, cifratura e path transforms complessi non sono supportati dal restore. Il crash in CoreFoundation è stato isolato nel provider hardware macOS SteamKit e corretto usando un’identità stabile dell’installazione. Validati su Steam reale la lettura delle statistiche Blue Revolver e il download in staging con verifica hash dei cinque saves Cruelty Squad e del save principale Blue Revolver. I test del restore usano file simulati; nessun save reale è stato sostituito. I file Steam API fuori dai pattern dichiarati sono esclusi dal restore, inclusi i replay Blue Revolver. Non presentare questa versione come sync bidirezionale completa o come sblocchi/ore inviati a Steam.

## Stato 0.8.0

Il client di compatibilità Steam API Windows GSE è incluso e integrato con preparazione automatica e backup/recovery. Il watcher raccoglie i nuovi earned dalla partita, conserva il journal e invia i bit allo schema corrente tramite ClientStoreUserStats2; la conferma richiede la rilettura del server. Il servizio resta connesso per Persona e GamesPlayed, controlla PlayingBlocked/PID/parent e non forza altre sessioni. GUI trofei/cloud/Workshop nativa, senza pagine incorporate. I binari non sono installati nei prefix reali dai tool durante lo sviluppo: l'app lo farà all'avvio dei giochi supportati.

Il trasporto di lettura e StoreStats è verificato su Steam reale con un obiettivo già ottenuto, senza cambiamenti di progressi o date. Restano da verificare in partita la cattura DLL Windows e il popup: il test Wine isolato nell'ambiente Codex fallisce al bootstrap wineserver/mach_port, prima della DLL. Il ponte resta sperimentale per i singoli giochi; macOS nativo non usa questa DLL. Upload cloud e nuovi trasferimenti SDK-cloud non sono implementati da questa versione.

## Stato 0.8.1

Corretto il percorso di avvio dei giochi Steam esterni: un'installazione rilevata non apre più la selezione di download. Un bundle Mac unico e valido viene avviato direttamente; per installazioni ambigue rimane il collegamento allo store. Componenti Windows ricontrollati anche prima dell'avvio, con ricevute per prefix e recupero HTTPS Microsoft di Visual C++ 2015–2022 in base alle architetture PE. I vecchi script 2015+ non causano downgrade. Il pacchetto x64 ufficiale è stato scaricato correttamente; 72 test Swift superati. L'avvio effettivo di Denshattack sul Mac dell'utente resta da provare. Le limitazioni di cloud e ponte trofei della 0.8.0 restano valide.

## Stato 0.8.2

Aggiunta pagina Log con eventi applicazione/Steam/trofei, code dei log Wine e dettagli degli ultimi installer Visual C++ per container, aggiornamento live, filtro/copia/export e prova popup locale senza sblocchi. Il log dell'installer Denshattack conferma 0x80070666 (versione più recente già installata). Il controllo in sola lettura del container reale riconosce runtime 14.51 x64/x86; corretto il falso requisito `vcruntime140_1.dll` su x86. I codici 102 vengono accettati solo per Visual C++ con registrazione e DLL PE/versione compatibili verificate. Test watcher: un solo popup richiesto per nuovo evento noto, esclusione degli sblocchi già presenti/sconosciuti, journal offline, prova notifica senza invio Steam. La verifica ABI isolata Wine resta inconcludente: wineserver/mach_port non si avvia; la visibilità del popup nella partita reale non è certificata. Nessun nuovo trofeo dell'account reale è stato simulato o forzato.

## Stato 0.9.0

Runtime Windows gestito direttamente: download Wine Staging 11.18 e DXMT 0.80 upstream, verifica dimensione/SHA-256, cache/staging/installazione atomica, annullamento e backup dei registri dei container prima della migrazione. Rimossa la ricerca automatica di CrossOver e la scelta obbligatoria di un eseguibile esterno. Verificata l'estrazione dei pacchetti reali e l'avvio del Wine privato con `--version`; nessun container reale viene modificato dai test.

Il comando helper `-deck-launch-metadata` legge solo i metadati di avvio, senza download del gioco. Verificato su Steam reale per Denshattack. Le installazioni esterne vengono adottate usando l'eseguibile dichiarato; il ripiego `steam://` è eliminato. Il servizio Steamworks Windows può essere installato anche con schema trofei vuoto, senza sintetizzare sblocchi. Gli avvii Windows con Steam SDK riconosciuto ma senza ponte locale pronto sono bloccati anziché ripiegare sul client. Le versioni Mac contenenti Steamworks originale vengono segnalate non supportate dal servizio autonomo; è disponibile la scelta Windows quando pubblicata.

DXMT gestisce DX10/11; i bootstrapper Unreal con modulo D3D11 e senza scelta esplicita usano DX11. Nessuna copia di D3DMetal da CrossOver è distribuita. Titoli DX12-only/DRM/anti-cheat e i giochi nativi con SDK Steam originale non sono universalmente supportati. La compatibilità reale di Denshattack nel nuovo motore non è certificata dal test `--version`. Restano le limitazioni cloud/trofei indicate per le versioni precedenti.
