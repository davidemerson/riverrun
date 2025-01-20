# Use a specific version for stability
FROM golang:1.21 AS builder

# Set working directory
WORKDIR /app

# Copy application source
COPY streamer/ ./streamer/
COPY converter/ ./converter/
COPY uploader/ ./uploader/

# Build applications
RUN cd streamer && go mod tidy && go build -o /app/bin/streamer && cd ..
RUN cd converter && go mod tidy && go build -o /app/bin/converter && cd ..
RUN cd uploader && go mod tidy && go build -o /app/bin/uploader && cd ..

# Minimal runtime image
FROM debian:bullseye-slim

# Install necessary runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy built binaries
COPY --from=builder /app/bin/ ./bin/

# Expose ports if needed
EXPOSE 8080 8081 8082

# Entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Define entrypoint
ENTRYPOINT ["/entrypoint.sh"]
