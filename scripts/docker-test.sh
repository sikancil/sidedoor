#!/bin/bash

# VM Access API - Docker Testing Script

set -e

ACTION=${1:-"build"}

case "$ACTION" in
  build)
    echo "🔨 Building Docker image..."
    docker build -t vm-access-api .
    ;;

  run)
    echo "🚀 Running container..."
    docker run --rm -it \
      --privileged \
      -p 3000:3000 \
      -p 2222:22 \
      -v "$(pwd)/data:/app/data" \
      -v "$(pwd)/config.json:/app/config.json:ro" \
      vm-access-api
    ;;

  shell)
    echo "🐚 Opening shell in container..."
    docker run --rm -it \
      --privileged \
      -p 3000:3000 \
      -p 2222:22 \
      -v "$(pwd):/app" \
      vm-access-api \
      bash
    ;;

  test)
    echo "🧪 Testing API..."
    # Wait for API to start
    sleep 3

    # Health check
    echo "Health check:"
    curl -s http://localhost:3000/health | jq .

    echo ""
    echo "Root endpoint:"
    curl -s http://localhost:3000/ | jq .

    echo ""
    echo "Creating certificate..."
    RESPONSE=$(curl -s -X POST http://localhost:3000/api/certificates \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer vm-access-api-default-token-please-change-in-production" \
      -d '{
        "directoryPath": "/home/sftp/test/uploads",
        "permissions": ["sftp", "read-write"],
        "ttl": 3600,
        "authenticatorToken": "vm-access-api-default-token-please-change-in-production"
      }')

    echo "$RESPONSE" | jq .

    CERT_ID=$(echo "$RESPONSE" | jq -r '.data.id // empty')

    if [ -n "$CERT_ID" ]; then
      echo ""
      echo "Listing certificates:"
      curl -s http://localhost:3000/api/certificates \
        -H "Authorization: Bearer vm-access-api-default-token-please-change-in-production" | jq .

      echo ""
      echo "Testing SFTP connection (will fail without user setup in container):"
      echo "sftp -P 2222 -i downloaded.key cert_user_$CERT_ID@localhost"
    fi
    ;;

  compose)
    echo "🐳 Using docker-compose..."
    docker-compose up --build
    ;;

  clean)
    echo "🧹 Cleaning up..."
    docker-compose down -v
    docker system prune -f
    ;;

  *)
    echo "VM Access API - Docker Testing Script"
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  build    - Build the Docker image"
    echo "  run      - Run the container"
    echo "  shell    - Open a shell in the container"
    echo "  test     - Run API tests"
    echo "  compose  - Use docker-compose"
    echo "  clean    - Clean up containers and images"
    echo ""
    exit 1
    ;;
esac
