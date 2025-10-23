FROM node:18-alpine
WORKDIR /app

# Copy package files from subfolder (works with root build context)
COPY signaling_server/package*.json ./

# Install dependencies
RUN npm ci --only=production

# Copy server code from subfolder
COPY signaling_server/server.js ./

# Expose WebSocket port
EXPOSE 8080

# Health check (use curl; add it to the image)
RUN apk add --no-cache curl
HEALTHCHECK --interval=30s --timeout=3s CMD curl -fsS http://localhost:8080/ || exit 1

# Start server
CMD ["node", "server.js"]