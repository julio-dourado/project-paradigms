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

As rotas seguem o contrato da tela (``frontend/src/Api.elm``) e respondem
tanto na raiz (``/new-game``) quanto em ``/api`` (``/api/new-game``).
Toda resposta que muda a partida tem o mesmo formato:

    {"state": {...}, "result": null | {...}, "event": {...}, "game_over": null | {...}}

- ``result`` é o ``game_over/6``: ``{"winner": "player", "points": 14}``,
  ou ``null`` enquanto há jogo. É o campo que a tela usa;
- ``event`` conta o que aconteceu (quem jogou, qual peça, o que comprou);
- ``game_over`` é o ``result`` com ``reason``: ``domino`` na batida ou
  ``blocked`` no jogo trancado.

Quem decide se a jogada vale, quem ganhou e o que o computador joga é o
Prolog (``app/prolog.py``). Aqui só ficam as checagens de protocolo:
se é a vez certa, se a partida já acabou e se o estado recebido é um
jogo de dominó possível.

Poderes especiais (``backend/prolog/powers.pl``, só valem depois da primeira
peça na mesa): o estado ganha três
campos opcionais, que o navegador devolve como recebeu:

    "player_powers":   ["freeze", "shield", "time"],
    "opponent_powers": ["curse", "swap", "flames"],
    "effects":         [["freeze", "opponent", "left"], ["used", "player"]]

e toda resposta que muda a partida traz, já calculado pelo Prolog:
``player_moves`` (jogadas ``[peça, lado]`` permitidas agora, com
congelamento e chamas), ``must_draw``, ``can_pass``, ``usable_powers`` e
``revealed`` (buchas do computador reveladas pela Sobrecarga). Sem
poderes no estado, tudo se comporta como o dominó comum.

Erros: 400 quando a jogada não vale (com a frase em ``detail``), 409
quando não é a vez de quem pediu ou a partida já acabou, e 422 quando o
corpo da requisição não é um estado possível.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Annotated, Any, Literal

from fastapi import APIRouter, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field, TypeAdapter, model_validator

from . import prolog

Number = Annotated[int, Field(ge=0, le=6)]
Piece = Annotated[list[Number], Field(min_length=2, max_length=2)]
Side = Literal["left", "right"]
Turn = Literal["player", "opponent"]
Power = Literal["freeze", "curse", "overload", "shield", "recovery", "teleport", "time", "swap", "flames"]

# Quantos itens cada efeito tem: [tipo, alvo, ...]. Só valida o formato;
# o que cada efeito faz fica no Prolog.
EFFECT_SIZES = {"freeze": 3, "flames": 3, "revealed": 3, "curse": 2, "curse_due": 2, "time": 2, "used": 2}

POWER_NAMES = {
    "freeze": "Congelamento",
    "curse": "Maldição",
    "overload": "Sobrecarga",
    "shield": "Escudo",
    "recovery": "Recuperação",
    "teleport": "Teletransporte",
    "time": "Manipulação do tempo",
    "swap": "Troca",
    "flames": "Chamas",
}

ALL_PIECES = sorted((a, b) for a in range(7) for b in range(a, 7))


class GameState(BaseModel):
    player_hand: list[Piece]
    opponent_hand: list[Piece]
    table: list[Piece]
    boneyard: list[Piece]
    turn: Turn
    player_powers: list[Power] = Field(default_factory=list)
    opponent_powers: list[Power] = Field(default_factory=list)
    effects: list[list[Any]] = Field(default_factory=list)

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
        # Poderes: ninguém tem o mesmo poder duas vezes.
        for name in ("player_powers", "opponent_powers"):
            if len(set(getattr(self, name))) != len(getattr(self, name)):
                raise ValueError(f"{name}: poder repetido")
        for effect in self.effects:
            _check_effect(effect)
        return self

    def hand(self, who: str) -> list[list[int]]:
        return self.player_hand if who == "player" else self.opponent_hand


def _check_effect(effect: list[Any]) -> None:
    """Confere o formato de um efeito ativo, como ``["freeze", "opponent", "left"]``."""
    kind = effect[0] if effect else None
    if kind not in EFFECT_SIZES or len(effect) != EFFECT_SIZES[kind]:
        raise ValueError(f"efeito inválido: {effect}")
    if effect[1] not in ("player", "opponent"):
        raise ValueError(f"efeito com alvo inválido: {effect}")
    if kind == "freeze" and effect[2] not in ("left", "right"):
        raise ValueError(f"efeito com ponta inválida: {effect}")
    if kind == "flames" and not (isinstance(effect[2], int) and 0 <= effect[2] <= 6):
        raise ValueError(f"efeito com número inválido: {effect}")
    if kind == "revealed":
        for piece in effect[2]:
            Piece_adapter.validate_python(piece)


Piece_adapter = TypeAdapter(Piece)


class StateRequest(BaseModel):
    state: GameState


class PlayRequest(BaseModel):
    """Jogada do jogador.

    Formato da tela: ``action`` igual ao ``hint/4`` (``[[2,4], "right"]``,
    ``"draw"`` ou ``"pass"``). Também aceita ``piece`` + ``side``.
    """

    state: GameState
    action: tuple[Piece, Side] | Literal["draw", "pass"] | None = None
    piece: Piece | None = None
    side: Side | None = None

    @model_validator(mode="after")
    def _one_action(self) -> "PlayRequest":
        if self.action is None and (self.piece is None or self.side is None):
            raise ValueError("mande action ([peça, lado], draw ou pass) ou piece + side")
        return self


class PowerRequest(BaseModel):
    """Uso de um poder. ``arg``: ``left``/``right`` (freeze), 0 a 6 (flames),
    uma peça da mão (swap); nos outros poderes não precisa."""

    state: GameState
    power: Power
    arg: str | int | list[int] | None = None


app = FastAPI(
    title="Dominó em Prolog + Elm",
    description="Ponte HTTP/JSON entre a tela em Elm e as regras em SWI-Prolog (via janus).",
    version="1.2.0",
)

# Liberado para o `elm reactor` e servidores de desenvolvimento em outras portas.
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

router = APIRouter()


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


def _player_view(state: GameState) -> dict[str, Any]:
    """O que a tela precisa saber da vez do jogador, tudo vindo do Prolog.

    - ``player_moves``: jogadas ``[peça, lado]`` permitidas agora;
    - ``must_draw`` / ``can_pass``: se precisa comprar ou se pode passar;
    - ``usable_powers``: poderes que dá para usar neste momento;
    - ``revealed``: buchas do computador reveladas pela Sobrecarga.
    """
    data = state.model_dump()
    if _game_over(state) is not None:
        return {"player_moves": [], "must_draw": False, "can_pass": False, "usable_powers": [], "revealed": []}
    moves = [[list(piece), side] for piece, side in prolog.legal_moves("player", data)]
    if not state.table:
        starter, piece = prolog.starter(state.player_hand, state.opponent_hand)
        moves = [[piece, "right"]] if starter == "player" else []
    return {
        "player_moves": moves,
        "must_draw": prolog.must_draw("player", data),
        "can_pass": prolog.can_pass_now("player", data),
        "usable_powers": _usable_powers(state),
        "revealed": prolog.revealed_pieces("opponent", data),
    }


def _usable_powers(state: GameState) -> list[str]:
    """Poderes do jogador que ``can_use/4`` aceita agora (com um argumento de exemplo)."""
    if state.turn != "player":
        return []
    data = state.model_dump()
    sample = {"freeze": "left", "flames": 0, "swap": state.player_hand[0] if state.player_hand else None}
    return [p for p in state.player_powers if prolog.can_use("player", p, sample.get(p), data)]


def _response(state: GameState, event: dict[str, Any]) -> dict[str, Any]:
    over = _game_over(state)
    result = None if over is None else {"winner": over["winner"], "points": over["points"]}
    return {"state": state.model_dump(), "result": result, "event": event, "game_over": over, **_player_view(state)}


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


def _refusal(state: GameState, who: str, piece: list[int], side: str) -> str:
    """Frase para uma jogada que o Prolog recusou.

    Quem recusou foi ``powers:play/5``; aqui só se escolhe a explicação:
    se a peça encaixaria no dominó comum, a culpa é de um efeito ativo.
    """
    encaixaria = prolog.play_piece(piece, side, state.hand(who), state.table) is not None
    if encaixaria:
        if ["curse_due", who] in state.effects:
            return "A Maldição obriga você a comprar mais uma peça antes de jogar."
        if ["freeze", who, side] in state.effects:
            ponta = "esquerda" if side == "left" else "direita"
            return f"Jogada inválida: a ponta {ponta} está congelada neste turno."
        flames = next((e for e in state.effects if e[0] == "flames" and e[1] == who), None)
        if flames is not None:
            return f"Jogada inválida: as Chamas obrigam a jogar uma peça com o número {flames[2]}."
    return "Jogada inválida: a peça não está na mão ou não encaixa nessa ponta."


def _play(state: GameState, who: str, piece: list[int], side: str) -> GameState:
    """Joga a peça pelo Prolog (``powers:play/5``). Erro 400 se a jogada não vale.

    Normalmente a vez passa; com "Manipulação do tempo" pode continuar.
    """
    opening = _opening(state)
    if opening is not None and sorted(piece) != opening:
        raise HTTPException(400, f"A partida abre com a peça {opening}.")
    result = prolog.pw_play(who, piece, side, state.model_dump())
    if result is None:
        raise HTTPException(400, _refusal(state, who, piece, side))
    return GameState.model_validate(result)


def _player_draw(state: GameState) -> dict[str, Any]:
    """O jogador compra uma peça (``powers:draw_one/4``). Só vale quando é obrigado."""
    _check_turn(state, "player")
    data = state.model_dump()
    if not prolog.must_draw("player", data):
        if prolog.legal_moves("player", data):
            raise HTTPException(400, "Você ainda tem peça que encaixa: não precisa comprar.")
        raise HTTPException(400, "O monte acabou: passe a vez.")
    drawn = prolog.pw_draw_one("player", data)
    assert drawn is not None
    new_data, piece = drawn
    return _response(GameState.model_validate(new_data), {"type": "draw", "who": "player", "pieces": [piece]})


def _player_pass(state: GameState) -> dict[str, Any]:
    """O jogador passa a vez (``powers:pass/3``): só sem jogada e com o monte vazio."""
    _check_turn(state, "player")
    data = state.model_dump()
    new_data = prolog.pw_pass("player", data)
    if new_data is None:
        if prolog.legal_moves("player", data):
            raise HTTPException(400, "Você ainda tem peça que encaixa.")
        raise HTTPException(400, "Ainda dá para comprar do monte.")
    return _response(GameState.model_validate(new_data), {"type": "pass", "who": "player"})


POWER_REFUSALS = {
    "freeze": "Escolha a ponta esquerda ou direita.",
    "flames": "Escolha um número de 0 a 6.",
    "swap": "Escolha uma peça da sua mão e confira se ainda há peças no monte.",
    "recovery": "Não há peças no monte para trocar.",
    "teleport": "Você não tem Congelamento nem Chamas para ignorar agora.",
    "time": "Você precisa de pelo menos duas peças na mão.",
}


def _power_refusal(state: GameState, power: str) -> str:
    if power == "shield":
        return "O Escudo é automático: ele protege você sozinho quando o adversário atacar."
    if power not in state.player_powers:
        return f"Você não tem o poder {POWER_NAMES[power]}."
    if not state.table:
        return "Os poderes só podem ser usados depois da primeira peça na mesa."
    if ["used", "player"] in state.effects:
        return "Só dá para usar um poder por turno."
    return POWER_REFUSALS.get(power, f"{POWER_NAMES[power]} não pode ser usado agora.")


# ----------------------------------------------------------------------
# Rotas
# ----------------------------------------------------------------------


@router.get("/health")
def health() -> dict[str, str]:
    """Confere se o Prolog carregou."""
    prolog.next_turn("player")
    return {"status": "ok"}


@router.post("/new-game")
def new_game() -> dict[str, Any]:
    """Partida nova (``new_game/5``). A mesa começa vazia; quem tem a vez abre com ``start_piece``.

    Cada jogador recebe poderes sorteados (``deal_powers/2``).
    """
    g = prolog.new_game()
    mine, theirs = prolog.deal_powers()
    state = GameState(
        player_hand=g["player_hand"],
        opponent_hand=g["opponent_hand"],
        table=[],
        boneyard=g["boneyard"],
        turn=g["turn"],
        player_powers=mine,
        opponent_powers=theirs,
    )
    response = _response(state, {"type": "new_game", "turn": g["turn"], "start_piece": g["start_piece"]})
    response["start_piece"] = g["start_piece"]
    return response


@router.post("/play")
def play(req: PlayRequest) -> dict[str, Any]:
    """Vez do jogador: joga uma peça (``powers:play/5``), compra (``draw``) ou passa (``pass``)."""
    if req.action == "draw":
        return _player_draw(req.state)
    if req.action == "pass":
        return _player_pass(req.state)
    piece, side = (list(req.action[0]), req.action[1]) if req.action else (req.piece, req.side)
    _check_turn(req.state, "player")
    state = _play(req.state, "player", piece, side)
    return _response(state, {"type": "play", "who": "player", "piece": sorted(piece), "side": side})


@router.post("/power")
def power(req: PowerRequest) -> dict[str, Any]:
    """O jogador usa um poder (``powers:use_power/6``). Um por turno, antes de jogar.

    O ``event`` traz ``power.outcome``: ``applied``, ``shielded`` (o Escudo do
    adversário anulou), ``swapped`` (com ``gave`` e ``got``) ou ``revealed``
    (com as buchas do computador).
    """
    state = req.state
    _check_turn(state, "player")
    result = prolog.use_power("player", req.power, req.arg, state.model_dump())
    if result is None:
        raise HTTPException(400, _power_refusal(state, req.power))
    new_data, outcome = result
    info: dict[str, Any] = {"name": req.power, "arg": req.arg, "outcome": outcome[0]}
    if outcome[0] == "swapped":
        info.update(gave=outcome[1], got=outcome[2])
    elif outcome[0] == "revealed":
        info.update(revealed=outcome[1])
    return _response(GameState.model_validate(new_data), {"type": "power", "who": "player", "power": info})


@router.post("/draw")
def draw(req: StateRequest) -> dict[str, Any]:
    """O mesmo que ``/play`` com ``"action": "draw"``."""
    return _player_draw(req.state)


@router.post("/pass")
def pass_turn(req: StateRequest) -> dict[str, Any]:
    """O mesmo que ``/play`` com ``"action": "pass"``."""
    return _player_pass(req.state)


@router.post("/opponent-move")
def opponent_move(req: StateRequest) -> dict[str, Any]:
    """Vez do computador, inteira de uma vez (``powers:computer_turn/4``).

    1. Com a mesa vazia, abre com a peça de saída (``starter/4``).
    2. Pode usar um poder (o ``event`` traz ``power`` se usou).
    3. Se não tem jogada, compra até ter (e a peça extra da Maldição).
    4. Joga a de maior nota ou passa a vez; com "Manipulação do tempo"
       joga duas vezes (``extra`` no ``event``).
    """
    state = req.state
    _check_turn(state, "opponent")

    opening = _opening(state)
    if opening is not None:
        new_state = _play(state, "opponent", opening, "right")
        return _response(new_state, {"type": "play", "who": "opponent", "piece": opening, "side": "right", "drawn": []})

    new_data, events = prolog.computer_turn("opponent", state.model_dump())
    plays = [e for e in events if e[0] == "play"]
    drawn = [piece for e in events if e[0] == "draw" for piece in e[2]]
    used = next((e for e in events if e[0] == "power"), None)

    event: dict[str, Any] = {"type": "play" if plays else "pass", "who": "opponent"}
    if plays:
        event.update(piece=plays[0][2], side=plays[0][3])
    event["drawn"] = drawn
    if used is not None:
        # Só o nome e o resultado: as peças trocadas do computador ficam escondidas.
        event["power"] = {"name": used[2], "arg": None if used[3] == "none" else used[3], "outcome": used[4][0]}
    if len(plays) > 1:
        event["extra"] = {"piece": plays[1][2], "side": plays[1][3]}
    return _response(GameState.model_validate(new_data), event)


@router.post("/hint")
def hint(req: StateRequest) -> dict[str, Any]:
    """Dica para o jogador, no formato do ``hint/4`` (respeitando congelamento e chamas).

    ``{"hint": [[2,4], "right"]}``, ``{"hint": "draw"}`` ou ``{"hint": "pass"}``.
    """
    state = req.state
    _check_turn(state, "player")
    opening = _opening(state)
    if opening is not None:
        return {"hint": [opening, "right"]}
    h = prolog.pw_hint("player", state.model_dump())
    if isinstance(h, tuple):
        return {"hint": [h[0], h[1]]}
    return {"hint": h}


# A tela chama as rotas na raiz (o endereço do backend + "/new-game");
# /api fica como alternativa para quem prefere separar a API dos arquivos.
app.include_router(router)
app.include_router(router, prefix="/api")


# ----------------------------------------------------------------------
# Frontend
# ----------------------------------------------------------------------

# Serve a pasta `frontend/` na raiz, para o jogo e a API ficarem na mesma
# origem: http://localhost:8000/ abre o jogo e /preview.html a vitrine.
# Na imagem Docker a pasta vem da variável FRONTEND_DIR.
FRONTEND_DIR = Path(os.environ.get("FRONTEND_DIR", Path(__file__).resolve().parents[2] / "frontend"))
if FRONTEND_DIR.is_dir():
    app.mount("/", StaticFiles(directory=FRONTEND_DIR, html=True), name="frontend")
