# MacGameDeck — anteprima 0.3

App macOS Swift/SwiftUI per Apple Silicon, macOS 13+. Il progetto e il nome dello schema Xcode restano `MacGameDock` per mantenere le impostazioni esistenti. L'app si presenta come **MacGameDeck**. Usa la cartella dati precedente, senza migrazioni distruttive.

## Aprire l'app e il progetto

La app compilata si trova accanto alla cartella del progetto: `MacGameDeck.app`. Aprila dal Finder. È una build locale firmata ad hoc, senza notarizzazione.

In Xcode apri **Package.swift**, seleziona lo schema MacGameDock / My Mac e premi ⌘R. Le risorse includono già il motore Steam e il runtime .NET: non occorre installare .NET per eseguire l'app o compilare Swift.

Per ricreare l'app: `./scripts/build-app.sh`. L'output predefinito è `dist/MacGameDeck.app`. Sono configurabili `MACGAMEDOCK_BUILD_DIR` e `MACGAMEDOCK_APP_OUTPUT`.

## Accesso e installazione diretta Steam

1. Account Steam → **Accedi con QR Steam** (o **Ricollega con QR** per l'account della versione precedente).
2. Scansiona il codice mostrato nell'app usando Steam Guard sul telefono e conferma MacGameDeck.
3. Dopo il caricamento della libreria cerca il gioco e premi **Installa**.
4. L'app scarica e verifica i depot Windows nel suo container, legge i metadati di avvio, inizializza Wine ed esegue le dipendenze supportate incluse nel gioco. Dopo la preparazione il pulsante diventa **Gioca**.

Non si apre Steam per il download o per la richiesta di avvio diretta. La sessione viene salvata nel Portachiavi e riutilizzata finché valida. La chiave Web API non è più richiesta. Il vecchio catalogo viene conservato se la nuova lettura fallisce. La sessione download è distinta dal precedente login OpenID.

È possibile una sola operazione Steam alla volta. Il pannello inferiore mostra QR, fase/progresso e Annulla. I download parziali restano disponibili per essere ripresi premendo Installa; `-validate` verifica i file già presenti. Non è ancora disponibile una coda persistente, aggiornamento automatico o gestione Steam Cloud/Workshop.

## Container e runtime

Cartella dati: `~/Library/Application Support/MacGameDock/`.

- `Containers/Steam/APPID/prefix`: ambiente Windows dedicato.
- `prefix/drive_c/Program Files/MacGameDeck/Games/APPID`: file del gioco.
- `library.json`: catalogo e percorsi, scritto atomicamente.
- `Logs/`: output degli avvii Wine; il log del gioco viene sostituito a ogni avvio.
- `Tools/SteamRuntime`: copia verificata del motore Steam incluso nell'app.

Il runtime Wine installato in CrossOver viene rilevato automaticamente, come alcuni percorsi Wine noti. Il motore Windows non è redistribuito. Se non è presente, l'app lo segnala. È possibile selezionare un runtime alternativo in Il tuo Mac. Non viene modificata un'installazione già gestita dal client Steam: MacGameDeck scarica una propria copia Windows. La scansione non sovrascrive i container gestiti.

L'eseguibile viene scelto dai metadati Steam, senza cercare casualmente file `.exe`. Percorsi esterni, traversali o collegamenti simbolici sono rifiutati. Un download o prefix incompleto non viene registrato come pronto. Sono supportati installer `.exe`/`.msi` degli script `Run Process` sotto `%INSTALLDIR%`; gli script del registro e installer esterni ai file del gioco fermano la preparazione con un messaggio. Gli installer riusciti sono memorizzati per non ripeterli.

Backend DirectX/Metal, risoluzione e qualità non sono ancora ottimizzati per ogni titolo. Viene usato il runtime rilevato con configurazione standard. Alcuni giochi richiedono client Steam Windows, DRM o servizi Steamworks: questa versione non fornisce quei servizi e non ne garantisce l'avvio, multiplayer, achievement o cloud. Non tutti i giochi sono supportati. Il processo Wine monitorato può terminare prima di un launcher figlio.

Primo caso scelto dall'utente: **Nasty Zombies**, [Steam AppID 2851700](https://store.steampowered.com/app/2851700/Nasty_Zombies/). La prova con l'account e l'installazione reale resta da effettuare nell'app; non è certificata la compatibilità su M1.

## Account e sicurezza

La sessione è un refresh token Steam, non la password. Viene conservata nel Portachiavi (`com.macgamedeck.steam-session`). Durante ogni operazione è resa disponibile al helper in una cartella privata temporanea (0700, account.config 0600 se preesistente), poi la cartella viene rimossa. Cartelle rimaste da un'interruzione anomala vengono rimosse dopo 24 ore all'avvio. Non si persistono stdout, QR o token nei log. I metadati protocollo collegano il catalogo e il download allo SteamID atteso; un account diverso viene rifiutato. Scollega elimina la sessione e il catalogo cloud, conservando i file locali.

Il codice OpenID/Web API della versione precedente resta nei sorgenti con i test, ma il flusso principale usa la sessione Steam diretta. Una chiave Web API precedente resta nel Portachiavi originale e non viene utilizzata dal nuovo flusso.

L'anteprima non usa App Sandbox. Per prove isolate: `MACGAMEDOCK_DATA_DIRECTORY=/percorso/assoluto`. Non salvare o condividere la cartella dati con sessioni attive.

## Altri store

Epic e GOG mantengono scansione/importazione delle installazioni locali. Epic può ancora avviare il suo client. Login e download autonomi Epic/GOG non sono inclusi in questa versione. Per Steam sono lette le licenze e le informazioni prodotto dell'account; DLC e contenuti non avviabili non diventano giochi separati. Metadati dei pacchetti incompleti non sostituiscono la cache valida.

## Verifica e componenti

Build Swift debug e release su Apple Silicon con Xcode 26.3. 20 test XCTest passati su parser, cataloghi, sicurezza HTTP/OpenID, manifest, metadati di avvio, argomenti Windows, attraversamento di percorsi/symlink, conservazione dei container e dipendenze. Il motore incluso si avvia su .NET 9.0.20. Login/download autenticati non esercitati dall'agente. La prova Wine in ambiente di sviluppo isolato incontra il limite `server_mach_port`; l'app deve essere provata normalmente sul Mac.

Motore download: [SteamRE DepotDownloader 3.4.0](https://github.com/SteamRE/DepotDownloader/releases/tag/DepotDownloader_3.4.0), con [SteamKit](https://github.com/SteamRE/SteamKit), componenti comunitari. Le modifiche aggiungono protocollo JSON, QR nell'app, catalogo licenze, metadati di avvio, completezza dei depot e sessioni temporanee. GPLv2 e sorgenti corrispondenti inclusi in `Helpers/SteamDownloader/Source`, script di patch e ricostruzione a fianco. Il runtime Microsoft è separato con licenza e ThirdPartyNotices. Nessun binario CrossOver è incluso.

Per ricostruire il helper serve .NET SDK 9: `Helpers/SteamDownloader/build-helper.sh` (variabile `MACGAMEDECK_DOTNET` per un percorso alternativo). Lo script aggiorna le risorse e il manifesto SHA-256. La compilazione Swift usa i binari inclusi e non scarica componenti.
