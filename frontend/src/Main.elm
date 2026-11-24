module Main exposing (main)

{-| Lógica da tela (parte 5).

Liga o visual (`View.elm`, parte 6) ao backend (`Api.elm`, parte 4).
Aqui ficam a seleção de peça e de ponta, o controle de turnos, o uso dos
poderes especiais e as mensagens de erro.

Quem decide as regras é o Prolog. A tela guarda o último estado que o
backend confirmou e segue o `turn` que vem nele: depois da jogada do
jogador, se a vez passou para o computador, a tela espera um pouco
("computador pensando") e pede a jogada dele em `opponent-move`.

O endereço do backend pode vir pelos flags; sem ele, vale
`http://localhost:8000`.

-}

import Api
import Browser
import Html exposing (Html)
import Process
import Task
import View exposing (End(..), Hint(..), Piece, Power(..), PowerArg(..), Status(..), Winner(..))


main : Program (Maybe String) Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = \_ -> Sub.none
        }



-- MODELO


type alias Model =
    { api : String
    , state : Api.State
    , phase : Phase
    , opening : Maybe Piece
    , selected : Maybe Piece
    , hint : Maybe Hint
    , lastPlayed : Maybe Piece
    , log : List String
    , score : { player : Int, opponent : Int }
    , error : Maybe String

    -- Frase do poder que o computador acabou de usar. Fica à vista na mesa
    -- até o jogador fazer a próxima jogada.
    , rivalPower : Maybe String

    -- O que o Prolog calculou para a vez do jogador (veja `Api.Reply`).
    , moves : Maybe (List ( Piece, End ))
    , mustDraw : Maybe Bool
    , usable : List Power
    , revealed : List Piece

    -- Poder que espera o jogador escolher ponta, número ou peça.
    , picking : Maybe Power

    -- Há uma requisição em andamento: cliques são ignorados até ela voltar.
    , busy : Bool

    -- Conta as partidas. Resposta de uma partida antiga é descartada.
    , game : Int

    -- Tentativas seguidas de pedir a jogada do computador.
    , retries : Int
    }


type Phase
    = Starting
    | Playing
    | Over Winner Int


emptyState : Api.State
emptyState =
    { playerHand = []
    , opponentHand = []
    , table = []
    , boneyard = []
    , turn = Api.Player
    , playerPowers = []
    , opponentPowers = []
    , effects = []
    }


init : Maybe String -> ( Model, Cmd Msg )
init flags =
    startGame
        { api = Maybe.withDefault "http://localhost:8000" flags
        , state = emptyState
        , phase = Starting
        , opening = Nothing
        , selected = Nothing
        , hint = Nothing
        , lastPlayed = Nothing
        , log = []
        , score = { player = 0, opponent = 0 }
        , error = Nothing
        , rivalPower = Nothing
        , moves = Nothing
        , mustDraw = Nothing
        , usable = []
        , revealed = []
        , picking = Nothing
        , busy = False
        , game = 0
        , retries = 0
        }


{-| Pede uma partida nova. O placar continua.
-}
startGame : Model -> ( Model, Cmd Msg )
startGame model =
    let
        game =
            model.game + 1
    in
    ( { model
        | state = emptyState
        , phase = Starting
        , opening = Nothing
        , selected = Nothing
        , hint = Nothing
        , lastPlayed = Nothing
        , log = []
        , error = Nothing
        , rivalPower = Nothing
        , moves = Nothing
        , mustDraw = Nothing
        , usable = []
        , revealed = []
        , picking = Nothing
        , busy = True
        , game = game
        , retries = 0
      }
    , Api.newGame model.api (GotGame game)
    )



-- MENSAGENS


type Msg
    = Select (Maybe Piece)
    | PlayPiece Piece End
    | DrawFromBoneyard
    | PassTurn
    | AskHint
    | PickPower (Maybe Power)
    | UsePower Power PowerArg
    | NewGame
    | OpponentThinks Int
    | GotGame Int (Result Api.Error Api.Reply)
    | GotPlay Int Api.Action (Result Api.Error Api.Reply)
    | GotOpponent Int (Result Api.Error Api.Reply)
    | GotHint Int (Result Api.Error Hint)
    | GotPower Int Power (Result Api.Error Api.Reply)


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        NewGame ->
            startGame model

        Select choice ->
            if canAct model then
                ( { model | selected = choice }, Cmd.none )

            else
                ( model, Cmd.none )

        PlayPiece piece end ->
            act (Api.Place piece end) model

        DrawFromBoneyard ->
            if canAct model && List.isEmpty model.state.boneyard then
                ( { model | error = Just "O monte acabou: não há mais peça para comprar." }, Cmd.none )

            else
                act Api.Draw model

        PassTurn ->
            act Api.Pass model

        AskHint ->
            if canAct model && model.hint == Nothing then
                ( { model | busy = True, error = Nothing }
                , Api.hint model.api model.state (GotHint model.game)
                )

            else
                ( model, Cmd.none )

        PickPower choice ->
            if canAct model then
                ( { model | picking = choice, selected = Nothing, error = Nothing }, Cmd.none )

            else
                ( model, Cmd.none )

        UsePower chosen arg ->
            if canAct model then
                ( { model | busy = True, picking = Nothing, selected = Nothing, hint = Nothing, error = Nothing }
                , Api.usePower model.api model.state chosen arg (GotPower model.game chosen)
                )

            else
                ( model, Cmd.none )

        OpponentThinks game ->
            if game == model.game && opponentTurn model && not model.busy then
                ( { model | busy = True }
                , Api.opponentMove model.api model.state (GotOpponent game)
                )

            else
                ( model, Cmd.none )

        GotGame game result ->
            if game /= model.game then
                ( model, Cmd.none )

            else
                case result of
                    Ok reply ->
                        let
                            started =
                                { model | phase = Playing, opening = reply.startPiece }
                        in
                        settle reply (openingLine reply) started

                    Err error ->
                        ( { model | busy = False, error = Just (Api.errorMessage model.api error) }, Cmd.none )

        GotPlay game action result ->
            if game /= model.game then
                ( model, Cmd.none )

            else
                case result of
                    Ok reply ->
                        settle reply (playerLines action model.state reply) model

                    Err error ->
                        ( { model | busy = False, error = Just (describe model (rejected action) error) }
                        , Cmd.none
                        )

        GotOpponent game result ->
            if game /= model.game then
                ( model, Cmd.none )

            else
                case result of
                    Ok reply ->
                        settle reply (opponentLines model.state reply) { model | retries = 0 }

                    Err error ->
                        retryOpponent error model

        GotPower game chosen result ->
            if game /= model.game then
                ( model, Cmd.none )

            else
                case result of
                    Ok reply ->
                        settle reply (playerPowerLines reply) model

                    Err error ->
                        ( { model | busy = False, error = Just (describe model ("Não deu para usar " ++ View.powerName chosen ++ " agora.") error) }
                        , Cmd.none
                        )

        GotHint game result ->
            if game /= model.game then
                ( model, Cmd.none )

            else
                case result of
                    Ok hint ->
                        ( { model | busy = False, hint = Just hint }, Cmd.none )

                    Err error ->
                        ( { model | busy = False, error = Just (describe model "Não deu para pedir a dica agora." error) }
                        , Cmd.none
                        )


{-| Manda a ação do jogador para o backend, se for a vez dele.
-}
act : Api.Action -> Model -> ( Model, Cmd Msg )
act action model =
    if canAct model then
        ( { model | busy = True, selected = Nothing, hint = Nothing, error = Nothing }
        , Api.play model.api model.state action (GotPlay model.game action)
        )

    else
        ( model, Cmd.none )



-- TURNOS


{-| O jogador só age na vez dele, com a partida em andamento e sem
outra requisição pendente.
-}
canAct : Model -> Bool
canAct model =
    model.phase == Playing && model.state.turn == Api.Player && not model.busy


opponentTurn : Model -> Bool
opponentTurn model =
    model.phase == Playing && model.state.turn == Api.Opponent


{-| Aplica o estado que o backend confirmou e decide o próximo passo:
fim de jogo, vez do computador ou vez do jogador.
-}
settle : Api.Reply -> List String -> Model -> ( Model, Cmd Msg )
settle reply lines model =
    let
        next =
            { model
                | state = reply.state
                , busy = False
                , error = Nothing
                , lastPlayed =
                    case List.reverse reply.event.played of
                        ( p, _ ) :: _ ->
                            Just p

                        [] ->
                            model.lastPlayed
                , moves = reply.moves
                , mustDraw = reply.mustDraw
                , usable = reply.usable
                , revealed = reply.revealed
                , picking = Nothing
                , rivalPower = rivalAlert reply
                , log = lines ++ model.log
            }
    in
    case reply.outcome of
        Just ( winner, points ) ->
            ( finish winner points next, Cmd.none )

        Nothing ->
            if opponentTurn next then
                ( next, think 900 next )

            else
                ( next, Cmd.none )


{-| Se o computador usou um poder nesta resposta, a frase para a faixa de
aviso da mesa. Qualquer outra resposta (a jogada do jogador, por exemplo)
apaga o aviso.
-}
rivalAlert : Api.Reply -> Maybe String
rivalAlert reply =
    case reply.event.power of
        Just used ->
            if used.who == Api.Opponent then
                Just (powerLine used)

            else
                Nothing

        Nothing ->
            Nothing


{-| A pausa de "computador pensando" antes de pedir a jogada dele.
-}
think : Float -> Model -> Cmd Msg
think ms model =
    Process.sleep ms |> Task.perform (\_ -> OpponentThinks model.game)


{-| Se a jogada do computador falhar, tenta de novo algumas vezes antes de
desistir; sem isso a partida ficaria parada na vez dele.
-}
retryOpponent : Api.Error -> Model -> ( Model, Cmd Msg )
retryOpponent error model =
    let
        message =
            Api.errorMessage model.api error
    in
    if model.retries < 2 then
        let
            next =
                { model | busy = False, retries = model.retries + 1, error = Just (message ++ " Tentando de novo…") }
        in
        ( next, think 2500 next )

    else
        ( { model | busy = False, error = Just (message ++ " Clique em \"Nova partida\" para recomeçar.") }
        , Cmd.none
        )


finish : Winner -> Int -> Model -> Model
finish winner points model =
    let
        score =
            model.score

        line =
            case winner of
                PlayerWins ->
                    "Fim: você venceu e marcou " ++ String.fromInt points ++ " pontos."

                OpponentWins ->
                    "Fim: o computador venceu e marcou " ++ String.fromInt points ++ " pontos."

                Draw ->
                    "Fim: jogo trancado e empatado."
    in
    { model
        | phase = Over winner points
        , selected = Nothing
        , hint = Nothing
        , log = line :: model.log
        , score =
            case winner of
                PlayerWins ->
                    { score | player = score.player + points }

                OpponentWins ->
                    { score | opponent = score.opponent + points }

                Draw ->
                    score
    }



-- LANCE A LANCE
--
-- As frases saem da diferença entre o estado de antes e o de depois, então
-- o backend só precisa devolver o estado novo. A mais nova vem primeiro.


openingLine : Api.Reply -> List String
openingLine reply =
    case ( reply.startPiece, reply.state.turn ) of
        ( Just p, Api.Player ) ->
            [ "Nova partida. Você tem a " ++ text p ++ " e abre o jogo." ]

        ( Just p, Api.Opponent ) ->
            [ "Nova partida. O computador tem a " ++ text p ++ " e abre o jogo." ]

        ( Nothing, _ ) ->
            [ "Nova partida." ]


playerLines : Api.Action -> Api.State -> Api.Reply -> List String
playerLines action before reply =
    let
        after =
            reply.state
    in
    case action of
        Api.Place _ _ ->
            case reply.event.played of
                ( p, side ) :: _ ->
                    -- Com a Manipulação do tempo a vez continua com o jogador.
                    (if after.turn == Api.Player then
                        [ "Manipulação do tempo: você joga de novo." ]

                     else
                        []
                    )
                        ++ [ placeLine "Você" before.table p side ]

                [] ->
                    []

        Api.Draw ->
            case List.filter (\p -> not (List.member p before.playerHand)) after.playerHand of
                [] ->
                    [ "Você comprou do monte." ]

                bought ->
                    List.map (\p -> "Você comprou a " ++ text p ++ ".") bought

        Api.Pass ->
            [ "Você passou a vez." ]


{-| O computador pode usar um poder, comprar várias peças (e a extra da
Maldição) e jogar uma ou duas peças. As peças dele ficam escondidas: só a
quantidade aparece. As frases saem do `event` da resposta; a mais nova vem
primeiro.
-}
opponentLines : Api.State -> Api.Reply -> List String
opponentLines before reply =
    let
        event =
            reply.event

        playLines =
            List.indexedMap
                (\i ( p, side ) ->
                    placeLine "Computador"
                        (if i == 0 then
                            before.table

                         else
                            [ p ]
                        )
                        p
                        side
                )
                event.played

        moveLines =
            if List.isEmpty playLines then
                [ "Computador passou a vez." ]

            else
                List.reverse playLines

        drawLine =
            if event.drawn == 1 then
                [ "Computador comprou 1 peça." ]

            else if event.drawn > 1 then
                [ "Computador comprou " ++ String.fromInt event.drawn ++ " peças." ]

            else
                []
    in
    moveLines ++ drawLine ++ powerLines reply


playerPowerLines : Api.Reply -> List String
playerPowerLines =
    powerLines


powerLines : Api.Reply -> List String
powerLines reply =
    case reply.event.power of
        Just used ->
            [ powerLine used ]

        Nothing ->
            []


{-| A frase de um poder usado, por quem usou e pelo resultado.
-}
powerLine : Api.PowerEvent -> String
powerLine used =
    let
        ( who, target ) =
            case used.who of
                Api.Player ->
                    ( "Você", "o computador" )

                Api.Opponent ->
                    ( "O computador", "você" )

        name =
            View.powerName used.power

        argText =
            Maybe.withDefault "" used.arg
    in
    if used.outcome == "shielded" then
        who ++ " usou " ++ name ++ ", mas o Escudo anulou o ataque."

    else
        case used.power of
            Freeze ->
                who ++ " usou " ++ name ++ ": " ++ target ++ " não joga na " ++ endWord argText ++ " no próximo turno."

            Curse ->
                who ++ " usou " ++ name ++ ": " ++ target ++ " compra uma peça a mais se não puder jogar."

            Flames ->
                who ++ " usou " ++ name ++ ": a próxima peça de " ++ target ++ " deve ter o " ++ argText ++ ", se possível."

            Overload ->
                case used.revealed of
                    [] ->
                        who ++ " usou " ++ name ++ ": " ++ target ++ " não tem buchas."

                    shown ->
                        who ++ " usou " ++ name ++ ": buchas reveladas: " ++ String.join ", " (List.map text shown) ++ "."

            Swap ->
                swapLine who name used

            Recovery ->
                swapLine who name used

            Teleport ->
                who ++ " usou " ++ name ++ ": as restrições foram ignoradas."

            TimeWarp ->
                who ++ " usou " ++ name ++ ": pode jogar duas peças seguidas."

            Shield ->
                who ++ " usou " ++ name ++ "."


swapLine : String -> String -> Api.PowerEvent -> String
swapLine who name used =
    case ( used.gave, used.got ) of
        ( Just out, Just inn ) ->
            who ++ " usou " ++ name ++ ": trocou a " ++ text out ++ " pela " ++ text inn ++ " do monte."

        _ ->
            who ++ " usou " ++ name ++ ": trocou uma peça com o monte."


endWord : String -> String
endWord side =
    if side == "left" then
        "ponta esquerda"

    else
        "ponta direita"


placeLine : String -> List Piece -> Piece -> End -> String
placeLine who table p side =
    if List.isEmpty table then
        who ++ " abriu com " ++ text p ++ "."

    else
        who ++ " jogou " ++ text p ++ " na " ++ endName side ++ "."



-- MENSAGENS DE ERRO


{-| Quando o backend recusa sem explicar, a tela explica pela ação.
-}
rejected : Api.Action -> String
rejected action =
    case action of
        Api.Place p side ->
            "A " ++ text p ++ " não encaixa na " ++ endName side ++ "."

        Api.Draw ->
            "Só dá para comprar quando nenhuma peça da mão encaixa."

        Api.Pass ->
            "Só dá para passar sem peça que encaixe e com o monte vazio."


describe : Model -> String -> Api.Error -> String
describe model fallback error =
    case error of
        Api.Rejected Nothing ->
            fallback

        _ ->
            Api.errorMessage model.api error



-- TELA


view : Model -> Html Msg
view model =
    View.view
        { onSelect = Select
        , onPlay = PlayPiece
        , onDraw = DrawFromBoneyard
        , onPass = PassTurn
        , onHint = AskHint
        , onNewGame = NewGame
        , onPowerPick = PickPower
        , onPowerUse = UsePower
        }
        (toProps model)


toProps : Model -> View.Props
toProps model =
    { playerHand = model.state.playerHand
    , opponentHand = model.state.opponentHand
    , table = model.state.table
    , boneyard = List.length model.state.boneyard
    , status = status model
    , selected = model.selected
    , hint = model.hint
    , lastPlayed = model.lastPlayed
    , opening =
        if List.isEmpty model.state.table then
            model.opening

        else
            Nothing
    , log = model.log
    , score = model.score
    , error = model.error
    , rivalPower = model.rivalPower
    , powers = powersView model
    }


{-| O painel de poderes. Os poderes só são usáveis na vez do jogador; o que
vale como jogada e a compra obrigatória vêm do Prolog (`moves`, `mustDraw`).
-}
powersView : Model -> Maybe View.PowersView
powersView model =
    Just
        { mine = model.state.playerPowers
        , usable =
            if canAct model then
                model.usable

            else
                []
        , opponentCount = List.length model.state.opponentPowers
        , effects = effectNotes model.state.effects
        , revealed = model.revealed
        , moves = model.moves
        , mustDraw = model.mustDraw
        , picking = model.picking
        }


{-| Frases dos efeitos ativos. Quem decide o que cada efeito faz é o Prolog;
aqui eles só viram texto.
-}
effectNotes : List Api.Effect -> List String
effectNotes effects =
    List.filterMap effectNote effects


effectNote : Api.Effect -> Maybe String
effectNote e =
    case e of
        Api.Frozen Api.Player side ->
            Just ("Congelamento: você não joga na " ++ endName side ++ " neste turno.")

        Api.Frozen Api.Opponent side ->
            Just ("Congelamento: o computador não joga na " ++ endName side ++ " no turno dele.")

        Api.Burning Api.Player n ->
            Just ("Chamas: sua peça deve ter o " ++ String.fromInt n ++ ", se possível.")

        Api.Burning Api.Opponent n ->
            Just ("Chamas: a próxima peça do computador deve ter o " ++ String.fromInt n ++ ".")

        Api.Cursed Api.Player ->
            Just "Maldição: na primeira vez que você comprar do monte, leva uma peça a mais."

        Api.Cursed Api.Opponent ->
            Just "Maldição: na primeira vez que o computador comprar do monte, ele leva uma peça a mais."

        Api.CurseDue Api.Player ->
            Just "Maldição: compre mais uma peça antes de jogar."

        Api.ExtraPlay Api.Player ->
            Just "Manipulação do tempo: você joga duas peças neste turno."

        Api.Used Api.Player ->
            Just "Você já usou um poder neste turno."

        _ ->
            Nothing


status : Model -> Status
status model =
    case model.phase of
        Starting ->
            Loading

        Playing ->
            case model.state.turn of
                Api.Player ->
                    PlayerTurn

                Api.Opponent ->
                    OpponentTurn

        Over winner points ->
            Finished winner points



-- AJUDANTES


text : Piece -> String
text ( a, b ) =
    String.fromInt a ++ "|" ++ String.fromInt b


endName : End -> String
endName end =
    case end of
        LeftEnd ->
            "ponta esquerda"

        RightEnd ->
            "ponta direita"
