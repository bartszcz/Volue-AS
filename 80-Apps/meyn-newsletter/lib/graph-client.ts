import {
  type IPublicClientApplication,
  InteractionRequiredAuthError,
} from "@azure/msal-browser";
import { Client } from "@microsoft/microsoft-graph-client";
import { graphScopes } from "./msal-config";

async function getAccessToken(
  msalInstance: IPublicClientApplication,
  scopes: string[]
): Promise<string> {
  const accounts = msalInstance.getAllAccounts();
  if (accounts.length === 0) {
    throw new Error("No authenticated account found. Please sign in.");
  }

  try {
    const response = await msalInstance.acquireTokenSilent({
      scopes,
      account: accounts[0],
    });
    return response.accessToken;
  } catch (error) {
    if (error instanceof InteractionRequiredAuthError) {
      const response = await msalInstance.acquireTokenPopup({ scopes });
      return response.accessToken;
    }
    throw error;
  }
}

export function createGraphClient(
  msalInstance: IPublicClientApplication
): Client {
  return Client.init({
    authProvider: async (done) => {
      try {
        const token = await getAccessToken(
          msalInstance,
          graphScopes.files
        );
        done(null, token);
      } catch (error) {
        done(error as Error, null);
      }
    },
  });
}

export { getAccessToken };
