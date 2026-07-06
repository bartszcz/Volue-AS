# Stage 1: Dependencies
FROM node:24-alpine AS deps
RUN apk add --no-cache libc6-compat
WORKDIR /app

# Install pnpm (pinned — keep in sync with renovate-pipeline.yml)
RUN corepack enable && corepack prepare pnpm@9.15.0 --activate

# Copy package files
COPY package.json pnpm-lock.yaml ./

# Install dependencies
RUN pnpm install --frozen-lockfile

# Stage 2: Builder
FROM node:24-alpine AS builder
WORKDIR /app

RUN corepack enable && corepack prepare pnpm@9.15.0 --activate

COPY --from=deps /app/node_modules ./node_modules
COPY . .

# Build arguments for MSAL and OneDrive configuration
ARG NEXT_PUBLIC_MSAL_CLIENT_ID
ARG NEXT_PUBLIC_MSAL_TENANT_ID
ARG NEXT_PUBLIC_ONEDRIVE_DRIVE_ID
ARG NEXT_PUBLIC_ONEDRIVE_ITEM_ID
ARG NEXT_PUBLIC_ONEDRIVE_FOLDER_PATH

# Set environment variables for build
ENV NEXT_TELEMETRY_DISABLED=1
ENV NODE_ENV=production
ENV NEXT_PUBLIC_MSAL_CLIENT_ID=$NEXT_PUBLIC_MSAL_CLIENT_ID
ENV NEXT_PUBLIC_MSAL_TENANT_ID=$NEXT_PUBLIC_MSAL_TENANT_ID
ENV NEXT_PUBLIC_ONEDRIVE_DRIVE_ID=$NEXT_PUBLIC_ONEDRIVE_DRIVE_ID
ENV NEXT_PUBLIC_ONEDRIVE_ITEM_ID=$NEXT_PUBLIC_ONEDRIVE_ITEM_ID
ENV NEXT_PUBLIC_ONEDRIVE_FOLDER_PATH=$NEXT_PUBLIC_ONEDRIVE_FOLDER_PATH

# Build the application
RUN pnpm build

# Stage 3: Runner
FROM node:24-alpine AS runner
WORKDIR /app

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

# Create non-root user for security
RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 nextjs

# Copy necessary files from builder
COPY --from=builder /app/public ./public
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static

# Set correct ownership
RUN chown -R nextjs:nodejs /app

USER nextjs

EXPOSE 3000

ENV PORT=3000
ENV HOSTNAME="0.0.0.0"

CMD ["node", "server.js"]
