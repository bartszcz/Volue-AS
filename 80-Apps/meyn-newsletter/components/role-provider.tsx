'use client';

import { createContext, useContext, useMemo, type ReactNode } from 'react';
import { useMsal } from '@azure/msal-react';
import {
  AppRoles,
  type AppRole,
  getUserRoles,
  getHighestRole,
  hasPermission,
  canUpload,
  canDelete,
  canManageSettings,
  canViewAnalytics,
  isAdmin,
  isEditor,
  Permissions,
  type Permission,
} from '@/lib/roles';

interface RoleContextType {
  roles: AppRole[];
  highestRole: AppRole | null;
  isAdmin: boolean;
  isEditor: boolean;
  isViewer: boolean;
  canUpload: boolean;
  canDelete: boolean;
  canManageSettings: boolean;
  canViewAnalytics: boolean;
  hasPermission: (permission: Permission) => boolean;
  hasRole: (role: AppRole) => boolean;
  isLoading: boolean;
}

const RoleContext = createContext<RoleContextType | undefined>(undefined);

export function RoleProvider({ children }: { children: ReactNode }) {
  const { accounts, inProgress } = useMsal();
  const account = accounts[0];
  
  const value = useMemo(() => {
    const idTokenClaims = account?.idTokenClaims as Record<string, unknown> | undefined;
    const roles = getUserRoles(idTokenClaims);
    const highestRole = getHighestRole(roles);
    
    return {
      roles,
      highestRole,
      isAdmin: isAdmin(roles),
      isEditor: isEditor(roles),
      isViewer: roles.length > 0,
      canUpload: canUpload(roles),
      canDelete: canDelete(roles),
      canManageSettings: canManageSettings(roles),
      canViewAnalytics: canViewAnalytics(roles),
      hasPermission: (permission: Permission) => hasPermission(roles, permission),
      hasRole: (role: AppRole) => roles.includes(role) || (role !== AppRoles.ADMIN && isAdmin(roles)),
      isLoading: inProgress !== 'none',
    };
  }, [account, inProgress]);
  
  return (
    <RoleContext.Provider value={value}>
      {children}
    </RoleContext.Provider>
  );
}

export function useRoles() {
  const context = useContext(RoleContext);
  if (context === undefined) {
    throw new Error('useRoles must be used within a RoleProvider');
  }
  return context;
}

// Re-export for convenience
export { AppRoles, Permissions };
export type { AppRole, Permission };
