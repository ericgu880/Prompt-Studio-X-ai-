FROM node:20-bookworm-slim AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY tsconfig.json ./
COPY prisma ./prisma
COPY src ./src
RUN npm run prisma:generate && npm run build

FROM node:20-bookworm-slim
WORKDIR /app
ENV NODE_ENV=production
COPY package*.json ./
RUN npm ci --omit=dev
COPY --from=build /app/dist ./dist
COPY --from=build /app/node_modules/.prisma ./node_modules/.prisma
COPY prisma ./prisma
EXPOSE 8787
CMD ["npm", "run", "start"]
