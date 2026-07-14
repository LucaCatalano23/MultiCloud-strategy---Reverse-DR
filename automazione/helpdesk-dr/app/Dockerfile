FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app
COPY requirements.txt .
RUN pip install --requirement requirements.txt \
    && addgroup --system --gid 10001 helpdesk \
    && adduser --system --uid 10001 --ingroup helpdesk --no-create-home helpdesk
COPY --chown=helpdesk:helpdesk main.py automation.py ./

USER helpdesk
EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
