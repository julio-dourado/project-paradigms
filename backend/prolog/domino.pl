:- encoding(utf8).
% domino.pl -- Responsável pela preparação inicial de uma partida de dominó.
%
% Representação dos dados:
% - Cada peça é representada por uma lista com dois números.
%   Exemplo: [3,5] representa uma peça com 3 e 5 pontos.
% - As peças são armazenadas em ordem crescente (A =< B),
%   evitando representar a mesma peça de duas formas diferentes.
% - As mãos dos jogadores e o monte são listas de peças.
% - O turno é identificado pelos átomos player ou opponent.
%
% Utilizamos listas e átomos para facilitar a comunicação com o Janus,
% que faz a integração entre Prolog e o backend.

:- module(domino, [
    all_pieces/1,      % -Pieces
    shuffle/2,         % +Pieces, -Shuffled
    deal/4,            % +Shuffled, -Player, -Opponent, -Boneyard
    piece_rank/2,      % +Piece, -Rank
    starter/4,         % +Player, +Opponent, -Turn, -Piece
    new_game/5         % -Player, -Opponent, -Boneyard, -Turn, -StartPiece
]).

:- use_module(library(lists)).
:- use_module(library(random)).

%% all_pieces(-Pieces)
% Gera todas as 28 peças possíveis do dominó duplo-seis.
% O primeiro número varia de 0 a 6, enquanto o segundo começa
% no valor do primeiro número para evitar peças repetidas.
all_pieces(Pieces) :-
    findall([A,B], ( between(0, 6, A), between(A, 6, B) ), Pieces).
    
    
%% shuffle(+Pieces, -Shuffled)
% Recebe a lista de peças e retorna uma nova lista embaralhada.
shuffle(Pieces, Shuffled) :-
    random_permutation(Pieces, Shuffled).
    

%% deal(+Shuffled, -Player, -Opponent, -Boneyard)
% Distribui as peças entre os dois jogadores.
% Cada jogador recebe 7 peças e as 14 restantes ficam no monte.
deal(Shuffled, Player, Opponent, Boneyard) :-
    length(Player, 7),
    length(Opponent, 7),
    append(Player, Rest, Shuffled),
    append(Opponent, Boneyard, Rest).
    
%% piece_rank(+Piece, -Rank)
% Calcula a prioridade de uma peça para definir quem começa.
%
% As peças duplas (buchas) recebem uma pontuação acima das demais.
% Entre duas buchas, a de maior número tem prioridade.
% Quando não há bucha, a peça com a maior soma de pontos tem prioridade.
%
% O corte (!) garante que, ao encontrar uma peça dupla, o Prolog
% não tente também aplicar a regra destinada às peças comuns.
piece_rank([A,A], Rank) :- !, Rank is 100 + A.
piece_rank([A,B], Rank) :- Rank is A + B.

%% new_game(-Player, -Opponent, -Boneyard, -Turn, -StartPiece)
% Reúne todas as etapas necessárias para iniciar uma nova partida:
% 1. Gera as 28 peças possíveis.
% 2. Embaralha as peças para definir uma ordem aleatória.
% 3. Distribui 7 peças para cada jogador e separa o monte.
% 4. Determina quem começa e qual será a peça inicial.
%
% Este é o predicado principal do backend
starter(Player, Opponent, Turn, Piece) :-
    findall(Rank-(Who-P),
            ( member(Who-Hand, [player-Player, opponent-Opponent]),
              member(P, Hand),
              piece_rank(P, Rank) ),
            Candidates),
    max_member(_-(Turn-Piece), Candidates).

%% new_game(-Player, -Opponent, -Boneyard, -Turn, -StartPiece)
%  Predicado que o backend vai chamar: monta uma partida completa.
new_game(Player, Opponent, Boneyard, Turn, StartPiece) :-
    all_pieces(Pieces),
    shuffle(Pieces, Shuffled),
    deal(Shuffled, Player, Opponent, Boneyard),
    starter(Player, Opponent, Turn, StartPiece).