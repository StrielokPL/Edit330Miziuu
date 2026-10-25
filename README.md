# Ursus C-330/330M — edit StrielokPL

Repozytorium zawiera **wyłącznie nowe i zmienione pliki**, niezmienione zasoby
oryginału są pominięte. Nie zawiera historii roboczego repozytorium z pełnym modem.

## Baza i wersja editu

- Edit: **0.0.5.1**.
- Wymagana paczka na KingMods: **V1.1.2.0**.
- Numer wewnątrz oryginalnego `modDesc.xml`: **1.1.2.0**.
- [Strona autora na KingMods](https://www.kingmods.net/en/fs25/mods/63913/ursus-c-330330m).
- [Strona pobrania właściwej paczki na ModsFire](https://modsfire.com/4aJ7Ur5T4hNVzE9).
- Suma SHA-256 oryginalnego ZIP-a: `e7ae69046d4cbf6754d78b700d8fc549f49e111b0d0b3fcd095565b003c0ed21`.

Inne wersje oryginału **nie są jeszcze potwierdzone jako zgodne**. Pole
`baseMod.compatibleVersions` jest na razie puste. Numer bazy określa punkt
odniesienia do porównania, a nie deklarację nowego testu w grze. Docelowa polityka
updatera przy niezgodnej wersji: ostrzeżenie z wyborem kontynuacji lub anulowania
(`compatibilityPolicy: warn-and-confirm`). Updater wymaga jeszcze obsługi tego
formatu nakładki; obecna wersja a13 jej nie instaluje.

## Zawartość

- `files/` — **5 zmienionych i 6 nowych plików**, ze ścieżkami jak w oryginale.
- `updater.json` — wersje bazy, sumy kontrolne, pochodzenie i kompletna lista operacji.
- `delete.json` — jawna lista usunięć; obecnie **0** plików.
- `comparison.json` — wynik porównania i weryfikacji odtworzenia.
- `edit-config.json` — konfiguracja przygotowywania następnych wersji.
- `tools/edit_package.py` — odtwarzalne budowanie i weryfikacja paczki zmian.

**95 niezmienionych plików oryginału nie znajduje się w `files/`.**
Zmiana modelu lub tekstury oznacza zamieszczenie całego zmienionego pliku,
a nie różnicy binarnej. Zmienione pliki zachowują informacje o autorach.

## Budowanie kolejnego editu

Potrzebny jest osobny, czysty checkout repozytorium roboczego oraz oryginalny ZIP
przechowywany **poza tym repozytorium**. Używać Pythona 3.10 lub nowszego.

```bash
python3 tools/edit_package.py build --source /sciezka/do/repo-roboczego --base /sciezka/do/oryginalnego.zip --replace
python3 tools/edit_package.py verify --source /sciezka/do/repo-roboczego --base /sciezka/do/oryginalnego.zip
python3 -m unittest discover -s tests -v
```

`--replace` odtwarza wygenerowane `files/` i metadane; nie modyfikuje repo roboczego
ani oryginału. Parametry w `edit-config.json` należy ustawić przed zmianą bazy.
Paczka w `dist/` zawiera tylko `updater.json`, `delete.json` i `files/`.
`dist/` i oryginalne ZIP-y są wykluczone z Git. Nie wolno instalować ZIP-a editu
lub archiwum „Source code” bezpośrednio jako moda w folderze `mods`.

Weryfikacja sprawdza, czy po zastąpieniu wskazanych plików i wykonaniu jawnych
usunięć zawartość odpowiada **plik w plik** produkcyjnej zawartości repo roboczego.
Niezgodny oryginał, uszkodzony lub dodatkowy plik nakładki przerywa weryfikację.
Test nie uruchamia FS25 i nie potwierdza nowej sesji SP/MP.

## Pochodzenie

Źródło: `StrielokPL/ursus330fs25`, commit `f376b83bb31efe11de2c71fa8421c6c6c8e5f362`.
Do tego repo skopiowano aktualną zawartość zmienionych plików, bez historii
pełnego moda. Pominięto dokumentację roboczą, diagnostykę i narzędzia źródłowe,
które nie należą do produkcyjnej paczki.

Autor editu: **StrielokPL**. Autorstwo oryginalnego moda i zasobów pozostaje
zachowane w `modDesc.xml` i źródłach; to repo nie nadaje nowej licencji tym zasobom.
