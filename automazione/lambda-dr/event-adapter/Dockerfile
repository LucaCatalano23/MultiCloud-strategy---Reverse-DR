FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN addgroup --system adapter && adduser --system --ingroup adapter adapter

WORKDIR /app
COPY automazione/lambda-dr/event-adapter/requirements.txt ./requirements.txt
RUN pip install --requirement requirements.txt
COPY automazione/lambda-dr/event-adapter/app.py ./app.py

USER adapter
EXPOSE 8080
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "2"]
