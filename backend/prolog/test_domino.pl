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
    
:- end_tests(domino).