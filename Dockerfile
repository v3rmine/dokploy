FROM node:18-alpine AS base
ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
RUN corepack enable

FROM base AS build
COPY . /usr/src/app
WORKDIR /usr/src/app

RUN apk add --no-cache python3 make g++ git bash jq rsync

# Install dependencies
RUN --mount=type=cache,id=pnpm,target=/pnpm/store pnpm install --frozen-lockfile

# Deploy only the dokploy app
ENV NODE_ENV=production
RUN mkdir -p /prod/dokploy
RUN bash -c 'cp -R /usr/src/app/apps/dokploy/{next.config.mjs,public,package.json,drizzle,components.json} /prod/dokploy/'

FROM build AS build-server
RUN pnpm --filter=./apps/dokploy run build-server
# Extract server dependencies
RUN cat apps/dokploy/dist/metafile.json | jq -r '[.outputs | map_values(.imports) | to_entries[] | select(.value | length > 0) | .value[] | select(.external) | .path | select(test("node:")| not)] | unique' > apps/dokploy/dist/imports-deps.json
RUN echo '"copy-webpack-plugin"' | jq -r '. | split(",")' > apps/dokploy/dist/manual-deps.json
RUN jq -s '.[0] as $package | [.[1], .[2]] | flatten | . as $deps | [$package | .dependencies | to_entries[] | .key as $key | select($deps[] | contains($key))] | from_entries | . as $newDeps | $package | .devDependencies = {} | .dependencies = $newDeps' apps/dokploy/package.json apps/dokploy/dist/imports-deps.json apps/dokploy/dist/manual-deps.json > apps/dokploy/new-package.json
RUN rm -rf node_modules apps/dokploy/node_modules && mv apps/dokploy/new-package.json apps/dokploy/package.json
RUN --mount=type=cache,id=pnpm,target=/pnpm/store pnpm install --fix-lockfile
RUN ls -al node_modules apps/dokploy/node_modules && exit 1
# Deploy server dependencies
RUN mv apps/dokploy/node_modules apps/dokploy/symlinked_node_modules && mkdir -p apps/dokploy/node_modules
RUN find apps/dokploy/symlinked_node_modules -maxdepth 2 -type l -exec bash -c 'out="$(echo "{}" | sed "s|symlinked_node_modules|node_modules|")"; mkdir -p "$(dirname "$out")" && cp -r "$(readlink "{}" | sed -E "s|^(../)+||")" "$out"' ';'
RUN cp -r apps/dokploy/dist apps/dokploy/node_modules /prod/dokploy

FROM build AS build-next
RUN pnpm --filter=./apps/dokploy run build-next
RUN mkdir -p /prod/dokploy/.next
RUN cp -R /usr/src/app/apps/dokploy/.next/standalone/apps/dokploy /prod/dokploy/.next/standalone
# Fix symlinks in node_modules
RUN find /prod/dokploy/.next/standalone/node_modules -maxdepth 2 -type l -exec bash -c 'ln -sfT "$(readlink "{}" | sed "s|../../../node_modules/||" | tee -a /tmp/used_module.txt)" "{}"' ';'
RUN cp -R /usr/src/app/apps/dokploy/.next/standalone/node_modules/.pnpm /prod/dokploy/.next/standalone/node_modules
RUN cp -R /usr/src/app/apps/dokploy/.next/static /prod/dokploy/.next/static

FROM build AS merger
WORKDIR /prod/dokploy

# Copy only the necessary files
COPY --from=build /prod/dokploy/next.config.mjs /prod/dokploy/next.config.mjs
COPY --from=build /prod/dokploy/public /prod/dokploy/public
COPY --from=build /prod/dokploy/drizzle /prod/dokploy/drizzle
COPY --from=build /prod/dokploy/components.json /prod/dokploy/components.json
COPY --from=build-next /prod/dokploy/.next/standalone /prod/dokploy/
COPY --from=build-next /prod/dokploy/.next/static /prod/dokploy/.next/static
COPY --from=build-server /prod/dokploy/dist /prod/dokploy/dist
COPY --from=build-server /prod/dokploy/node_modules /prod/dokploy/node_modules_to_merge
# TODO: Merge dirs
RUN rsync -av --keep-dirlinks node_modules_to_merge/ node_modules
RUN rm -rf ./node_modules_to_merge

COPY .env.production ./.env

FROM base AS dokploy
WORKDIR /app

# Set production
ENV NODE_ENV=production
ENV HOSTNAME=0.0.0.0

RUN apk add --no-cache curl apache2-utils bash tar

COPY --from=merger /prod/dokploy /app

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
