"use client";

import { useIsAuthenticated, useMsal } from "@azure/msal-react";
import { InteractionStatus } from "@azure/msal-browser";
import { useTranslation } from "@/lib/i18n";
import { loginRequest } from "@/lib/msal-config";
import { Button } from "@/components/ui/button";
import { LogIn, Loader2 } from "lucide-react";
import { ThemeToggle } from "@/components/theme-toggle";
import { LanguageToggle } from "@/components/i18n/language-toggle";
import { MeynLogo } from "@/components/meyn-logo";
import type { ReactNode } from "react";

export function AuthGate({ children }: { children: ReactNode }) {
  const isAuthenticated = useIsAuthenticated();
  const { instance, inProgress } = useMsal();
  const { t } = useTranslation();

  if (inProgress !== InteractionStatus.None) {
    return (
      <div className="flex h-screen items-center justify-center bg-background">
        <div className="flex flex-col items-center gap-4">
          <Loader2 className="h-8 w-8 animate-spin text-primary" />
          <p className="text-sm text-muted-foreground">Loading...</p>
        </div>
      </div>
    );
  }

  if (!isAuthenticated) {
    return (
      <div className="flex min-h-screen flex-col bg-background">
        <div className="absolute right-4 top-4 flex items-center gap-1">
          <LanguageToggle />
          <ThemeToggle />
        </div>

        <div className="flex flex-1 items-center justify-center p-4">
          <div className="w-full max-w-md">
            <div className="mb-8 flex flex-col items-center text-center">
              <div className="mb-6">
                <MeynLogo size="xl" />
              </div>
              <h1 className="text-2xl font-bold tracking-tight text-foreground">
                {t("auth.title")}
              </h1>
              <p className="mt-1 text-sm text-muted-foreground">
                {t("auth.subtitle")}
              </p>
            </div>

            <div className="rounded-xl border border-border bg-card p-6 shadow-sm">
              <p className="mb-6 text-center text-sm leading-relaxed text-muted-foreground">
                {t("auth.description")}
              </p>

              <Button
                onClick={() => instance.loginPopup(loginRequest)}
                className="w-full gap-2"
                size="lg"
              >
                <LogIn className="h-4 w-4" />
                {t("auth.signIn")}
              </Button>
            </div>

            <p className="mt-4 text-center text-xs text-muted-foreground">
              {t("auth.footer")}
            </p>
          </div>
        </div>
      </div>
    );
  }

  return <>{children}</>;
}
