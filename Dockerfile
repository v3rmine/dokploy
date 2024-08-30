FROM node:18-alpine AS base
ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
RUN corepack enable

FROM base AS build
COPY . /usr/src/app
WORKDIR /usr/src/app

RUN apk add --no-cache python3 make g++ git bash

# Install dependencies
RUN --mount=type=cache,id=pnpm,target=/pnpm/store pnpm install --frozen-lockfile

# Deploy only the dokploy app

ENV NODE_ENV=production
RUN pnpm --filter=./apps/dokploy run build
RUN pnpm --filter=./apps/dokploy --prod deploy /prod/dokploy

RUN cp -R /usr/src/app/apps/dokploy/.next /prod/dokploy/.next
RUN cp -R /usr/src/app/apps/dokploy/dist /prod/dokploy/dist

FROM base AS dokploy
WORKDIR /app

# Set production
ENV NODE_ENV=production

RUN apk add --no-cache curl apache2-utils bash tar

# Copy only the necessary files
COPY --from=build /prod/dokploy/.next ./.next
COPY --from=build /prod/dokploy/dist ./dist
COPY --from=build /prod/dokploy/next.config.mjs ./next.config.mjs
COPY --from=build /prod/dokploy/public ./public
COPY --from=build /prod/dokploy/package.json ./package.json
COPY --from=build /prod/dokploy/drizzle ./drizzle
COPY .env.production ./.env
COPY --from=build /prod/dokploy/components.json ./components.json
COPY --from=build /prod/dokploy/node_modules ./node_modules


# Install docker
RUN apk add --no-cache docker-cli

# Install Nixpacks and tsx
# | VERBOSE=1 VERSION=1.21.0 bash
RUN curl -sSL https://nixpacks.com/install.sh -o install.sh \
    && chmod +x install.sh \
    && ./install.sh \
    && pnpm install -g tsx

# Install buildpacks
COPY --from=buildpacksio/pack:0.35.0-base /usr/local/bin/pack /usr/local/bin/pack

EXPOSE 3000
CMD [ "pnpm", "start" ]
