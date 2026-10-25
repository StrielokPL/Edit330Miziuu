# Weryfikacja przygotowania editu

- Źródło: `StrielokPL/ursus330fs25`, commit `f376b83bb31efe11de2c71fa8421c6c6c8e5f362`.
- Wersja editu: `0.0.5.1`.
- Oryginał: KingMods **1.1.2.0**, XML **1.1.2.0**.
- SHA-256 oryginału: `e7ae69046d4cbf6754d78b700d8fc549f49e111b0d0b3fcd095565b003c0ed21`.
- Produkcyjne pliki źródłowe po odtworzeniu: **106**.
- Nakładka: **5 zmian, 6 nowych plików, 0 usunięć**.
- Niezmienione pliki oryginału pominięte w nakładce: **95**.

Z oryginalnego ZIP-a i nakładki utworzono testowo nowy ZIP poza tym repozytorium.
Sprawdzono CRC, pełną listę plików oraz zawartość każdego pliku względem produkcyjnego
zestawu źródeł. Odtworzona paczka jest zgodna ze źródłami plik w plik; różnice
w kompresji lub znacznikach czasu ZIP-a nie są różnicami zawartości moda.

Wszystkie testy narzędzia generowania nakładki przeszły: dodawanie, podmiana,
usuwanie, zachowanie bajtów/końców linii, odrzucenie błędnej bazy, uszkodzonego
payloadu, dodatkowych plików i niebezpiecznych ścieżek. Zmiany bazowane są na
konkretnym SHA-256, a nie wyłącznie na numerze w modDesc.xml.

Przeszły istniejące testy manifestu, XML i czystości paczki, kompilacja Lua
oraz 102 izolowane asercje regresji źródeł C-330.

Nie wykonano nowej sesji w FS25. Nie potwierdzono dodatkowych wersji oryginału
ani aktualnego działania multiplayer.
