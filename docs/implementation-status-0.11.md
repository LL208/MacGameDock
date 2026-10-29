# Modalità controller 0.11.0

La modalità Big Picture è attiva per impostazione predefinita e può essere disabilitata dalle impostazioni. La modalità desktop conserva la voce «Modalità controller» per rientrare.

## Copertura

- Home, libreria, ricerca, filtri, preferiti, raccolte, giochi nascosti e paginazione.
- Pagina gioco: avvio/ritorno, versioni Mac/Windows, manutenzione, trasferimento, disinstallazione con backup e rimozione del catalogo con conferma.
- Coda e cronologia download, priorità, pausa/ripresa e annullamento.
- Account Steam/QR, presenza, trofei, cloud e risoluzione esplicita dei conflitti.
- Ricerca Workshop, download e scelta della cartella della mod, attivazione/disattivazione.
- Impostazioni, rilevamento delle librerie, scelta del disco, importazione dei giochi e log interni/esportazione.
- Tastiera e browser delle cartelle interni: nessun pannello di selezione macOS per queste azioni.

## Input

GameController riconosce i dispositivi supportati da macOS con profilo extendedGamepad o microGamepad. Non viene promesso il supporto di qualsiasi periferica HID priva di un profilo macOS. Le icone sono quelle dei pulsanti reali riportate dal framework; in loro assenza viene usato un simbolo generico. Il dispositivo che riceve input diventa attivo; scollegamento e riconnessione non eseguono il pulsante tenuto premuto.

«Inverti Conferma e Indietro» conserva la preferenza e scambia gli input dell’interfaccia e i suggerimenti. Non rimappa i pulsanti passati al gioco. La tastiera fisica conserva Invio/Esc come conferma/indietro.

La direzione si ripete dopo 380 ms, poi ogni 110 ms; i pulsanti di azione richiedono un nuovo fronte di pressione. Le selezioni usano ID stabili e le conferme distruttive partono da Annulla. In background gli input ordinari non navigano nell’app; tenere Menu per 1,2 secondi richiede il ritorno alla finestra, lasciando il gioco aperto.

L’abbinamento Bluetooth, i permessi di sistema e Steam Guard restano nelle rispettive interfacce. Non sono implementati controller virtuali o profili Steam Input per gioco. La compatibilità degli input dentro ogni gioco Wine dipende dal runtime e dal titolo.

## Verifica

Suite di logica: 117 test, 5 saltati, nessun errore (112 eseguiti). Build nativa verificata in Xcode. Test automatici su focus, griglie incomplete, ripetizione, riconnessione, cronologia, conferme, inversione e compatibilità delle preferenze esistenti. Prova UI con dati separati dall’account reale: fullscreen, pagina gioco, ricerca con tastiera a schermo, cartelle e inversione con aggiornamento dei suggerimenti. DualShock 4 rilevato sul Mac e simboli PlayStation visualizzati. Il ritorno da un gioco con Menu richiede una verifica fisica durante una partita; il rilevamento del controller non certifica quel percorso.
