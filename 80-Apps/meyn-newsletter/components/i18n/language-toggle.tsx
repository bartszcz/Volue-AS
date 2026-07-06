"use client";

import { useTranslation, type Locale } from "@/lib/i18n";
import { Button } from "@/components/ui/button";
import { Languages } from "lucide-react";

export function LanguageToggle() {
  const { locale, setLocale } = useTranslation();

  const toggle = () => {
    const next: Locale = locale === "en" ? "pl" : "en";
    setLocale(next);
  };

  return (
    <Button
      variant="ghost"
      size="sm"
      onClick={toggle}
      className="gap-1.5 text-muted-foreground hover:text-foreground"
      aria-label={`Switch to ${locale === "en" ? "Polish" : "English"}`}
    >
      <Languages className="h-4 w-4" />
      <span className="text-xs font-medium uppercase">{locale === "en" ? "PL" : "EN"}</span>
    </Button>
  );
}
