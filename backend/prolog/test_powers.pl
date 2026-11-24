:- encoding(utf8).
:- use_module(domino).
:- use_module(powers).
:- use_module(library(plunit)).
:- use_module(library(lists)).

% Monta um estado: st(Player, Opponent, Table, Boneyard, PP, OP, Effects, Turn, S).
st(P, O, T, B, PP, OP, E, Turn, [P, O, T, B, PP, OP, E, Turn]).

effects_of(S, E) :- nth1(7, S, E).
turn_of(S, T)    :- nth1(8, S, T).
hand_of(player, S, H)   :- nth1(1, S, H).
hand_of(opponent, S, H) :- nth1(2, S, H).
table_of(S, T)   :- nth1(3, S, T).
yard_of(S, B)    :- nth1(4, S, B).
powers_of_(player, S, P)   :- nth1(5, S, P).
powers_of_(opponent, S, P) :- nth1(6, S, P).

all_in_state(S, Pieces) :-
    nth1(1, S, P), nth1(2, S, O), nth1(3, S, T), nth1(4, S, B),
    findall(Q, ( member(L, [P,O,B]), member(Q, L) ), Loose),
    findall(N, ( member([A,Bp], T), msort([A,Bp], N) ), TableNorm),
    append(Loose, TableNorm, Pieces).

:- begin_tests(catalogo).

test(nove_poderes) :-
    all_powers(Ps), length(Ps, 9).

test(todo_poder_tem_tipo) :-
    all_powers(Ps),
    forall(member(P, Ps), power_kind(P, _)).

test(sorteio_tamanho_e_sem_repeticao) :-
    deal_powers(A, B),
    powers_per_player(N),
    length(A, N), length(B, N),
    append(A, B, All),
    sort(All, Sorted),
    length(Sorted, Len),
    Len =:= 2 * N.

test(sorteio_so_poderes_validos) :-
    all_powers(Todos),
    deal_powers(A, B),
    forall(member(P, A), memberchk(P, Todos)),
    forall(member(P, B), memberchk(P, Todos)).

test(estado_inicial) :-
    initial_state([[0,1]], [[2,3]], [[4,5]], player, S),
    length(S, 8),
    table_of(S, []),
    effects_of(S, []),
    turn_of(S, player).

test(atomize_converte_strings_em_qualquer_nivel) :-
    atomize([["left", 3], "draw", [[1,2], "right"]], R),
    R == [[left, 3], draw, [[1,2], right]].

:- end_tests(catalogo).


:- begin_tests(restricoes).

test(sem_efeitos_igual_ao_domino) :-
    st([[2,6],[1,1]], [], [[6,3]], [], [], [], [], player, S),
    legal_moves(player, S, M),
    domino:valid_moves([[2,6],[1,1]], [[6,3]], M).

test(congelamento_tira_a_ponta) :-
    % pontas 6 e 3; [3,6] encaixa nas duas, [2,6] só na esquerda
    st([[3,6],[2,6]], [], [[6,3]], [], [], [], [[freeze,player,left]], player, S),
    legal_moves(player, S, M),
    M == [[[3,6],right]].

test(congelamento_do_outro_nao_afeta) :-
    st([[3,6]], [], [[6,3]], [], [], [], [[freeze,opponent,left]], player, S),
    legal_moves(player, S, M),
    length(M, 2).

test(chamas_restringe_quando_da) :-
    st([[3,6],[2,6]], [], [[6,3]], [], [], [], [[flames,player,2]], player, S),
    legal_moves(player, S, M),
    M == [[[2,6],left]].

test(chamas_ignorada_se_impossivel) :-
    st([[3,6],[2,6]], [], [[6,3]], [], [], [], [[flames,player,5]], player, S),
    legal_moves(player, S, M),
    length(M, 3).

test(congelamento_e_chamas_juntos) :-
    st([[3,6],[2,6]], [], [[6,3]], [], [], [],
       [[freeze,player,left],[flames,player,2]], player, S),
    legal_moves(player, S, M),
    % [2,6] só encaixa na esquerda (congelada): sobra [3,6]/right,
    % e as chamas (2) não se aplicam a ele, então vale
    M == [[[3,6],right]].

test(jogar_ponta_congelada_falha, [fail]) :-
    st([[3,6]], [[0,0]], [[6,3]], [], [], [], [[freeze,player,left]], player, S),
    play(player, [3,6], left, S, _).

test(jogar_ponta_livre_funciona) :-
    % esquerda congelada, mas a direita (ponta 3) aceita o [3,6]
    st([[3,6]], [[0,0]], [[6,3]], [], [], [], [[freeze,player,left]], player, S),
    play(player, [3,6], right, S, S1),
    table_of(S1, [[6,3],[3,6]]).

test(jogar_fora_da_vez_falha, [fail]) :-
    st([[3,6]], [[0,0]], [[6,3]], [], [], [], [], opponent, S),
    play(player, [3,6], left, S, _).

test(jogar_tira_da_mao_e_passa_a_vez) :-
    st([[3,6],[1,1]], [[0,0]], [[6,3]], [], [], [], [], player, S),
    play(player, [3,6], left, S, S1),
    hand_of(player, S1, [[1,1]]),
    table_of(S1, [[3,6],[6,3]]),
    turn_of(S1, opponent).

test(fim_do_turno_remove_efeitos_de_quem_jogou) :-
    st([[3,6],[1,1]], [[0,0]], [[6,3]], [],
       [], [],
       [[freeze,player,right],[freeze,opponent,left],[flames,player,1]],
       player, S),
    play(player, [3,6], left, S, S1),
    effects_of(S1, E),
    E == [[freeze,opponent,left]].

test(passar_so_sem_jogada_e_sem_monte) :-
    st([[1,1]], [[0,0]], [[6,3]], [], [], [], [], player, S),
    pass(player, S, S1),
    turn_of(S1, opponent).

test(nao_passa_com_monte, [fail]) :-
    st([[1,1]], [[0,0]], [[6,3]], [[2,2]], [], [], [], player, S),
    pass(player, S, _).

test(nao_passa_com_jogada, [fail]) :-
    st([[3,3]], [[0,0]], [[6,3]], [], [], [], [], player, S),
    pass(player, S, _).

test(congelado_sem_alternativa_pode_passar) :-
    % só a ponta esquerda serve e está congelada, monte vazio
    st([[6,6]], [[0,0]], [[6,3]], [], [], [], [[freeze,player,left],[freeze,player,right]],
       player, S),
    pass(player, S, S1),
    turn_of(S1, opponent).

:- end_tests(restricoes).


:- begin_tests(maldicao).

% O oponente (mão [0,0]) fica sem jogada na mesa onde só há 1 e 6; só para o
% teste, devolvemos a vez ao jogador sem mexer nos efeitos.
pass_turn_back(S0, S) :-
    nth1(8, S0, opponent),
    S0 = [P, O, T, B, PP, OP, E, _],
    S  = [P, O, T, B, PP, OP, E, player].

% mesa [[6,6]] (pontas 6 e 6); mão [1,2] não encaixa
cursed(Effects, S) :-
    st([[1,2]], [[0,0]], [[6,6]], [[3,4],[0,6],[2,5],[1,1]],
       [], [], Effects, player, S).

test(sem_maldicao_para_ao_achar_jogada) :-
    cursed([], S),
    must_draw(player, S),
    draw_one(player, S, S1, P1), P1 == [3,4],
    must_draw(player, S1),
    draw_one(player, S1, S2, P2), P2 == [0,6],
    \+ must_draw(player, S2).

test(maldicao_obriga_uma_compra_extra) :-
    cursed([[curse,player]], S),
    draw_one(player, S, S1, _),          % [3,4], sem jogada
    draw_one(player, S1, S2, _),         % [0,6], agora joga
    must_draw(player, S2),               % mas deve comprar mais uma
    draw_one(player, S2, S3, P3), P3 == [2,5],
    \+ must_draw(player, S3),
    effects_of(S3, E),
    \+ memberchk([curse_due,player], E),
    \+ memberchk([curse,player], E).

test(maldicao_nao_faz_nada_se_ja_tem_jogada) :-
    st([[1,6]], [[0,0]], [[6,6]], [[3,4]], [], [], [[curse,player]], player, S),
    \+ must_draw(player, S).

test(maldicao_sem_monte_nao_compra_extra) :-
    st([[1,2]], [[0,0]], [[6,6]], [[0,6]], [], [], [[curse,player]], player, S),
    draw_one(player, S, S1, _),
    \+ must_draw(player, S1).

test(maldicao_dura_ate_a_primeira_compra) :-
    % o alvo tem jogada, joga, e a Maldição continua nele
    st([[1,6],[2,2]], [[0,0]], [[6,6]], [[3,4]], [], [], [[curse,player]], player, S),
    play(player, [1,6], right, S, S1),
    effects_of(S1, E1),
    memberchk([curse,player], E1),
    turn_of(S1, opponent).

test(maldicao_dispara_na_compra_de_um_turno_futuro) :-
    % turno 1: joga e mantém a Maldição; turno 2: sem jogada, compra + extra
    st([[1,6],[4,5]], [[0,0]], [[6,6]], [[3,4],[0,6],[2,5],[1,1]],
       [], [], [[curse,player]], player, S0),
    play(player, [1,6], right, S0, S1),            % mesa agora com ponta 1
    pass_turn_back(S1, S2),                        % vez do oponente passa
    effects_of(S2, E2),
    memberchk([curse,player], E2),
    must_draw(player, S2),                         % [4,5] não encaixa em 1
    draw_one(player, S2, S3, _),                   % [3,4]: ainda sem jogada
    draw_one(player, S3, S4, _),                   % [0,6]: agora joga, mas deve a extra
    effects_of(S4, E4),
    \+ memberchk([curse,player], E4),
    draw_one(player, S4, S5, _),
    \+ must_draw(player, S5).

test(maldicao_nao_empilha, [fail]) :-
    st([[1,6]], [[0,0]], [[6,6]], [[3,4],[2,2]],
       [curse], [], [[curse,opponent]], player, S),
    can_use(player, curse, none, S).

test(maldicao_nao_empilha_com_compra_pendente, [fail]) :-
    st([[1,6]], [[0,0]], [[6,6]], [[3,4],[2,2]],
       [curse], [], [[curse_due,opponent]], player, S),
    can_use(player, curse, none, S).

test(maldicao_pode_ser_lancada_de_novo_depois_de_disparar) :-
    st([[1,6]], [[0,0]], [[6,6]], [[3,4],[2,2]],
       [curse], [], [], player, S),
    can_use(player, curse, none, S).

test(escudo_anula_a_maldicao_na_hora) :-
    st([[1,6]], [[0,0]], [[6,6]], [[3,4],[2,2]],
       [curse], [shield], [], player, S),
    use_power(player, curse, none, S, S1, Outcome),
    Outcome == [shielded],
    effects_of(S1, E),
    \+ memberchk([curse,opponent], E),
    powers_of_(opponent, S1, []).

test(comprar_sem_obrigacao_falha, [fail]) :-
    st([[1,6]], [[0,0]], [[6,6]], [[3,4]], [], [], [], player, S),
    draw_one(player, S, _, _).

test(jogar_antes_de_pagar_a_extra_falha, [fail]) :-
    cursed([[curse,player]], S),
    draw_one(player, S, S1, _),
    draw_one(player, S1, S2, _),
    play(player, [0,6], right, S2, _).

:- end_tests(maldicao).


:- begin_tests(poderes).

base(Extra, S) :-
    st([[3,6],[2,2],[1,4]], [[0,0],[5,5],[3,3]], [[6,3]], [[0,1],[2,5],[4,4]],
       [freeze,curse,overload], [teleport,time,recovery], Extra, player, S).

test(congelar_adiciona_efeito_e_gasta_o_poder) :-
    base([], S),
    use_power(player, freeze, left, S, S1, Out),
    Out == [applied],
    effects_of(S1, E),
    memberchk([freeze,opponent,left], E),
    memberchk([used,player], E),
    powers_of_(player, S1, [curse,overload]).

test(nenhum_poder_antes_da_primeira_peca, [fail]) :-
    % a peça de saída poderia ir para o monte com Troca/Recuperação
    st([[6,6],[1,2]], [[5,5]], [], [[0,1]], [recovery], [], [], player, S),
    use_power(player, recovery, none, S, _, _).

test(nenhum_poder_antes_da_primeira_peca_vale_para_todos) :-
    all_powers(Ps),
    forall(member(P, Ps),
           (   st([[6,6],[1,2]], [[5,5]], [], [[0,1]], [P], [], [], player, S),
               \+ can_use(player, P, none, S),
               \+ can_use(player, P, left, S),
               \+ can_use(player, P, 0, S),
               \+ can_use(player, P, [1,2], S)
           )).

test(congelar_sem_mesa_falha, [fail]) :-
    st([[3,6]], [[0,0]], [], [], [freeze], [], [], player, S),
    use_power(player, freeze, left, S, _, _).

test(congelar_ponta_invalida_falha, [fail]) :-
    base([], S),
    use_power(player, freeze, middle, S, _, _).

test(so_um_poder_por_turno, [fail]) :-
    base([], S),
    use_power(player, freeze, left, S, S1, _),
    use_power(player, curse, none, S1, _, _).

test(poder_que_nao_tem_falha, [fail]) :-
    base([], S),
    use_power(player, flames, 2, S, _, _).

test(poder_fora_da_vez_falha, [fail]) :-
    base([], S),
    use_power(opponent, shield, none, S, _, _).

test(escudo_nao_e_ativavel, [fail]) :-
    st([[3,6]], [[0,0]], [[6,3]], [], [], [shield], [], opponent, S),
    use_power(opponent, shield, none, S, _, _).

test(escudo_anula_ataque) :-
    st([[3,6]], [[0,0]], [[6,3]], [], [freeze], [shield,time], [], player, S),
    use_power(player, freeze, left, S, S1, Out),
    Out == [shielded],
    effects_of(S1, E),
    \+ memberchk([freeze,opponent,left], E),
    powers_of_(player, S1, []),          % o ataque foi gasto
    powers_of_(opponent, S1, [time]).    % e o escudo também

test(escudo_vale_para_chamas_e_maldicao) :-
    forall(member(Pow-Arg, [curse-none, flames-3, overload-none]),
           (   st([[3,6]], [[0,0]], [[6,3]], [], [Pow], [shield], [], player, S),
               use_power(player, Pow, Arg, S, _, Out),
               Out == [shielded]
           )).

test(sobrecarga_revela_buchas) :-
    base([], S),
    use_power(player, overload, none, S, S1, Out),
    Out == [revealed, [[0,0],[5,5],[3,3]]],
    revealed_pieces(opponent, S1, R),
    R == [[0,0],[3,3],[5,5]].

test(sobrecarga_so_mostra_o_que_ainda_esta_na_mao) :-
    st([[3,6]], [[0,0],[1,2]], [[6,3]], [], [overload], [], [], player, S),
    use_power(player, overload, none, S, S1, _),
    revealed_pieces(opponent, S1, [[0,0]]),
    % depois que o computador joga a bucha, ela deixa de aparecer
    nth1(2, S1, _, Rest),
    nth1(2, S2, [[1,2]], Rest),
    revealed_pieces(opponent, S2, []).

test(sobrecarga_sem_buchas) :-
    st([[3,6]], [[0,1],[2,3]], [[6,3]], [], [overload], [], [], player, S),
    use_power(player, overload, none, S, S1, Out),
    Out == [revealed, []],
    revealed_pieces(opponent, S1, []).

test(chamas_vira_efeito_no_alvo) :-
    st([[3,6]], [[0,0]], [[6,3]], [], [flames], [], [], player, S),
    use_power(player, flames, 4, S, S1, _),
    effects_of(S1, E),
    memberchk([flames,opponent,4], E).

test(chamas_numero_fora_de_0_a_6_falha, [fail]) :-
    st([[3,6]], [[0,0]], [[6,3]], [], [flames], [], [], player, S),
    use_power(player, flames, 7, S, _, _).

test(teletransporte_remove_restricoes_do_proprio) :-
    st([[3,6]], [[0,0]], [[6,3]], [], [teleport], [], [[freeze,player,left],[flames,player,2]],
       player, S),
    use_power(player, teleport, none, S, S1, _),
    effects_of(S1, E),
    \+ memberchk([freeze,player,left], E),
    \+ memberchk([flames,player,2], E),
    legal_moves(player, S1, M),
    length(M, 2).

test(teletransporte_sem_restricao_falha, [fail]) :-
    st([[3,6]], [[0,0]], [[6,3]], [], [teleport], [], [], player, S),
    use_power(player, teleport, none, S, _, _).

test(tempo_permite_duas_jogadas) :-
    % [3,6] na esquerda deixa as pontas 3 e 3; o [3,3] ainda encaixa
    st([[3,6],[3,3],[1,1]], [[0,0]], [[6,3]], [], [time], [], [], player, S),
    use_power(player, time, none, S, S1, _),
    play(player, [3,6], left, S1, S2),
    turn_of(S2, player),
    play(player, [3,3], left, S2, S3),
    turn_of(S3, opponent),
    effects_of(S3, E),
    \+ memberchk([time,player], E).

test(tempo_sem_segunda_jogada_passa_a_vez) :-
    % depois do [3,6] nada mais encaixa, então a vez passa
    st([[3,6],[1,1]], [[0,0]], [[6,3]], [], [time], [], [], player, S),
    use_power(player, time, none, S, S1, _),
    play(player, [3,6], left, S1, S2),
    turn_of(S2, opponent),
    effects_of(S2, E),
    \+ memberchk([time,player], E).

test(tempo_precisa_de_duas_pecas, [fail]) :-
    st([[3,6]], [[0,0]], [[6,3]], [], [time], [], [], player, S),
    use_power(player, time, none, S, _, _).

test(troca_escolhida_conserva_as_pecas) :-
    st([[3,6],[2,2],[1,4]], [[0,0],[5,5],[3,3]], [[6,3]], [[0,1],[2,5],[4,4]],
       [swap], [], [], player, S),
    use_power(player, swap, [4,1], S, S2, Out),
    Out = [swapped, [1,4], In],
    hand_of(player, S2, H),
    length(H, 3),
    \+ memberchk([1,4], H),
    memberchk(In, H),
    yard_of(S2, B),
    length(B, 3),
    memberchk([1,4], B),
    \+ memberchk(In, B).

test(troca_peca_que_nao_tem_falha, [fail]) :-
    st([[3,6]], [[0,0]], [[6,3]], [[2,2]], [swap], [], [], player, S),
    use_power(player, swap, [1,1], S, _, _).

test(troca_sem_monte_falha, [fail]) :-
    st([[3,6]], [[0,0]], [[6,3]], [], [swap], [], [], player, S),
    use_power(player, swap, [3,6], S, _, _).

test(recuperacao_troca_a_mais_pesada) :-
    st([[1,2],[5,6],[0,3]], [[0,0]], [[6,3]], [[2,2],[1,1]], [recovery], [], [], player, S),
    use_power(player, recovery, none, S, S1, Out),
    Out = [swapped, [5,6], In],
    memberchk(In, [[2,2],[1,1]]),
    hand_of(player, S1, H),
    length(H, 3),
    \+ memberchk([5,6], H),
    yard_of(S1, B),
    memberchk([5,6], B),
    length(B, 2).

test(recuperacao_sem_monte_falha, [fail]) :-
    st([[1,2]], [[0,0]], [[6,3]], [], [recovery], [], [], player, S),
    use_power(player, recovery, none, S, _, _).

:- end_tests(poderes).


:- begin_tests(computador).

test(computador_joga_e_passa_a_vez) :-
    st([[0,0]], [[3,6],[1,1]], [[6,3]], [[4,4]], [], [], [], opponent, S),
    computer_turn(opponent, S, S1, Ev),
    memberchk([play,opponent,_,_], Ev),
    turn_of(S1, player).

test(computador_compra_ate_ter_jogada) :-
    st([[0,0]], [[1,2]], [[6,6]], [[3,4],[0,6],[2,5]], [], [], [], opponent, S),
    computer_turn(opponent, S, S1, Ev),
    memberchk([draw,opponent,[[3,4],[0,6]]], Ev),
    memberchk([play,opponent,_,_], Ev),
    turn_of(S1, player).

test(computador_passa_sem_jogada_e_sem_monte) :-
    st([[0,0]], [[1,2]], [[6,6]], [], [], [], [], opponent, S),
    computer_turn(opponent, S, S1, Ev),
    Ev == [[pass,opponent]],
    turn_of(S1, player).

test(computador_usa_teletransporte_quando_restrito) :-
    st([[0,0]], [[3,6]], [[6,3]], [[1,1]], [], [teleport], [[freeze,opponent,left]],
       opponent, S),
    computer_turn(opponent, S, _, Ev),
    memberchk([power,opponent,teleport,none,[applied]], Ev).

test(computador_nao_usa_o_que_nao_tem) :-
    st([[0,0]], [[3,6]], [[6,3]], [[1,1]], [], [], [], opponent, S),
    computer_turn(opponent, S, _, Ev),
    \+ memberchk([power|_], Ev).

test(computador_nao_joga_na_ponta_congelada) :-
    st([[0,0]], [[2,6]], [[6,3]], [], [], [], [[freeze,opponent,left]], opponent, S),
    computer_turn(opponent, S, S1, Ev),
    Ev == [[pass,opponent]],
    turn_of(S1, player).

test(dica_respeita_congelamento) :-
    st([[2,6]], [[0,0]], [[6,3]], [], [], [], [[freeze,player,left]], player, S),
    hint_for(player, S, pass).

test(dica_manda_comprar_com_maldicao_pendente) :-
    st([[1,6]], [[0,0]], [[6,6]], [[3,4]], [], [], [[curse_due,player]], player, S),
    hint_for(player, S, draw).

test(dica_sugere_jogada) :-
    st([[3,6]], [[0,0]], [[6,3]], [[2,2]], [], [], [], player, S),
    hint_for(player, S, [[3,6],Side]),
    memberchk(Side, [left,right]).

:- end_tests(computador).


% Partidas inteiras com o computador dos dois lados: confere que as 28
% peças nunca se perdem, que toda partida termina e que os poderes
% são realmente usados.
:- begin_tests(partidas_inteiras).

simulate(S, Steps, Max, Final, UsedPowers) :-
    simulate(S, Steps, Max, Final, [], UsedPowers).

simulate(S, _, _, S, Used, Used) :-
    S = [P,O,T,B|_],
    domino:game_over(P, O, T, B, _, _), !.
simulate(S, Steps, Max, Final, Used0, Used) :-
    Steps < Max,
    turn_of(S, Who),
    computer_turn(Who, S, S1, Events),
    findall(Pow, member([power,_,Pow|_], Events), Pows),
    append(Used0, Pows, Used1),
    assertion(conserva(S1)),
    Steps1 is Steps + 1,
    simulate(S1, Steps1, Max, Final, Used1, Used).

conserva(S) :-
    all_in_state(S, Pieces),
    length(Pieces, 28),
    msort(Pieces, Sorted),
    sort(Pieces, Unique),
    Sorted == Unique.

test(trinta_partidas_terminam_e_conservam_pecas) :-
    findall(ok,
            ( between(1, 30, _),
              domino:new_game(P, O, B, Turn, Start),
              initial_state(P, O, B, Turn, S0),
              abertura(Turn, Start, S0, S1),
              simulate(S1, 0, 400, Final, _),
              Final = [FP,FO,FT,FB|_],
              domino:game_over(FP, FO, FT, FB, _, _) ),
            Oks),
    length(Oks, 30).

test(poderes_sao_usados_nas_partidas) :-
    findall(Used,
            ( between(1, 30, _),
              domino:new_game(P, O, B, Turn, Start),
              initial_state(P, O, B, Turn, S0),
              abertura(Turn, Start, S0, S1),
              simulate(S1, 0, 400, _, Used) ),
            Lists),
    append(Lists, All),
    All \== [].

% Joga a peça de saída (sem poder) como a API faz.
abertura(Turn, Start, S0, S) :-
    play(Turn, Start, right, S0, S).

:- end_tests(partidas_inteiras).
