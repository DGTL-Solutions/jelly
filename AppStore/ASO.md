# Gefunden werden im App Store

Stand 8.11.2026, Version 1.2.1. Ziel: unter den ersten drei bei der Suche nach „jellyfin“.

## Was die Reihenfolge bestimmt

1. **Wörter im Namen** (am stärksten), dann im Untertitel, dann im Schlagwort-Feld (100 Bytes, nicht sichtbar). Ein Wort
   zählt nur einmal: was im Namen steht, gehört nicht noch ins Schlagwort-Feld. Apple kombiniert die Wörter aller drei Felder.
2. **Wie viele Suchende tippen und laden** – Icon und erste Screenshots sind schon in der Trefferliste zu sehen.
3. **Bewertungen**: Anzahl und Schnitt.

Deshalb seit 1.2.1: „Jelly – Player für Jellyfin“ (und je Sprache entsprechend), Untertitel „Filme & Serien in Dolby
Vision“, Schlagwörter ohne Doppelungen (`AppStore/metadata*/<Sprache>/keywords.txt`). Fremde App-Namen (Infuse, Plex,
Swiftfin) nie als Schlagwort – Apple lehnt das ab. Die Beschreibung sagt in jeder Sprache, dass Jelly kein offizielles
Produkt des Jellyfin-Projekts ist.

## Welche Sprachen in welchem Land zählen

Laut Apple (App Store Connect Help › App Store localizations) zählt in jedem Land die Hauptsprache plus Zusatzsprachen:

| Land | zählt |
| --- | --- |
| Deutschland, Österreich, Frankreich, Niederlande, Dänemark, Brasilien, Mexiko, Australien | eigene Sprache **+ Englisch (UK)** |
| Schweiz | Deutsch + Englisch (UK), Französisch, Italienisch |
| USA | Englisch (US) + u. a. Französisch, Portugiesisch (BR), Spanisch (MX) |
| Kanada | Englisch (Kanada) + Französisch (Kanada) |

Darum hält en-GB englische Begriffe, die das deutsche/französische Feld nicht hat, und seit 1.2.1 gibt es en-AU, en-CA
und fr-CA.

## Bewertungen

iPhone/iPad: Apples Abfrage nach dem ersten zu Ende geschauten Titel. Apple TV hat keine solche Abfrage; Jelly zeigt dort
einmalig (nie wieder, auch nicht nach Updates) die Seite „Gefällt dir Jelly?“ mit Code fürs iPhone, dazu dauerhaft
Einstellungen › Info › Jelly bewerten.

## Messen

Die öffentliche Such-Schnittstelle bildet die Store-Reihenfolge (iPhone/iPad) ungefähr ab:

```sh
curl -s "https://itunes.apple.com/search?term=jellyfin&entity=software&country=de&limit=200" \
  | python3 -c "import sys,json;r=json.load(sys.stdin)['results'];print([i+1 for i,a in enumerate(r) if a['trackId']==6826379119])"
```

Ausgangswerte vor 1.2.1 (8.11.2026):

| Suche | Deutschland | USA |
| --- | --- | --- |
| jellyfin | 67 | nicht unter 161 |
| jellyfin player | 19 | 53 |
| jellyfin client | 19 | 85 |
| jellyfin apple tv | – | – |

Vor Jelly standen bei „jellyfin“: Jellyfin Mobile, Swiftfin, Streamyfin, Moonfin, Infuse, JellyTV, Finamp.

## Später

- **Eigene Produktseiten mit Schlagwörtern** (App Store Connect › Produktseiten): eine Seite je Suchbegriff-Gruppe,
  z. B. „jellyfin apple tv“ mit Apple-TV-Screenshots, „jellyfin offline“ mit Downloads; sie erscheinen auch in der
  normalen Suche.
- **Produktseiten-Test** (A/B) für Icon und ersten Screenshot, sobald täglich genug Besucher kommen.
- **In-App-Events** (z. B. zu einem großen Update) erscheinen als eigene Karte in Suche und Heute-Tab.
