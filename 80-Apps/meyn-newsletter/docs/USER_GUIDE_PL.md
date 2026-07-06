# HSE Newsletter Manager — Przewodnik użytkownika

## Opis aplikacji

**HSE Newsletter Manager** to aplikacja webowa do zarządzania, harmonogramowania i dystrybucji biuletynów bezpieczeństwa (HSE — Zdrowie, Bezpieczeństwo i Środowisko). Aplikacja integruje się z Microsoft 365 (OneDrive) do przechowywania dokumentów i używa Azure AD do uwierzytelniania. Przepływ Power Automate automatycznie wysyła zaplanowane biuletyny pocztą e-mail w dni robocze o **7:00 CET**.

---

## Role użytkowników

| Rola | Uprawnienia |
|------|-------------|
| **Admin** | Przesyłanie, usuwanie, zmiana kolejności, zarządzanie harmonogramem i dniami przerwy, wszystkie ustawienia |
| **Editor** | Przesyłanie, usuwanie, zmiana kolejności, zarządzanie harmonogramem i dniami przerwy |
| **Viewer** | Tylko przeglądanie biuletynów i harmonogramu — brak możliwości edycji |

Role są przypisywane przez administratora IT za pośrednictwem Azure Active Directory.

---

## Pierwsze kroki

1. Otwórz adres URL aplikacji w przeglądarce.
2. Kliknij **Zaloguj się** (prawy górny róg) i zaloguj się kontem Microsoft 365.
3. Jeśli widzisz znaczek **„Tryb demo"**, nie jesteś zalogowany — synchronizacja z OneDrive nie będzie działać.
4. Rola (Admin / Editor / Viewer) jest przypisywana automatycznie na podstawie konta Azure AD.

---

## Układ interfejsu

```
┌─────────────────────────────────────────────────────────┐
│  NAGŁÓWEK: Logo | Statystyki | Język | Motyw | Sync | L │
├───────────────────────┬─────────────────────────────────┤
│  LEWY PANEL           │  PRAWY PANEL                    │
│  [ Strefa przesyłania ]│  [ Podgląd / edytor wiadomości]│
│                       │                                 │
│  Zakładki:            │  Zakładki:                      │
│  • Harmonogram        │  • Podgląd                      │
│  • Kolejka            │  • Źródło (HTML)                │
│  • Pliki OneDrive     │                                 │
│  • Dni przerwy        │                                 │
└───────────────────────┴─────────────────────────────────┘
│  STOPKA: „Power Automate wysyła pon.–pt. o 7:00 CET"   │
└─────────────────────────────────────────────────────────┘
```

---

## Główne scenariusze użycia

### Scenariusz 1 — Tworzenie i harmonogramowanie nowego biuletynu

To podstawowy proces publikowania nowych treści.

1. **Przygotuj dokument** — Utwórz plik Word (.docx) z treścią biuletynu. Używaj czytelnej nazwy pliku (np. `Aktualizacja-Bezpieczenstwo-Kwiecien.docx`) — nazwa pliku staje się tytułem biuletynu.
2. **Prześlij plik** — Przeciągnij i upuść plik .docx na obszar przesyłania w górnej części lewego panelu lub kliknij **Wybierz pliki**.
3. **Sprawdź podgląd** — Zaznacz przesłaną wiadomość w zakładce **Kolejka**. Prawy panel wyświetla wygenerowany podgląd tego, jak e-mail będzie wyglądał.
4. **Edytuj jeśli potrzeba** — Kliknij ikonę ołówka, aby edytować tytuł lub treść HTML.
5. **Ustaw kolejność** — Przeciągaj wiadomości w górę/dół lub używaj przycisków strzałek, aby ułożyć je w kolejności wysyłania.
6. **Synchronizuj z OneDrive** — Kliknij **Synchronizuj z OneDrive** (prawy górny róg). Potwierdź okno dialogowe. Pasek postępu pokazuje status przesyłania.
7. **Sprawdź harmonogram** — Przejdź do zakładki **Harmonogram**, aby potwierdzić, który biuletyn wysyłany jest w którym dniu.
8. **Oznacz dni wolne** — Przejdź do zakładki **Dni przerwy**, aby zablokować dni, w których biuletyny nie powinny być wysyłane.

---

### Scenariusz 2 — Przeglądanie harmonogramu wysyłki

1. Kliknij zakładkę **Harmonogram** w lewym panelu.
2. Na górze zakładki widoczna jest pozycja **„Następny do wysłania"** — biuletyn, który zostanie wysłany następnego dnia roboczego.
3. Widok kalendarza pokazuje nadchodzące dni robocze z kolorowym oznaczeniem:
   - **Niebieski** — dzisiejszy biuletyn
   - **Czerwony** — dzień przerwy (biuletyn nie jest wysyłany)
   - **Przerywana ramka** — dzień bez przypisanej treści
4. Kliknij **ikonę oka** przy dowolnej dacie, aby wyświetlić podgląd biuletynu w prawym panelu.

---

### Scenariusz 3 — Ponowne edytowanie istniejącego biuletynu

1. Przejdź do zakładki **Pliki OneDrive**.
2. Przeglądaj listę plików HTML przechowywanych w folderze Safety Bulletin.
3. Kliknij **ikonę importu** (pobierania) obok pliku, który chcesz ponownie użyć.
4. Plik pojawia się w **Kolejce** jako wersja robocza.
5. Edytuj tytuł lub treść HTML według potrzeb.
6. Gdy gotowy, zsynchronizuj z OneDrive, aby opublikować.

---

## Opis funkcji

### Kolejka przesyłania

Kolejka to Twoja lokalna przestrzeń robocza przed synchronizacją z OneDrive.

| Akcja | Sposób |
|-------|--------|
| Prześlij .docx | Przeciągnij i upuść lub kliknij „Wybierz pliki" |
| Wybierz wiadomość | Kliknij jej tytuł na liście |
| Edytuj tytuł/treść | Kliknij ikonę ołówka |
| Podgląd renderowanego HTML | Kliknij ikonę oka |
| Zmień kolejność | Przeciągnij i upuść lub użyj przycisków strzałek |
| Usuń wiadomość | Kliknij ikonę kosza |

**Znaczki statusu:**
- **Wersja robocza** — jeszcze nie przesłana do OneDrive
- **Zsynchronizowana** — pomyślnie przesłana do OneDrive
- **W kolejce** — oczekuje na następną synchronizację

> Kolejka jest automatycznie zapisywana w przeglądarce. Wyczyszczenie danych przeglądarki spowoduje utratę niezapisanych wersji roboczych.

---

### Synchronizacja z OneDrive

Operacja synchronizacji zastępuje wszystkie istniejące pliki w folderze Safety Bulletin na OneDrive Twoją bieżącą kolejką.

- Pliki są automatycznie numerowane: `01-Tytuł.html`, `02-Tytuł.html` itd.
- Numeracja określa kolejność wysyłania.
- **Tej operacji nie można cofnąć.** Przygotuj pełną kolejkę przed synchronizacją.

Po synchronizacji przepływ Power Automate pobiera pliki i wysyła je zgodnie z skonfigurowanym harmonogramem.

---

### Harmonogram wysyłki

Biuletyny są wysyłane wyłącznie w **dni robocze (poniedziałek–piątek)** w cyklu kolejnym:

- Przy 5 biuletynach kolejność wysyłania to: 1 → 2 → 3 → 4 → 5 → 1 → 2 → ...
- Dni przerwy są pomijane bez „zużywania" miejsca w cyklu.
- Po dniu przerwy ten sam biuletyn jest wysyłany następnego dostępnego dnia roboczego.

Widok **Zarządzanie kolejnością** (w zakładce Harmonogram) umożliwia przeciąganie i zmianę kolejności biuletynów już na OneDrive, a następnie kliknięcie **Zapisz kolejność** w celu zastosowania zmian.

---

### Dni przerwy

Użyj tej funkcji, aby zapobiec wysyłaniu biuletynów w dni świąteczne lub dni przerwy w pracy.

1. Kliknij przyszłą datę w kalendarzu, aby oznaczyć ją jako dzień przerwy (zmieni kolor na czerwony).
2. Opcjonalnie dodaj notatkę (np. „Święto państwowe", „Zamknięcie firmy").
3. Aby usunąć dzień przerwy, kliknij go ponownie w kalendarzu lub użyj ikony kosza na liście.
4. Kliknij **Zapisz**, aby zapisać zmiany w OneDrive.

> Dni przerwy nie usuwają biuletynu z cyklu — jedynie go opóźniają.

---

### Pliki OneDrive (Katalog)

Przeglądaj wszystkie pliki HTML aktualnie przechowywane w folderze Safety Bulletin na OneDrive.

| Kolumna | Opis |
|---------|------|
| Nazwa pliku | Nazwa pliku zawierająca prefiks numeryczny |
| Rozmiar | Rozmiar pliku w KB |
| Ostatnia modyfikacja | Data i godzina ostatniej zmiany |
| Akcje | Podgląd (ikona oka), Import (ikona pobierania) |

Kliknij **Odśwież**, aby ponownie załadować listę z OneDrive.

---

### Podgląd wiadomości

Prawy panel ma dwie zakładki:

- **Podgląd** — renderuje HTML biuletynu dokładnie tak, jak odbiorcy zobaczą go w kliencie poczty.
- **Źródło** — wyświetla surowy kod HTML do wglądu lub skopiowania.

Kliknij **ikonę pełnego ekranu** (prawy górny róg panelu podglądu), aby wyświetlić w trybie pełnoekranowym.

---

## Język i motyw

| Kontrolka | Lokalizacja | Opcje |
|-----------|-------------|-------|
| Język | Prawy górny nagłówek | Angielski / Polski |
| Motyw | Prawy górny nagłówek | Jasny / Ciemny (preferencja systemowa respektowana automatycznie) |

Ustawienia są zapisywane w przeglądarce.

---

## Wskazówki i częste błędy

- **Nie synchronizuj po każdym przesłaniu.** Najpierw przygotuj pełną kolejkę, potem zsynchronizuj raz.
- **Wersje robocze są w przeglądarce.** Nie czyść danych przeglądarki, gdy masz niezapisane wiadomości.
- **Wielu edytorów:** Brak rozwiązywania konfliktów — ostatni zapis wygrywa. Koordynuj działania ze współpracownikami przed wprowadzaniem zmian.
- **Nazwy plików:** Nie zmieniaj nazw plików ręcznie. Pozwól aplikacji automatycznie przypisywać numerację, aby uniknąć konfliktów.
- **Dni przerwy:** Ustaw je przed synchronizacją nowej partii, aby harmonogram wyświetlał się poprawnie.
- **Tryb demo:** Jeśli widoczny jest znaczek „Tryb demo", najpierw zaloguj się — zmiany nie dotrą do OneDrive.

---

## Słownik pojęć

| Pojęcie | Znaczenie |
|---------|-----------|
| Safety Bulletin | Zaplanowany biuletyn HSE wysyłany pocztą e-mail |
| Synchronizacja | Przesłanie wszystkich wiadomości z kolejki do OneDrive z zastąpieniem poprzednich plików |
| Dzień przerwy | Dzień roboczy wykluczony z harmonogramu wysyłki biuletynów |
| Power Automate | Usługa automatyzacji Microsoft wysyłająca e-maile na podstawie zawartości OneDrive |
| Wersja robocza | Wiadomość w lokalnej kolejce, jeszcze niesynchronizowana z OneDrive |
| Prefiks kolejności | Numer na początku nazwy pliku (01-, 02-) określający kolejność wysyłania |

---

*Power Automate wysyła biuletyny od poniedziałku do piątku o 7:00 CET.*
