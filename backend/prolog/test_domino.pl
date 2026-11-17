:- encoding(utf8).
:- use_module(domino).
:- use_module(library(plunit)).
:- use_module(library(lists)).

:- begin_tests(domino).

test(vinte_e_oito_pecas) :-
    all_pieces(Ps),
    length(Ps, 28).

test(sem_repeticao) :-
    all_pieces(Ps),
    sort(Ps, Sorted),
    length(Sorted, 28).

test(pecas_ordenadas) :-
    all_pieces(Ps),
    forall(member([A,B], Ps), A =< B).
    
test(shuffle_preserva_pecas) :-
    all_pieces(Ps),
    shuffle(Ps, S),
    msort(S, Sorted),
    msort(Ps, Sorted).
    
test(deal_tamanhos) :-
    all_pieces(Ps), shuffle(Ps, S),
    deal(S, P, O, B),
    length(P, 7), length(O, 7), length(B, 14).

test(deal_nao_perde_nem_duplica) :-
    all_pieces(Ps), shuffle(Ps, S),
    deal(S, P, O, B),
    append([P, O, B], Todas),
    msort(Todas, Sorted),
    msort(Ps, Sorted).
    
test(rank_bucha_vence_peca_comum) :-
    piece_rank([0,0], C), piece_rank([5,6], N),
    C > N.

test(starter_maior_carroca) :-
    starter([[3,3],[0,1],[2,4]], [[5,5],[1,2],[0,6]], Turn, Piece),
    Turn == opponent, Piece == [5,5].

test(starter_sem_carroca_soma_unica) :-
    starter([[1,2],[5,6]], [[4,5],[0,1]], Turn, Piece),
    Turn == player, Piece == [5,6].
    
test(new_game_peca_inicial_esta_na_mao_de_quem_comeca) :-
    forall(between(1, 50, _),
           ( new_game(P, O, B, Turn, Start),
             length(B, 14),
             ( Turn == player -> memberchk(Start, P) ; memberchk(Start, O) ) )).
             
:- end_tests(domino).

:- begin_tests(regras).

test(pontas_da_mesa) :-
    table_ends([[6,5],[5,2],[2,2]], L, R),
    L == 6, R == 2.

test(pontas_com_uma_peca) :-
    table_ends([[3,4]], L, R),
    L == 3, R == 4.

test(mesa_vazia_sem_pontas, [fail]) :-
    table_ends([], _, _).

test(mesa_vazia_aceita_qualquer_peca) :-
    valid_moves([[1,2],[3,3]], [], Moves),
    Moves == [[[1,2],right], [[3,3],right]].

test(jogadas_validas) :-
    valid_moves([[0,6],[2,4],[1,3]], [[6,5],[5,2]], Moves),
    Moves == [[[0,6],left], [[2,4],right]].

test(peca_que_serve_nos_dois_lados) :-
    valid_moves([[3,5]], [[3,1],[1,5]], Moves),
    Moves == [[[3,5],left], [[3,5],right]].

test(bucha_nao_duplica_jogada) :-
    valid_moves([[5,5]], [[5,1]], Moves),
    Moves == [[[5,5],left]].

test(pecas_jogaveis) :-
    playable_pieces([[3,5],[0,0],[1,6]], [[3,1],[1,5]], Ps),
    Ps == [[3,5]].

test(nenhuma_peca_jogavel) :-
    playable_pieces([[0,0],[2,4]], [[6,5],[5,1]], Ps),
    Ps == [].

test(jogar_na_mesa_vazia) :-
    play_piece([6,6], right, [[1,2],[6,6]], [], H, T),
    H == [[1,2]], T == [[6,6]].

test(jogar_na_direita_sem_girar) :-
    play_piece([2,4], right, [[2,4],[0,1]], [[6,5],[5,2]], H, T),
    H == [[0,1]], T == [[6,5],[5,2],[2,4]].

test(jogar_na_direita_girando) :-
    play_piece([0,2], right, [[0,2]], [[6,5],[5,2]], H, T),
    H == [], T == [[6,5],[5,2],[2,0]].

test(jogar_na_esquerda_girando) :-
    play_piece([3,6], left, [[3,6]], [[6,5],[5,2]], _, T),
    T == [[3,6],[6,5],[5,2]].

test(jogar_na_esquerda_sem_girar) :-
    play_piece([1,3], left, [[1,3]], [[3,5]], _, T),
    T == [[1,3],[3,5]].

test(aceita_peca_fora_de_ordem) :-
    play_piece([4,2], right, [[2,4]], [[6,5],[5,2]], H, T),
    H == [], T == [[6,5],[5,2],[2,4]].

test(peca_que_nao_encaixa, [fail]) :-
    play_piece([0,1], right, [[0,1]], [[6,5],[5,2]], _, _).

test(peca_que_nao_esta_na_mao, [fail]) :-
    play_piece([2,4], right, [[0,1]], [[6,5],[5,2]], _, _).

test(lado_errado, [fail]) :-
    play_piece([2,4], left, [[2,4]], [[6,5],[5,2]], _, _).

test(mesa_continua_encadeada) :-
    play_piece([2,4], right, [[2,4],[3,6]], [[6,5],[5,2]], H1, T1),
    play_piece([3,6], left, H1, T1, _, T2),
    T2 == [[3,6],[6,5],[5,2],[2,4]],
    encadeada(T2).

test(comprar_do_monte) :-
    draw([[1,1],[2,3]], [[0,4]], B, H),
    B == [[2,3]], H == [[0,4],[1,1]].

test(monte_vazio_nao_compra, [fail]) :-
    draw([], [[0,4]], _, _).

test(compra_ate_poder_jogar) :-
    draw_until_playable([[0,0]], [[6,5]], [[1,2],[3,4],[5,6],[2,2]], H, B, Comprou),
    Comprou == [[1,2],[3,4],[5,6]],
    H == [[0,0],[1,2],[3,4],[5,6]],
    B == [[2,2]].

test(nao_compra_se_ja_pode_jogar) :-
    draw_until_playable([[5,1]], [[6,5]], [[1,2]], H, B, Comprou),
    Comprou == [], H == [[5,1]], B == [[1,2]].

test(compra_ate_o_monte_acabar) :-
    draw_until_playable([[0,0]], [[6,5]], [[1,2],[3,4]], H, B, Comprou),
    Comprou == [[1,2],[3,4]], H == [[0,0],[1,2],[3,4]], B == [].

test(pode_passar_sem_jogada_e_sem_monte) :-
    can_pass([[0,0]], [[6,5]], []).

test(nao_passa_com_monte, [fail]) :-
    can_pass([[0,0]], [[6,5]], [[1,1]]).

test(nao_passa_com_jogada, [fail]) :-
    can_pass([[5,0]], [[6,5]], []).

test(alterna_turno) :-
    next_turn(player, A), next_turn(opponent, B),
    A == opponent, B == player.

test(partida_ate_o_fim_mantem_mesa_valida) :-
    forall(between(1, 30, _), partida_aleatoria).

:- end_tests(regras).

% Cada peça encosta na seguinte pelo mesmo número.
encadeada([]).
encadeada([Primeira|Resto]) :-
    encadeada(Resto, Primeira).

encadeada([], _).
encadeada([[X,Y]|Resto], [_,X]) :-
    encadeada(Resto, [X,Y]).

% Joga uma partida inteira escolhendo sempre a primeira jogada válida
% e confere que nenhuma peça some ou se repete.
partida_aleatoria :-
    new_game(P, O, B, Turn, Start),
    ( Turn == player -> Hands0 = P-O ; Hands0 = O-P ),
    Hands0 = Mao0-Outra0,
    play_piece(Start, right, Mao0, [], Mao1, Mesa1),
    next_turn(Turn, T1),
    rodadas(T1, Outra0, Mao1, Mesa1, B, 0, MaoA-MaoB-Mesa-Monte),
    encadeada(Mesa),
    append([MaoA, MaoB, Mesa, Monte], Todas),
    maplist(msort, Todas, Norm),
    msort(Norm, Sorted),
    all_pieces(Ps),
    Sorted == Ps.

% rodadas(+Turno, +MaoDaVez, +OutraMao, +Mesa, +Monte, +PassesSeguidos, -Final)
rodadas(_, Mao, Outra, Mesa, Monte, _, Mao-Outra-Mesa-Monte) :-
    ( Mao == [] ; Outra == [] ), !.
rodadas(_, Mao, Outra, Mesa, Monte, 2, Mao-Outra-Mesa-Monte) :- !.
rodadas(Turn, Mao, Outra, Mesa, Monte, Passes, Final) :-
    draw_until_playable(Mao, Mesa, Monte, Mao1, Monte1, _),
    next_turn(Turn, Next),
    (   valid_moves(Mao1, Mesa, [[Peca, Lado]|_])
    ->  play_piece(Peca, Lado, Mao1, Mesa, Mao2, Mesa2),
        rodadas(Next, Outra, Mao2, Mesa2, Monte1, 0, Final)
    ;   can_pass(Mao1, Mesa, Monte1),
        P1 is Passes + 1,
        rodadas(Next, Outra, Mao1, Mesa, Monte1, P1, Final)
    ).

:- begin_tests(fim_de_jogo).

test(bateu) :-
    domino_out([]).

test(nao_bateu, [fail]) :-
    domino_out([[1,2]]).

test(pontos_da_mao) :-
    hand_points([[1,2],[6,6],[0,0]], P),
    P == 15.

test(pontos_mao_vazia) :-
    hand_points([], P),
    P == 0.

test(jogo_trancado) :-
    blocked([[0,0]], [[1,1]], [[6,5],[5,6]], []).

test(nao_tranca_com_monte, [fail]) :-
    blocked([[0,0]], [[1,1]], [[6,5],[5,6]], [[2,3]]).

test(nao_tranca_se_alguem_joga, [fail]) :-
    blocked([[0,0]], [[1,6]], [[6,5],[5,6]], []).

test(nao_tranca_mesa_vazia, [fail]) :-
    blocked([[0,0]], [[1,1]], [], []).

test(jogador_bateu) :-
    game_over([], [[3,4],[1,1]], [[2,2]], [[5,5]], W, P),
    W == player, P == 9.

test(oponente_bateu) :-
    game_over([[6,6]], [], [[2,2]], [], W, P),
    W == opponent, P == 12.

test(batida_contra_mao_so_com_zero) :-
    game_over([], [[0,0]], [[2,2]], [], W, P),
    W == player, P == 0.

test(trancado_vence_menor_soma) :-
    game_over([[0,1]], [[2,3]], [[6,5],[5,6]], [], W, P),
    W == player, P == 5.

test(trancado_oponente_vence) :-
    game_over([[4,4]], [[0,0],[1,2]], [[6,5],[5,6]], [], W, P),
    W == opponent, P == 8.

test(trancado_empate) :-
    game_over([[1,2]], [[0,3]], [[6,5],[5,6]], [], W, P),
    W == draw, P == 0.

test(partida_em_andamento, [fail]) :-
    game_over([[1,2]], [[0,3]], [[6,1]], [[4,4]], _, _).

:- end_tests(fim_de_jogo).
