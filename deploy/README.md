# Deploy na VM Oracle

O dominó roda na VM Oracle (ARM, Ubuntu 24.04) ao lado do Koin, sem mexer nele:

```
GitHub Actions ──build arm64──> ghcr.io/julio-dourado/project-paradigms:sha-xxxxxxx
      │
      └── ssh domino-deploy@VM "sha-xxxxxxx" ──> /usr/local/bin/domino-deploy
                                                   docker compose -p domino (/opt/domino)
                                                   container domino-app:8000 ─┐
                                                                              │ rede koin-edge
          Caddy do Koin (80/443, HTTPS automático) ───────────────────────────┘
          /opt/koin/proxy/caddy/sites/domino.caddy -> domino-app:8000
```

Endereço: **https://domino.144-22-232-63.sslip.io**

## Como publicar

O workflow `.github/workflows/ci.yml` roda os testes em todo push e PR. O deploy só acontece com push na branch **`deploy`**:

```bash
git push origin main:deploy
```

Ou abra um PR de `main` para `deploy` e faça o merge. O job compila a imagem para `linux/arm64`, publica no GHCR com a tag `sha-<commit>` e chama a VM. Se a versão nova não ficar saudável (healthcheck em `/health`), a VM volta sozinha para a anterior.

## O que fica na VM

| Caminho | Dono | O que é |
|---|---|---|
| `/usr/local/bin/domino-deploy` | root | Script que a chave de deploy pode rodar (cópia de `deploy/domino-deploy`). |
| `/home/domino-deploy/.ssh/authorized_keys` | domino-deploy | Chave do GitHub Actions, presa ao script acima (`command=...,restrict`). |
| `/opt/domino/compose.yml` e `.env` | domino-deploy | Stack do dominó. O `.env` só guarda `APP_IMAGE`, gravado pelo deploy. |
| `/opt/koin/proxy/caddy/sites/domino.caddy` | deploy | Site no Caddy do Koin (cópia de `deploy/domino.caddy`). |

O CD do dominó não escreve nos arquivos do Koin. A chave do dominó só roda o `domino-deploy`, e a do Koin só roda o `koin-deploy`.

## Secrets do repositório

| Secret | Valor |
|---|---|
| `DEPLOY_SSH_KEY` | Chave privada ed25519 do usuário `domino-deploy`. |
| `DEPLOY_HOST` | IP da VM. |
| `DEPLOY_KNOWN_HOSTS` | Saída de `ssh-keyscan -t ed25519 <IP>`, para o Actions conferir a VM. |

O pull da imagem usa o `GITHUB_TOKEN` temporário do próprio job, então não há token do GHCR guardado na VM.

## Instalação na VM (uma vez só)

Feita com o usuário `ubuntu`:

```bash
sudo useradd -m -s /bin/bash domino-deploy
sudo usermod -aG docker domino-deploy
sudo install -d -o domino-deploy -g domino-deploy /opt/domino
sudo install -m 755 deploy/domino-deploy /usr/local/bin/domino-deploy
# authorized_keys de domino-deploy:
#   command="/usr/local/bin/domino-deploy",restrict ssh-ed25519 AAAA... github-actions@domino
sudo install -o deploy -g deploy -m 644 deploy/domino.caddy /opt/koin/proxy/caddy/sites/domino.caddy
sudo docker exec koin-proxy-caddy-1 caddy validate --config /etc/caddy/Caddyfile
sudo docker exec koin-proxy-caddy-1 caddy reload --config /etc/caddy/Caddyfile
```

Mudou `domino-deploy` ou `domino.caddy`? Repita a linha correspondente: o CD não se autoatualiza. Antes de recarregar o Caddy, rode sempre o `caddy validate`, porque um erro no site do dominó impediria o Caddy de subir depois de um reboot, e aí o Koin também cairia.

## Comandos úteis na VM

```bash
sudo docker compose -p domino --project-directory /opt/domino ps
sudo docker compose -p domino --project-directory /opt/domino logs -f app
curl -s https://domino.144-22-232-63.sslip.io/health
```

## Rodar a imagem localmente

```bash
docker build -t domino .
docker run --rm -p 8000:8000 domino
```
