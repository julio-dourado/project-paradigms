module Preview exposing (main)

{-| Vitrine do visual (parte 6), só para desenvolvimento.

Mostra o `View` sem precisar do backend. "Partida nova" é uma partida de
verdade contra o computador: sorteio, turnos, compra, passe e fim de jogo.
Os outros cenários são fotos de situações para conferir o visual, e também
continuam com turnos quando você joga.

As regras copiam o `domino.pl` para a vitrine funcionar sozinha. No jogo de
verdade quem decide é o Prolog. Diferenças de propósito:

  - Aqui o jogador pode passar a vez mesmo tendo peça. O `can_pass/3` só
    deixa passar sem jogada e com o monte vazio.
  - O computador tem três níveis. O Prolog só tem um, o `choose_move/3`,
    que é o nível Difícil daqui.

-}

import Browser
import Html exposing (Html)
import Html.Attributes as HA
import Html.Events as HE
import Process
import Random
import Task
import View exposing (End(..), Hint(..), Piece, Power(..), Status(..), Winner(..))


{-| O número do cenário pode vir na URL: `preview.html#3`.
-}
main : Program Int Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = \_ -> Sub.none
        }


type alias Model =
    { scenario : Int
    , props : View.Props
    , boneyard : List Piece
    , level : Level
    , seed : Random.Seed

    -- Conta as partidas carregadas. Um "computador pensando" que chega
    -- de uma partida antiga é ignorado.
    , game : Int
    }


{-| O nível do computador. Não é inteligência artificial: é uma regra fixa
para escolher a jogada, como nos jogos antigos.
-}
type Level
    = Easy
    | Medium
    | Hard


type Msg
    = Pick Int
    | SetLevel Level
    | GotSeed Random.Seed
    | Select (Maybe Piece)
    | Play Piece End
    | DrawPiece
    | Pass
    | AskHint
    | NewGame
    | ComputerStep Int
    | Noop


init : Int -> ( Model, Cmd Msg )
init i =
    let
        model =
            { scenario = i
            , props = { base | status = Loading }
            , boneyard = []
            , level = Medium
            , seed = Random.initialSeed i
            , game = 0
            }
    in
    ( model, Random.generate GotSeed Random.independentSeed )



-- CENÁRIOS


type alias Scenario =
    { name : String
    , props : View.Props
    , boneyard : List Piece
    }


base : View.Props
base =
    { playerHand = []
    , opponentHand = []
    , table = []
    , boneyard = 0
    , status = PlayerTurn
    , selected = Nothing
    , hint = Nothing
    , lastPlayed = Nothing
    , opening = Nothing
    , log = []
    , score = noScore
    , error = Nothing
    , rivalPower = Nothing
    , powers = Nothing
    }


noScore : { player : Int, opponent : Int }
noScore =
    { player = 0, opponent = 0 }


midTable : List Piece
midTable =
    [ ( 6, 5 ), ( 5, 2 ), ( 2, 2 ), ( 2, 4 ), ( 4, 4 ), ( 4, 1 ) ]


midBoneyard : List Piece
midBoneyard =
    [ ( 0, 1 ), ( 3, 3 ), ( 0, 2 ), ( 4, 6 ), ( 1, 2 ), ( 0, 4 ), ( 1, 1 ), ( 3, 6 ), ( 0, 5 ), ( 5, 5 ), ( 6, 6 ) ]


midGame : View.Props
midGame =
    { base
        | playerHand = [ ( 0, 6 ), ( 1, 3 ), ( 3, 5 ), ( 1, 6 ), ( 0, 0 ), ( 2, 3 ) ]
        , opponentHand = [ ( 0, 3 ), ( 1, 5 ), ( 2, 6 ), ( 3, 4 ), ( 4, 5 ) ]
        , table = midTable
        , boneyard = List.length midBoneyard
        , lastPlayed = Just ( 4, 1 )
        , score = { player = 12, opponent = 7 }
        , log =
            [ "Computador jogou 4|1 na ponta direita."
            , "Você jogou 4|4 na ponta direita."
            , "Computador jogou 2|4 na ponta direita."
            , "Você jogou 5|2 na ponta direita."
            , "Computador comprou 1 peça."
            , "Você abriu com 6|5."
            ]
    }


{-| Uma cadeia com as 28 peças do duplo-seis, para testar a mesa cheia.
-}
fullChain : List Piece
fullChain =
    [ ( 0, 0 ), ( 0, 1 ), ( 1, 1 ), ( 1, 2 ), ( 2, 2 ), ( 2, 3 ), ( 3, 3 ), ( 3, 4 ), ( 4, 4 ), ( 4, 5 ), ( 5, 5 ), ( 5, 6 ), ( 6, 6 ), ( 6, 0 ), ( 0, 2 ), ( 2, 4 ), ( 4, 6 ), ( 6, 1 ), ( 1, 3 ), ( 3, 5 ), ( 5, 0 ), ( 0, 3 ), ( 3, 6 ), ( 6, 2 ), ( 2, 5 ), ( 5, 1 ), ( 1, 4 ), ( 4, 0 ) ]


{-| Painel de poderes de exemplo, só para ver o visual.
-}
demoPowers : View.PowersView
demoPowers =
    { mine = [ Freeze, Shield, Flames, Swap ]
    , usable = [ Freeze, Flames, Swap ]
    , opponentCount = 3
    , effects =
        [ "Congelamento: você não joga na ponta esquerda neste turno."
        , "Chamas: sua peça deve ter o 4, se possível."
        ]
    , revealed = []
    , moves = Nothing
    , mustDraw = Nothing
    , picking = Nothing
    }


{-| O primeiro cenário é sorteado na hora (veja `newGame`).
-}
scenarios : List Scenario
scenarios =
    [ { name = "Partida nova", props = base, boneyard = [] }
    , { name = "Meio de jogo", props = midGame, boneyard = midBoneyard }
    , { name = "Escolher a ponta", props = { midGame | selected = Just ( 1, 6 ) }, boneyard = midBoneyard }
    , { name = "Com dica", props = { midGame | hint = Just (PlayHint ( 1, 6 ) RightEnd), selected = Just ( 1, 6 ) }, boneyard = midBoneyard }
    , { name = "Sem jogada"
      , props = { midGame | playerHand = [ ( 3, 5 ), ( 0, 0 ), ( 2, 3 ) ], hint = Just DrawHint }
      , boneyard = midBoneyard
      }
    , { name = "Computador pensando", props = { midGame | status = OpponentTurn }, boneyard = midBoneyard }
    , { name = "Mesa longa"
      , props =
            { base
                | table = List.take 22 fullChain
                , playerHand = [ ( 3, 6 ), ( 1, 5 ), ( 1, 4 ) ]
                , opponentHand = [ ( 2, 6 ), ( 2, 5 ), ( 0, 4 ) ]
                , lastPlayed = Just ( 0, 3 )
                , score = { player = 31, opponent = 40 }
                , log = [ "Computador jogou 0|3 na ponta direita." ]
            }
      , boneyard = []
      }
    , { name = "Vitória"
      , props =
            { midGame
                | playerHand = []
                , opponentHand = [ ( 3, 5 ), ( 2, 4 ) ]
                , status = Finished PlayerWins 14
                , score = { player = 26, opponent = 7 }
            }
      , boneyard = midBoneyard
      }
    , { name = "Derrota no trancado"
      , props =
            { midGame
                | playerHand = [ ( 4, 5 ), ( 3, 3 ) ]
                , opponentHand = [ ( 1, 2 ) ]
                , boneyard = 0
                , status = Finished OpponentWins 15
            }
      , boneyard = []
      }
    , { name = "Empate"
      , props =
            { midGame
                | playerHand = [ ( 2, 3 ) ]
                , opponentHand = [ ( 1, 4 ) ]
                , boneyard = 0
                , status = Finished Draw 0
            }
      , boneyard = []
      }
    , { name = "Poderes"
      , props = { midGame | powers = Just demoPowers }
      , boneyard = midBoneyard
      }
    , { name = "Computador usou poder"
      , props =
            { midGame
                | powers = Just demoPowers
                , rivalPower = Just "O computador usou Congelamento: você não joga na ponta esquerda no próximo turno."
                , log =
                    "Computador jogou 0|3 na ponta direita."
                        :: "O computador usou Congelamento: você não joga na ponta esquerda no próximo turno."
                        :: midGame.log
            }
      , boneyard = midBoneyard
      }
    , { name = "Poderes: escolher a ponta"
      , props = { midGame | powers = Just { demoPowers | picking = Just Freeze } }
      , boneyard = midBoneyard
      }
    , { name = "Poderes: buchas reveladas"
      , props =
            { midGame
                | opponentHand = [ ( 3, 3 ), ( 1, 2 ), ( 5, 5 ), ( 0, 6 ) ]
                , powers = Just { demoPowers | revealed = [ ( 3, 3 ), ( 5, 5 ) ], picking = Just Flames }
            }
      , boneyard = midBoneyard
      }
    , { name = "Carregando", props = { base | status = Loading }, boneyard = [] }
    , { name = "Erro de rede"
      , props = { midGame | error = Just "Não consegui falar com o servidor em http://localhost:8000. Ele está rodando?" }
      , boneyard = midBoneyard
      }
    ]


{-| Carrega um cenário. O 0 é uma partida sorteada.
-}
load : Int -> Model -> ( Model, Cmd Msg )
load i model =
    if i == 0 then
        newGame noScore { model | scenario = 0 }

    else
        case List.head (List.drop i scenarios) of
            Just s ->
                let
                    next =
                        { model | scenario = i, props = s.props, boneyard = s.boneyard, game = model.game + 1 }
                in
                ( next
                , if s.props.status == OpponentTurn then
                    think next

                  else
                    Cmd.none
                )

            Nothing ->
                newGame noScore { model | scenario = 0 }



-- PARTIDA NOVA (new_game/5)


allPieces : List Piece
allPieces =
    List.concatMap (\a -> List.map (Tuple.pair a) (List.range a 6)) (List.range 0 6)


shuffle : List a -> Random.Generator (List a)
shuffle xs =
    Random.list (List.length xs) (Random.float 0 1)
        |> Random.map
            (\keys ->
                List.map2 Tuple.pair keys xs
                    |> List.sortBy Tuple.first
                    |> List.map Tuple.second
            )


{-| Como o `piece_rank/2`: bucha vale 100 + o número, as outras valem a soma.
-}
rank : Piece -> Int
rank ( a, b ) =
    if a == b then
        100 + a

    else
        a + b


{-| Como o `starter/4`: quem tiver a peça de maior valor começa com ela.
No empate (duas peças sem bucha com a mesma soma), o Prolog dá a vez ao
jogador, e aqui também.
-}
starter : List Piece -> List Piece -> ( Bool, Piece )
starter player opponent =
    let
        strongest hand =
            List.sortBy (\x -> negate (rank x)) hand |> List.head |> Maybe.withDefault ( 0, 0 )

        p =
            strongest player

        o =
            strongest opponent
    in
    if rank p >= rank o then
        ( True, p )

    else
        ( False, o )


newGame : { player : Int, opponent : Int } -> Model -> ( Model, Cmd Msg )
newGame score model =
    let
        ( shuffled, seed ) =
            Random.step (shuffle allPieces) model.seed

        player =
            List.take 7 shuffled |> List.sort

        opponent =
            List.take 7 (List.drop 7 shuffled)

        boneyard =
            List.drop 14 shuffled

        ( playerStarts, opening ) =
            starter player opponent

        why =
            if isDouble opening then
                ", a maior bucha"

            else
                ", a peça mais pesada (ninguém tem bucha)"

        next =
            { model
                | seed = seed
                , boneyard = boneyard
                , game = model.game + 1
                , props =
                    { base
                        | playerHand = player
                        , opponentHand = opponent
                        , boneyard = List.length boneyard
                        , opening = Just opening
                        , score = score
                        , status =
                            if playerStarts then
                                PlayerTurn

                            else
                                OpponentTurn
                        , log =
                            [ if playerStarts then
                                "Nova partida. Você tem a " ++ text opening ++ why ++ ", e abre o jogo."

                              else
                                "Nova partida. O computador tem a " ++ text opening ++ why ++ ", e abre o jogo."
                            ]
                    }
            }
    in
    ( next
    , if playerStarts then
        Cmd.none

      else
        think next
    )



-- ATUALIZAÇÃO


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    let
        props =
            model.props

        playerTurn =
            props.status == PlayerTurn
    in
    case msg of
        GotSeed seed ->
            let
                seeded =
                    { model | seed = seed }
            in
            load model.scenario seeded

        Pick i ->
            load i model

        SetLevel level ->
            ( { model | level = level }, Cmd.none )

        NewGame ->
            newGame props.score { model | scenario = 0 }

        Select choice ->
            if playerTurn then
                ( { model | props = { props | selected = choice } }, Cmd.none )

            else
                ( model, Cmd.none )

        Play piece end ->
            if playerTurn && List.member end (fitsFor props.opening props.table piece) then
                let
                    ( table, placed ) =
                        place end piece props.table

                    line =
                        if List.isEmpty props.table then
                            "Você abriu com " ++ text placed ++ "."

                        else
                            "Você jogou " ++ text placed ++ " na " ++ endName end ++ "."
                in
                endPlayerTurn model
                    { props
                        | playerHand = remove piece props.playerHand
                        , table = table
                        , lastPlayed = Just placed
                        , selected = Nothing
                        , hint = Nothing
                        , log = line :: props.log
                    }

            else
                ( model, Cmd.none )

        DrawPiece ->
            case model.boneyard of
                p :: rest ->
                    if playerTurn && List.isEmpty (moves props.opening props.table props.playerHand) then
                        ( { model
                            | boneyard = rest
                            , props =
                                { props
                                    | playerHand = props.playerHand ++ [ p ]
                                    , boneyard = List.length rest
                                    , hint = Nothing
                                    , log = ("Você comprou a " ++ text p ++ ".") :: props.log
                                }
                          }
                        , Cmd.none
                        )

                    else
                        ( model, Cmd.none )

                [] ->
                    ( model, Cmd.none )

        Pass ->
            if playerTurn && not (List.isEmpty props.table) then
                endPlayerTurn model
                    { props | selected = Nothing, hint = Nothing, log = "Você passou a vez." :: props.log }

            else
                ( model, Cmd.none )

        AskHint ->
            let
                -- Como o hint/4: a jogada que o computador faria no seu lugar.
                hint =
                    case best moveScore props.opening props.table props.playerHand of
                        Just ( p, e ) ->
                            PlayHint p e

                        Nothing ->
                            if List.isEmpty model.boneyard then
                                PassHint

                            else
                                DrawHint
            in
            ( { model | props = { props | hint = Just hint } }, Cmd.none )

        Noop ->
            ( model, Cmd.none )

        ComputerStep game ->
            if game == model.game && props.status == OpponentTurn then
                computerStep model

            else
                ( model, Cmd.none )


{-| Depois da jogada (ou do passe) do jogador: acabou a partida ou é a vez
do computador.
-}
endPlayerTurn : Model -> View.Props -> ( Model, Cmd Msg )
endPlayerTurn model props =
    case outcome props model.boneyard of
        Just result ->
            ( { model | props = finish result props }, Cmd.none )

        Nothing ->
            let
                next =
                    { model | props = { props | status = OpponentTurn } }
            in
            ( next, think next )


{-| A pausa de "computador pensando" antes de cada passo dele.
-}
think : Model -> Cmd Msg
think model =
    wait 1100 model


wait : Float -> Model -> Cmd Msg
wait ms model =
    Process.sleep ms |> Task.perform (\_ -> ComputerStep model.game)


{-| Um passo do computador. Como no `draw_until_playable/6`, ele compra até
ter jogada, uma peça por passo para dar para ver o monte diminuindo. Sem
jogada e sem monte, passa a vez.
-}
computerStep : Model -> ( Model, Cmd Msg )
computerStep model =
    let
        props =
            model.props

        hand =
            props.opponentHand

        ( choice, seed ) =
            choose model.level model.seed props.opening props.table hand
    in
    case ( choice, model.boneyard ) of
        ( Just ( piece, end ), _ ) ->
            let
                ( table, placed ) =
                    place end piece props.table

                line =
                    if List.isEmpty props.table then
                        "Computador abriu com " ++ text placed ++ "."

                    else
                        "Computador jogou " ++ text placed ++ " na " ++ endName end ++ "."
            in
            endComputerTurn { model | seed = seed }
                { props
                    | opponentHand = remove piece hand
                    , table = table
                    , lastPlayed = Just placed
                    , log = line :: props.log
                }

        ( Nothing, p :: rest ) ->
            let
                next =
                    { model
                        | seed = seed
                        , boneyard = rest
                        , props =
                            { props
                                | opponentHand = hand ++ [ p ]
                                , boneyard = List.length rest
                                , log = "Computador comprou 1 peça." :: props.log
                            }
                    }
            in
            ( next, wait 650 next )

        ( Nothing, [] ) ->
            endComputerTurn { model | seed = seed } { props | log = "Computador passou a vez." :: props.log }


endComputerTurn : Model -> View.Props -> ( Model, Cmd Msg )
endComputerTurn model props =
    case outcome props model.boneyard of
        Just result ->
            ( { model | props = finish result props }, Cmd.none )

        Nothing ->
            ( { model | props = { props | status = PlayerTurn } }, Cmd.none )



-- REGRAS (copiadas do domino.pl)


{-| Onde a peça encaixa, como no `fits/3`. Com a mesa vazia, só a peça de
abertura entra.
-}
fitsFor : Maybe Piece -> List Piece -> Piece -> List End
fitsFor opening table ( a, b ) =
    case ( ends table, opening ) of
        ( Nothing, Just o ) ->
            if same o ( a, b ) then
                [ RightEnd ]

            else
                []

        ( Nothing, Nothing ) ->
            [ RightEnd ]

        ( Just ( l, r ), _ ) ->
            List.filterMap identity
                [ if a == l || b == l then
                    Just LeftEnd

                  else
                    Nothing
                , if a == r || b == r then
                    Just RightEnd

                  else
                    Nothing
                ]


{-| Todas as jogadas da mão, como no `valid_moves/3`.
-}
moves : Maybe Piece -> List Piece -> List Piece -> List ( Piece, End )
moves opening table hand =
    List.concatMap (\p -> List.map (Tuple.pair p) (fitsFor opening table p)) hand


ends : List Piece -> Maybe ( Int, Int )
ends table =
    case ( List.head table, List.head (List.reverse table) ) of
        ( Just ( l, _ ), Just ( _, r ) ) ->
            Just ( l, r )

        _ ->
            Nothing


{-| Coloca a peça na mesa já virada, como no `play_piece/6`.
-}
place : End -> Piece -> List Piece -> ( List Piece, Piece )
place end ( a, b ) table =
    case ( ends table, end ) of
        ( Nothing, _ ) ->
            ( [ ( a, b ) ], ( a, b ) )

        ( Just ( l, _ ), LeftEnd ) ->
            let
                p =
                    if b == l then
                        ( a, b )

                    else
                        ( b, a )
            in
            ( p :: table, p )

        ( Just ( _, r ), RightEnd ) ->
            let
                p =
                    if a == r then
                        ( a, b )

                    else
                        ( b, a )
            in
            ( table ++ [ p ], p )


{-| Como o `game_over/6`: batida ou jogo trancado.
-}
outcome : View.Props -> List Piece -> Maybe ( Winner, Int )
outcome props boneyard =
    let
        stuck hand =
            List.isEmpty (moves Nothing props.table hand)

        pp =
            points props.playerHand

        op =
            points props.opponentHand
    in
    if List.isEmpty props.playerHand then
        Just ( PlayerWins, op )

    else if List.isEmpty props.opponentHand then
        Just ( OpponentWins, pp )

    else if List.isEmpty boneyard && not (List.isEmpty props.table) && stuck props.playerHand && stuck props.opponentHand then
        if pp < op then
            Just ( PlayerWins, op )

        else if pp > op then
            Just ( OpponentWins, pp )

        else
            Just ( Draw, 0 )

    else
        Nothing


finish : ( Winner, Int ) -> View.Props -> View.Props
finish ( winner, pts ) props =
    let
        score =
            props.score

        line =
            case winner of
                PlayerWins ->
                    "Fim: você venceu e marcou " ++ String.fromInt pts ++ " pontos."

                OpponentWins ->
                    "Fim: o computador venceu e marcou " ++ String.fromInt pts ++ " pontos."

                Draw ->
                    "Fim: jogo trancado e empatado."
    in
    { props
        | status = Finished winner pts
        , selected = Nothing
        , hint = Nothing
        , log = line :: props.log
        , score =
            case winner of
                PlayerWins ->
                    { score | player = score.player + pts }

                OpponentWins ->
                    { score | opponent = score.opponent + pts }

                Draw ->
                    score
    }



-- ALGORITMO DO COMPUTADOR


{-| Escolhe a jogada do computador conforme o nível:

  - Fácil: sorteia qualquer peça que encaixa.
  - Médio: joga a peça mais pesada, para não ficar com pontos na mão.
  - Difícil: a mesma nota do `move_score/4` do Prolog (pontos da peça,
    +5 se for bucha, +2 por peça que continua jogável depois).

Sem jogada, devolve `Nothing` e o computador compra ou passa.

-}
choose : Level -> Random.Seed -> Maybe Piece -> List Piece -> List Piece -> ( Maybe ( Piece, End ), Random.Seed )
choose level seed opening table hand =
    case level of
        Easy ->
            let
                options =
                    moves opening table hand

                ( i, next ) =
                    Random.step (Random.int 0 (List.length options - 1)) seed
            in
            ( List.head (List.drop i options), next )

        Medium ->
            ( best (\_ _ ( ( a, b ), _ ) -> a + b) opening table hand, seed )

        Hard ->
            ( best moveScore opening table hand, seed )


{-| A jogada de maior nota. No empate fica a primeira, como no `keysort`
do `choose_move/3`.
-}
best : (List Piece -> List Piece -> ( Piece, End ) -> Int) -> Maybe Piece -> List Piece -> List Piece -> Maybe ( Piece, End )
best score opening table hand =
    moves opening table hand
        |> List.foldl
            (\m acc ->
                let
                    s =
                        score table hand m
                in
                case acc of
                    Just ( _, top ) ->
                        if s > top then
                            Just ( m, s )

                        else
                            acc

                    Nothing ->
                        Just ( m, s )
            )
            Nothing
        |> Maybe.map Tuple.first


{-| A nota do `move_score/4`.
-}
moveScore : List Piece -> List Piece -> ( Piece, End ) -> Int
moveScore table hand ( piece, end ) =
    let
        ( a, b ) =
            piece

        ( newTable, _ ) =
            place end piece table

        newHand =
            remove piece hand

        options =
            List.filter (\p -> not (List.isEmpty (fitsFor Nothing newTable p))) newHand
    in
    a
        + b
        + (if a == b then
            5

           else
            0
          )
        + 2
        * List.length options



-- AJUDANTES


remove : Piece -> List Piece -> List Piece
remove piece =
    List.filter (\p -> not (same p piece))


same : Piece -> Piece -> Bool
same ( a, b ) ( c, d ) =
    (a == c && b == d) || (a == d && b == c)


isDouble : Piece -> Bool
isDouble ( a, b ) =
    a == b


points : List Piece -> Int
points =
    List.foldl (\( a, b ) acc -> acc + a + b) 0


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



-- TELA


view : Model -> Html Msg
view model =
    Html.div []
        [ Html.nav [ HA.class "vitrine", HA.attribute "aria-label" "Cenários" ]
            (Html.span [ HA.class "vitrine__titulo" ] [ Html.text "Vitrine do visual" ]
                :: List.indexedMap
                    (\i s -> chip (i == model.scenario) (Pick i) s.name)
                    scenarios
            )
        , Html.nav [ HA.class "vitrine", HA.attribute "aria-label" "Nível do computador" ]
            (Html.span [ HA.class "vitrine__titulo" ] [ Html.text "Nível do computador" ]
                :: List.map
                    (\( level, name ) -> chip (level == model.level) (SetLevel level) name)
                    [ ( Easy, "Fácil" ), ( Medium, "Médio" ), ( Hard, "Difícil" ) ]
            )
        , View.view
            { onSelect = Select
            , onPlay = Play
            , onDraw = DrawPiece
            , onPass = Pass
            , onHint = AskHint
            , onNewGame = NewGame
            , onPowerPick = \_ -> Noop
            , onPowerUse = \_ _ -> Noop
            }
            model.props
        ]


chip : Bool -> Msg -> String -> Html Msg
chip active msg label =
    Html.button
        [ HA.classList [ ( "vitrine__botao", True ), ( "vitrine__botao--ativo", active ) ]
        , HA.attribute "aria-pressed"
            (if active then
                "true"

             else
                "false"
            )
        , HE.onClick msg
        ]
        [ Html.text label ]
