"""API do dominó: liga a tela em Elm às regras em Prolog.

O servidor não guarda nada entre uma requisição e outra. O navegador
manda o estado da partida inteiro e recebe o estado novo de volta, no
formato descrito no README:

    {
      "player_hand":   [[0,1],[2,4]],
      "opponent_hand": [[3,3],[1,6]],
      "table":         [[6,5],[5,2]],
      "boneyard":      [[0,0],[4,5]],
      "turn":          "player"
    }

Toda resposta que muda a partida tem o mesmo formato:

    {"state": {...}, "event": {...}, "game_over": null | {...}}

- ``event`` conta o que aconteceu (quem jogou, qual peça, o que comprou),
  para a tela montar o lance a lance;
- ``game_over`` vem preenchido quando a partida acaba
  (``winner``, ``points`` e ``reason``: ``domino`` na batida ou
  ``blocked`` no jogo trancado).

Quem decide se a jogada vale, quem ganhou e o que o computador joga é o
Prolog (``app/prolog.py``). Aqui só ficam as checagens de protocolo:
se é a vez certa, se a partida já acabou e se o estado recebido é um
jogo de dominó possível.
"""

from __future__ import annotations

from pathlib import Path
from typing import Annotated, Any, Literal

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field, model_validator

from . import prolog

Number = Annotated[int, Field(ge=0, le=6)]
Piece = Annotated[list[Number], Field(min_length=2, max_length=2)]
Side = Literal["left", "right"]
Turn = Literal["player", "opponent"]

ALL_PIECES = sorted((a, b) for a in range(7) for b in range(a, 7))


class GameState(BaseModel):
    player_hand: list[Piece]
    opponent_hand: list[Piece]
    table: list[Piece]
    boneyard: list[Piece]
    turn: Turn

    @model_validator(mode="after")
    def _consistent(self) -> "GameState":
        # Na mão e no monte as peças ficam em ordem crescente, como no Prolog.
        for name in ("player_hand", "opponent_hand", "boneyard"):
            for a, b in getattr(self, name):
                if a > b:
                    raise ValueError(f"{name}: a peça [{a},{b}] deve vir como [{b},{a}]")
        # Na mesa cada peça encosta na vizinha.
        for (_, right), (left, _) in zip(self.table, self.table[1:]):
            if right != left:
                raise ValueError("table: peças vizinhas não encostam")
        # As 28 peças aparecem uma vez só, somando mãos, mesa e monte.
        seen = [tuple(sorted(p)) for p in self.player_hand + self.opponent_hand + self.table + self.boneyard]
        if sorted(seen) != ALL_PIECES:
            raise ValueError("o estado precisa ter as 28 peças, cada uma uma vez só")
        return self

    def hand(self, who: str) -> list[list[int]]:
        return self.player_hand if who == "player" else self.opponent_hand


class StateRequest(BaseModel):
    state: GameState


class PlayRequest(BaseModel):
    state: GameState
    piece: Piece
    side: Side


app = FastAPI(
    title="Dominó em Prolog + Elm",
    description="Ponte HTTP/JSON entre a tela em Elm e as regras em SWI-Prolog (via janus).",
    version="1.0.0",
)

# Liberado para o `elm reactor` e servidores de desenvolvimento em outras portas.
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])


# ----------------------------------------------------------------------
# Auxiliares
# ----------------------------------------------------------------------


def _game_over(state: GameState) -> dict[str, Any] | None:
    result = prolog.game_over(state.player_hand, state.opponent_hand, state.table, state.boneyard)
    if result is None:
        return None
    winner, points = result
    reason = "domino" if not state.player_hand or not state.opponent_hand else "blocked"
    return {"winner": winner, "points": points, "reason": reason}


def _response(state: GameState, event: dict[str, Any]) -> dict[str, Any]:
    return {"state": state.model_dump(), "event": event, "game_over": _game_over(state)}


def _check_turn(state: GameState, who: str) -> None:
    if _game_over(state) is not None:
        raise HTTPException(409, "A partida já terminou. Comece uma nova.")
    if state.turn != who:
        quem = "do jogador" if who == "player" else "do computador"
        raise HTTPException(409, f"Não é a vez {quem}.")


def _opening(state: GameState) -> list[int] | None:
    """Com a mesa vazia, só a peça de saída (``starter/4``) pode entrar."""
    if state.table:
        return None
    starter, piece = prolog.starter(state.player_hand, state.opponent_hand)
    if starter != state.turn:
        raise HTTPException(409, "Quem abre a partida é o outro jogador.")
    return piece


def _play(state: GameState, who: str, piece: list[int], side: str) -> GameState:
    """Joga a peça pelo Prolog e passa a vez. Erro 422 se a jogada não vale."""
    opening = _opening(state)
    if opening is not None and sorted(piece) != opening:
        raise HTTPException(422, f"A partida abre com a peça {opening}.")
    result = prolog.play_piece(piece, side, state.hand(who), state.table)
    if result is None:
        raise HTTPException(422, "Jogada inválida: a peça não está na mão ou não encaixa nessa ponta.")
    new_hand, new_table = result
    data = state.model_dump()
    data["player_hand" if who == "player" else "opponent_hand"] = new_hand
    data["table"] = new_table
    data["turn"] = prolog.next_turn(who)
    return GameState.model_validate(data)


# ----------------------------------------------------------------------
# Rotas
# ----------------------------------------------------------------------


@app.get("/api/health")
def health() -> dict[str, str]:
    """Confere se o Prolog carregou."""
    prolog.next_turn("player")
    return {"status": "ok"}


@app.post("/api/new-game")
def new_game() -> dict[str, Any]:
    """Partida nova (``new_game/5``). A mesa começa vazia; quem tem a vez abre com ``start_piece``."""
    g = prolog.new_game()
    state = GameState(
        player_hand=g["player_hand"],
        opponent_hand=g["opponent_hand"],
        table=[],
        boneyard=g["boneyard"],
        turn=g["turn"],
    )
    return _response(state, {"type": "new_game", "turn": g["turn"], "start_piece": g["start_piece"]})


@app.post("/api/play")
def play(req: PlayRequest) -> dict[str, Any]:
    """Jogada do jogador (``play_piece/6``)."""
    _check_turn(req.state, "player")
    state = _play(req.state, "player", req.piece, req.side)
    return _response(state, {"type": "play", "who": "player", "piece": sorted(req.piece), "side": req.side})


@app.post("/api/draw")
def draw(req: StateRequest) -> dict[str, Any]:
    """O jogador compra uma peça (``draw/4``). Só vale sem jogada na mão."""
    state = req.state
    _check_turn(state, "player")
    if prolog.playable_pieces(state.player_hand, state.table):
        raise HTTPException(422, "Você ainda tem peça que encaixa: não precisa comprar.")
    result = prolog.draw(state.boneyard, state.player_hand)
    if result is None:
        raise HTTPException(422, "O monte acabou: passe a vez.")
    boneyard, hand = result
    new_state = state.model_copy(update={"player_hand": hand, "boneyard": boneyard})
    return _response(new_state, {"type": "draw", "who": "player", "pieces": [hand[-1]]})


@app.post("/api/pass")
def pass_turn(req: StateRequest) -> dict[str, Any]:
    """O jogador passa a vez (``can_pass/3``): só sem jogada e com o monte vazio."""
    state = req.state
    _check_turn(state, "player")
    if not prolog.can_pass(state.player_hand, state.table, state.boneyard):
        if prolog.playable_pieces(state.player_hand, state.table):
            raise HTTPException(422, "Você ainda tem peça que encaixa.")
        raise HTTPException(422, "Ainda dá para comprar do monte.")
    new_state = state.model_copy(update={"turn": prolog.next_turn("player")})
    return _response(new_state, {"type": "pass", "who": "player"})


@app.post("/api/opponent-move")
def opponent_move(req: StateRequest) -> dict[str, Any]:
    """Vez do computador, inteira de uma vez.

    1. Com a mesa vazia, abre com a peça de saída (``starter/4``).
    2. Se não tem jogada, compra até ter (``draw_until_playable/6``).
    3. Joga a de maior nota (``choose_move/3``) ou passa a vez.
    """
    state = req.state
    _check_turn(state, "opponent")

    opening = _opening(state)
    if opening is not None:
        new_state = _play(state, "opponent", opening, "right")
        return _response(new_state, {"type": "play", "who": "opponent", "piece": opening, "side": "right", "drawn": []})

    hand, boneyard, drawn = prolog.draw_until_playable(state.opponent_hand, state.table, state.boneyard)
    state = state.model_copy(update={"opponent_hand": hand, "boneyard": boneyard})

    move = prolog.choose_move(hand, state.table)
    if move is None:
        new_state = state.model_copy(update={"turn": prolog.next_turn("opponent")})
        return _response(new_state, {"type": "pass", "who": "opponent", "drawn": drawn})

    piece, side = move
    new_state = _play(state, "opponent", piece, side)
    return _response(new_state, {"type": "play", "who": "opponent", "piece": piece, "side": side, "drawn": drawn})


@app.post("/api/hint")
def hint(req: StateRequest) -> dict[str, Any]:
    """Dica para o jogador (``hint/4``).

    Devolve ``{"type": "play", "piece": [2,4], "side": "right"}``,
    ``{"type": "draw"}`` ou ``{"type": "pass"}``.
    """
    state = req.state
    _check_turn(state, "player")
    opening = _opening(state)
    if opening is not None:
        return {"hint": {"type": "play", "piece": opening, "side": "right"}}
    h = prolog.hint(state.player_hand, state.table, state.boneyard)
    if isinstance(h, tuple):
        return {"hint": {"type": "play", "piece": h[0], "side": h[1]}}
    return {"hint": {"type": h}}


# ----------------------------------------------------------------------
# Frontend
# ----------------------------------------------------------------------

# Serve a pasta `frontend/` na raiz, para o jogo e a API ficarem na mesma
# origem: http://localhost:8000/ abre o jogo e /preview.html a vitrine.
FRONTEND_DIR = Path(__file__).resolve().parents[2] / "frontend"
if FRONTEND_DIR.is_dir():
    app.mount("/", StaticFiles(directory=FRONTEND_DIR, html=True), name="frontend")
