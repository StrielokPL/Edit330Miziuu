# Ocena zgodności wersji oryginału z editem

Ocena dotyczy konkretnej wersji editu, a nie całego moda na zawsze.

- **Źródłowa**: `baseMod.version`, nadal zalecana. Numer z KingMods może różnić się
  od `baseMod.modDescVersion`, dlatego zapisano oba.
- **Kompatybilna — sprawdzona**: jawny wpis `verification: verified`, po potwierdzeniu
  działania w grze.
- **Kompatybilna — oszacowana**: jawny wpis `verification: estimated`, na podstawie
  porównania zawartości i zależności z bazą źródłową; wymaga testu w grze.
- **Niekompatybilna**: wersja z `incompatibleVersions` albo równa/nowsza niż
  `incompatibleFrom`. Granica ma pierwszeństwo; wpis zgodności na/ponad granicą
  jest błędem metadanych.

Wersja bez oceny nie jest automatycznie uznawana za zgodną. Updater pokazuje
„Brak oceny”, a jako domyślny wybór zachowuje wersję źródłową.

Przykład składni (numery zastępcze, nie są oceną tego editu):

```json
{
  "compatibleVersions": [
    {"version": "1.0.1.0", "verification": "verified", "notes": "Potwierdzona próba w grze."},
    {"version": "1.0.2.0", "verification": "estimated", "notes": "Opis porównania plików."}
  ],
  "incompatibleFrom": "2.0.0.0",
  "incompatibleVersions": [],
  "incompatibilityReason": "Opis wykrytego konfliktu."
}
```

Pola znajdują się pod `baseMod` w `edit-config.json`. Po ich zmianie należy
wygenerować ponownie `updater.json` oraz paczkę editu narzędziem `tools/edit_package.py`.
Metadane na głównej gałęzi opisują edit wskazany przez pole `version`; przy
publikacji konkretnego wydania ten sam plik powinien towarzyszyć jego paczce.

Zgodność z editem nie jest obietnicą zachowania wszystkich nowości oryginału:
nowe pliki mogą pozostać, a zmienione definicje zostać nadpisane starszymi z editu.
Nowe elementy mogą być pominięte lub działać inaczej. Ostrzeżenie dotyczy obu
rodzajów zgodności. Wersja źródłowa pozostaje zalecaną bazą.

Aktualnie brak dodatkowych wersji potwierdzonych jako sprawdzone lub oszacowane.

Dla editu **0.0.5.1**: źródłowa **1.1.2.0**; niekompatybilna **1.9.1.0 i wszystkie nowsze**.
[Analiza 1.9.1.0](compatibility/1.9.1.0.md). Wersja 1.9.0.0 pozostaje nieoceniona.
