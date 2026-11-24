:- encoding(utf8).
% ======================================================================
% Poderes especiais
% ======================================================================
%
% Cada jogador recebe poderes no início da partida e cada poder vale
% para um uso. Num turno o jogador pode usar UM poder (antes de jogar,
% comprar ou passar) e depois faz a jogada normal.
%
% Poder (átomo)  | Tipo      | Efeito
% ---------------+-----------+----------------------------------------------
% freeze         | ataque    | adversário não joga numa ponta (left/right)
% curse          | ataque    | na 1ª compra do adversário, ele leva uma peça extra
% overload       | ataque    | adversário revela as buchas da mão
% shield         | defesa    | anula um ataque (passivo, automático)
% recovery       | defesa    | troca a peça mais pesada da mão por uma do monte
% teleport       | defesa    | ignora freeze e flames que pesam sobre você
% time           | estratégia| permite jogar duas peças seguidas
% swap           | estratégia| troca uma peça escolhida por uma do monte
% flames         | estratégia| adversário deve jogar peça com o número N
%
% O janus só passa listas, números e átomos; por isso o estado é uma
% lista de 8 elementos, sempre na mesma ordem:
%
%   [Player, Opponent, Table, Boneyard,
%    PlayerPowers, OpponentPowers, Effects, Turn]
%
% e os efeitos ativos são listas:
%
%   [freeze, Alvo, Lado]      [flames, Alvo, N]       [curse, Alvo]
%   [curse_due, Alvo]         [time, Quem]            [used, Quem]
%   [revealed, Alvo, Buchas]
%
% Todos os predicados daqui só leem o estado recebido e devolvem um
% estado novo (sem assert/retract), como no resto do projeto. As regras
% básicas (encaixe, giro da peça, pontos) continuam no módulo domino.

:- module(powers, [
    all_powers/1,        % -Powers
    powers_per_player/1, % -N
    power_kind/2,        % ?Power, ?Kind
    deal_powers/2,       % -PlayerPowers, -OpponentPowers
    initial_state/5,     % +Player, +Opponent, +Boneyard, +Turn, -State
    atomize/2,           % +Json, -Termo (strings viram átomos)
    other/2,             % ?Who, ?Other
    legal_moves/3,       % +Who, +State, -Moves
    must_draw/2,         % +Who, +State
    can_pass_now/2,      % +Who, +State
    draw_one/4,          % +Who, +State, -NewState, -Piece
    play/5,              % +Who, +Piece, +Side, +State, -NewState
    pass/3,              % +Who, +State, -NewState
    can_use/4,           % +Who, +Power, +Arg, +State
    use_power/6,         % +Who, +Power, +Arg, +State, -NewState, -Outcome
    revealed_pieces/3,   % +Who, +State, -Pieces
    hint_for/3,          % +Who, +State, -Hint
    computer_turn/4      % +Who, +State, -NewState, -Events
]).

:- use_module(domino).
:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(random)).

% ----------------------------------------------------------------------
% Catálogo
% ----------------------------------------------------------------------

all_powers([freeze, curse, overload, shield, recovery, teleport,
            time, swap, flames]).

powers_per_player(3).

power_kind(freeze,   attack).
power_kind(curse,    attack).
power_kind(overload, attack).
power_kind(shield,   defense).
power_kind(recovery, defense).
power_kind(teleport, defense).
power_kind(time,     strategy).
power_kind(swap,     strategy).
power_kind(flames,   strategy).

% Poderes que agem sobre o adversário (e que o escudo pode anular).
targets_opponent(freeze).
targets_opponent(curse).
targets_opponent(overload).
targets_opponent(flames).

%% deal_powers(-Mine, -Theirs)
% Sorteia poderes diferentes para os dois jogadores.
deal_powers(Mine, Theirs) :-
    all_powers(All),
    random_permutation(All, Shuffled),
    powers_per_player(N),
    length(Mine, N),
    length(Theirs, N),
    append(Mine, Rest, Shuffled),
    append(Theirs, _, Rest).

%% initial_state(+Player, +Opponent, +Boneyard, +Turn, -State)
initial_state(Player, Opponent, Boneyard, Turn,
              [Player, Opponent, [], Boneyard, PP, OP, [], Turn]) :-
    deal_powers(PP, OP).

%% atomize(+Json, -Termo)
% Strings viram átomos, em qualquer profundidade das listas. Serve para
% o estado que chega do navegador, onde "left" é uma string.
atomize(X, Y) :- string(X), !, atom_string(Y, X).
atomize(X, Y) :- is_list(X), !, maplist(atomize, X, Y).
atomize(X, X).

other(player, opponent).
other(opponent, player).

% ----------------------------------------------------------------------
% Acesso ao estado
% ----------------------------------------------------------------------

key_index(player,          1).
key_index(opponent,        2).
key_index(table,           3).
key_index(boneyard,        4).
key_index(player_powers,   5).
key_index(opponent_powers, 6).
key_index(effects,         7).
key_index(turn,            8).

powers_key(player,   player_powers).
powers_key(opponent, opponent_powers).

get(Key, S, V) :- key_index(Key, I), nth1(I, S, V).

% nth1/4 sem lista de saída: insere V na posição I de Rest.
put(Key, V, S0, S) :-
    key_index(Key, I),
    nth1(I, S0, _, Rest),
    nth1(I, S, V, Rest).

powers_of(Who, S, Ps) :- powers_key(Who, K), get(K, S, Ps).
set_powers(Who, Ps, S0, S) :- powers_key(Who, K), put(K, Ps, S0, S).

add_effect(Eff, S0, S) :-
    get(effects, S0, E),
    put(effects, [Eff|E], S0, S).

% Remove todos os efeitos que unificam com o padrão.
drop_effects(Pattern, S0, S) :-
    get(effects, S0, E),
    exclude(unifies(Pattern), E, E1),
    put(effects, E1, S0, S).

unifies(Pattern, X) :- \+ \+ Pattern = X.

normalize([X,Y], [A,B]) :- A is min(X,Y), B is max(X,Y).

% ----------------------------------------------------------------------
% Jogadas com restrições
% ----------------------------------------------------------------------

%% legal_moves(+Who, +State, -Moves)
% Jogadas [Peça, Lado] permitidas agora: as de domino:valid_moves/3
% menos as da ponta congelada; se houver "chamas" e alguma jogada com
% o número, só essas valem (se nenhuma tiver, vale tudo).
legal_moves(Who, S, Moves) :-
    get(Who, S, Hand),
    get(table, S, Table),
    get(effects, S, Effs),
    domino:valid_moves(Hand, Table, Base),
    findall(M,
            ( member(M, Base),
              M = [_, Side],
              \+ memberchk([freeze, Who, Side], Effs) ),
            Free),
    apply_flames(Who, Effs, Free, Moves).

apply_flames(Who, Effs, Free, Moves) :-
    memberchk([flames, Who, N], Effs),
    findall(M, ( member(M, Free), M = [Piece, _], memberchk(N, Piece) ), Hit),
    Hit \== [],
    !,
    Moves = Hit.
apply_flames(_, _, Free, Free).

%% must_draw(+Who, +State)
% Quem não tem jogada compra enquanto houver monte. Com a maldição,
% depois de achar uma peça jogável ainda deve comprar mais uma.
must_draw(Who, S) :-
    get(boneyard, S, [_|_]),
    (   legal_moves(Who, S, [])
    ->  true
    ;   get(effects, S, E),
        memberchk([curse_due, Who], E)
    ).

%% can_pass_now(+Who, +State)
can_pass_now(Who, S) :-
    get(boneyard, S, []),
    legal_moves(Who, S, []).

%% draw_one(+Who, +State, -NewState, -Piece)
% Compra uma peça (a primeira do monte). Falha se não for obrigado a
% comprar.
draw_one(Who, S0, S, Piece) :-
    must_draw(Who, S0),
    get(boneyard, S0, [Piece|Rest]),
    get(Who, S0, Hand),
    append(Hand, [Piece], Hand1),
    legal_moves(Who, S0, Before),
    put(Who, Hand1, S0, S1),
    put(boneyard, Rest, S1, S2),
    curse_after_draw(Who, Before, S2, S).

% Primeira compra de quem está amaldiçoado (ela só acontece quando é
% obrigatória): a Maldição se desfaz e ele passa a dever uma compra extra.
curse_after_draw(Who, [], S0, S) :-
    get(effects, S0, E),
    memberchk([curse, Who], E),
    !,
    drop_effects([curse, Who], S0, S1),
    add_effect([curse_due, Who], S1, S).
% Já tinha jogada e devia uma compra: esta foi a extra.
curse_after_draw(Who, [_|_], S0, S) :-
    get(effects, S0, E),
    memberchk([curse_due, Who], E),
    !,
    drop_effects([curse_due, Who], S0, S).
curse_after_draw(_, _, S, S).

%% play(+Who, +Piece, +Side, +State, -NewState)
% Falha se não for a vez, se ainda deve comprar ou se a jogada não é
% permitida pelas restrições.
play(Who, Piece, Side, S0, S) :-
    get(turn, S0, Who),
    \+ must_draw(Who, S0),
    normalize(Piece, P),
    legal_moves(Who, S0, Moves),
    memberchk([P, Side], Moves),
    get(Who, S0, Hand),
    get(table, S0, Table),
    domino:play_piece(P, Side, Hand, Table, Hand1, Table1),
    put(Who, Hand1, S0, S1),
    put(table, Table1, S1, S2),
    after_play(Who, S2, S).

% Com "time" ativo e outra jogada possível, a vez continua com Who.
after_play(Who, S0, S) :-
    get(effects, S0, E),
    (   memberchk([time, Who], E),
        get(Who, S0, [_|_]),
        legal_moves(Who, S0, [_|_])
    ->  drop_effects([time, Who], S0, S)
    ;   end_turn(Who, S0, S)
    ).

%% pass(+Who, +State, -NewState)
pass(Who, S0, S) :-
    get(turn, S0, Who),
    can_pass_now(Who, S0),
    end_turn(Who, S0, S).

% Fim do turno de Who: some o que valia só para o turno dele e a vez passa.
% A Maldição ([curse, Who]) NÃO some aqui: ela dura até a primeira compra de
% Who, em qualquer turno futuro (só o Escudo de quem a recebe a evita, na hora
% em que é lançada).
end_turn(Who, S0, S) :-
    get(effects, S0, E),
    findall(X, ( member(X, E), \+ expires(Who, X) ), E1),
    put(effects, E1, S0, S1),
    other(Who, Next),
    put(turn, Next, S1, S).

expires(Who, [freeze, Who, _]).
expires(Who, [flames, Who, _]).
expires(Who, [curse_due, Who]).
expires(Who, [time, Who]).
expires(Who, [used, Who]).

% ----------------------------------------------------------------------
% Usar poderes
% ----------------------------------------------------------------------

%% can_use(+Who, +Power, +Arg, +State)
% Poderes só valem com a mesa já aberta: antes disso, Troca ou Recuperação
% poderiam mandar a peça de saída para o monte e a partida ficaria sem
% quem a abra.
% Arg: left/right (freeze), 0..6 (flames), peça [A,B] (swap); nos demais
% poderes é ignorado (use none). O escudo é passivo e nunca é "usado".
can_use(Who, Power, Arg, S) :-
    get(turn, S, Who),
    get(table, S, [_|_]),            % só depois da primeira peça (veja abaixo)
    powers_of(Who, S, Ps),
    memberchk(Power, Ps),
    get(effects, S, E),
    \+ memberchk([used, Who], E),
    valid_arg(Power, Arg, Who, S).

valid_arg(freeze, Side, _, S) :-
    memberchk(Side, [left, right]),
    get(table, S, [_|_]).
% A Maldição fica no adversário até ele comprar do monte pela primeira vez;
% enquanto ela (ou a compra extra que ela gera) estiver pendente, não dá
% para lançá-la de novo.
valid_arg(curse, _, Who, S) :-
    other(Who, Target),
    get(effects, S, E),
    \+ memberchk([curse, Target], E),
    \+ memberchk([curse_due, Target], E).
valid_arg(overload, _, _, _).
valid_arg(flames, N, _, _) :-
    integer(N),
    between(0, 6, N).
valid_arg(recovery, _, Who, S) :-
    get(Who, S, [_|_]),
    get(boneyard, S, [_|_]).
valid_arg(swap, Piece, Who, S) :-
    is_list(Piece),
    normalize(Piece, P),
    get(Who, S, Hand),
    memberchk(P, Hand),
    get(boneyard, S, [_|_]).
valid_arg(teleport, _, Who, S) :-
    get(effects, S, E),
    (   memberchk([freeze, Who, _], E)
    ;   memberchk([flames, Who, _], E)
    ),
    !.
valid_arg(time, _, Who, S) :-
    get(Who, S, [_,_|_]).

%% use_power(+Who, +Power, +Arg, +State, -NewState, -Outcome)
% Outcome: [applied], [shielded], [revealed, Buchas] ou [swapped, Saiu, Entrou].
use_power(Who, Power, Arg, S0, S, Outcome) :-
    can_use(Who, Power, Arg, S0),
    powers_of(Who, S0, Ps),
    selectchk(Power, Ps, Rest),
    set_powers(Who, Rest, S0, S1),
    add_effect([used, Who], S1, S2),
    (   targets_opponent(Power)
    ->  other(Who, Target),
        attack(Power, Arg, Target, S2, S, Outcome)
    ;   self_power(Power, Arg, Who, S2, S, Outcome)
    ).

% Quem tem escudo anula o ataque e gasta o escudo.
attack(_, _, Target, S0, S, [shielded]) :-
    powers_of(Target, S0, TP),
    selectchk(shield, TP, TP1),
    !,
    set_powers(Target, TP1, S0, S).
attack(freeze, Side, Target, S0, S, [applied]) :-
    add_effect([freeze, Target, Side], S0, S).
attack(curse, _, Target, S0, S, [applied]) :-
    add_effect([curse, Target], S0, S).
attack(flames, N, Target, S0, S, [applied]) :-
    add_effect([flames, Target, N], S0, S).
attack(overload, _, Target, S0, S, [revealed, Doubles]) :-
    get(Target, S0, Hand),
    findall([A,A], member([A,A], Hand), Doubles),
    (   Doubles == []
    ->  S = S0
    ;   add_effect([revealed, Target, Doubles], S0, S)
    ).

self_power(teleport, _, Who, S0, S, [applied]) :-
    drop_effects([freeze, Who, _], S0, S1),
    drop_effects([flames, Who, _], S1, S).
self_power(time, _, Who, S0, S, [applied]) :-
    add_effect([time, Who], S0, S).
self_power(swap, Piece, Who, S0, S, [swapped, P, In]) :-
    normalize(Piece, P),
    swap_piece(Who, P, S0, S, In).
self_power(recovery, _, Who, S0, S, [swapped, P, In]) :-
    get(Who, S0, Hand),
    heaviest(Hand, P),
    swap_piece(Who, P, S0, S, In).

% A peça mais pesada (maior soma; no empate, a última da mão).
heaviest(Hand, P) :-
    findall(Pts-X, ( member(X, Hand), X = [A,B], Pts is A + B ), L),
    keysort(L, Sorted),
    last(Sorted, _-P).

% Troca P da mão por uma peça aleatória do monte; P ocupa o lugar dela.
swap_piece(Who, P, S0, S, In) :-
    get(Who, S0, Hand),
    get(boneyard, S0, Boneyard),
    length(Boneyard, N),
    N1 is N - 1,
    random_between(0, N1, I),
    nth0(I, Boneyard, In, Rest),
    nth0(I, Boneyard1, P, Rest),
    selectchk(P, Hand, Hand0),
    append(Hand0, [In], Hand1),
    put(Who, Hand1, S0, S1),
    put(boneyard, Boneyard1, S1, S).

%% revealed_pieces(+Who, +State, -Pieces)
% Buchas da mão de Who que foram reveladas e ainda não foram jogadas.
revealed_pieces(Who, S, Pieces) :-
    get(effects, S, E),
    get(Who, S, Hand),
    findall(P,
            ( member([revealed, Who, Ps], E),
              member(P, Ps),
              memberchk(P, Hand) ),
            All),
    sort(All, Pieces).

% ----------------------------------------------------------------------
% Dica e computador
% ----------------------------------------------------------------------

%% hint_for(+Who, +State, -Hint)
% Mesma ideia do domino:hint/4, mas respeitando as restrições:
% [Peça, Lado], draw ou pass.
hint_for(Who, S, draw) :- must_draw(Who, S), !.
hint_for(Who, S, Move) :- choose_legal_move(Who, S, Move), !.
hint_for(_, _, pass).

% Melhor jogada permitida, pela nota de domino:move_score/4.
choose_legal_move(Who, S, Move) :-
    legal_moves(Who, S, Moves),
    Moves \== [],
    get(Who, S, Hand),
    get(table, S, Table),
    findall(Neg-M,
            ( member(M, Moves),
              domino:move_score(M, Hand, Table, Score),
              Neg is -Score ),
            Scored),
    keysort(Scored, [_-Move|_]).

%% computer_turn(+Who, +State, -NewState, -Events)
% Turno inteiro do computador: usa um poder (se compensar), compra o que
% for obrigado e joga (duas vezes com "time") ou passa. Events conta o
% que aconteceu, na ordem:
%   [power, Who, Poder, Arg, Outcome]   [draw, Who, Pecas]
%   [play, Who, Peça, Lado]             [pass, Who]
computer_turn(Who, S0, S, Events) :-
    get(turn, S0, Who),
    power_step(Who, S0, S1, E1),
    draw_step(Who, S1, S2, E2),
    move_step(Who, S2, S, E3),
    append([E1, E2, E3], Events).

power_step(Who, S0, S, [[power, Who, Power, Arg, Outcome]]) :-
    choose_power(Who, S0, Power, Arg),
    !,
    use_power(Who, Power, Arg, S0, S, Outcome).
power_step(_, S, S, []).

draw_step(Who, S0, S, Events) :-
    draw_all(Who, S0, S, Drawn),
    (   Drawn == []
    ->  Events = []
    ;   Events = [[draw, Who, Drawn]]
    ).

draw_all(Who, S0, S, [P|Ps]) :-
    must_draw(Who, S0),
    !,
    draw_one(Who, S0, S1, P),
    draw_all(Who, S1, S, Ps).
draw_all(_, S, S, []).

move_step(Who, S0, S, Events) :-
    (   choose_legal_move(Who, S0, [Piece, Side])
    ->  play(Who, Piece, Side, S0, S1),
        (   get(turn, S1, Who)
        ->  move_step(Who, S1, S, Rest)      % "time": segunda jogada
        ;   S = S1, Rest = []
        ),
        Events = [[play, Who, Piece, Side]|Rest]
    ;   pass(Who, S0, S),
        Events = [[pass, Who]]
    ).

% O primeiro poder da lista de prioridades que puder ser usado.
choose_power(Who, S, Power, Arg) :-
    candidate(Who, S, Power, Arg),
    can_use(Who, Power, Arg, S),
    !.

candidate(_, _, teleport, none).
candidate(Who, S, recovery, none) :-
    must_draw(Who, S),
    legal_moves(Who, S, []).
candidate(Who, S, time, none) :-
    legal_moves(Who, S, [_,_|_]).
candidate(Who, S, freeze, Side) :-
    get(table, S, Table),
    domino:table_ends(Table, L, R),
    unseen(L, Who, S, CL),
    unseen(R, Who, S, CR),
    (   CL >= CR -> Side = left ; Side = right ).
candidate(Who, S, flames, N) :-
    findall(C-N0, ( between(0, 6, N0), unseen(N0, Who, S, C) ), L),
    keysort(L, Sorted),
    last(Sorted, _-N).
candidate(_, S, curse, none) :-
    get(boneyard, S, [_,_|_]).

% Quantas peças com o número N ainda não apareceu na mesa nem na mão
% de Who (são as que o adversário ou o monte podem ter).
unseen(N, Who, S, Count) :-
    get(Who, S, Hand),
    get(table, S, Table),
    append(Hand, Table, Known),
    findall(P, ( member(P, Known), memberchk(N, P) ), Seen),
    length(Seen, K),
    Count is 7 - K.
