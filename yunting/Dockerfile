FROM node:22-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY app.js game.html index.html about.html poems.html ./
COPY poems/ ./poems/
ENV PORT=3000
EXPOSE 3000
CMD ["node", "app.js"]
