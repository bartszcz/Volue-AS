"use client";

import {
  createContext,
  useContext,
  useState,
  useCallback,
  type ReactNode,
} from "react";

export type Locale = "en" | "pl";

const translations: Record<Locale, Record<string, string>> = {
  en: {
    // Header
    "app.title": "HSE Newsletter Manager",
    "app.subtitle": "Safety Bulletin Queue",
    "header.messages": "messages",
    "header.drafts": "drafts",
    "header.synced": "synced",
    "header.demoMode": "Demo mode",
    "header.signOut": "Sign out",

    // Auth gate
    "auth.title": "HSE Newsletter Manager",
    "auth.subtitle": "Safety Bulletin Management Portal",
    "auth.description":
      "Sign in with your organizational account to manage HSE safety bulletin newsletters, control the delivery schedule, and sync content to OneDrive.",
    "auth.signIn": "Sign in with Microsoft",
    "auth.footer": "Access restricted to authorized personnel only.",

    // Upload
    "upload.title": "Drop .docx files here",
    "upload.subtitle": "Files will be automatically converted to HTML for email delivery",
    "upload.browse": "Browse files",
    "upload.converting": "Converting",
    "upload.of": "of",
    "upload.files": "files...",
    "upload.error": "Failed to convert some files:",

    // Message list
    "list.title": "MESSAGE QUEUE",
    "list.dragHint": "Drag to reorder",
    "list.empty": "No messages yet",
    "list.emptyHint": "Upload .docx files above to get started",

    // Message card
    "card.draft": "Draft",
    "card.synced": "Synced",
    "card.delete": "Delete message",
    "card.moveUp": "Move up",
    "card.moveDown": "Move down",

    // Preview
    "preview.title": "Preview",
    "preview.source": "Source",
    "preview.empty": "No message selected",
    "preview.emptyHint": "Select a message from the list to preview it here",
    "preview.edit": "Edit HTML",
    "preview.expand": "Expand",
    "preview.collapse": "Collapse",

    // Editor
    "editor.title": "Edit HTML Source",
    "editor.save": "Save changes",
    "editor.cancel": "Cancel",
    "editor.placeholder": "HTML content will appear here...",

    // Sync
    "sync.button": "Sync to OneDrive",
    "sync.syncing": "Syncing...",
    "sync.confirm.title": "Sync to OneDrive?",
    "sync.confirm.description":
      "This will upload all messages to the Safety bulletin folder on OneDrive, replacing any existing files. The Power Automate flow will pick them up on the next scheduled run.",
    "sync.confirm.messages": "messages will be synced",
    "sync.confirm.warning":
      "Existing files in the OneDrive folder will be replaced.",
    "sync.confirm.cancel": "Cancel",
    "sync.confirm.confirm": "Yes, sync now",
    "sync.success": "Synced successfully",
    "sync.error": "Sync failed",

    // Tabs
    "tabs.sendSchedule": "Send Schedule",
    "tabs.queue": "Upload Queue",
    "tabs.catalog": "OneDrive Files",
    "tabs.skipDays": "Skip Days",

    // Catalog
    "catalog.title": "OneDrive Safety Bulletin Files",
    "catalog.refresh": "Refresh",
    "catalog.loading": "Loading files from OneDrive...",
    "catalog.empty": "No files found in the Safety bulletin folder",
    "catalog.emptyHint": "Upload and sync messages to populate this folder",
    "catalog.import": "Import to queue",
    "catalog.preview": "Preview",
    "catalog.name": "File name",
    "catalog.modified": "Last modified",
    "catalog.size": "Size",
    "catalog.actions": "Actions",
    "catalog.error": "Failed to load files from OneDrive",
    "catalog.importSuccess": "Imported to queue",
    "catalog.signInRequired": "Sign in to view OneDrive files",

    // Schedule
    "schedule.title": "Delivery Schedule",
    "schedule.subtitle":
      "Click on dates to skip newsletter delivery. The Power Automate flow checks this schedule before sending.",
    "schedule.skipDays": "Skipped days",
    "schedule.noSkips": "No days are currently skipped",
    "schedule.addNote": "Add note (optional)",
    "schedule.remove": "Remove",
    "schedule.save": "Save schedule",
    "schedule.saving": "Saving...",
    "schedule.saved": "Schedule saved to OneDrive",
    "schedule.error": "Failed to save schedule",
    "schedule.loadError": "Failed to load schedule",
    "schedule.loading": "Loading schedule...",
    "schedule.signInRequired": "Sign in to manage the schedule",
    "schedule.holiday": "Holiday / Day off",
  },
  pl: {
    // Header
    "app.title": "Menedzer Newslettera BHP",
    "app.subtitle": "Kolejka Biuletynow Bezpieczenstwa",
    "header.messages": "wiadomosci",
    "header.drafts": "szkicow",
    "header.synced": "zsynchronizowanych",
    "header.demoMode": "Tryb demo",
    "header.signOut": "Wyloguj",

    // Auth gate
    "auth.title": "Menedzer Newslettera BHP",
    "auth.subtitle": "Portal Zarzadzania Biuletynami Bezpieczenstwa",
    "auth.description":
      "Zaloguj sie kontem organizacyjnym, aby zarzadzac biuletynami bezpieczenstwa BHP, kontrolowac harmonogram dostaw i synchronizowac tresc z OneDrive.",
    "auth.signIn": "Zaloguj sie przez Microsoft",
    "auth.footer": "Dostep ograniczony do upowaznionych osob.",

    // Upload
    "upload.title": "Upusc pliki .docx tutaj",
    "upload.subtitle":
      "Pliki zostana automatycznie przekonwertowane na HTML do wysylki e-mail",
    "upload.browse": "Przegladaj pliki",
    "upload.converting": "Konwertowanie",
    "upload.of": "z",
    "upload.files": "plikow...",
    "upload.error": "Nie udalo sie przekonwertowac niektorych plikow:",

    // Message list
    "list.title": "KOLEJKA WIADOMOSCI",
    "list.dragHint": "Przeciagnij, aby zmienic kolejnosc",
    "list.empty": "Brak wiadomosci",
    "list.emptyHint": "Wgraj pliki .docx powyzej, aby rozpoczac",

    // Message card
    "card.draft": "Szkic",
    "card.synced": "Zsynchronizowany",
    "card.delete": "Usun wiadomosc",
    "card.moveUp": "Przesun w gore",
    "card.moveDown": "Przesun w dol",

    // Preview
    "preview.title": "Podglad",
    "preview.source": "Zrodlo",
    "preview.empty": "Nie wybrano wiadomosci",
    "preview.emptyHint": "Wybierz wiadomosc z listy, aby ja podgladnac",
    "preview.edit": "Edytuj HTML",
    "preview.expand": "Rozwin",
    "preview.collapse": "Zwin",

    // Editor
    "editor.title": "Edytuj zrodlo HTML",
    "editor.save": "Zapisz zmiany",
    "editor.cancel": "Anuluj",
    "editor.placeholder": "Tresc HTML pojawi sie tutaj...",

    // Sync
    "sync.button": "Synchronizuj z OneDrive",
    "sync.syncing": "Synchronizowanie...",
    "sync.confirm.title": "Synchronizowac z OneDrive?",
    "sync.confirm.description":
      "Spowoduje to przeslanie wszystkich wiadomosci do folderu Safety bulletin w OneDrive, zastepujac istniejace pliki. Przepyw Power Automate pobierze je przy nastepnym zaplanowanym uruchomieniu.",
    "sync.confirm.messages": "wiadomosci zostanie zsynchronizowanych",
    "sync.confirm.warning":
      "Istniejace pliki w folderze OneDrive zostana zastapione.",
    "sync.confirm.cancel": "Anuluj",
    "sync.confirm.confirm": "Tak, synchronizuj",
    "sync.success": "Zsynchronizowano pomyslnie",
    "sync.error": "Synchronizacja nie powiodla sie",

    // Tabs
    "tabs.sendSchedule": "Harmonogram wysylki",
    "tabs.queue": "Kolejka wgrywania",
    "tabs.catalog": "Pliki OneDrive",
    "tabs.skipDays": "Dni wolne",

    // Catalog
    "catalog.title": "Pliki biuletynow bezpieczenstwa w OneDrive",
    "catalog.refresh": "Odswiez",
    "catalog.loading": "Ladowanie plikow z OneDrive...",
    "catalog.empty": "Brak plikow w folderze Safety bulletin",
    "catalog.emptyHint":
      "Wgraj i zsynchronizuj wiadomosci, aby zapelnic ten folder",
    "catalog.import": "Importuj do kolejki",
    "catalog.preview": "Podglad",
    "catalog.name": "Nazwa pliku",
    "catalog.modified": "Ostatnia modyfikacja",
    "catalog.size": "Rozmiar",
    "catalog.actions": "Akcje",
    "catalog.error": "Nie udalo sie zaladowac plikow z OneDrive",
    "catalog.importSuccess": "Zaimportowano do kolejki",
    "catalog.signInRequired": "Zaloguj sie, aby wyswietlic pliki OneDrive",

    // Schedule
    "schedule.title": "Harmonogram Dostarczania",
    "schedule.subtitle":
      "Kliknij na daty, aby pominac dostarczanie newslettera. Przeplyw Power Automate sprawdza ten harmonogram przed wyslaniem.",
    "schedule.skipDays": "Pominiete dni",
    "schedule.noSkips": "Zaden dzien nie jest obecnie pominiety",
    "schedule.addNote": "Dodaj notatke (opcjonalnie)",
    "schedule.remove": "Usun",
    "schedule.save": "Zapisz harmonogram",
    "schedule.saving": "Zapisywanie...",
    "schedule.saved": "Harmonogram zapisany w OneDrive",
    "schedule.error": "Nie udalo sie zapisac harmonogramu",
    "schedule.loadError": "Nie udalo sie zaladowac harmonogramu",
    "schedule.loading": "Ladowanie harmonogramu...",
    "schedule.signInRequired": "Zaloguj sie, aby zarzadzac harmonogramem",
    "schedule.holiday": "Swieto / Dzien wolny",
  },
};

type I18nContextType = {
  locale: Locale;
  setLocale: (l: Locale) => void;
  t: (key: string) => string;
};

const I18nContext = createContext<I18nContextType>({
  locale: "en",
  setLocale: () => {},
  t: (key: string) => key,
});

export function I18nProvider({ children }: { children: ReactNode }) {
  const [locale, setLocaleState] = useState<Locale>(() => {
    if (typeof window !== "undefined") {
      return (localStorage.getItem("hse-locale") as Locale) || "en";
    }
    return "en";
  });

  const setLocale = useCallback((l: Locale) => {
    setLocaleState(l);
    if (typeof window !== "undefined") {
      localStorage.setItem("hse-locale", l);
      document.documentElement.lang = l;
    }
  }, []);

  const t = useCallback(
    (key: string) => translations[locale][key] || key,
    [locale]
  );

  return (
    <I18nContext.Provider value={{ locale, setLocale, t }}>
      {children}
    </I18nContext.Provider>
  );
}

export function useTranslation() {
  return useContext(I18nContext);
}
