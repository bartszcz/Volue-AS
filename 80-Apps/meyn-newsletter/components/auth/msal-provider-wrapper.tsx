"use client";

import { type ReactNode, useEffect, useState } from "react";
import {
  PublicClientApplication,
  EventType,
  type AuthenticationResult,
} from "@azure/msal-browser";
import { MsalProvider } from "@azure/msal-react";
import { msalConfig } from "@/lib/msal-config";
import { RoleProvider } from "@/components/role-provider";

const msalInstance = new PublicClientApplication(msalConfig);

function MsalInitializer({ children }: { children: ReactNode }) {
  const [isInitialized, setIsInitialized] = useState(false);

  useEffect(() => {
    const init = async () => {
      await msalInstance.initialize();

      // Handle redirect response
      const response = await msalInstance.handleRedirectPromise();
      if (response) {
        msalInstance.setActiveAccount(response.account);
      }

      // Set active account if not already set
      if (
        !msalInstance.getActiveAccount() &&
        msalInstance.getAllAccounts().length > 0
      ) {
        msalInstance.setActiveAccount(msalInstance.getAllAccounts()[0]);
      }

      // Listen for sign-in events
      msalInstance.addEventCallback((event) => {
        if (
          event.eventType === EventType.LOGIN_SUCCESS &&
          event.payload
        ) {
          const result = event.payload as AuthenticationResult;
          msalInstance.setActiveAccount(result.account);
        }
      });

      setIsInitialized(true);
    };

    init();
  }, []);

  if (!isInitialized) {
    return (
      <div className="flex items-center justify-center min-h-screen bg-background">
        <div className="flex flex-col items-center gap-4">
          <div className="h-8 w-8 animate-spin rounded-full border-4 border-primary border-t-transparent" />
          <p className="text-sm text-muted-foreground">Initializing...</p>
        </div>
      </div>
    );
  }

  return (
    <MsalProvider instance={msalInstance}>
      <RoleProvider>{children}</RoleProvider>
    </MsalProvider>
  );
}

export default function MsalProviderWrapper({
  children,
}: {
  children: ReactNode;
}) {
  const hasConfig =
    process.env.NEXT_PUBLIC_MSAL_CLIENT_ID &&
    process.env.NEXT_PUBLIC_MSAL_TENANT_ID;

  if (!hasConfig) {
    // In demo mode without MSAL config, render children directly
    return <>{children}</>;
  }

  return <MsalInitializer>{children}</MsalInitializer>;
}
