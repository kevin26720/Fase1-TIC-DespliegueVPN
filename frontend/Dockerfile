# ==========================================
# Stage 1: Build Next.js Application
# ==========================================
FROM node:20-alpine AS builder
WORKDIR /app

# Upgrade npm to latest version for security and performance
RUN npm install -g npm@latest

# Copy package configurations and install dependencies
COPY package.json package-lock.json ./
RUN npm ci

# Copy code and build application
COPY . .
RUN npm run build

# ==========================================
# Stage 2: Minimal Runner Environment
# ==========================================
FROM node:20-alpine AS runner
WORKDIR /app

# Upgrade pre-installed npm to resolve CVEs in its transitive dependencies (cross-spawn, glob, minimatch, tar)
RUN npm install -g npm@latest

ENV NODE_ENV=production
ENV PORT=3000
ENV HOSTNAME="0.0.0.0"

# Create a non-root system user and group for security
RUN addgroup --system --gid 1001 nodejs \
    && adduser --system --uid 1001 nextjs

# Copy required runtime files from builder stage
COPY --from=builder /app/public ./public
COPY --from=builder /app/.next ./.next
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./package.json

# Drop root privileges
USER nextjs

EXPOSE 3000

# Start Next.js in production mode
CMD ["npm", "start"]
