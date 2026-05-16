ARG BUN_IMAGE=oven/bun:1.3.13-debian@sha256:e95356cb8e1de62ad69ab3bd3584ba947013d27650a226804d2fc0af4e17dac2

FROM ${BUN_IMAGE} AS deps
WORKDIR /app/services/typescript-bun
COPY services/typescript-bun/package.json services/typescript-bun/bun.lock ./
RUN bun install --frozen-lockfile --production

FROM ${BUN_IMAGE}
WORKDIR /app/services/typescript-bun
ENV NODE_ENV=production
COPY --from=deps /app/services/typescript-bun/node_modules ./node_modules
COPY services/typescript-bun/package.json services/typescript-bun/tsconfig.json ./
COPY services/typescript-bun/src ./src
USER bun
CMD ["bun", "run", "src/index.ts"]
