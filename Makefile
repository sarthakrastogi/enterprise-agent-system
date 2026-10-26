.PHONY: help install test manifest validate fmt deploy ui user destroy dev-agent dev-mcp

PY ?= .venv/bin/python
TERRAFORM ?= terraform
export TERRAFORM

help:
	@echo "install     create .venv with runtime, test and UI dependencies"
	@echo "test        run unit tests (no AWS needed)"
	@echo "manifest    validate agents/ and write build/agents.json"
	@echo "validate    terraform fmt -check + validate"
	@echo "deploy      build images and apply Terraform (scripts/deploy.sh)"
	@echo "ui          run the chat UI on http://localhost:8501"
	@echo "user        invite a user: make user EMAIL=a@b.com [ADMIN=1]"
	@echo "dev-agent   run an agent locally: make dev-agent AGENT=it_helpdesk"
	@echo "dev-mcp     run the knowledge MCP server locally on :8000/mcp"
	@echo "destroy     delete everything"

install:
	python3 -m venv .venv
	$(PY) -m pip install -q --upgrade pip
	$(PY) -m pip install -q -e ".[dev]" -r frontend/requirements.txt

test:
	$(PY) -m pytest -q

manifest:
	@mkdir -p build
	$(PY) -m eap.manifest > build/agents.json
	@cat build/agents.json

validate: manifest
	$(TERRAFORM) -chdir=infra fmt -check -recursive
	$(TERRAFORM) -chdir=infra init -backend=false -input=false >/dev/null
	$(TERRAFORM) -chdir=infra validate

fmt:
	$(TERRAFORM) -chdir=infra fmt -recursive

deploy:
	scripts/deploy.sh

ui:
	cd frontend && ../$(PY) -m streamlit run app.py --browser.gatherUsageStats=false

user:
	scripts/create_user.sh $(EMAIL) $(if $(ADMIN),--admin,)

# Runs the agent loop against real Bedrock with your local AWS credentials.
# Without GATEWAY_URL it has no gateway tools; LOCAL_DEV=1 skips the JWT.
dev-agent:
	AGENT_NAME=$(AGENT) LOCAL_DEV=1 $(PY) -m eap.runtime.app

dev-mcp:
	$(PY) mcp_servers/knowledge/server.py

destroy:
	scripts/destroy.sh
