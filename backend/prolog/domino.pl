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
% - A mesa é a lista das peças jogadas, da ponta esquerda para a direita.
%   Na mesa, cada peça fica virada de modo a encostar na vizinha:
%   [[6,5],[5,2],[2,2]] tem pontas 6 (esquerda) e 2 (direita).
% - O lado da jogada é o átomo left ou right.
%
% Utilizamos listas e átomos para facilitar a comunicação com o Janus,
% que faz a integração entre Prolog e o backend.

:- module(domino, [
    all_pieces/1,      % -Pieces
    shuffle/2,         % +Pieces, -Shuffled
    deal/4,            % +Shuffled, -Player, -Opponent, -Boneyard
    piece_rank/2,      % +Piece, -Rank
    starter/4,         % +Player, +Opponent, -Turn, -Piece
    new_game/5,        % -Player, -Opponent, -Boneyard, -Turn, -StartPiece
    table_ends/3,      % +Table, -Left, -Right
    fits/3,            % +Piece, +Table, ?Side
    valid_moves/3,     % +Hand, +Table, -Moves
    playable_pieces/3, % +Hand, +Table, -Pieces
    play_piece/6,      % +Piece, +Side, +Hand, +Table, -NewHand, -NewTable
    draw/4,            % +Boneyard, +Hand, -NewBoneyard, -NewHand
    draw_until_playable/6, % +Hand, +Table, +Boneyard, -NewHand, -NewBoneyard, -Drawn
    can_pass/3,        % +Hand, +Table, +Boneyard
    next_turn/2,       % +Turn, -Next
    domino_out/1,      % +Hand
    blocked/4,         % +Player, +Opponent, +Table, +Boneyard
    hand_points/2,     % +Hand, -Points
    game_over/6,       % +Player, +Opponent, +Table, +Boneyard, -Winner, -Points
    move_score/4,      % +Move, +Hand, +Table, -Score
    choose_move/3      % +Hand, +Table, -Move
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


% ======================================================================
% Regras das jogadas
% ======================================================================

%% table_ends(+Table, -Left, -Right)
% Devolve os números das duas pontas da mesa.
% Falha com a mesa vazia, porque ainda não existe ponta.
table_ends(Table, Left, Right) :-
    Table = [[Left,_]|_],
    last(Table, [_,Right]).

%% fits(+Piece, +Table, ?Side)
% Verdadeiro se a peça pode ser encaixada no lado Side da mesa.
% Na mesa vazia qualquer peça entra; usamos right para não
% gerar a mesma jogada duas vezes.
fits(_, [], right).
fits(Piece, Table, left) :-
    table_ends(Table, Left, _),
    memberchk(Left, Piece).
fits(Piece, Table, right) :-
    table_ends(Table, _, Right),
    memberchk(Right, Piece).

%% valid_moves(+Hand, +Table, -Moves)
% Lista todas as jogadas possíveis no formato [Peça, Lado].
% Uma peça que encaixa nas duas pontas aparece duas vezes,
% uma para cada lado.
valid_moves(Hand, Table, Moves) :-
    findall([Piece, Side],
            ( member(Piece, Hand), fits(Piece, Table, Side) ),
            Moves).

%% playable_pieces(+Hand, +Table, -Pieces)
% Lista as peças da mão que podem ser jogadas, sem repetição.
playable_pieces(Hand, Table, Pieces) :-
    findall(Piece,
            ( member(Piece, Hand), once(fits(Piece, Table, _)) ),
            Pieces).

%% orient(+Side, +Table, +Piece, -Oriented)
% Vira a peça, se preciso, para o número que encosta na mesa
% ficar do lado de dentro.
orient(_, [], Piece, Piece) :- !.
orient(left, Table, [A,B], Oriented) :-
    table_ends(Table, Left, _),
    ( B =:= Left -> Oriented = [A,B] ; Oriented = [B,A] ).
orient(right, Table, [A,B], Oriented) :-
    table_ends(Table, _, Right),
    ( A =:= Right -> Oriented = [A,B] ; Oriented = [B,A] ).

%% play_piece(+Piece, +Side, +Hand, +Table, -NewHand, -NewTable)
% Joga a peça no lado escolhido: tira da mão e coloca na mesa já virada.
% Falha se a peça não está na mão ou não encaixa naquele lado.
% A peça pode vir em qualquer ordem ([5,3] ou [3,5]); na mão
% ela é procurada na forma crescente.
play_piece([X,Y], Side, Hand, Table, NewHand, NewTable) :-
    A is min(X, Y), B is max(X, Y),
    selectchk([A,B], Hand, NewHand),
    fits([A,B], Table, Side), !,
    orient(Side, Table, [A,B], Oriented),
    place(Side, Oriented, Table, NewTable).

place(left, Piece, Table, [Piece|Table]).
place(right, Piece, Table, NewTable) :-
    append(Table, [Piece], NewTable).

%% draw(+Boneyard, +Hand, -NewBoneyard, -NewHand)
% Compra uma peça do monte. Como o monte já está embaralhado,
% pega a primeira. Falha se o monte estiver vazio.
draw([Piece|Boneyard], Hand, Boneyard, NewHand) :-
    append(Hand, [Piece], NewHand).

%% draw_until_playable(+Hand, +Table, +Boneyard, -NewHand, -NewBoneyard, -Drawn)
% Compra do monte até ter uma peça jogável ou o monte acabar.
% Drawn é a lista das peças compradas, na ordem da compra.
draw_until_playable(Hand, Table, Boneyard, Hand, Boneyard, []) :-
    ( Boneyard == [] ; playable_pieces(Hand, Table, [_|_]) ), !.
draw_until_playable(Hand, Table, Boneyard, NewHand, NewBoneyard, [Piece|Drawn]) :-
    draw(Boneyard, Hand, Boneyard1, Hand1),
    last(Hand1, Piece),
    draw_until_playable(Hand1, Table, Boneyard1, NewHand, NewBoneyard, Drawn).

%% can_pass(+Hand, +Table, +Boneyard)
% Só pode passar a vez quem não tem jogada e não tem mais o que comprar.
can_pass(Hand, Table, []) :-
    playable_pieces(Hand, Table, []).

%% next_turn(+Turn, -Next)
% Alterna a vez entre o jogador e o computador.
next_turn(player, opponent).
next_turn(opponent, player).


% ======================================================================
% Fim de jogo
% ======================================================================

%% domino_out(+Hand)
% Verdadeiro se o jogador bateu, ou seja, jogou todas as peças.
domino_out([]).

%% blocked(+Player, +Opponent, +Table, +Boneyard)
% Verdadeiro se o jogo trancou: o monte acabou e nenhum dos
% dois jogadores tem peça que encaixe na mesa.
blocked(Player, Opponent, Table, []) :-
    Table \== [],
    can_pass(Player, Table, []),
    can_pass(Opponent, Table, []).

%% hand_points(+Hand, -Points)
% Soma os pontos de todas as peças da mão.
hand_points(Hand, Points) :-
    findall(S, ( member([A,B], Hand), S is A + B ), Sums),
    sum_list(Sums, Points).

%% game_over(+Player, +Opponent, +Table, +Boneyard, -Winner, -Points)
% Verdadeiro se a partida acabou. Falha enquanto ainda há jogo.
%
% Winner é player, opponent ou draw (empate).
% Points é quanto o vencedor marca: a soma das peças que sobraram
% na mão do perdedor. No empate ninguém marca.
%
% - Batida: vence quem ficou sem peças.
% - Trancado: vence quem tem menos pontos na mão; com a mesma
%   soma, dá empate.
game_over([], Opponent, _, _, player, Points) :- !,
    hand_points(Opponent, Points).
game_over(Player, [], _, _, opponent, Points) :- !,
    hand_points(Player, Points).
game_over(Player, Opponent, Table, Boneyard, Winner, Points) :-
    blocked(Player, Opponent, Table, Boneyard),
    hand_points(Player, PP),
    hand_points(Opponent, OP),
    compare(Order, PP, OP),
    blocked_result(Order, PP, OP, Winner, Points).

% No trancado, quem tem menos pontos vence e marca os pontos do outro.
blocked_result(<, _, OP, player, OP).
blocked_result(>, PP, _, opponent, PP).
blocked_result(=, _, _, draw, 0).


% ======================================================================
% Adversário (computador)
% ======================================================================

%% move_score(+Move, +Hand, +Table, -Score)
% Dá uma nota para a jogada [Peça, Lado]; quanto maior, melhor.
% A nota soma três ideias:
% - Pontos da peça: livrar-se das peças pesadas diminui o prejuízo
%   se o adversário bater ou o jogo trancar.
% - Bucha: vale 5 a mais, porque só encaixa num número e
%   costuma ficar presa na mão.
% - Opções: o dobro do número de peças que continuam jogáveis
%   depois da jogada, para não ficar sem saída na próxima vez.
move_score([Piece, Side], Hand, Table, Score) :-
    play_piece(Piece, Side, Hand, Table, NewHand, NewTable),
    Piece = [A,B],
    ( A =:= B -> Double = 5 ; Double = 0 ),
    playable_pieces(NewHand, NewTable, Options),
    length(Options, N),
    Score is A + B + Double + 2 * N.

%% choose_move(+Hand, +Table, -Move)
% Escolhe a jogada do computador no formato [Peça, Lado]:
% a de maior nota em move_score/4.
% Em caso de empate, fica a que aparece primeiro em valid_moves/3.
% Falha se não houver jogada; aí o computador precisa comprar
% (draw_until_playable/6) ou passar a vez (can_pass/3).
%
% As notas entram negativas para o keysort, que ordena do menor
% para o maior e mantém a ordem original nos empates.
choose_move(Hand, Table, Move) :-
    valid_moves(Hand, Table, Moves),
    Moves \== [],
    findall(Neg-M,
            ( member(M, Moves),
              move_score(M, Hand, Table, Score),
              Neg is -Score ),
            Scored),
    keysort(Scored, [_-Move|_]).
