# Build context = repo root (Render default)
FROM node:22-alpine AS client-build
WORKDIR /client
COPY dashboard/client/package.json dashboard/client/package-lock.json ./
RUN npm ci
COPY dashboard/client/ ./
RUN npm run build

FROM node:22-alpine
WORKDIR /app
COPY dashboard/server/package.json dashboard/server/package-lock.json ./
RUN npm ci --omit=dev
COPY dashboard/server/index.js dashboard/server/mockInfer.js dashboard/server/mock-data.json ./
COPY --from=client-build /client/dist ./public
ENV NODE_ENV=production
ENV PORT=3000
EXPOSE 3000
CMD ["node", "index.js"]
