"""Testes de integração dos poderes especiais: HTTP -> FastAPI -> janus -> Prolog.

Mesmo estilo de ``test_api.py``: o SWI-Prolog de verdade, sem dublês.
"""

from __future__ import annotations

import random

import pytest
from fastapi.testclient import TestClient

from app.main import ALL_PIECES, app

client = TestClient(app)

ALL_POWERS = {"freeze", "curse", "overload", "shield", "recovery", "teleport", "time", "swap", "flames"}


def make_state(player, opponent, table, boneyard=None, turn="player", pp=(), op=(), effects=()):
    """Estado válido com as 28 peças e poderes. O que sobra vai para o monte."""
    used = {tuple(sorted(p)) for p in player + opponent + table}
    if boneyard is None:
        boneyard = [list(p) for p in ALL_PIECES if p not in used]
    else:
        # o que não foi citado vai para a mão de quem não age no teste, para fechar as 28
        used |= {tuple(p) for p in boneyard}
        leftover = [list(p) for p in ALL_PIECES if p not in used]
        if turn == "player":
            opponent = opponent + leftover
        else:
            player = player + leftover
    return {
        "player_hand": player,
        "opponent_hand": opponent,
        "table": table,
        "boneyard": boneyard,
        "turn": turn,
        "player_powers": list(pp),
        "opponent_powers": list(op),
        "effects": [list(e) for e in effects],
    }


def power(state, name, arg=None):
    return client.post("/api/power", json={"state": state, "power": name, "arg": arg})


def play(state, piece, side):
    return client.post("/api/play", json={"state": state, "piece": piece, "side": side})


# Mesa [6,3] (pontas 6 e 3). Mão do jogador com uma peça para cada lado:
# [2,6] encaixa na esquerda e [3,5] na direita.
def base(**kw):
    kw.setdefault("player", [[2, 6], [3, 5], [1, 1]])
    kw.setdefault("opponent", [[0, 0], [5, 5]])
    kw.setdefault("table", [[6, 3]])
    return make_state(**kw)


# ----------------------------------------------------------------------
# Partida nova e formato da resposta
# ----------------------------------------------------------------------


def test_new_game_sorteia_tres_poderes_diferentes_para_cada_lado():
    for _ in range(10):
        s = client.post("/api/new-game").json()["state"]
        assert len(s["player_powers"]) == 3
        assert len(s["opponent_powers"]) == 3
        todos = s["player_powers"] + s["opponent_powers"]
        assert len(set(todos)) == 6
        assert set(todos) <= ALL_POWERS
        assert s["effects"] == []


def test_new_game_traz_o_que_a_tela_precisa():
    body = client.post("/api/new-game").json()
    for chave in ("player_moves", "must_draw", "can_pass", "usable_powers", "revealed"):
        assert chave in body
    s = body["state"]
    if s["turn"] == "player":
        assert body["player_moves"] == [[body["start_piece"], "right"]]
    else:
        assert body["player_moves"] == []


def test_resposta_traz_jogadas_permitidas_calculadas_pelo_prolog():
    body = power(base(pp=["curse"]), "curse").json()
    moves = {(tuple(piece), side) for piece, side in body["player_moves"]}
    assert moves == {((2, 6), "left"), ((3, 5), "right")}
    assert body["must_draw"] is False and body["can_pass"] is False


def test_estado_de_exemplo_e_valido():
    assert client.post("/api/hint", json={"state": base()}).status_code == 200


# ----------------------------------------------------------------------
# Validação do estado
# ----------------------------------------------------------------------


def test_estado_sem_poderes_continua_valido():
    s = base()
    for k in ("player_powers", "opponent_powers", "effects"):
        s.pop(k)
    assert client.post("/api/hint", json={"state": s}).status_code == 200


def test_poder_repetido_devolve_422():
    s = base(pp=["freeze", "freeze"])
    assert client.post("/api/hint", json={"state": s}).status_code == 422


def test_poder_desconhecido_devolve_422():
    s = base(pp=["fireball"])
    assert client.post("/api/hint", json={"state": s}).status_code == 422


@pytest.mark.parametrize(
    "efeito",
    [["freeze", "player"], ["freeze", "player", "middle"], ["flames", "player", 9], ["nada", "player"], ["curse", "ninguem"]],
)
def test_efeito_malformado_devolve_422(efeito):
    s = base(effects=[efeito])
    assert client.post("/api/hint", json={"state": s}).status_code == 422


# ----------------------------------------------------------------------
# Usar poderes
# ----------------------------------------------------------------------


def test_congelamento_vira_efeito_no_adversario():
    r = power(base(pp=["freeze", "curse"]), "freeze", "left")
    assert r.status_code == 200
    body = r.json()
    assert body["event"] == {
        "type": "power",
        "who": "player",
        "power": {"name": "freeze", "arg": "left", "outcome": "applied"},
    }
    assert ["freeze", "opponent", "left"] in body["state"]["effects"]
    assert ["used", "player"] in body["state"]["effects"]
    assert body["state"]["player_powers"] == ["curse"]
    assert body["state"]["turn"] == "player"  # usar poder não gasta a vez


def test_so_um_poder_por_turno():
    r = power(base(pp=["freeze", "curse"]), "freeze", "left")
    r2 = power(r.json()["state"], "curse")
    assert r2.status_code == 400
    assert "um poder por turno" in r2.json()["detail"]


def test_poder_que_nao_tem_devolve_400():
    r = power(base(pp=["curse"]), "freeze", "left")
    assert r.status_code == 400
    assert "Congelamento" in r.json()["detail"]


def test_escudo_nao_e_ativavel():
    r = power(base(pp=["shield"]), "shield")
    assert r.status_code == 400
    assert "automático" in r.json()["detail"]


def test_congelamento_sem_peca_na_mesa_devolve_400():
    s = make_state([[6, 6], [1, 1]], [[5, 5]], [], pp=["freeze"])
    r = power(s, "freeze", "left")
    assert r.status_code == 400


def test_poder_fora_da_vez_devolve_409():
    r = power(base(pp=["curse"], turn="opponent"), "curse")
    assert r.status_code == 409


def test_chamas_com_numero_fora_de_0_a_6_devolve_400():
    assert power(base(pp=["flames"]), "flames", 7).status_code == 400


def test_escudo_do_adversario_anula_o_ataque():
    r = power(base(pp=["freeze"], op=["shield", "time"]), "freeze", "left")
    body = r.json()
    assert r.status_code == 200
    assert body["event"]["power"]["outcome"] == "shielded"
    assert not any(e[0] == "freeze" for e in body["state"]["effects"])
    assert body["state"]["player_powers"] == []
    assert body["state"]["opponent_powers"] == ["time"]


def test_sobrecarga_revela_as_buchas_do_computador():
    s = base(opponent=[[0, 0], [5, 5], [1, 2]], pp=["overload"])
    body = power(s, "overload").json()
    assert body["event"]["power"]["outcome"] == "revealed"
    assert sorted(body["event"]["power"]["revealed"]) == [[0, 0], [5, 5]]
    assert sorted(body["revealed"]) == [[0, 0], [5, 5]]


def test_troca_devolve_o_que_saiu_e_o_que_entrou():
    s = base(pp=["swap"], boneyard=[[0, 1], [2, 5]])
    r = power(s, "swap", [1, 1])
    assert r.status_code == 200
    ev = r.json()["event"]["power"]
    assert ev["outcome"] == "swapped" and ev["gave"] == [1, 1]
    novo = r.json()["state"]
    assert [1, 1] not in novo["player_hand"] and ev["got"] in novo["player_hand"]
    assert [1, 1] in novo["boneyard"]
    assert len(novo["boneyard"]) == len(s["boneyard"])


def test_troca_de_peca_que_nao_esta_na_mao_devolve_400():
    s = base(pp=["swap"], boneyard=[[0, 1], [2, 5]])
    assert power(s, "swap", [4, 4]).status_code == 400


def test_recuperacao_troca_a_peca_mais_pesada():
    s = base(player=[[1, 2], [5, 6], [0, 3]], pp=["recovery"], boneyard=[[2, 2], [1, 1]])
    ev = power(s, "recovery").json()["event"]["power"]
    assert ev["outcome"] == "swapped" and ev["gave"] == [5, 6]


def test_recuperacao_sem_monte_devolve_400():
    s = base(pp=["recovery"], boneyard=[])
    assert power(s, "recovery").status_code == 400


def test_usable_powers_lista_so_o_que_da_para_usar():
    # sem jogada, o jogador compra; o teletransporte não serve (nenhuma restrição)
    s = maldito(pp=["teleport", "curse"])
    body = client.post("/api/draw", json={"state": s}).json()
    assert body["usable_powers"] == ["curse"]


def test_poderes_so_depois_da_primeira_peca():
    # regressão: Troca/Recuperação antes da abertura mandavam a peça de saída para o monte
    for _ in range(10):
        body = client.post("/api/new-game").json()
        s = body["state"]
        assert body["usable_powers"] == []
        for nome in s["player_powers"]:
            if s["turn"] == "player" and nome != "shield":  # o escudo tem aviso próprio
                r = power(s, nome, "left")
                assert r.status_code == 400
                assert "primeira peça" in r.json()["detail"]


def test_usable_powers_no_new_game_e_subconjunto_dos_poderes_do_jogador():
    for _ in range(10):
        body = client.post("/api/new-game").json()
        assert set(body["usable_powers"]) <= set(body["state"]["player_powers"])
        if body["state"]["turn"] != "player":
            assert body["usable_powers"] == []


# ----------------------------------------------------------------------
# Efeitos sobre as jogadas do jogador
# ----------------------------------------------------------------------


def test_ponta_congelada_recusa_com_explicacao():
    s = base(effects=[["freeze", "player", "left"]])
    r = play(s, [2, 6], "left")
    assert r.status_code == 400
    assert "congelada" in r.json()["detail"]


def test_player_moves_respeita_congelamento():
    s = base(player=[[2, 6], [1, 1]], pp=["curse"], boneyard=[[0, 1]], effects=[["freeze", "player", "left"]])
    body = power(s, "curse").json()
    assert body["player_moves"] == []
    assert body["must_draw"] is True


def test_chamas_obrigam_o_numero_quando_possivel():
    s = base(effects=[["flames", "player", 2]])
    r = play(s, [3, 5], "right")
    assert r.status_code == 400
    assert "Chamas" in r.json()["detail"] and "2" in r.json()["detail"]
    assert play(s, [2, 6], "left").status_code == 200


def test_chamas_sem_peca_com_o_numero_nao_restringe():
    s = base(effects=[["flames", "player", 4]])
    assert play(s, [3, 5], "right").status_code == 200


def test_efeitos_do_jogador_somem_quando_a_vez_passa():
    s = base(effects=[["flames", "player", 2], ["freeze", "opponent", "right"]])
    novo = play(s, [2, 6], "left").json()["state"]
    assert novo["turn"] == "opponent"
    assert novo["effects"] == [["freeze", "opponent", "right"]]


def test_teletransporte_remove_as_restricoes():
    s = base(pp=["teleport"], effects=[["freeze", "player", "left"], ["flames", "player", 2]])
    body = power(s, "teleport").json()
    assert body["state"]["effects"] == [["used", "player"]]
    assert {tuple(m[0]) for m in body["player_moves"]} >= {(2, 6), (3, 5)}


def test_teletransporte_sem_restricao_devolve_400():
    r = power(base(pp=["teleport"]), "teleport")
    assert r.status_code == 400
    assert "ignorar" in r.json()["detail"]


def test_tempo_permite_duas_jogadas_seguidas():
    # depois do [2,6] na esquerda as pontas são 2 e 3, e o [2,2] ainda encaixa
    s = base(player=[[2, 6], [2, 2], [1, 1]], pp=["time"])
    s2 = power(s, "time").json()["state"]
    r = play(s2, [2, 6], "left").json()
    assert r["state"]["turn"] == "player"
    assert r["player_moves"] != []
    r2 = play(r["state"], [2, 2], "left").json()
    assert r2["state"]["turn"] == "opponent"
    assert ["time", "player"] not in r2["state"]["effects"]


def test_tempo_sem_segunda_jogada_passa_a_vez():
    s = base(player=[[2, 6], [1, 1]], pp=["time"])
    s2 = power(s, "time").json()["state"]
    assert play(s2, [2, 6], "left").json()["state"]["turn"] == "opponent"


# ----------------------------------------------------------------------
# Maldição, compra e passar
# ----------------------------------------------------------------------


def maldito(**kw):
    # mesa [[6,6]]; a mão [1,2] não encaixa; o monte tem [3,4] (não), [0,6] (sim), [2,5] (não)
    return make_state([[1, 2]], [[0, 0]], [[6, 6]], boneyard=[[3, 4], [0, 6], [2, 5]], **kw)


def test_maldicao_obriga_uma_compra_extra():
    s = maldito(effects=[["curse", "player"]])
    r1 = client.post("/api/draw", json={"state": s}).json()
    assert r1["event"]["pieces"] == [[3, 4]] and r1["must_draw"] is True
    r2 = client.post("/api/draw", json={"state": r1["state"]}).json()
    assert r2["event"]["pieces"] == [[0, 6]]
    # já tem jogada, mas a Maldição obriga mais uma compra
    assert r2["must_draw"] is True
    assert play(r2["state"], [0, 6], "right").status_code == 400
    assert "Maldição" in play(r2["state"], [0, 6], "right").json()["detail"]
    r3 = client.post("/api/draw", json={"state": r2["state"]}).json()
    assert r3["event"]["pieces"] == [[2, 5]]
    assert r3["must_draw"] is False
    assert play(r3["state"], [0, 6], "right").status_code == 200


def test_sem_maldicao_compra_so_ate_ter_jogada():
    r1 = client.post("/api/draw", json={"state": maldito()}).json()
    r2 = client.post("/api/draw", json={"state": r1["state"]}).json()
    assert r2["must_draw"] is False
    assert client.post("/api/draw", json={"state": r2["state"]}).status_code == 400


def test_comprar_com_jogada_na_mao_devolve_400_mesmo_com_poderes():
    r = client.post("/api/draw", json={"state": base(pp=["time"])})
    assert r.status_code == 400
    assert "ainda tem peça" in r.json()["detail"]


def test_passar_preso_pela_ponta_congelada_com_monte_vazio():
    s = make_state([[2, 6]], [[0, 0]], [[6, 3]], boneyard=[], effects=[["freeze", "player", "left"]])
    r = client.post("/api/pass", json={"state": s})
    assert r.status_code == 200
    assert r.json()["state"]["turn"] == "opponent"


# ----------------------------------------------------------------------
# Computador e dica
# ----------------------------------------------------------------------


def test_computador_usa_teletransporte_quando_esta_preso():
    s = make_state(
        [[0, 0]], [[2, 6]], [[6, 3]], boneyard=[[1, 1]], turn="opponent",
        op=["teleport"], effects=[["freeze", "opponent", "left"]],
    )
    ev = client.post("/api/opponent-move", json={"state": s}).json()["event"]
    assert ev["power"] == {"name": "teleport", "arg": None, "outcome": "applied"}


def test_computador_nao_joga_na_ponta_congelada():
    s = make_state([[0, 0]], [[2, 6]], [[6, 3]], boneyard=[], turn="opponent",
                   effects=[["freeze", "opponent", "left"]])
    body = client.post("/api/opponent-move", json={"state": s}).json()
    assert body["event"]["type"] == "pass"
    assert body["state"]["turn"] == "player"


def test_computador_compra_a_peca_extra_da_maldicao():
    s = make_state([[0, 0]], [[1, 2]], [[6, 6]], boneyard=[[3, 4], [0, 6], [2, 5]], turn="opponent",
                   effects=[["curse", "opponent"]])
    body = client.post("/api/opponent-move", json={"state": s}).json()
    assert body["event"]["drawn"] == [[3, 4], [0, 6], [2, 5]]
    assert body["event"]["type"] == "play"


def test_computador_com_tempo_joga_duas_pecas():
    s = make_state([[0, 0]], [[2, 6], [3, 5], [2, 2]], [[6, 3]], boneyard=[], turn="opponent", op=["time"])
    body = client.post("/api/opponent-move", json={"state": s}).json()
    assert body["event"]["power"]["name"] == "time"
    assert "extra" in body["event"]
    assert body["state"]["turn"] == "player"


def test_evento_do_computador_nao_vaza_pecas_trocadas():
    # sem jogada e com monte: o computador usa Recuperação em vez de comprar
    s = make_state([[0, 0]], [[1, 2], [5, 6]], [[3, 3]], boneyard=[[2, 3], [0, 4]], turn="opponent", op=["recovery"])
    ev = client.post("/api/opponent-move", json={"state": s}).json()["event"]
    assert ev["power"]["name"] == "recovery"
    assert set(ev["power"]) == {"name", "arg", "outcome"}


def test_dica_respeita_o_congelamento():
    s = base(player=[[2, 6]], effects=[["freeze", "player", "left"]], boneyard=[])
    assert client.post("/api/hint", json={"state": s}).json() == {"hint": "pass"}


def test_dica_manda_comprar_com_maldicao_pendente():
    s = make_state([[1, 6]], [[0, 0]], [[6, 6]], boneyard=[[3, 4]], effects=[["curse_due", "player"]])
    assert client.post("/api/hint", json={"state": s}).json() == {"hint": "draw"}


# ----------------------------------------------------------------------
# Partidas inteiras pela API
# ----------------------------------------------------------------------


def jogar_partida_com_poderes(rng: random.Random):
    """Jogador automático: usa poder quando dá (ao acaso), segue a dica; computador pela API."""
    body = client.post("/api/new-game").json()
    state = body["state"]
    usados = []
    for _ in range(600):
        if body["game_over"] is not None:
            return body, usados
        if state["turn"] == "opponent":
            body = client.post("/api/opponent-move", json={"state": state}).json()
        else:
            usable = body["usable_powers"]
            if usable and rng.random() < 0.6:
                nome = rng.choice(usable)
                arg = {"freeze": rng.choice(["left", "right"]), "flames": rng.randint(0, 6),
                       "swap": state["player_hand"][0]}.get(nome)
                r = power(state, nome, arg)
                assert r.status_code == 200, (nome, arg, r.text)
                usados.append(nome)
                body = r.json()
                state = body["state"]
            h = client.post("/api/hint", json={"state": state}).json()["hint"]
            if h == "draw":
                r = client.post("/api/draw", json={"state": state})
            elif h == "pass":
                r = client.post("/api/pass", json={"state": state})
            else:
                r = play(state, h[0], h[1])
            assert r.status_code == 200, r.text
            body = r.json()
        state = body["state"]
        todas = state["player_hand"] + state["opponent_hand"] + state["table"] + state["boneyard"]
        assert sorted(tuple(sorted(p)) for p in todas) == ALL_PIECES
    pytest.fail("a partida com poderes não terminou")


@pytest.mark.parametrize("rodada", range(8))
def test_partida_completa_com_poderes_termina(rodada):
    body, usados = jogar_partida_com_poderes(random.Random(rodada))
    assert body["game_over"]["winner"] in ("player", "opponent", "draw")
    assert body["result"] is not None


def test_poderes_sao_usados_nas_partidas_completas():
    todos = []
    for rodada in range(8):
        _, usados = jogar_partida_com_poderes(random.Random(100 + rodada))
        todos += usados
    assert todos, "nenhum poder foi usado em 8 partidas"
