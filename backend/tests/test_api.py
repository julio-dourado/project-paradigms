"""Testes de integração: HTTP -> FastAPI -> janus -> Prolog.

Rodam com o SWI-Prolog de verdade, sem dublês: se passam, as três
camadas conversam direito.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.main import ALL_PIECES, app

client = TestClient(app)


def make_state(player, opponent, table, turn="player", boneyard=None, rest="opponent"):
    """Estado válido com as 28 peças.

    Sem ``boneyard``, o que não está nas mãos nem na mesa vai para o monte.
    Com ``boneyard``, o que sobra vai para a mão indicada em ``rest``.
    """
    used = {tuple(sorted(p)) for p in player + opponent + table}
    if boneyard is None:
        boneyard = [list(p) for p in ALL_PIECES if p not in used]
        used |= {tuple(p) for p in boneyard}
    else:
        used |= {tuple(p) for p in boneyard}
        leftover = [list(p) for p in ALL_PIECES if p not in used]
        if rest == "opponent":
            opponent = opponent + leftover
        else:
            player = player + leftover
    return {
        "player_hand": player,
        "opponent_hand": opponent,
        "table": table,
        "boneyard": boneyard,
        "turn": turn,
    }


def all_pieces_in(state):
    pieces = state["player_hand"] + state["opponent_hand"] + state["table"] + state["boneyard"]
    return sorted(tuple(sorted(p)) for p in pieces)


# ----------------------------------------------------------------------
# Saúde e partida nova
# ----------------------------------------------------------------------


def test_health():
    r = client.get("/api/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_new_game_distribui_as_pecas():
    r = client.post("/api/new-game")
    assert r.status_code == 200
    body = r.json()
    s = body["state"]
    assert len(s["player_hand"]) == 7
    assert len(s["opponent_hand"]) == 7
    assert len(s["boneyard"]) == 14
    assert s["table"] == []
    assert all_pieces_in(s) == ALL_PIECES
    assert body["game_over"] is None


def test_new_game_diz_quem_abre_e_com_qual_peca():
    body = client.post("/api/new-game").json()
    event, s = body["event"], body["state"]
    assert event["type"] == "new_game"
    assert event["turn"] == s["turn"]
    assert event["start_piece"] in s["player_hand" if s["turn"] == "player" else "opponent_hand"]


# ----------------------------------------------------------------------
# Jogada do jogador
# ----------------------------------------------------------------------


def test_play_encaixa_na_direita_e_passa_a_vez():
    s = make_state([[2, 4], [0, 0]], [[1, 1]], [[6, 5], [5, 2]])
    r = client.post("/api/play", json={"state": s, "piece": [2, 4], "side": "right"})
    assert r.status_code == 200
    body = r.json()
    assert body["state"]["table"] == [[6, 5], [5, 2], [2, 4]]
    assert body["state"]["player_hand"] == [[0, 0]]
    assert body["state"]["turn"] == "opponent"
    assert body["event"] == {"type": "play", "who": "player", "piece": [2, 4], "side": "right"}


def test_play_aceita_peca_invertida():
    s = make_state([[2, 4]], [[1, 1]], [[6, 5], [5, 2]])
    r = client.post("/api/play", json={"state": s, "piece": [4, 2], "side": "right"})
    assert r.status_code == 200
    assert r.json()["state"]["table"][-1] == [2, 4]


def test_play_vira_a_peca_na_esquerda():
    s = make_state([[0, 6], [1, 1]], [[3, 3]], [[6, 5], [5, 2]])
    r = client.post("/api/play", json={"state": s, "piece": [0, 6], "side": "left"})
    assert r.json()["state"]["table"] == [[0, 6], [6, 5], [5, 2]]


def test_play_invalida_devolve_422():
    s = make_state([[0, 1], [3, 3]], [[1, 1]], [[6, 5], [5, 2]])
    r = client.post("/api/play", json={"state": s, "piece": [0, 1], "side": "right"})
    assert r.status_code == 422
    assert "inválida" in r.json()["detail"]


def test_play_peca_que_nao_esta_na_mao_devolve_422():
    s = make_state([[0, 1]], [[1, 1]], [[6, 5], [5, 2]])
    r = client.post("/api/play", json={"state": s, "piece": [2, 3], "side": "right"})
    assert r.status_code == 422


def test_play_fora_da_vez_devolve_409():
    s = make_state([[2, 4]], [[1, 1]], [[6, 5], [5, 2]], turn="opponent")
    r = client.post("/api/play", json={"state": s, "piece": [2, 4], "side": "right"})
    assert r.status_code == 409


def test_mesa_vazia_so_aceita_a_peca_de_saida():
    s = make_state([[6, 6], [0, 1]], [[5, 5]], [])
    r = client.post("/api/play", json={"state": s, "piece": [0, 1], "side": "right"})
    assert r.status_code == 422
    r = client.post("/api/play", json={"state": s, "piece": [6, 6], "side": "right"})
    assert r.status_code == 200
    assert r.json()["state"]["table"] == [[6, 6]]


def test_batida_termina_a_partida():
    s = make_state([[2, 4]], [[1, 1], [3, 6]], [[6, 5], [5, 2]])
    body = client.post("/api/play", json={"state": s, "piece": [2, 4], "side": "right"}).json()
    over = body["game_over"]
    assert over["winner"] == "player"
    assert over["reason"] == "domino"
    assert over["points"] == sum(a + b for a, b in body["state"]["opponent_hand"])


def test_partida_terminada_nao_aceita_jogada():
    s = make_state([], [[1, 1]], [[6, 5], [5, 2]], turn="opponent")
    r = client.post("/api/opponent-move", json={"state": s})
    assert r.status_code == 409


# ----------------------------------------------------------------------
# Comprar e passar
# ----------------------------------------------------------------------


def test_draw_compra_uma_peca_do_monte():
    s = make_state([[0, 1]], [[3, 3]], [[6, 5], [5, 2]], boneyard=[[4, 4], [1, 2]])
    r = client.post("/api/draw", json={"state": s})
    assert r.status_code == 200
    body = r.json()
    assert body["state"]["player_hand"] == [[0, 1], [4, 4]]
    assert body["state"]["boneyard"] == [[1, 2]]
    assert body["state"]["turn"] == "player"
    assert body["event"] == {"type": "draw", "who": "player", "pieces": [[4, 4]]}


def test_draw_com_jogada_na_mao_devolve_422():
    s = make_state([[2, 4]], [[3, 3]], [[6, 5], [5, 2]])
    r = client.post("/api/draw", json={"state": s})
    assert r.status_code == 422


def test_draw_com_monte_vazio_devolve_422():
    s = make_state([[0, 1]], [[3, 3]], [[6, 5], [5, 2]], boneyard=[])
    r = client.post("/api/draw", json={"state": s})
    assert r.status_code == 422


def test_pass_sem_jogada_e_sem_monte():
    s = make_state([[0, 1]], [[2, 3]], [[6, 5], [5, 2]], boneyard=[])
    r = client.post("/api/pass", json={"state": s})
    assert r.status_code == 200
    assert r.json()["state"]["turn"] == "opponent"
    assert r.json()["event"] == {"type": "pass", "who": "player"}


@pytest.mark.parametrize(
    "player, boneyard",
    [([[2, 4]], []), ([[0, 1]], [[4, 4]])],
    ids=["tem_jogada", "monte_cheio"],
)
def test_pass_recusado(player, boneyard):
    s = make_state(player, [[3, 3]], [[6, 5], [5, 2]], boneyard=boneyard)
    r = client.post("/api/pass", json={"state": s})
    assert r.status_code == 422


def test_jogada_que_tranca_o_jogo():
    # Depois do [5,6] as duas pontas são 6 e os sete 6 estão na mesa.
    table = [[6, 0], [0, 1], [1, 6], [6, 6], [6, 2], [2, 3], [3, 6], [6, 4], [4, 5]]
    s = make_state([[5, 6], [0, 0]], [[3, 4]], table, boneyard=[])
    body = client.post("/api/play", json={"state": s, "piece": [5, 6], "side": "right"}).json()
    over = body["game_over"]
    assert over["reason"] == "blocked"
    assert over["winner"] == "player"
    assert over["points"] == sum(a + b for a, b in body["state"]["opponent_hand"])


# ----------------------------------------------------------------------
# Computador
# ----------------------------------------------------------------------


def test_opponent_abre_a_mesa_com_a_peca_de_saida():
    s = make_state([[5, 5]], [[6, 6], [0, 1]], [], turn="opponent")
    body = client.post("/api/opponent-move", json={"state": s}).json()
    assert body["state"]["table"] == [[6, 6]]
    assert body["state"]["turn"] == "player"


def test_opponent_joga_a_de_maior_nota():
    # choose_move/3 prefere a bucha [2,2] (2+2+5) à [0,2] (0+2).
    s = make_state([[1, 1]], [[0, 2], [2, 2]], [[6, 5], [5, 2]], turn="opponent")
    body = client.post("/api/opponent-move", json={"state": s}).json()
    assert body["event"]["type"] == "play"
    assert body["event"]["piece"] == [2, 2]
    assert body["state"]["turn"] == "player"


def test_opponent_compra_ate_ter_jogada():
    s = make_state(
        [[1, 1]], [[0, 0]], [[6, 5], [5, 2]], turn="opponent", boneyard=[[3, 4], [2, 3], [1, 2]], rest="player"
    )
    body = client.post("/api/opponent-move", json={"state": s}).json()
    assert body["event"]["drawn"] == [[3, 4], [2, 3]]
    assert body["event"]["piece"] == [2, 3]
    assert body["state"]["boneyard"] == [[1, 2]]


def test_opponent_passa_sem_jogada_e_sem_monte():
    s = make_state([[1, 1]], [[0, 0]], [[6, 5], [5, 2]], turn="opponent", boneyard=[], rest="player")
    body = client.post("/api/opponent-move", json={"state": s}).json()
    assert body["event"]["type"] == "pass"
    assert body["state"]["turn"] == "player"


# ----------------------------------------------------------------------
# Dica
# ----------------------------------------------------------------------


def test_hint_sugere_jogada():
    s = make_state([[0, 6], [2, 4]], [[1, 1]], [[6, 5], [5, 2]])
    hint = client.post("/api/hint", json={"state": s}).json()["hint"]
    assert hint["type"] == "play"
    assert [hint["piece"], hint["side"]] in [[[0, 6], "left"], [[2, 4], "right"]]


def test_hint_sugere_comprar():
    s = make_state([[0, 1]], [[3, 3]], [[6, 5], [5, 2]])
    assert client.post("/api/hint", json={"state": s}).json()["hint"] == {"type": "draw"}


def test_hint_sugere_passar():
    s = make_state([[0, 1]], [[3, 3]], [[6, 5], [5, 2]], boneyard=[])
    assert client.post("/api/hint", json={"state": s}).json()["hint"] == {"type": "pass"}


def test_hint_na_mesa_vazia_e_a_peca_de_saida():
    s = make_state([[6, 6], [0, 1]], [[5, 5]], [])
    hint = client.post("/api/hint", json={"state": s}).json()["hint"]
    assert hint == {"type": "play", "piece": [6, 6], "side": "right"}


# ----------------------------------------------------------------------
# Estado inválido
# ----------------------------------------------------------------------


def test_estado_sem_as_28_pecas_devolve_422():
    s = make_state([[2, 4]], [[1, 1]], [[6, 5], [5, 2]])
    s["boneyard"].pop()
    assert client.post("/api/hint", json={"state": s}).status_code == 422


def test_estado_com_peca_fora_de_ordem_na_mao_devolve_422():
    s = make_state([[2, 4]], [[1, 1]], [[6, 5], [5, 2]])
    s["player_hand"] = [[4, 2]]
    assert client.post("/api/hint", json={"state": s}).status_code == 422


def test_estado_com_mesa_que_nao_encosta_devolve_422():
    s = make_state([[2, 4]], [[1, 1]], [[6, 5], [5, 2]])
    s["table"] = [[5, 6], [5, 2]]
    assert client.post("/api/hint", json={"state": s}).status_code == 422


def test_numero_fora_do_dominio_devolve_422():
    s = make_state([[2, 4]], [[1, 1]], [[6, 5], [5, 2]])
    r = client.post("/api/play", json={"state": s, "piece": [2, 7], "side": "right"})
    assert r.status_code == 422


# ----------------------------------------------------------------------
# Partida inteira
# ----------------------------------------------------------------------


def play_full_game():
    """Joga uma partida inteira seguindo a dica, até alguém ganhar ou trancar."""
    body = client.post("/api/new-game").json()
    for _ in range(200):
        s = body["state"]
        if body["game_over"]:
            return body
        if s["turn"] == "opponent":
            r = client.post("/api/opponent-move", json={"state": s})
        else:
            hint = client.post("/api/hint", json={"state": s}).json()["hint"]
            if hint["type"] == "play":
                r = client.post("/api/play", json={"state": s, "piece": hint["piece"], "side": hint["side"]})
            else:
                r = client.post(f"/api/{hint['type']}", json={"state": s})
        assert r.status_code == 200, r.text
        body = r.json()
        assert all_pieces_in(body["state"]) == ALL_PIECES
    pytest.fail("a partida não terminou")


@pytest.mark.parametrize("rodada", range(10))
def test_partida_completa_termina(rodada):
    over = play_full_game()["game_over"]
    assert over["winner"] in {"player", "opponent", "draw"}
    assert over["reason"] in {"domino", "blocked"}
    assert over["points"] >= 0
