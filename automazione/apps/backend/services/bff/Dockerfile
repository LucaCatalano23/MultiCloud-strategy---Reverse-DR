FROM python:3.12.8-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app/src

RUN addgroup --system --gid 10001 helios \
    && adduser --system --uid 10001 --ingroup helios --home /nonexistent helios

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir --requirement requirements.txt
COPY src ./src

USER 10001:10001
EXPOSE 8000
CMD ["uvicorn", "helios_bff.main:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
