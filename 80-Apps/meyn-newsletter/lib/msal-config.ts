import { type Configuration, LogLevel } from "@azure/msal-browser";

const clientId = process.env.NEXT_PUBLIC_MSAL_CLIENT_ID || "";
const tenantId = process.env.NEXT_PUBLIC_MSAL_TENANT_ID || "";

export const msalConfig: Configuration = {
  auth: {
    clientId,
    authority: `https://login.microsoftonline.com/${tenantId}`,
    redirectUri: typeof window !== "undefined" ? window.location.origin : "",
    postLogoutRedirectUri:
      typeof window !== "undefined" ? window.location.origin : "",
  },
  cache: {
    cacheLocation: "sessionStorage",
    storeAuthStateInCookie: false,
  },
  system: {
    loggerOptions: {
      loggerCallback: (level, message, containsPii) => {
        if (containsPii) return;
        switch (level) {
          case LogLevel.Error:
            console.error(message);
            break;
          case LogLevel.Warning:
            console.warn(message);
            break;
          default:
            break;
        }
      },
    },
  },
};

export const loginRequest = {
  scopes: ["User.Read", "Files.ReadWrite.All"],
};

export const graphScopes = {
  // Files.ReadWrite.All with admin consent allows accessing other users' OneDrive
  files: ["Files.ReadWrite.All"],
  user: ["User.Read"],
};
