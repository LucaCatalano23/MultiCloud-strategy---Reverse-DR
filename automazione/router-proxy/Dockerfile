FROM alpine:3.20

RUN apk add --no-cache squid

EXPOSE 3128

CMD ["sh", "-ec", "rm -f /tmp/squid.pid; exec squid -NCd1 -f /etc/squid/squid.conf"]
