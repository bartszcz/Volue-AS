#!/usr/bin/env python3
"""
Generate intelligent commit messages based on git diff
"""

import subprocess
import sys
import os
import re

def get_git_diff():
    """Get the staged git diff"""
    try:
        result = subprocess.run(
            ['git', 'diff', '--cached'],
            capture_output=True,
            text=True,
            check=True
        )
        return result.stdout
    except subprocess.CalledProcessError:
        return ""

def get_changed_files():
    """Get list of changed files"""
    try:
        result = subprocess.run(
            ['git', 'diff', '--cached', '--name-only'],
            capture_output=True,
            text=True,
            check=True
        )
        return result.stdout.strip().split('\n')
    except subprocess.CalledProcessError:
        return []

def analyze_changes(diff, files):
    """Analyze the diff to determine commit type and message"""
    
    # Count changes
    additions = len(re.findall(r'^\+[^+]', diff, re.MULTILINE))
    deletions = len(re.findall(r'^-[^-]', diff, re.MULTILINE))
    
    # Determine commit type based on changes
    commit_type = "chore"
    scope = ""
    description = ""
    
    # Analyze file types and patterns
    has_feature = any(keyword in diff.lower() for keyword in ['new', 'add', 'create', 'implement'])
    has_fix = any(keyword in diff.lower() for keyword in ['fix', 'bug', 'error', 'issue', 'resolve'])
    has_docs = any(f.endswith(('.md', '.txt', '.rst')) for f in files)
    has_test = any('test' in f.lower() for f in files)
    has_config = any(f in ['.gitignore', 'package.json', 'requirements.txt', 'pyproject.toml'] for f in files)
    has_refactor = additions > 0 and deletions > 0 and not has_feature and not has_fix
    
    # Determine type
    if has_fix:
        commit_type = "fix"
        description = "resolve issues and bugs"
    elif has_feature:
        commit_type = "feat"
        description = "add new functionality"
    elif has_docs:
        commit_type = "docs"
        description = "update documentation"
    elif has_test:
        commit_type = "test"
        description = "add or update tests"
    elif has_refactor:
        commit_type = "refactor"
        description = "improve code structure"
    elif has_config:
        commit_type = "chore"
        description = "update configuration"
    elif deletions > additions:
        commit_type = "refactor"
        description = "remove unused code"
    else:
        commit_type = "chore"
        description = "update codebase"
    
    # Determine scope from files
    if files:
        # Get the most common directory or file type
        dirs = [f.split('/')[0] for f in files if '/' in f]
        if dirs:
            from collections import Counter
            scope = Counter(dirs).most_common(1)[0][0]
        elif len(files) == 1:
            scope = os.path.splitext(os.path.basename(files[0]))[0]
    
    # Generate specific description from file names
    if len(files) == 1:
        filename = os.path.basename(files[0])
        description = f"update {filename}"
    elif len(files) <= 3:
        filenames = [os.path.basename(f) for f in files]
        description = f"update {', '.join(filenames)}"
    else:
        description = f"update {len(files)} files"
    
    # Format commit message
    if scope:
        message = f"{commit_type}({scope}): {description}"
    else:
        message = f"{commit_type}: {description}"
    
    return message

def generate_ai_message():
    """Generate commit message using AI (requires API key)"""
    api_key = os.getenv('OPENAI_API_KEY') or os.getenv('ANTHROPIC_API_KEY')
    
    if not api_key:
        return None
    
    diff = get_git_diff()
    if not diff:
        return None
    
    # Truncate diff if too long
    if len(diff) > 3000:
        diff = diff[:3000] + "\n... (truncated)"
    
    try:
        # Try OpenAI first
        if os.getenv('OPENAI_API_KEY'):
            import openai
            openai.api_key = os.getenv('OPENAI_API_KEY')
            
            response = openai.ChatCompletion.create(
                model="gpt-4",
                messages=[
                    {"role": "system", "content": "You are a helpful assistant that generates concise, conventional commit messages. Use the format: type(scope): description. Types: feat, fix, docs, style, refactor, test, chore."},
                    {"role": "user", "content": f"Generate a commit message for this diff:\n\n{diff}"}
                ],
                max_tokens=100,
                temperature=0.7
            )
            
            return response.choices[0].message.content.strip()
    except Exception:
        pass
    
    return None

def main():
    commit_type = sys.argv[1] if len(sys.argv) > 1 else "auto"
    
    # Try AI generation first if available
    if commit_type == "ai":
        message = generate_ai_message()
        if message:
            print(message)
            return
    
    # Fall back to rule-based generation
    diff = get_git_diff()
    files = get_changed_files()
    
    if not diff:
        print("chore: update files")
        return
    
    message = analyze_changes(diff, files)
    print(message)

if __name__ == "__main__":
    main()
