'use client';

import { type ReactNode } from 'react';
import { useRoles, type AppRole, type Permission } from '@/components/role-provider';

interface RequireRoleProps {
  children: ReactNode;
  role?: AppRole;
  permission?: Permission;
  fallback?: ReactNode;
}

/**
 * Component that conditionally renders children based on user role or permission
 * 
 * Usage:
 * <RequireRole role="Admin">
 *   <AdminPanel />
 * </RequireRole>
 * 
 * <RequireRole permission="upload:newsletters">
 *   <UploadButton />
 * </RequireRole>
 */
export function RequireRole({ children, role, permission, fallback = null }: RequireRoleProps) {
  const { hasRole, hasPermission, isLoading } = useRoles();
  
  if (isLoading) {
    return null;
  }
  
  // Check role if provided
  if (role && !hasRole(role)) {
    return <>{fallback}</>;
  }
  
  // Check permission if provided
  if (permission && !hasPermission(permission)) {
    return <>{fallback}</>;
  }
  
  return <>{children}</>;
}

/**
 * Component that renders children only for Admins
 */
export function AdminOnly({ children, fallback = null }: { children: ReactNode; fallback?: ReactNode }) {
  const { isAdmin, isLoading } = useRoles();
  
  if (isLoading) return null;
  if (!isAdmin) return <>{fallback}</>;
  
  return <>{children}</>;
}

/**
 * Component that renders children for Admins and Editors
 */
export function EditorOnly({ children, fallback = null }: { children: ReactNode; fallback?: ReactNode }) {
  const { isEditor, isLoading } = useRoles();
  
  if (isLoading) return null;
  if (!isEditor) return <>{fallback}</>;
  
  return <>{children}</>;
}

/**
 * Component that renders children when user can upload
 */
export function CanUpload({ children, fallback = null }: { children: ReactNode; fallback?: ReactNode }) {
  const { canUpload, isLoading } = useRoles();
  
  if (isLoading) return null;
  if (!canUpload) return <>{fallback}</>;
  
  return <>{children}</>;
}

/**
 * Component that renders children when user can delete
 */
export function CanDelete({ children, fallback = null }: { children: ReactNode; fallback?: ReactNode }) {
  const { canDelete, isLoading } = useRoles();
  
  if (isLoading) return null;
  if (!canDelete) return <>{fallback}</>;
  
  return <>{children}</>;
}

/**
 * Component that renders children when user can manage settings
 */
export function CanManageSettings({ children, fallback = null }: { children: ReactNode; fallback?: ReactNode }) {
  const { canManageSettings, isLoading } = useRoles();
  
  if (isLoading) return null;
  if (!canManageSettings) return <>{fallback}</>;
  
  return <>{children}</>;
}

/**
 * Component that renders children when user can view analytics
 */
export function CanViewAnalytics({ children, fallback = null }: { children: ReactNode; fallback?: ReactNode }) {
  const { canViewAnalytics, isLoading } = useRoles();
  
  if (isLoading) return null;
  if (!canViewAnalytics) return <>{fallback}</>;
  
  return <>{children}</>;
}
