# AgentCore Runtime requires linux/arm64.
FROM --platform=linux/arm64 public.ecr.aws/docker/library/python:3.13-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY server.py .
COPY policies ./policies

RUN useradd --create-home app && chown -R app /app
USER app

EXPOSE 8000
CMD ["opentelemetry-instrument", "python", "server.py"]
