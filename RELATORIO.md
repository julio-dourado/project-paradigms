# Relatório: Dominó em Prolog + Elm

Trabalho final de **Paradigmas de Programação**. Jogo de dominó duplo-seis em que uma pessoa joga contra o computador no navegador.

## 1. Equipe

| Parte | Responsável |
|---|---|
| 1. Prolog: preparação | VituuDias |
| 2. Prolog: jogadas | Guga |
| 3. Prolog: fim de jogo e adversário | Pedro Luiz |
| 4. Elm: modelo e API | Bruno |
| 5. Elm: lógica da tela | Samuel Ricardo |
| 6. Elm: visual | Patrick Anderson Carvalho dos Santos |
| 7. Integração e documentação | Julio Cesar Almeida Dourado |

## 2. Objetivo

Construir um jogo completo usando dois paradigmas diferentes, cada um onde ele rende mais:

- **Lógico (Prolog)** para as regras: o dominó é um conjunto de relações entre peças, mãos e mesa ("esta peça encaixa naquela ponta", "este jogador pode passar"), o que combina com fatos, regras e busca.
- **Funcional (Elm)** para a interface: a tela é uma função pura do estado da partida, e toda mudança passa por mensagens tipadas.

Um backend em **Python/FastAPI** liga os dois. Ele não faz parte da avaliação e por isso foi mantido fino: só traduz HTTP/JSON para consultas Prolog e de volta.

## 3. Arquitetura

```
Navegador (Elm)  <--HTTP/JSON-->  FastAPI (Python)  <--janus-->  SWI-Prolog
 frontend/src/                     backend/app/                  backend/prolog/
```

| Camada | Arquivos | Papel |
|---|---|---|
| Regras | `backend/prolog/domino.pl` | Toda a lógica do jogo: distribuir, validar, comprar, passar, fim de jogo, jogada do computador e dica. |
| Ponte | `backend/app/prolog.py` | Uma função Python por predicado, chamada pelo [janus](https://www.swi-prolog.org/pldoc/man?section=janus). |
| API | `backend/app/main.py` | Rotas HTTP, validação do estado recebido e montagem das respostas. Também serve a pasta `frontend/`. |
| Tela | `frontend/src/View.elm`, `style.css` | Desenho da mesa, das mãos e do fim de jogo, recebendo tudo pronto em `View.Props`. |

O servidor **não guarda estado**. O navegador manda a partida inteira em cada requisição e recebe a partida nova. Isso tem três vantagens:

1. O Prolog trabalha só com termos que chegam como argumento, sem `assert`/`retract` nem variáveis globais, que é o estilo natural do paradigma lógico.
2. No Elm o estado também é um valor imutável no `Model`, então os dois lados pensam da mesma forma: `estado novo = f(estado antigo, ação)`.
3. Reiniciar o servidor não perde nenhuma partida, e vários jogadores podem usar o mesmo backend.

## 4. Paradigma lógico: o Prolog

As regras estão em um único módulo, `domino`, com 22 predicados exportados. Alguns recursos do paradigma que aparecem no código:

**Geração por busca.** As 28 peças não são escritas à mão. `all_pieces/1` descreve o que é uma peça e deixa o `findall/3` enumerar as soluções:

```prolog
all_pieces(Pieces) :-
    findall([A,B], ( between(0, 6, A), between(A, 6, B) ), Pieces).
```

**Predicados reversíveis.** `fits(+Piece, +Table, ?Side)` serve tanto para perguntar "encaixa na direita?" quanto para descobrir os lados possíveis. `valid_moves/3` é só o `findall` dessa segunda forma, e o backtracking faz o resto.

**Unificação no lugar de condicionais.** `table_ends/3` obtém as pontas casando o padrão da primeira peça e da última, e falha sozinho com a mesa vazia. `place/4` escolhe o lado da jogada pela cláusula que unifica com `left` ou `right`.

**Corte para regras exclusivas.** Em `piece_rank/2` a cláusula da bucha (`[A,A]`) usa `!` para que uma bucha não seja avaliada também como peça comum. Em `game_over/6`, o corte separa batida de jogo trancado.

**Recursão.** `draw_until_playable/6` compra uma peça por vez até ter jogada ou o monte acabar, devolvendo a lista do que foi comprado.

**Falha como resposta.** `game_over/6` falha enquanto há jogo, `choose_move/3` falha quando não há jogada e `can_pass/3` só é verdadeiro sem jogada e sem monte. A API usa essas falhas diretamente: falhou, a ação não é permitida.

**Adversário sem IA.** `choose_move/3` dá uma nota a cada jogada (`move_score/4`: pontos da peça, +5 se for bucha, +2 por peça que continua jogável) e pega a maior com `keysort/2`. A mesma regra alimenta a dica (`hint/4`).

Os 67 testes de `backend/prolog/test_domino.pl` (plunit) cobrem cada predicado.

## 5. Paradigma funcional: o Elm

A interface segue a **Arquitetura Elm** (modelo, `update` e `view`):

- **Tipos algébricos** descrevem tudo o que a tela pode mostrar: `Status = Loading | PlayerTurn | OpponentTurn | Finished Winner Int`, `Hint = PlayHint Piece End | DrawHint | PassHint`, `End = LeftEnd | RightEnd`. Estados impossíveis não compilam.
- **Funções puras**: `View.view config props` só transforma dados em HTML/SVG. As peças, o monte e o logo são SVG gerados por funções, sem nenhuma imagem baixada.
- **Efeitos como dados**: a tela não chama a API. Ela devolve mensagens (`onPlay`, `onDraw`, `onHint`...) pelas funções de `View.Config`, e quem decide o que fazer é o `update`.
- **Separação por contrato**: `View.elm` não importa `Main` nem `Domino`. Com isso o visual pôde ser feito e testado (na vitrine `Preview.elm`) antes do restante da tela existir.

## 6. Integração (parte 7)

### 6.1 janus

O janus converte listas, inteiros e átomos, mas não termos compostos. Por isso o projeto inteiro representa peça como lista `[A,B]` e lado/turno como átomo, o que faz os dados chegarem ao Python sem nenhuma conversão manual.

Um detalhe: string do Python vira *string* no Prolog, não átomo. Os lados (`"left"`/`"right"`) e o turno entram na consulta por `atom_string/2`:

```python
janus.query_once(
    "atom_string(Side, SideS), domino:play_piece(Piece, Side, Hand, Table, NewHand, NewTable)",
    {"Piece": [2, 4], "SideS": "right", "Hand": hand, "Table": table},
)
```

O FastAPI atende as rotas em várias threads; um `threading.Lock` em `prolog.py` deixa só uma consulta Prolog rodar por vez.

### 6.2 Rotas

As rotas seguem o contrato da tela (`frontend/src/Api.elm`, parte 5). Todas recebem e devolvem JSON e respondem na raiz (`/new-game`) e também em `/api` (`/api/new-game`). As que mudam a partida respondem com `{"state", "result", "event", "game_over"}`.

| Rota | Corpo | Predicados usados | O que faz |
|---|---|---|---|
| `POST /new-game` | — | `new_game/5` | Partida nova com a mesa vazia. `start_piece` diz a peça de saída. |
| `POST /play` | `state`, `action` | `starter/4`, `play_piece/6`, `draw/4`, `can_pass/3`, `next_turn/2` | Vez do jogador. `action` tem o formato do `hint/4`: `[[2,4],"right"]`, `"draw"` ou `"pass"`. |
| `POST /opponent-move` | `state` | `starter/4`, `draw_until_playable/6`, `choose_move/3`, `play_piece/6` | Vez inteira do computador: compra o que precisar e joga ou passa. |
| `POST /hint` | `state` | `starter/4`, `hint/4` | Dica no formato do `hint/4`: `[[2,4],"right"]`, `"draw"` ou `"pass"`. |
| `GET /health` | — | `next_turn/2` | Confere se o Prolog carregou. |

Também existem `POST /draw` e `POST /pass`, atalhos para o `/play` com `"draw"` e `"pass"`.

Toda resposta com estado passa por `game_over/6`. `result` é `null` enquanto há jogo e, no fim, `{"winner", "points"}`, que é o campo usado pela tela. `game_over` traz o mesmo com `reason` (`domino` na batida, `blocked` no jogo trancado), e `event` conta o lance (quem jogou, qual peça, o que comprou).

Erros: **400** quando a jogada não vale, **409** quando não é a vez de quem pediu ou a partida já acabou, e **422** quando o corpo não é um estado possível. A frase vem em `detail`, em português, e a tela mostra no campo `error`.

### 6.3 Decisões

- **Peça de saída.** O `fits/3` aceita qualquer peça com a mesa vazia, mas a partida deve abrir com a maior bucha. Em vez de guardar a `StartPiece` no estado, a API pergunta de novo ao `starter/4`: com a mesa vazia as mãos ainda são as do começo, então a resposta é a mesma do `new_game/5`.
- **Passar a vez segue o `can_pass/3`.** O visual libera o botão "Passar" mesmo com peça na mão (ver README). A integração manteve a regra do Prolog: o passe com jogada ou com monte é recusado com 400 e uma mensagem explicando o porquê. Assim a regra continua num lugar só.
- **Compra uma a uma para o jogador, de uma vez para o computador.** O jogador compra com `draw/4`, para a tela animar cada peça e a dica voltar a valer. O computador usa `draw_until_playable/6`, e `event.drawn` lista o que ele comprou.
- **Validação do estado.** Como o estado vem do navegador, a API confere se ele é um jogo possível: números de 0 a 6, peças da mão e do monte em ordem crescente, peças vizinhas da mesa encostando e as 28 peças presentes uma vez só. Isso evita que um estado adulterado chegue ao Prolog.
- **Mesma origem.** O FastAPI serve a pasta `frontend/`, então `http://localhost:8000/` abre o jogo e as rotas ficam no mesmo endereço, sem precisar de CORS. O `index.html` usa o próprio endereço da página como backend, o que vale tanto para o computador de quem desenvolve quanto para o site no ar. O CORS fica liberado só para facilitar o desenvolvimento com `elm reactor`.

### 6.4 Testes da integração

`backend/tests/test_api.py` tem 49 testes que passam pelas três camadas (HTTP, FastAPI, janus e o SWI-Prolog de verdade, sem dublês):

- cada rota no caminho feliz e nos erros (jogada inválida, fora da vez, monte vazio, passe recusado);
- abertura com a peça de saída, batida e jogo trancado;
- computador comprando até ter jogada e passando;
- estados inválidos recusados;
- 10 partidas inteiras jogadas só pela API como a tela faz (a dica vira a `action` do `/play`), na raiz e em `/api`, conferindo a cada lance que as 28 peças continuam lá;
- o contrato da tela: `start_piece`, `result`, `action` e a frase em `detail`.

## 7. Como rodar

Requisitos: SWI-Prolog 9 ou mais novo, Python 3.10 ou mais novo e, para a tela, Elm 0.19.1.

```bash
make install     # ambiente Python do backend (FastAPI + janus)
make test        # 67 testes do Prolog + 49 da API
make build       # compila o Elm
make run         # http://localhost:8000 (jogo) e http://localhost:8000/docs (API)
```

`make preview` abre a vitrine do visual, que não precisa do backend.

Com Docker, a imagem completa: `docker build -t domino .` e `docker run --rm -p 8000:8000 domino`.

### 7.1 Deploy

O jogo fica no ar em **https://domino.144-22-232-63.sslip.io**, numa VM Oracle (ARM) que já hospeda outro projeto:

- **Uma imagem só** (`Dockerfile`): a primeira etapa compila o Elm, a segunda instala FastAPI e janus sobre a imagem oficial do SWI-Prolog, e a final junta o backend e os arquivos da tela. O Elm só existe para x86-64, então essa etapa roda sempre em amd64; o JavaScript gerado serve para o ARM.
- **GitHub Actions** (`.github/workflows/ci.yml`): testes em todo push e PR; push na branch `deploy` gera a imagem `linux/arm64`, publica no GHCR e chama a VM.
- **Na VM**, o deploy usa um usuário próprio, cuja chave SSH só consegue rodar o script `domino-deploy`. O script baixa a imagem, sobe o container e volta para a versão anterior se o healthcheck falhar. O HTTPS fica com o Caddy que já estava na VM, que ganhou só um arquivo de site novo; o outro projeto não foi alterado.

Detalhes em `deploy/README.md`.

## 8. Situação e próximos passos

| Item | Situação |
|---|---|
| Regras em Prolog (partes 1 a 3) | Prontas e testadas. |
| Visual em Elm (parte 6) | Pronto, com vitrine jogável. |
| Lógica da tela (`Main.elm`, parte 5) | Pronta e ligada ao backend de verdade, com um `Api.elm` provisório. |
| Modelo e API em Elm (`Domino.elm`, `Api.elm`, parte 4) | Pendente; o `Api.elm` provisório da parte 5 já segue o contrato da seção 6.2. |
| Backend, Makefile, deploy e documentação (parte 7) | Prontos e testados; jogo no ar. |

## 9. Conclusão

Separar as regras em Prolog e a tela em Elm deixou cada paradigma fazer o que faz melhor. As regras do dominó viraram relações curtas e verificáveis, e a busca por jogadas, a dica e o adversário saíram quase de graça do backtracking e do `findall`. Na tela, os tipos algébricos e as funções puras permitiram construir e testar o visual sozinho, só com dados. A integração ficou simples porque o formato dos dados (listas e átomos) foi combinado desde o começo, e o backend sem estado manteve as duas pontas pensando da mesma forma: uma partida é um valor, e cada jogada produz um valor novo.
