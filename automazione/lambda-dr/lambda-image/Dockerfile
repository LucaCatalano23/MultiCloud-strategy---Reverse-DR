ARG AWS_LAMBDA_BASE_IMAGE=public.ecr.aws/lambda/python:3.11

FROM ${AWS_LAMBDA_BASE_IMAGE} AS lambda-base

FROM lambda-base AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# AWS Lambda base images already contain the Lambda Runtime Interface Emulator.
# Keeping the binary in the final image lets the same artifact run unchanged on
# AWS Lambda and on-premises; the entrypoint selects the execution mode.
RUN test -x /usr/local/bin/aws-lambda-rie

COPY automazione/lambda-dr/lambda-image/lambda-entrypoint.sh /opt/lambda-dr/lambda-entrypoint.sh
RUN chmod 0755 /opt/lambda-dr/lambda-entrypoint.sh

# Replace this COPY with the application artifact in a real pipeline. The
# handler module is intentionally isolated from the DR bootstrap code so Lambda
# business logic does not need on-premises-specific imports or branches.
COPY automazione/lambda-dr/sample-lambda/app.py ${LAMBDA_TASK_ROOT}/app.py

ENTRYPOINT ["/opt/lambda-dr/lambda-entrypoint.sh"]
CMD ["app.handler"]
