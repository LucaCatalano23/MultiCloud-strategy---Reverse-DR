ARG AWS_LAMBDA_BASE_IMAGE=public.ecr.aws/lambda/python:3.11

FROM ${AWS_LAMBDA_BASE_IMAGE} AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Stessa immagine per entrambi i siti: le base image AWS Lambda includono gia'
# il Runtime Interface Emulator, quindi l'artefatto che gira su AWS Lambda gira
# invariato anche sotto lambda-dr. Non ci sono dipendenze applicative: la
# function usa solo la standard library, cosi' l'immagine resta minima e non
# introduce una superficie di patching in piu' nel percorso DR.
COPY automazione/apps/functions/ticket-processor/handler.py ${LAMBDA_TASK_ROOT}/handler.py

CMD ["handler.handler"]
