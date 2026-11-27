FROM redis:7.4-alpine
RUN apk add --no-cache bash python3
WORKDIR /app
COPY bin/redis-tui.sh bin/redis-tls.py ./
ENTRYPOINT ["bash", "/app/redis-tui.sh"]
