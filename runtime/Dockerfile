# The ONE agent image. Every agent in agents/ runs this; AGENT_NAME picks which.
# Build from the repo root:  docker buildx build --platform linux/arm64 -f runtime/Dockerfile .
FROM --platform=linux/arm64 public.ecr.aws/docker/library/python:3.13-slim

ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /app

COPY pyproject.toml README.md ./
COPY eap ./eap
COPY agents ./agents
RUN pip install ".[otel]"

RUN useradd --create-home app && chown -R app /app
USER app

EXPOSE 8080
# opentelemetry-instrument + ADOT sends LangChain/LangGraph spans to CloudWatch.
CMD ["opentelemetry-instrument", "python", "-m", "eap.runtime.app"]
