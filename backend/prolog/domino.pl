:- encoding(utf8).
% domino.pl -- Preparação de uma partida de dominó (Parte 1: setup)
%
% Representação (pensada para passar bem pelo janus/JSON):
%   - Peça:  lista [A,B] com A =< B     ex.: [3,5], [6,6]
%   - Mão, monte e coleção de peças: listas de peças
%   - Turn:  o átomo `player` ou `opponent`
%
% Termos compostos NÃO atravessam o janus, por isso só usamos listas e átomos.

:- module(domino, [
    all_pieces/1       % -Pieces
]).

:- use_module(library(lists)).
:- use_module(library(random)).

%% all_pieces(-Pieces)
%  As 28 peças do dominó duplo-seis, sem repetição, sempre com A =< B.
all_pieces(Pieces) :-
    findall([A,B], ( between(0, 6, A), between(A, 6, B) ), Pieces).