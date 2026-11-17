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
    all_pieces/1,      % -Pieces
    shuffle/2,           % +Pieces, -Shuffled
    deal/4,             % +Shuffled, -Player, -Opponent, -Boneyard
    piece_rank/2       % +Piece, -Rank
]).

:- use_module(library(lists)).
:- use_module(library(random)).

%% all_pieces(-Pieces)
%  As 28 peças do dominó duplo-seis, sem repetição, sempre com A =< B.
all_pieces(Pieces) :-
    findall([A,B], ( between(0, 6, A), between(A, 6, B) ), Pieces).
    
    
%% shuffle(+Pieces, -Shuffled)
%  Embaralha. É não determinístico por natureza: cada chamada dá um resultado.
shuffle(Pieces, Shuffled) :-
    random_permutation(Pieces, Shuffled).
    
%% deal(+Shuffled, -Player, -Opponent, -Boneyard)
%  7 peças para cada jogador; as 14 restantes formam o monte (boneyard).
%  Aqui o Prolog brilha: descrevemos a forma do resultado e a unificação
%  faz a divisão da lista.
deal(Shuffled, Player, Opponent, Boneyard) :-
    length(Player, 7),
    length(Opponent, 7),
    append(Player, Rest, Shuffled),
    append(Opponent, Boneyard, Rest).
    
%% piece_rank(+Piece, -Rank)
%  Força da peça para decidir quem começa. Toda bucha (dupla) vale mais
%  que qualquer peça comum; entre bucha, a maior vence; entre peças
%  comuns, vale a soma dos pontos.
piece_rank([A,A], Rank) :- !, Rank is 100 + A.
piece_rank([A,B], Rank) :- Rank is A + B.