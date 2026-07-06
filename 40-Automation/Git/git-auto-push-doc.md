# Git Auto-Push PowerShell Script

## Overview

The Git Auto-Push PowerShell script automates the process of committing and pushing all local changes to GitHub. This tool is designed for developers who want to quickly save their work without manually typing git commands.

## Purpose

- Streamline the git workflow by automating add, commit, and push operations
- Reduce repetitive manual git commands during development
- Ensure consistent commit patterns with auto-generated timestamps
- Support custom commit messages when needed

## Features

- **Automatic Staging**: Stages all changed files with `git add .`
- **Smart Commit Messages**: Auto-generates timestamped messages or accepts custom messages
- **Change Detection**: Only commits when there are actual changes
- **Nested Repository Detection**: Warns about nested `.git` folders that could cause issues
- **Colored Console Output**: Clear visual feedback with color-coded messages
- **Error Handling**: Validates git repository, staged files, and push success
- **Repository Validation**: Ensures script runs from within a git repository

## Prerequisites

- Git installed and configured
- PowerShell 5.1 or higher
- Git repository initialized (`git init`)
- Remote repository configured (e.g., GitHub)
- Git credentials configured for push access

## Installation

1. Save the script to your repository's `scripts` folder
2. Ensure the file is named `git-auto-push.ps1`
3. Enable PowerShell script execution (if needed):
   \`\`\`powershell
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
   \`\`\`

## Usage

### Basic Usage (Auto-generated Commit Message)

Run from your repository root:

\`\`\`powershell
.\scripts\git-auto-push.ps1
\`\`\`

This will create a commit with a timestamp message like: `Auto-commit: 2024-01-15 14:30:45`

### Custom Commit Message

Provide a custom commit message using the `-Message` parameter:

\`\`\`powershell
.\scripts\git-auto-push.ps1 -Message "Fixed authentication bug"
\`\`\`

### Common Use Cases

**Quick save during development:**
\`\`\`powershell
.\scripts\git-auto-push.ps1
\`\`\`

**Feature completion:**
\`\`\`powershell
.\scripts\git-auto-push.ps1 -Message "Completed user profile feature"
\`\`\`

**Bug fix:**
\`\`\`powershell
.\scripts\git-auto-push.ps1 -Message "Fixed issue #123"
\`\`\`

## VS Code Integration

### Method 1: VS Code Task (Recommended)

Add to `.vscode/tasks.json`:

\`\`\`json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Git Auto-Push",
      "type": "shell",
      "command": "powershell",
      "args": [
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "${workspaceFolder}/scripts/git-auto-push.ps1"
      ],
      "presentation": {
        "reveal": "always",
        "panel": "new"
      },
      "problemMatcher": []
    }
  ]
}
\`\`\`

Run with: `Ctrl+Shift+P` → "Tasks: Run Task" → "Git Auto-Push"

### Method 2: Keyboard Shortcut

Add to `.vscode/keybindings.json`:

\`\`\`json
[
  {
    "key": "ctrl+shift+g ctrl+shift+p",
    "command": "workbench.action.tasks.runTask",
    "args": "Git Auto-Push"
  }
]
\`\`\`

Now press `Ctrl+Shift+G` then `Ctrl+Shift+P` to push changes.

### Method 3: PowerShell Alias

Add to your PowerShell profile (`$PROFILE`):

\`\`\`powershell
function Invoke-GitAutoPush {
    param([string]$Message = "")
    & "$PWD\scripts\git-auto-push.ps1" -Message $Message
}
Set-Alias -Name gap -Value Invoke-GitAutoPush
\`\`\`

Usage: `gap` or `gap -Message "Your message"`

## Technical Design

### Script Architecture

\`\`\`
┌─────────────────────────────────────┐
│      Parameter Processing           │
│  - Accept optional -Message param   │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│    Repository Validation            │
│  - Check for .git folder            │
│  - Exit if not a git repo           │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│      Change Detection               │
│  - Run git status --porcelain       │
│  - Exit if no changes               │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│  Nested Repository Detection        │
│  - Find nested .git folders         │
│  - Display warnings                 │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│       Stage Changes                 │
│  - Execute git add .                │
│  - Check staged files               │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│    Generate Commit Message          │
│  - Use custom message if provided   │
│  - Generate timestamp if not        │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│         Commit Changes              │
│  - Execute git commit               │
│  - Check exit code                  │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│         Push to Remote              │
│  - Execute git push                 │
│  - Report success/failure           │
└─────────────────────────────────────┘
\`\`\`

### Error Handling

The script implements comprehensive error checking at each stage:

1. **Repository Check**: Validates `.git` folder exists
2. **Change Detection**: Exits gracefully if no changes detected
3. **Staging Validation**: Ensures files were actually staged (handles nested repo issue)
4. **Commit Validation**: Checks `$LASTEXITCODE` after commit
5. **Push Validation**: Checks `$LASTEXITCODE` after push

### Exit Codes

- `0` - Success or no changes to commit
- `1` - Error occurred (not a repo, commit failed, push failed, or no files staged)

## Common Issues and Solutions

### Issue 1: Nested Git Repositories

**Symptom**: Warning message about nested repositories, no files staged

\`\`\`
Warning: Found nested git repositories. These will be skipped:
  - 20-Endpoint/Intune/intune-migration
\`\`\`

**Cause**: A subdirectory contains its own `.git` folder, causing `git add .` to skip it

**Solution**: Remove the nested `.git` folder:
\`\`\`powershell
Remove-Item -Path '.\20-Endpoint\Intune\intune-migration\.git' -Recurse -Force
\`\`\`

### Issue 2: Script Execution Disabled

**Symptom**: "cannot be loaded because running scripts is disabled"

**Solution**: Enable script execution:
\`\`\`powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
\`\`\`

### Issue 3: Push Authentication Failed

**Symptom**: "Error: Push failed. Check your remote configuration."

**Solutions**:
- Configure Git credentials: `git config credential.helper store`
- Use SSH keys instead of HTTPS
- Verify remote URL: `git remote -v`
- Check GitHub personal access token

### Issue 4: No Changes to Commit

**Symptom**: "No changes to commit." message

**Cause**: All files are already committed

**Solution**: This is normal behavior, no action needed

## Best Practices

### When to Use

- During active development for frequent saves
- End of coding sessions to ensure work is backed up
- After completing small incremental changes
- When switching between tasks or branches

### When NOT to Use

- For production releases (use proper versioning)
- When changes need careful review before commit
- For changes that should be split into multiple commits
- When working on sensitive code requiring approval

### Recommendations

1. **Use Custom Messages for Important Commits**: Auto-timestamps are great for quick saves, but use meaningful messages for significant changes
2. **Review Before Running**: Glance at changed files to ensure you're not committing unwanted files
3. **Configure .gitignore**: Ensure temporary files and secrets are properly ignored
4. **Combine with Branches**: Use feature branches and auto-push to safely experiment
5. **Regular Pushes**: Run frequently to minimize data loss risk

## Security Considerations

### Sensitive Data

- Always review `.gitignore` to exclude sensitive files
- Never commit API keys, passwords, or credentials
- Use environment variables for secrets
- Scan for secrets before pushing (use tools like `git-secrets`)

### Access Control

- Ensure GitHub repository permissions are properly configured
- Use SSH keys instead of password authentication
- Enable two-factor authentication on GitHub
- Rotate access tokens regularly

## Maintenance

### Updating the Script

To update to a newer version:

1. Backup current version: `Copy-Item scripts\git-auto-push.ps1 scripts\git-auto-push.ps1.bak`
2. Replace with new version
3. Test in non-production repository first

### Monitoring

Check script performance and success:

\`\`\`powershell
# View recent commits
git log --oneline -10

# Check if remote is up to date
git status
\`\`\`

## Alternative Approaches

### Manual Git Commands

Traditional approach for full control:
\`\`\`bash
git add .
git commit -m "Your message"
git push
\`\`\`

### Git Aliases

Create a git alias for similar functionality:
\`\`\`bash
git config --global alias.acp '!git add . && git commit -m "Auto-commit" && git push'
\`\`\`
Usage: `git acp`

### VS Code Source Control

Use VS Code's built-in Git UI:
- Stage changes in Source Control panel
- Write commit message
- Click push button

## Conclusion

The Git Auto-Push PowerShell script provides a streamlined workflow for developers who need quick, automated git operations. While it's not a replacement for thoughtful version control practices, it serves as an excellent tool for frequent saves during active development.

## Version History

- **v1.0** - Initial release with basic auto-commit and push
- **v1.1** - Added nested repository detection and validation
- **v1.2** - Improved error handling and staged file validation

## Support

For issues or questions:
- Check the Common Issues section above
- Review PowerShell execution policies
- Verify Git configuration
- Test with manual git commands to isolate issues

## License

This script is provided as-is for internal use. Modify as needed for your workflow.
