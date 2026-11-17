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

:- end_tests(domino).