module Main exposing (main)

{-| Lógica da tela (parte 5).

Liga o visual (`View.elm`, parte 6) ao backend (`Api.elm`, parte 4).
Aqui ficam a seleção de peça e de ponta, o controle de turnos e as
mensagens de erro.

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
import View exposing (End(..), Hint(..), Piece, Status(..), Winner(..))


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
    | NewGame
    | OpponentThinks Int
    | GotGame Int (Result Api.Error Api.Reply)
    | GotPlay Int Api.Action (Result Api.Error Api.Reply)
    | GotOpponent Int (Result Api.Error Api.Reply)
    | GotHint Int (Result Api.Error Hint)


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
                        settle reply (playerLines action model.state reply.state) model

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
                        settle reply (opponentLines model.state reply.state) { model | retries = 0 }

                    Err error ->
                        retryOpponent error model

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
                    case placed model.state.table reply.state.table of
                        Just ( p, _ ) ->
                            Just p

                        Nothing ->
                            model.lastPlayed
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


playerLines : Api.Action -> Api.State -> Api.State -> List String
playerLines action before after =
    case action of
        Api.Place _ _ ->
            case placed before.table after.table of
                Just ( p, side ) ->
                    [ placeLine "Você" before.table p side ]

                Nothing ->
                    []

        Api.Draw ->
            case List.filter (\p -> not (List.member p before.playerHand)) after.playerHand of
                [] ->
                    [ "Você comprou do monte." ]

                bought ->
                    List.map (\p -> "Você comprou a " ++ text p ++ ".") bought

        Api.Pass ->
            [ "Você passou a vez." ]


{-| O computador pode comprar várias peças antes de jogar ou passar
(`draw_until_playable/6`). As peças dele ficam escondidas: só a quantidade
aparece.
-}
opponentLines : Api.State -> Api.State -> List String
opponentLines before after =
    let
        move =
            placed before.table after.table

        played =
            if move == Nothing then
                0

            else
                1

        bought =
            List.length after.opponentHand - List.length before.opponentHand + played

        drawLine =
            if bought == 1 then
                [ "Computador comprou 1 peça." ]

            else if bought > 1 then
                [ "Computador comprou " ++ String.fromInt bought ++ " peças." ]

            else
                []

        moveLine =
            case move of
                Just ( p, side ) ->
                    placeLine "Computador" before.table p side

                Nothing ->
                    "Computador passou a vez."
    in
    moveLine :: drawLine


placeLine : String -> List Piece -> Piece -> End -> String
placeLine who table p side =
    if List.isEmpty table then
        who ++ " abriu com " ++ text p ++ "."

    else
        who ++ " jogou " ++ text p ++ " na " ++ endName side ++ "."


{-| A peça que entrou na mesa e em qual ponta, comparando antes e depois.
-}
placed : List Piece -> List Piece -> Maybe ( Piece, End )
placed before after =
    if List.length after /= List.length before + 1 then
        Nothing

    else
        case ( before, after ) of
            ( [], p :: _ ) ->
                Just ( p, RightEnd )

            ( b :: _, a :: _ ) ->
                if a /= b then
                    Just ( a, LeftEnd )

                else
                    List.reverse after |> List.head |> Maybe.map (\p -> ( p, RightEnd ))

            _ ->
                Nothing



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
    }


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
