# Role-Based Access Control (RBAC) Setup

This guide explains how to configure and manage role-based access control for the HSE Newsletter Manager.

## Overview

The app supports three roles with different permission levels:

| Role | Permissions |
|------|-------------|
| **Admin** | Full access - view, upload, delete newsletters, manage settings, view analytics |
| **Editor** | Can view, upload, and delete newsletters |
| **Viewer** | Read-only access to newsletters |

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Microsoft Entra ID                          │
│                                                                 │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐ │
│  │ HSE-Newsletter- │  │ HSE-Newsletter- │  │ HSE-Newsletter- │ │
│  │     Admins      │  │     Editors     │  │     Viewers     │ │
│  │    (Group)      │  │    (Group)      │  │    (Group)      │ │
│  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘ │
│           │                    │                    │          │
│           ▼                    ▼                    ▼          │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │           App Registration (App Roles)                   │   │
│  │   Admin ◄──────► Editor ◄──────► Viewer                 │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    HSE Newsletter Manager App                    │
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │
│  │ RoleProvider │──│  useRoles()  │──│ RequireRole Component│   │
│  └──────────────┘  └──────────────┘  └──────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Setup Instructions

### Step 1: Create Entra ID Security Groups

1. Go to [Azure Portal](https://portal.azure.com)
2. Navigate to **Microsoft Entra ID** > **Groups**
3. Click **+ New group** and create:

| Group Name | Type | Description |
|------------|------|-------------|
| `HSE-Newsletter-Admins` | Security | Full access to HSE Newsletter Manager |
| `HSE-Newsletter-Editors` | Security | Can upload and edit newsletters |
| `HSE-Newsletter-Viewers` | Security | Read-only access to newsletters |

4. Add users to the appropriate groups based on their required access level

### Step 2: Configure App Roles in App Registration

1. Go to **Microsoft Entra ID** > **App registrations**
2. Select **PL-LB-HSE Newsletter Manager**
3. Click **App roles** > **+ Create app role**

Create these three roles:

**Admin Role:**
- Display name: `Admin`
- Allowed member types: `Users/Groups`
- Value: `Admin`
- Description: `Full access - manage content, settings, and view analytics`
- Enabled: Yes

**Editor Role:**
- Display name: `Editor`
- Allowed member types: `Users/Groups`
- Value: `Editor`
- Description: `Can upload and manage newsletter content`
- Enabled: Yes

**Viewer Role:**
- Display name: `Viewer`
- Allowed member types: `Users/Groups`
- Value: `Viewer`
- Description: `Read-only access to newsletters`
- Enabled: Yes

### Step 3: Assign Groups to App Roles

1. Go to **Microsoft Entra ID** > **Enterprise applications**
2. Select **PL-LB-HSE Newsletter Manager**
3. Click **Users and groups** > **+ Add user/group**
4. For each group, select the group and assign the corresponding role:

| Group | Assigned Role |
|-------|---------------|
| HSE-Newsletter-Admins | Admin |
| HSE-Newsletter-Editors | Editor |
| HSE-Newsletter-Viewers | Viewer |

## Using Roles in Code

### Check User Roles with `useRoles()` Hook

```tsx
import { useRoles } from '@/components/role-provider';

function MyComponent() {
  const { 
    roles,           // Array of user's roles
    highestRole,     // 'Admin', 'Editor', or 'Viewer'
    isAdmin,         // true if user is Admin
    isEditor,        // true if user is Admin or Editor
    canUpload,       // true if user can upload
    canDelete,       // true if user can delete
    canManageSettings, // true if user can manage settings
    canViewAnalytics,  // true if user can view analytics
  } = useRoles();

  return (
    <div>
      {canUpload && <UploadButton />}
      {isAdmin && <AdminPanel />}
    </div>
  );
}
```

### Conditionally Render with `RequireRole` Component

```tsx
import { RequireRole, AdminOnly, EditorOnly, CanUpload } from '@/components/require-role';

function MyPage() {
  return (
    <div>
      {/* Show only for Admins */}
      <AdminOnly>
        <SettingsPanel />
      </AdminOnly>

      {/* Show for Admins and Editors */}
      <EditorOnly>
        <EditButton />
      </EditorOnly>

      {/* Show based on permission */}
      <CanUpload>
        <UploadButton />
      </CanUpload>

      {/* Show based on specific role */}
      <RequireRole role="Admin">
        <DeleteAllButton />
      </RequireRole>

      {/* Show fallback for unauthorized users */}
      <RequireRole 
        permission="manage:settings" 
        fallback={<p>You don't have access to settings</p>}
      >
        <SettingsForm />
      </RequireRole>
    </div>
  );
}
```

### Display User Role Badge

```tsx
import { RoleBadge, PermissionsSummary } from '@/components/role-badge';

function Header() {
  return (
    <header>
      <RoleBadge />  {/* Shows Admin/Editor/Viewer badge */}
    </header>
  );
}

function ProfilePage() {
  return (
    <div>
      <PermissionsSummary />  {/* Shows detailed permissions */}
    </div>
  );
}
```

## Permission Matrix

| Permission | Admin | Editor | Viewer |
|------------|:-----:|:------:|:------:|
| View newsletters | ✓ | ✓ | ✓ |
| Upload newsletters | ✓ | ✓ | ✗ |
| Delete newsletters | ✓ | ✓ | ✗ |
| Manage settings | ✓ | ✗ | ✗ |
| View analytics | ✓ | ✗ | ✗ |

## Managing Users

### Adding a New User

1. Go to [Azure Portal](https://portal.azure.com) > **Microsoft Entra ID** > **Groups**
2. Select the appropriate group (Admins, Editors, or Viewers)
3. Click **Members** > **+ Add members**
4. Search for and select the user
5. Click **Select**

The user will have access the next time they sign in.

### Changing a User's Role

1. Remove the user from their current group
2. Add them to the new group

### Removing Access

1. Remove the user from all HSE-Newsletter groups
2. The user will lose access the next time their token expires (or immediately if they sign out)

## Troubleshooting

### User doesn't see their role

1. Have the user sign out and sign back in
2. Check that the user is added to one of the security groups
3. Verify the group is assigned to an app role in Enterprise Applications

### Roles not appearing in token

1. Ensure app roles are enabled in App Registration
2. Ensure groups are assigned to roles in Enterprise Applications
3. Check that `roles` claim is included in the token

### "Access Denied" errors

1. Check user's group membership
2. Verify the component is using the correct permission check
3. Check browser console for any errors

## Security Best Practices

1. **Principle of Least Privilege**: Assign users the minimum role needed
2. **Regular Audits**: Review group memberships quarterly
3. **Separate Test/Prod**: Use different groups for test and production
4. **Document Changes**: Log all role changes with justification
5. **Emergency Access**: Ensure at least 2 Admins are always available
