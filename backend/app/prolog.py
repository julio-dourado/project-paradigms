"""Ponte entre o Python e as regras do jogo em Prolog.

Cada função daqui chama um predicado do módulo ``domino``
(``backend/prolog/domino.pl``) ou do módulo ``powers``
(``backend/prolog/powers.pl``, os poderes especiais) pelo janus e devolve
tipos simples do Python. Nenhuma regra do dominó é decidida aqui: este arquivo só
traduz os dados de um lado para o outro.

Sobre a conversão do janus:

- listas e números passam direto (``[3, 5]`` vira ``[3,5]``);
- átomos que voltam do Prolog chegam como ``str`` (``right``);
- ``str`` do Python vira *string* no Prolog, não átomo. Por isso os
  lados (``left``/``right``) entram com ``atom_string/2`` na própria
  consulta.

O SWI-Prolog é carregado uma vez por processo. Um ``Lock`` deixa só uma
consulta rodar por vez, porque o FastAPI atende as rotas em várias
threads.
"""

from __future__ import annotations

import threading
from pathlib import Path
from typing import Any

import janus_swi as janus

Piece = list[int]
Hand = list[Piece]

PROLOG_FILE = Path(__file__).resolve().parent.parent / "prolog" / "domino.pl"
POWERS_FILE = PROLOG_FILE.with_name("powers.pl")

_lock = threading.Lock()
_loaded = False


def _ensure_loaded() -> None:
    global _loaded
    if not _loaded:
        janus.consult(str(PROLOG_FILE))
        janus.consult(str(POWERS_FILE))
        _loaded = True


def _once(goal: str, **inputs: Any) -> dict[str, Any] | None:
    """Roda ``goal`` uma vez. Devolve as variáveis ligadas ou ``None`` se falhar."""
    with _lock:
        _ensure_loaded()
        result = janus.query_once(goal, inputs)
    if not result.pop("truth"):
        return None
    return result


def _holds(goal: str, **inputs: Any) -> bool:
    return _once(goal, **inputs) is not None


# ----------------------------------------------------------------------
# Preparação
# ----------------------------------------------------------------------


def new_game() -> dict[str, Any]:
    """``new_game/5``: mãos, monte, quem começa e com qual peça."""
    r = _once("domino:new_game(Player, Opponent, Boneyard, Turn, Start)")
    assert r is not None, "new_game/5 não deveria falhar"
    return {
        "player_hand": r["Player"],
        "opponent_hand": r["Opponent"],
        "boneyard": r["Boneyard"],
        "turn": r["Turn"],
        "start_piece": r["Start"],
    }


def starter(player: Hand, opponent: Hand) -> tuple[str, Piece]:
    """``starter/4``: quem abre a mesa e com qual peça."""
    r = _once("domino:starter(P, O, Turn, Piece)", P=player, O=opponent)
    assert r is not None, "starter/4 não deveria falhar com mãos cheias"
    return r["Turn"], r["Piece"]


# ----------------------------------------------------------------------
# Jogadas
# ----------------------------------------------------------------------


def play_piece(piece: Piece, side: str, hand: Hand, table: Hand) -> tuple[Hand, Hand] | None:
    """``play_piece/6``. ``None`` se a jogada for inválida."""
    r = _once(
        "atom_string(Side, SideS), domino:play_piece(Piece, Side, Hand, Table, NewHand, NewTable)",
        Piece=piece,
        SideS=side,
        Hand=hand,
        Table=table,
    )
    if r is None:
        return None
    return r["NewHand"], r["NewTable"]


def playable_pieces(hand: Hand, table: Hand) -> Hand:
    """``playable_pieces/3``."""
    r = _once("domino:playable_pieces(Hand, Table, Pieces)", Hand=hand, Table=table)
    assert r is not None
    return r["Pieces"]


def draw(boneyard: Hand, hand: Hand) -> tuple[Hand, Hand] | None:
    """``draw/4``. ``None`` com o monte vazio. Devolve ``(novo_monte, nova_mao)``."""
    r = _once("domino:draw(B, H, NB, NH)", B=boneyard, H=hand)
    if r is None:
        return None
    return r["NB"], r["NH"]


def draw_until_playable(hand: Hand, table: Hand, boneyard: Hand) -> tuple[Hand, Hand, Hand]:
    """``draw_until_playable/6``. Devolve ``(nova_mao, novo_monte, compradas)``."""
    r = _once(
        "domino:draw_until_playable(H, T, B, NH, NB, Drawn)",
        H=hand,
        T=table,
        B=boneyard,
    )
    assert r is not None
    return r["NH"], r["NB"], r["Drawn"]


def can_pass(hand: Hand, table: Hand, boneyard: Hand) -> bool:
    """``can_pass/3``."""
    return _holds("domino:can_pass(H, T, B)", H=hand, T=table, B=boneyard)


def next_turn(turn: str) -> str:
    """``next_turn/2``."""
    r = _once("atom_string(T, TS), domino:next_turn(T, Next)", TS=turn)
    assert r is not None
    return r["Next"]


# ----------------------------------------------------------------------
# Fim de jogo, adversário e dica
# ----------------------------------------------------------------------


def game_over(player: Hand, opponent: Hand, table: Hand, boneyard: Hand) -> tuple[str, int] | None:
    """``game_over/6``. ``None`` enquanto há jogo; senão ``(vencedor, pontos)``."""
    r = _once(
        "domino:game_over(P, O, T, B, Winner, Points)",
        P=player,
        O=opponent,
        T=table,
        B=boneyard,
    )
    if r is None:
        return None
    return r["Winner"], r["Points"]


def choose_move(hand: Hand, table: Hand) -> tuple[Piece, str] | None:
    """``choose_move/3``. ``None`` se não houver jogada."""
    r = _once("domino:choose_move(H, T, [Piece, Side])", H=hand, T=table)
    if r is None:
        return None
    return r["Piece"], r["Side"]


def hint(hand: Hand, table: Hand, boneyard: Hand) -> tuple[Piece, str] | str:
    """``hint/4``: ``(peça, lado)``, ``"draw"`` ou ``"pass"``."""
    r = _once("domino:hint(H, T, B, Hint)", H=hand, T=table, B=boneyard)
    assert r is not None, "hint/4 sempre tem resposta"
    h = r["Hint"]
    if isinstance(h, list):
        return h[0], h[1]
    return h


# ----------------------------------------------------------------------
# Poderes especiais (módulo ``powers``)
# ----------------------------------------------------------------------
#
# O módulo ``powers`` trabalha com o estado como uma lista de 8 itens
# (o janus só passa listas, números e átomos). ``_pack`` monta essa
# lista a partir do dicionário da API e ``_unpack`` faz o caminho
# contrário. Strings que chegam do navegador (``"left"``, ``"freeze"``)
# viram átomos em ``powers:atomize/2``.

State = dict[str, Any]

_STATE_KEYS = (
    "player_hand",
    "opponent_hand",
    "table",
    "boneyard",
    "player_powers",
    "opponent_powers",
    "effects",
    "turn",
)


def _pack(state: State) -> list[Any]:
    return [state[k] for k in _STATE_KEYS]


def _unpack(packed: list[Any]) -> State:
    return dict(zip(_STATE_KEYS, packed))


def _arg(arg: Any) -> Any:
    return "none" if arg is None else arg


_LOAD = "powers:atomize(SJ, S0), atom_string(Who, WhoS), "


def deal_powers() -> tuple[list[str], list[str]]:
    """``deal_powers/2``: poderes sorteados para o jogador e para o computador."""
    r = _once("powers:deal_powers(Mine, Theirs)")
    assert r is not None, "deal_powers/2 não deveria falhar"
    return r["Mine"], r["Theirs"]


def legal_moves(who: str, state: State) -> list[tuple[Piece, str]]:
    """``legal_moves/3``: jogadas ``(peça, lado)`` permitidas, com congelamento e chamas."""
    r = _once(_LOAD + "powers:legal_moves(Who, S0, Moves)", SJ=_pack(state), WhoS=who)
    assert r is not None
    return [(m[0], m[1]) for m in r["Moves"]]


def must_draw(who: str, state: State) -> bool:
    """``must_draw/2``: sem jogada (ou com a maldição) e ainda com monte."""
    return _holds(_LOAD + "powers:must_draw(Who, S0)", SJ=_pack(state), WhoS=who)


def can_pass_now(who: str, state: State) -> bool:
    """``can_pass_now/2``."""
    return _holds(_LOAD + "powers:can_pass_now(Who, S0)", SJ=_pack(state), WhoS=who)


def pw_play(who: str, piece: Piece, side: str, state: State) -> State | None:
    """``powers:play/5``. ``None`` se não for a vez, se deve comprar ou se a jogada não vale."""
    r = _once(
        _LOAD + "atom_string(Side, SideS), powers:play(Who, Piece, Side, S0, S)",
        SJ=_pack(state),
        WhoS=who,
        Piece=piece,
        SideS=side,
    )
    return None if r is None else _unpack(r["S"])


def pw_draw_one(who: str, state: State) -> tuple[State, Piece] | None:
    """``powers:draw_one/4``. ``None`` se não for obrigado a comprar."""
    r = _once(_LOAD + "powers:draw_one(Who, S0, S, Piece)", SJ=_pack(state), WhoS=who)
    return None if r is None else (_unpack(r["S"]), r["Piece"])


def pw_pass(who: str, state: State) -> State | None:
    """``powers:pass/3``."""
    r = _once(_LOAD + "powers:pass(Who, S0, S)", SJ=_pack(state), WhoS=who)
    return None if r is None else _unpack(r["S"])


def can_use(who: str, power: str, arg: Any, state: State) -> bool:
    """``powers:can_use/4``."""
    return _holds(
        _LOAD + "atom_string(Power, PowerS), powers:atomize(ArgJ, Arg), powers:can_use(Who, Power, Arg, S0)",
        SJ=_pack(state),
        WhoS=who,
        PowerS=power,
        ArgJ=_arg(arg),
    )


def use_power(who: str, power: str, arg: Any, state: State) -> tuple[State, list[Any]] | None:
    """``powers:use_power/6``. Devolve ``(estado, outcome)``; ``None`` se não puder usar.

    ``outcome``: ``["applied"]``, ``["shielded"]``, ``["revealed", buchas]``
    ou ``["swapped", saiu, entrou]``.
    """
    r = _once(
        _LOAD + "atom_string(Power, PowerS), powers:atomize(ArgJ, Arg), powers:use_power(Who, Power, Arg, S0, S, Out)",
        SJ=_pack(state),
        WhoS=who,
        PowerS=power,
        ArgJ=_arg(arg),
    )
    return None if r is None else (_unpack(r["S"]), r["Out"])


def revealed_pieces(who: str, state: State) -> list[Piece]:
    """``revealed_pieces/3``: buchas de ``who`` que a Sobrecarga revelou."""
    r = _once(_LOAD + "powers:revealed_pieces(Who, S0, Pieces)", SJ=_pack(state), WhoS=who)
    assert r is not None
    return r["Pieces"]


def pw_hint(who: str, state: State) -> tuple[Piece, str] | str:
    """``hint_for/3``: ``(peça, lado)``, ``"draw"`` ou ``"pass"``, respeitando as restrições."""
    r = _once(_LOAD + "powers:hint_for(Who, S0, Hint)", SJ=_pack(state), WhoS=who)
    assert r is not None, "hint_for/3 sempre tem resposta"
    h = r["Hint"]
    return (h[0], h[1]) if isinstance(h, list) else h


def computer_turn(who: str, state: State) -> tuple[State, list[list[Any]]]:
    """``computer_turn/4``: o turno inteiro do computador e o que aconteceu nele.

    Eventos: ``["power", who, poder, arg, outcome]``, ``["draw", who, peças]``,
    ``["play", who, peça, lado]`` e ``["pass", who]``.
    """
    r = _once(_LOAD + "powers:computer_turn(Who, S0, S, Events)", SJ=_pack(state), WhoS=who)
    assert r is not None, "computer_turn/4 não deveria falhar na vez do computador"
    return _unpack(r["S"]), r["Events"]
