# Dominó em Prolog + Elm: atalhos para instalar, testar e rodar.
#
#   make install   cria o ambiente Python do backend
#   make test      roda os testes do Prolog e da API
#   make build     compila o Elm (jogo e vitrine)
#   make run       sobe o backend em http://localhost:8000 (API + tela)
#   make preview   compila e abre a vitrine do visual (sem backend)
#   make validar   confere a forma do RELATORIO.md (scripts/validar_entrega.py)

PYTHON   ?= python3
PORT     ?= 8000
VENV     := backend/.venv
PY       := $(VENV)/bin/python
ELM      ?= elm

PROLOG_DIR   := backend/prolog
FRONTEND_DIR := frontend

.PHONY: help install test test-prolog test-api build build-main build-preview run preview clean validar

help:
	@sed -n 's/^#   //p' Makefile

$(PY):
	$(PYTHON) -m venv $(VENV)
	$(PY) -m pip install --upgrade pip
	$(PY) -m pip install -r backend/requirements.txt -r backend/requirements-dev.txt

install: $(PY)

test: test-prolog test-api

test-prolog:
	cd $(PROLOG_DIR) && swipl -g "consult(test_domino), (run_tests -> halt(0) ; halt(1))"

test-api: $(PY)
	cd backend && .venv/bin/python -m pytest -v

build: build-main build-preview

# O Main.elm é a parte 5; enquanto não existir, só a vitrine é compilada.
build-main:
	@if [ -f $(FRONTEND_DIR)/src/Main.elm ]; then \
		cd $(FRONTEND_DIR) && $(ELM) make src/Main.elm --optimize --output=build/main.js; \
	else \
		echo "frontend/src/Main.elm ainda não existe: pulando o jogo."; \
	fi

build-preview:
	cd $(FRONTEND_DIR) && $(ELM) make src/Preview.elm --output=build/preview.js

run: $(PY)
	cd backend && .venv/bin/uvicorn app.main:app --reload --port $(PORT)

preview: build-preview
	open $(FRONTEND_DIR)/preview.html 2>/dev/null || xdg-open $(FRONTEND_DIR)/preview.html

clean:
	rm -rf $(FRONTEND_DIR)/build $(FRONTEND_DIR)/elm-stuff
	find backend -name __pycache__ -type d -prune -exec rm -rf {} +
	rm -rf backend/.pytest_cache

validar:
	uv run scripts/validar_entrega.py
