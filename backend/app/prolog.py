"""Ponte entre o Python e as regras do jogo em Prolog.

Cada função daqui chama um predicado do módulo ``domino``
(``backend/prolog/domino.pl``) pelo janus e devolve tipos simples do
Python. Nenhuma regra do dominó é decidida aqui: este arquivo só
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

_lock = threading.Lock()
_loaded = False


def _ensure_loaded() -> None:
    global _loaded
    if not _loaded:
        janus.consult(str(PROLOG_FILE))
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
