# Dominó em Prolog + Elm

Trabalho final de Paradigmas de Programação: um jogo de dominó (duplo-seis) contra o computador.
As regras do jogo ficam em **Prolog**, a interface em **Elm**, e um backend em **Python/FastAPI** faz a ponte entre os dois.

> Projeto em construção. As partes já prontas estão marcadas na seção [Andamento](#andamento).

## Arquitetura

```
Navegador (Elm)  <--HTTP/JSON-->  FastAPI (Python)  <--janus-->  SWI-Prolog
   avaliado                        não avaliado                   avaliado
```

- **Prolog** (`backend/prolog/`): toda a lógica do jogo, como distribuir as peças, validar jogadas, comprar, passar a vez, detectar o fim e escolher a jogada do computador.
- **FastAPI** (`backend/app/`): recebe as requisições do navegador, chama o Prolog pelo [janus](https://www.swi-prolog.org/pldoc/man?section=janus) e devolve JSON.
- **Elm** (`frontend/src/`): a tela do jogo, com a mesa, a mão do jogador e a do oponente.

## Representação dos dados

O janus só converte listas, números e átomos. Termos compostos como `peca(3,5)` não passam, e por isso tudo é representado com listas e átomos.

| Conceito | Representação | Exemplo |
|---|---|---|
| Peça (na mão ou no monte) | lista `[A,B]` com `A =< B` | `[3,5]` |
| Mão / monte | lista de peças | `[[0,1],[2,2],[3,6]]` |
| Mesa | peças da ponta esquerda para a direita, cada uma virada para encostar na vizinha | `[[6,5],[5,2],[2,2]]` (pontas 6 e 2) |
| Lado da jogada | átomo `left` ou `right` | `right` |
| Jogada | lista `[Peça, Lado]` | `[[2,4], right]` |
| Turno | átomo `player` ou `opponent` | `player` |

Estado da partida trocado com o frontend:

```json
{
  "player_hand":   [[0,1],[2,4]],
  "opponent_hand": [[3,3],[1,6]],
  "table":         [[6,5],[5,2]],
  "boneyard":      [[0,0],[4,5]],
  "turn":          "player"
}
```

Rotas previstas: `new-game`, `play`, `opponent-move` e `hint`.

## Predicados Prolog

Todos ficam no módulo `domino` (`backend/prolog/domino.pl`).

### Preparação da partida

| Predicado | O que faz |
|---|---|
| `all_pieces(-Pieces)` | Gera as 28 peças do duplo-seis. |
| `shuffle(+Pieces, -Shuffled)` | Embaralha as peças. |
| `deal(+Shuffled, -Player, -Opponent, -Boneyard)` | Dá 7 peças para cada jogador e deixa 14 no monte. |
| `piece_rank(+Piece, -Rank)` | Força da peça: buchas valem mais e, entre as outras, vale a maior soma. |
| `starter(+Player, +Opponent, -Turn, -Piece)` | Decide quem começa e com qual peça. |
| `new_game(-Player, -Opponent, -Boneyard, -Turn, -StartPiece)` | Monta uma partida completa. |

### Regras das jogadas

| Predicado | O que faz |
|---|---|
| `table_ends(+Table, -Left, -Right)` | Pontas da mesa. Falha com a mesa vazia. |
| `fits(+Piece, +Table, ?Side)` | Verdadeiro se a peça encaixa naquele lado. Na mesa vazia, o lado é `right`. |
| `valid_moves(+Hand, +Table, -Moves)` | Todas as jogadas possíveis como `[Peça, Lado]`. |
| `playable_pieces(+Hand, +Table, -Pieces)` | Peças da mão que podem ser jogadas. |
| `play_piece(+Piece, +Side, +Hand, +Table, -NewHand, -NewTable)` | Joga a peça: tira da mão, vira se preciso e coloca na mesa. Aceita `[5,3]` ou `[3,5]`. Falha se a jogada for inválida. |
| `draw(+Boneyard, +Hand, -NewBoneyard, -NewHand)` | Compra uma peça do monte. Falha com o monte vazio. |
| `draw_until_playable(+Hand, +Table, +Boneyard, -NewHand, -NewBoneyard, -Drawn)` | Compra até ter jogada ou o monte acabar. `Drawn` lista as peças compradas. |
| `can_pass(+Hand, +Table, +Boneyard)` | Só pode passar quem não tem jogada e não tem mais o que comprar. |
| `next_turn(+Turn, -Next)` | Alterna entre `player` e `opponent`. |

### Fim de jogo

| Predicado | O que faz |
|---|---|
| `domino_out(+Hand)` | Verdadeiro se a mão está vazia (o jogador bateu). |
| `blocked(+Player, +Opponent, +Table, +Boneyard)` | Jogo trancado: monte vazio e nenhum dos dois tem jogada. |
| `hand_points(+Hand, -Points)` | Soma dos pontos da mão. |
| `game_over(+Player, +Opponent, +Table, +Boneyard, -Winner, -Points)` | Falha enquanto há jogo. `Winner` é `player`, `opponent` ou `draw`. Na batida vence quem ficou sem peças; no trancado, quem tem menos pontos. O vencedor marca a soma da mão do perdedor (0 no empate). |

### Adversário e dica

| Predicado | O que faz |
|---|---|
| `move_score(+Move, +Hand, +Table, -Score)` | Nota da jogada: pontos da peça + 5 se for bucha + 2 por peça que continua jogável depois. |
| `choose_move(+Hand, +Table, -Move)` | Jogada do computador: a de maior nota. Falha se não houver jogada (aí compra com `draw_until_playable/6` ou passa). |
| `hint(+Hand, +Table, +Boneyard, -Hint)` | Dica para o jogador: `[Peça, Lado]`, `draw` (comprar) ou `pass` (passar). |

Exemplo no `swipl`:

```prolog
?- use_module(backend/prolog/domino).

?- valid_moves([[0,6],[2,4],[1,3]], [[6,5],[5,2]], Moves).
Moves = [[[0,6], left], [[2,4], right]].

?- play_piece([0,2], right, [[0,2]], [[6,5],[5,2]], Hand, Table).
Hand = [],
Table = [[6,5],[5,2],[2,0]].
```

## Como rodar

Requisito: [SWI-Prolog](https://www.swi-prolog.org/download/stable) 9 ou mais novo.

Testes do Prolog:

```bash
cd backend/prolog
swipl -g "consult(test_domino), (run_tests -> halt(0) ; halt(1))"
```

O backend FastAPI e o frontend Elm ainda não estão no repositório. As instruções deles entram aqui quando forem adicionados.

## Andamento

| Parte | Responsável | Arquivos | Situação |
|---|---|---|---|
| 1. Prolog: preparação | VituuDias | `backend/prolog/domino.pl`, `test_domino.pl` | ✅ pronto |
| 2. Prolog: jogadas | Guga | `backend/prolog/domino.pl`, `test_domino.pl` | ✅ pronto |
| 3. Prolog: fim de jogo e adversário | Pedro Luiz | `backend/prolog/domino.pl`, `test_domino.pl` | ✅ pronto |
| 4. Elm: modelo e API | Bruno | `frontend/src/Domino.elm`, `Api.elm` | ⏳ pendente |
| 5. Elm: lógica da tela | Samuel Ricardo | `frontend/src/Main.elm` | ⏳ pendente |
| 6. Elm: visual | — | `frontend/src/View.elm`, `style.css` | ⏳ pendente |
| 7. Integração e documentação | — | `backend/app/`, `Makefile`, `RELATORIO.md` | ⏳ pendente |

## Prazos

- **18/11**: entrega sem desconto
- **23/11** e **30/11**: entrega com desconto
