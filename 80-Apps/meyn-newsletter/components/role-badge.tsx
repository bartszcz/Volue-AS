'use client';

import { useRoles } from '@/components/role-provider';
import { Badge } from '@/components/ui/badge';
import { Shield, Edit, Eye } from 'lucide-react';

/**
 * Displays the user's current role as a badge
 */
export function RoleBadge() {
  const { highestRole, isLoading } = useRoles();
  
  if (isLoading || !highestRole) return null;
  
  const roleConfig = {
    Admin: {
      icon: Shield,
      variant: 'default' as const,
      className: 'bg-red-600 hover:bg-red-700',
    },
    Editor: {
      icon: Edit,
      variant: 'default' as const,
      className: 'bg-blue-600 hover:bg-blue-700',
    },
    Viewer: {
      icon: Eye,
      variant: 'secondary' as const,
      className: '',
    },
  };
  
  const config = roleConfig[highestRole];
  const Icon = config.icon;
  
  return (
    <Badge variant={config.variant} className={config.className}>
      <Icon className="w-3 h-3 mr-1" />
      {highestRole}
    </Badge>
  );
}

/**
 * Displays a summary of user permissions (useful for debugging/admin)
 */
export function PermissionsSummary() {
  const { 
    roles, 
    highestRole,
    canUpload, 
    canDelete, 
    canManageSettings, 
    canViewAnalytics,
    isLoading 
  } = useRoles();
  
  if (isLoading) return <div>Loading permissions...</div>;
  
  if (roles.length === 0) {
    return (
      <div className="p-4 bg-yellow-50 border border-yellow-200 rounded-lg">
        <p className="text-yellow-800 font-medium">No roles assigned</p>
        <p className="text-yellow-600 text-sm">
          Contact an administrator to get access to this application.
        </p>
      </div>
    );
  }
  
  return (
    <div className="p-4 bg-gray-50 border rounded-lg space-y-3">
      <div className="flex items-center gap-2">
        <span className="text-sm font-medium text-gray-700">Your Role:</span>
        <RoleBadge />
      </div>
      
      <div className="text-sm text-gray-600">
        <p className="font-medium mb-1">Permissions:</p>
        <ul className="list-disc list-inside space-y-1">
          <li className="text-green-600">View newsletters</li>
          {canUpload && <li className="text-green-600">Upload newsletters</li>}
          {canDelete && <li className="text-green-600">Delete newsletters</li>}
          {canManageSettings && <li className="text-green-600">Manage settings</li>}
          {canViewAnalytics && <li className="text-green-600">View analytics</li>}
        </ul>
      </div>
    </div>
  );
}

/**
 * Displays an access denied message
 */
export function AccessDenied({ 
  message = "You don't have permission to access this feature.",
  requiredRole 
}: { 
  message?: string;
  requiredRole?: string;
}) {
  return (
    <div className="flex flex-col items-center justify-center p-8 text-center">
      <Shield className="w-12 h-12 text-gray-400 mb-4" />
      <h3 className="text-lg font-medium text-gray-900 mb-2">Access Denied</h3>
      <p className="text-gray-500 max-w-md">{message}</p>
      {requiredRole && (
        <p className="text-sm text-gray-400 mt-2">
          Required role: <span className="font-medium">{requiredRole}</span>
        </p>
      )}
    </div>
  );
}
