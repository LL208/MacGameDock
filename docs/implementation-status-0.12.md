# MacGameDeck 0.12.0 · artwork e layout

Big Picture ha griglia adattiva con copertine verticali, sfondo e logo del gioco selezionato, barra delle sezioni e controlli compatti. Il pulsante Modalità PC in alto, il pulsante Big Picture sul desktop e ⌘⇧B alternano le interfacce. Anche View/Share sui controller estesi permette il cambio mentre l’app è in primo piano. La preferenza è persistente.

SteamGridDB supporta copertine, immagini orizzontali, sfondi e loghi. Serve una chiave API personale configurabile nelle impostazioni desktop o con tastiera mascherata in Big Picture. La chiave è salvata privatamente (0600, cartella 0700), mai nei sorgenti o nei log e mai nelle richieste al CDN. Le richieste sono limitate a quattro contemporanee, con timeout e limiti di dimensioni e pixel.

Ricerca tramite App ID per Steam; solo corrispondenza univoca del titolo normalizzato per gli altri store. Scelta automatica degli asset statici, esclusione dei risultati marcati NSFW/humor, attribuzione all’autore. Cache locale gestita fino a 256 MiB, immagini decodificate fino a 96 MiB/64 voci. Un refresh offline conserva l’artwork già presente. Quando mancano risultati si usano immagini Steam o un segnaposto.

## Verifica

Suite di logica: 122 test, 117 superati e 5 saltati. Eseguita in Xcode e ripetuta da terminale con una cartella temporanea senza alias; comprende richieste API simulate, controllo dell’header Authorization, download senza chiave al CDN, cache offline, refresh fallito che conserva la copertina, filtri degli asset e permessi delle credenziali.

La build nativa Xcode compila. La connessione reale a SteamGridDB richiede la chiave personale dell’utente e non è stata verificata su un account reale. Le immagini Steam sono state scaricate nella libreria isolata di prova. Il controllo visivo completo e lo switch tramite interazione reale non sono certificati: il lettore delle finestre ha incontrato timeout ed errori del servizio di accessibilità. Le copie di prova sono separate dai dati reali.
