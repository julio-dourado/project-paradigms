# Imagem única do dominó: FastAPI + SWI-Prolog (janus) servindo a API e a tela em Elm.
#   docker build -t domino .
#   docker run --rm -p 8000:8000 domino      -> http://localhost:8000

# 1) Tela em Elm. O Elm só tem binário para Linux x86-64, então esta etapa roda
#    sempre em amd64; o JavaScript gerado serve para qualquer arquitetura.
FROM --platform=linux/amd64 node:22-bookworm-slim AS elm
RUN npm install -g elm@0.19.1-6
WORKDIR /src
COPY frontend/elm.json ./
COPY frontend/src ./src
RUN elm make src/Main.elm --optimize --output=build/main.js \
 && elm make src/Preview.elm --optimize --output=build/preview.js

# 2) Dependências Python. O janus-swi é compilado contra o SWI-Prolog da imagem.
FROM swipl:10.0.2 AS python
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-venv python3-dev gcc libc6-dev \
 && rm -rf /var/lib/apt/lists/*
COPY backend/requirements.txt /tmp/requirements.txt
RUN python3 -m venv /venv \
 && /venv/bin/pip install --no-cache-dir -r /tmp/requirements.txt

# 3) Imagem final: só o necessário para rodar.
FROM swipl:10.0.2
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home /app domino
COPY --from=python /venv /venv
WORKDIR /app
COPY backend/app ./backend/app
COPY backend/prolog/domino.pl ./backend/prolog/domino.pl
COPY frontend/index.html frontend/preview.html frontend/style.css ./frontend/
COPY frontend/assets ./frontend/assets
COPY --from=elm /src/build ./frontend/build

ENV FRONTEND_DIR=/app/frontend \
    PATH=/venv/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
USER domino
WORKDIR /app/backend
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=4)"
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--forwarded-allow-ips", "*"]
