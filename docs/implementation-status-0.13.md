# Dettaglio gioco 0.13.0

Panoramica nativa desktop e Big Picture: descrizione breve ed estesa in italiano quando disponibile nello store, generi, sviluppatore, giocatori attualmente online su Steam, modalità singolo/online/cooperativa locale/schermo condiviso o split-screen. Assenza di un tag significa non dichiarato, non certificazione di incompatibilità. Il massimo locale non è fornito dall’API usata ed è indicato come non specificato.

La sezione trofei carica automaticamente schema e progressi, riusa subito la cache per account/gioco e riceve gli aggiornamenti del monitor. Metadati, giocatori e trofei sono indipendenti; cambiando gioco/account si scartano le risposte tardive. Le letture non preparano il ponte Steam API e non modificano i file del gioco.

SteamSocial viene preferito quando connesso. Il fallback al downloader attende operazioni esistenti; la sua operazione ha un UUID distinto. Chiusura della pagina e avvio del gioco possono annullare soltanto la lettura di proprietà della pagina, senza interrompere download altrui.

## Verifica

Test su parsing descrizione/modalità, distinzione zero giocatori vs dato non disponibile, caricamento dei trofei con metadati offline, cache distinta tra account, cache offline e scarto delle risposte del gioco precedente. I servizi sono simulati: un nuovo sblocco Steam non è stato prodotto da questi test. Il conteggio reale e lo schema personale richiedono la disponibilità dei servizi Steam e della sessione dell’utente.
