// Role definitions for HSE Newsletter Manager
export const AppRoles = {
  ADMIN: 'Admin',
  EDITOR: 'Editor',
  VIEWER: 'Viewer',
} as const;

export type AppRole = (typeof AppRoles)[keyof typeof AppRoles];

// Permission definitions
export const Permissions = {
  // Content permissions
  VIEW_NEWSLETTERS: 'view:newsletters',
  UPLOAD_NEWSLETTERS: 'upload:newsletters',
  DELETE_NEWSLETTERS: 'delete:newsletters',
  
  // Settings permissions
  MANAGE_SETTINGS: 'manage:settings',
  
  // Analytics permissions
  VIEW_ANALYTICS: 'view:analytics',
} as const;

export type Permission = (typeof Permissions)[keyof typeof Permissions];

// Role to permissions mapping
export const RolePermissions: Record<AppRole, Permission[]> = {
  [AppRoles.ADMIN]: [
    Permissions.VIEW_NEWSLETTERS,
    Permissions.UPLOAD_NEWSLETTERS,
    Permissions.DELETE_NEWSLETTERS,
    Permissions.MANAGE_SETTINGS,
    Permissions.VIEW_ANALYTICS,
  ],
  [AppRoles.EDITOR]: [
    Permissions.VIEW_NEWSLETTERS,
    Permissions.UPLOAD_NEWSLETTERS,
    Permissions.DELETE_NEWSLETTERS,
  ],
  [AppRoles.VIEWER]: [
    Permissions.VIEW_NEWSLETTERS,
  ],
};

// Helper functions
export function getUserRoles(idTokenClaims: Record<string, unknown> | undefined): AppRole[] {
  if (!idTokenClaims) return [];
  
  const roles = idTokenClaims.roles as string[] | undefined;
  if (!roles || !Array.isArray(roles)) return [];
  
  // Filter to only valid app roles
  return roles.filter((role): role is AppRole => 
    Object.values(AppRoles).includes(role as AppRole)
  );
}

export function getHighestRole(roles: AppRole[]): AppRole | null {
  if (roles.includes(AppRoles.ADMIN)) return AppRoles.ADMIN;
  if (roles.includes(AppRoles.EDITOR)) return AppRoles.EDITOR;
  if (roles.includes(AppRoles.VIEWER)) return AppRoles.VIEWER;
  return null;
}

export function hasRole(userRoles: AppRole[], requiredRole: AppRole): boolean {
  // Admin has all roles
  if (userRoles.includes(AppRoles.ADMIN)) return true;
  
  // Editor has Editor and Viewer roles
  if (requiredRole === AppRoles.VIEWER && userRoles.includes(AppRoles.EDITOR)) return true;
  
  return userRoles.includes(requiredRole);
}

export function hasPermission(userRoles: AppRole[], permission: Permission): boolean {
  return userRoles.some(role => RolePermissions[role]?.includes(permission));
}

export function canUpload(userRoles: AppRole[]): boolean {
  return hasPermission(userRoles, Permissions.UPLOAD_NEWSLETTERS);
}

export function canDelete(userRoles: AppRole[]): boolean {
  return hasPermission(userRoles, Permissions.DELETE_NEWSLETTERS);
}

export function canManageSettings(userRoles: AppRole[]): boolean {
  return hasPermission(userRoles, Permissions.MANAGE_SETTINGS);
}

export function canViewAnalytics(userRoles: AppRole[]): boolean {
  return hasPermission(userRoles, Permissions.VIEW_ANALYTICS);
}

export function isAdmin(userRoles: AppRole[]): boolean {
  return userRoles.includes(AppRoles.ADMIN);
}

export function isEditor(userRoles: AppRole[]): boolean {
  return userRoles.includes(AppRoles.EDITOR) || userRoles.includes(AppRoles.ADMIN);
}

export function isViewer(userRoles: AppRole[]): boolean {
  return userRoles.length > 0; // Any role can view
}
