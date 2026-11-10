# moneymoney-become1

Eine [MoneyMoney](https://moneymoney.app/)-WebBanking-Extension, die Saldo und Buchungen der
**become.1 Card** abruft. Die Karte erscheint damit als Kreditkartenkonto in MoneyMoney.

become.1 bietet keine öffentliche API, keinen CSV- und keinen DATEV-Export für Karteninhaber.
Diese Extension nutzt dieselbe private GraphQL-API wie die Web-App unter `app.become1.de` —
ohne Screen-Parsing, aber auch ohne Zusicherung von become.1, dass die Felder stabil bleiben.

## Funktionen

- Alle Kartenbuchungen mit Datum, Händlertext und Betrag.
- Vorgemerkte Umsätze (`isPending`) werden als nicht gebucht übergeben und erscheinen in
  MoneyMoney als vorgemerkt.
- Saldo aus der Summe der gebuchten Buchungen, zusätzlich ein Saldo inklusive vorgemerkter
  Umsätze. Einen eigenen Saldo-Endpunkt für Karteninhaber gibt es in der API nicht.

## Voraussetzungen

- MoneyMoney mit der Möglichkeit, unsignierte Extensions zu laden.
- Ein become.1-Account mit aktiver Card.
- Ein Firebase Refresh-Token aus dem Browser (siehe unten).

> **Nur für Microsoft SSO gebaut und getestet.** Entwicklung und Test fanden ausschließlich
> gegen einen become.1-Account statt, der sich per **Microsoft SSO** anmeldet. Ob andere
> Anmeldeverfahren (E-Mail/Passwort, andere SSO-Anbieter) einen brauchbaren Refresh-Token
> liefern, ist ungetestet. Der Rest — GraphQL-Endpunkt, Queries, Mapping — hängt nicht am
> Anmeldeverfahren und sollte unverändert funktionieren, sobald ein gültiges ID-Token vorliegt.

## Der Refresh-Token

become.1 meldet sich über **Firebase Auth** an, im Fall dieser Extension mit
**Microsoft SSO** als Anmeldeverfahren. Dieser
SSO-Flow lässt sich in einer Lua-Extension nicht nachbauen — der langlebige Firebase
Refresh-Token dagegen schon: aus ihm holt die Extension bei jedem Login ein frisches
ID-Token (1 h gültig) und spricht damit die API an.

So liest du ihn aus:

1. <https://app.become1.de> im Browser öffnen, eingeloggt sein.
2. DevTools öffnen → Konsole.
3. Diesen Snippet ausführen:

   ```js
   await (async () => {
     const get = v => v?.stsTokenManager?.refreshToken;
     let token, quelle;

     // Firebase speichert die Session je nach Persistenz in localStorage oder IndexedDB
     const lsKey = Object.keys(localStorage).find(k => k.startsWith('firebase:authUser:'));
     if (lsKey) { try { token = get(JSON.parse(localStorage[lsKey])); quelle = 'localStorage'; } catch {} }

     if (!token && (await indexedDB.databases()).some(d => d.name === 'firebaseLocalStorageDb')) {
       const db = await new Promise(r => { const q = indexedDB.open('firebaseLocalStorageDb'); q.onsuccess = () => r(q.result); });
       if (db.objectStoreNames.contains('firebaseLocalStorage')) {
         const rows = await new Promise(r => { const q = db.transaction('firebaseLocalStorage').objectStore('firebaseLocalStorage').getAll(); q.onsuccess = () => r(q.result); });
         const rec = rows.map(r => r.value).find(get);
         if (rec) { token = get(rec); quelle = 'IndexedDB (' + rec.providerData?.map(p => p.providerId).join(', ') + ')'; }
       }
     }

     if (!token) {
       console.error('Kein Refresh-Token gefunden auf ' + location.origin +
         '. Bist du auf https://app.become1.de und dort eingeloggt?');
       return;
     }
     copy(token);
     console.log('Refresh-Token aus ' + quelle + ' in der Zwischenablage (' + token.length + ' Zeichen).');
   })();
   ```

4. Den Token als **Passwort** in MoneyMoney hinterlegen.

Wenn der Snippet „Kein Refresh-Token gefunden" meldet oder `Cannot read properties of
undefined` wirft, ist die Firebase-Session im aktuellen Tab nicht da. Übliche Ursachen:

- Der Tab steht nicht auf `app.become1.de` (die Hilfeseiten unter `help.become1.de` und die
  Microsoft-Loginseite haben jeweils einen eigenen Origin mit eigenem Speicher).
- Du bist in einem anderen Browser oder Browser-Profil eingeloggt als in dem Tab, in dem der
  Snippet läuft.
- Die Seite war noch nicht fertig geladen — einmal neu laden, bis die Karten-Übersicht steht,
  und den Snippet erneut ausführen.

Der Token ist ein vollwertiges Zugangsmerkmal zu deinem become.1-Account — behandle ihn wie
ein Passwort. Er bleibt gültig, bis du dich abmeldest, das Passwort änderst oder become.1
bzw. Microsoft die Session zurückzieht. Danach einmal neu auslesen.

## Installation

1. [`Become1.lua`](Become1.lua) in den MoneyMoney-Extensions-Ordner kopieren:

   ```
   ~/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Extensions/
   ```

   Alternativ in MoneyMoney: **Hilfe → Datenbank im Finder zeigen** → Ordner `Extensions`.

2. MoneyMoney neu starten.

3. Da die Extension unsigniert ist, ggf. einmalig **Einstellungen → Extensions →
   „Unsignierte Extensions erlauben"** aktivieren.

## Einrichtung in MoneyMoney

1. **Konto hinzufügen** → Dienst **become.1** wählen.
2. Im Login-Dialog eingeben:
   - **Benutzername:** leer lassen (Konto heißt dann „become.1 Card") oder ein eigener
     Kontoname.
   - **Passwort:** der Firebase Refresh-Token von oben.

## API-Details

Alles hier wurde aus der Web-App und gegen die Live-API ermittelt; offizielle Doku gibt es nicht.
Introspection ist auf dem Endpunkt abgeschaltet.

- **Token-Refresh:**
  `POST https://securetoken.googleapis.com/v1/token?key=<Firebase-Web-API-Key>`
  mit `grant_type=refresh_token&refresh_token=…` → `id_token` (JWT, 1 h).
  Firebase-Projekt: `become1-prod`, Web-API-Key `AIzaSyCQmxu5BULN61MH-r2qCpryqas0rXkUVjE`.

- **GraphQL-Endpunkt:** `POST https://api.become1.de/graphql`
  Header `Authorization: <JWT>` — die Web-App sendet das Token **ohne** `Bearer `-Präfix
  (mit Präfix funktioniert es ebenfalls).

- **Genutzte Queries:**

  ```graphql
  { getOwnB1CardUsers { id cardStatus } }
  ```

  ```graphql
  query B1CardTransactions {
    queryB1CardUserTransactions {
      id
      dateCreated          # ISO-8601 in UTC
      reference            # Händlertext, z.B. "SumUp  *Mama_s Haus"
      side                 # DEBIT (Zahlung) | CREDIT (Aufladung)
      isPending
      amount { value currency }   # value als Ganzzahl in Cent, currency = "EUR_CENT"
    }
  }
  ```

  Die Liste kommt bereits absteigend nach `dateCreated`. `queryOptions` mit
  `queryPagination { skip take }` wird unterstützt, `querySort` erwartet ein Enum und wurde
  nicht weiter verfolgt — die Datenmengen sind klein.

### Warum nicht über Swan oder PSD2?

Hinter become.1 steckt **Swan** als Banking-Partner. Swans API ist eine reine Partner-API
(become.1 hält das Project-Token), und der PSD2/AIS-Zugang läuft über Salt Edge und setzt einen
lizenzierten Drittanbieter voraus. Für Karteninhaber ist das kein gangbarer Weg.

## Entwicklung

Offline-Tests gegen Fixtures (stubben `WebBanking`, `Connection` und `JSON`):

```bash
lua test/run_tests.lua
```

Die API direkt per curl erkunden:

```bash
cp .env.example .env     # BECOME1_REFRESH_TOKEN eintragen
./explore.sh '{ getOwnB1CardUsers { id cardStatus } }'
```

Die `.env` ist über [`.gitignore`](.gitignore) ausgeschlossen.

## Hinweise

- `since` wird ignoriert; es werden immer alle Buchungen geladen, damit der summierte Saldo
  stimmt. MoneyMoney dedupliziert selbst.
- Private API ohne Zusicherungen: Feldnamen können sich jederzeit ändern. Wenn die Extension
  plötzlich `GRAPHQL_VALIDATION_FAILED` meldet, hat sich das Schema bewegt.
