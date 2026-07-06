#!/usr/bin/env bash
# sync-docs.sh — extracts authoritative values from config files and updates docs.
# Run from the repository root:  bash .github/scripts/sync-docs.sh
set -euo pipefail

APP="60-Utility/Personal"

# ── Source of truth ────────────────────────────────────────────────────────────
NODE_VERSION=$(grep -m1 'FROM node:' "$APP/Dockerfile" | sed 's/FROM node:\([0-9]*\).*/\1/')
PNPM_VERSION=$(grep -m1 'pnpm@[0-9]' "$APP/Dockerfile" | sed 's/.*pnpm@\([0-9][0-9.]*\).*/\1/')
NEXT_MAJOR=$(node -e "const v=require('./$APP/package.json').dependencies.next.replace(/[^0-9.]/g,''); console.log(v.split('.')[0])")
REACT_MAJOR=$(node -e "const v=require('./$APP/package.json').dependencies.react.replace(/[^0-9.]/g,''); console.log(v.split('.')[0])")
TODAY=$(date +'%B %d, %Y')

echo "Syncing: Node $NODE_VERSION | pnpm $PNPM_VERSION | Next.js $NEXT_MAJOR | React $REACT_MAJOR"

# ── README.md ──────────────────────────────────────────────────────────────────
README="$APP/README.md"
sed -i "s/Node\.js [0-9]*+/Node.js ${NODE_VERSION}+/g"              "$README"
sed -i "s/\*\*Node\.js [0-9]*+\*\*/\*\*Node.js ${NODE_VERSION}+\*\*/g" "$README"
sed -i "s/Next\.js [0-9]*/Next.js ${NEXT_MAJOR}/g"                  "$README"
sed -i "s/React [0-9]*/React ${REACT_MAJOR}/g"                       "$README"
sed -i "s/\*\*Last Updated\*\*: .*/\*\*Last Updated\*\*: ${TODAY}/" "$README"

# ── docs/HOW_IT_WORKS.md ──────────────────────────────────────────────────────
HOW="$APP/docs/HOW_IT_WORKS.md"
sed -i "s/Node\.js [0-9]*/Node.js ${NODE_VERSION}/g"                 "$HOW"
sed -i "s/Node [0-9]*/Node ${NODE_VERSION}/g"                        "$HOW"

# ── renovate-pipeline.yml — keep pnpm version pinned to match Dockerfile ──────
RENOVATE="$APP/renovate-pipeline.yml"
sed -i "s/pnpm@[0-9][0-9.]*/pnpm@${PNPM_VERSION}/g"                 "$RENOVATE"

echo "Done."
