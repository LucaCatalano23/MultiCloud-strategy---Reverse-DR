ARG LOCALSTACK_BASE_IMAGE=localstack/localstack-pro:latest
FROM ${LOCALSTACK_BASE_IMAGE}

COPY bootstrap/ready.d/10-bootstrap-aws.sh /etc/localstack/init/ready.d/10-bootstrap-aws.sh
COPY functions/ticket_processor.py /opt/reverse-dr/functions/ticket_processor.py

RUN chmod 0755 /etc/localstack/init/ready.d/10-bootstrap-aws.sh

