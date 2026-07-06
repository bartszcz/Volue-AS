"use client";

import { useMsal, useIsAuthenticated } from "@azure/msal-react";
import { loginRequest } from "@/lib/msal-config";
import { useTranslation } from "@/lib/i18n";
import { Button } from "@/components/ui/button";
import { LogIn, LogOut, User } from "lucide-react";

export default function LoginButton() {
  const { instance, accounts } = useMsal();
  const isAuthenticated = useIsAuthenticated();
  const { t } = useTranslation();

  const handleLogin = async () => {
    try {
      await instance.loginPopup(loginRequest);
    } catch (error) {
      console.error("Login failed:", error);
    }
  };

  const handleLogout = async () => {
    try {
      await instance.logoutPopup();
    } catch (error) {
      console.error("Logout failed:", error);
    }
  };

  if (isAuthenticated && accounts.length > 0) {
    return (
      <div className="flex items-center gap-3">
        <div className="flex items-center gap-2 rounded-lg bg-secondary px-3 py-1.5">
          <User className="h-4 w-4 text-muted-foreground" />
          <span className="text-sm font-medium text-secondary-foreground">
            {accounts[0].name || accounts[0].username}
          </span>
        </div>
        <Button variant="ghost" size="sm" onClick={handleLogout}>
          <LogOut className="mr-1.5 h-4 w-4" />
          {t("header.signOut")}
        </Button>
      </div>
    );
  }

  return (
    <Button onClick={handleLogin} size="sm">
      <LogIn className="mr-1.5 h-4 w-4" />
      {t("auth.signIn")}
    </Button>
  );
}
