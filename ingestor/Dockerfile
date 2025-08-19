FROM python:3.11-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py /app/main.py
COPY config.yaml /app/config.yaml

CMD ["python", "-m", "main"]
