module Preview exposing (main)

{-| Vitrine do visual (parte 6), só para desenvolvimento.

Mostra o `View` em vários cenários sem precisar do backend. Dá para clicar
nas peças, escolher a ponta, comprar e pedir dica, mas o computador não joga:
as regras de verdade ficam no Prolog. Aqui só tem o mínimo para mexer na tela.

-}

import Browser
import Html exposing (Html)
import Html.Attributes as HA
import Html.Events as HE
import View exposing (End(..), Hint(..), Piece, Status(..), Winner(..))


{-| O número do cenário pode vir na URL: `preview.html#3`.
-}
main : Program Int Model Msg
main =
    Browser.element
        { init = \i -> ( load i, Cmd.none )
        , update = \msg model -> ( update msg model, Cmd.none )
        , view = view
        , subscriptions = \_ -> Sub.none
        }


type alias Model =
    { scenario : Int
    , props : View.Props
    , boneyard : List Piece
    }


type Msg
    = Pick Int
    | Select (Maybe Piece)
    | Play Piece End
    | DrawPiece
    | Pass
    | AskHint
    | NewGame



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
    , log = []
    , score = { player = 0, opponent = 0 }
    , error = Nothing
    }


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


scenarios : List Scenario
scenarios =
    [ { name = "Início"
      , props =
            { base
                | playerHand = [ ( 1, 4 ), ( 2, 6 ), ( 0, 3 ), ( 5, 5 ), ( 3, 4 ), ( 1, 1 ), ( 2, 5 ) ]
                , opponentHand = [ ( 0, 0 ), ( 1, 2 ), ( 3, 6 ), ( 4, 4 ), ( 0, 5 ), ( 2, 3 ), ( 1, 6 ) ]
                , boneyard = 14
                , log = [ "Nova partida. Você começa." ]
            }
      , boneyard = [ ( 0, 1 ), ( 0, 2 ), ( 0, 4 ), ( 0, 6 ), ( 1, 3 ), ( 1, 5 ), ( 2, 2 ), ( 2, 4 ), ( 3, 3 ), ( 3, 5 ), ( 4, 5 ), ( 4, 6 ), ( 5, 6 ), ( 6, 6 ) ]
      }
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
    , { name = "Carregando", props = { base | status = Loading }, boneyard = [] }
    , { name = "Erro de rede"
      , props = { midGame | error = Just "Não consegui falar com o servidor em http://localhost:8000. Ele está rodando?" }
      , boneyard = midBoneyard
      }
    ]


load : Int -> Model
load i =
    case List.head (List.drop i scenarios) of
        Just s ->
            { scenario = i, props = s.props, boneyard = s.boneyard }

        Nothing ->
            { scenario = 0, props = base, boneyard = [] }



-- ATUALIZAÇÃO (só o bastante para a vitrine)


update : Msg -> Model -> Model
update msg model =
    let
        props =
            model.props
    in
    case msg of
        Pick i ->
            load i

        NewGame ->
            load 0

        Select choice ->
            { model | props = { props | selected = choice } }

        Play piece end ->
            let
                hand =
                    List.filter (\p -> not (same p piece)) props.playerHand

                ( table, placed ) =
                    place end piece props.table

                status =
                    if List.isEmpty hand then
                        Finished PlayerWins (points props.opponentHand)

                    else
                        PlayerTurn
            in
            { model
                | props =
                    { props
                        | playerHand = hand
                        , table = table
                        , lastPlayed = Just placed
                        , selected = Nothing
                        , hint = Nothing
                        , status = status
                        , log = ("Você jogou " ++ text placed ++ " na " ++ endName end ++ ".") :: props.log
                    }
            }

        DrawPiece ->
            case model.boneyard of
                p :: rest ->
                    { model
                        | boneyard = rest
                        , props =
                            { props
                                | playerHand = props.playerHand ++ [ p ]
                                , boneyard = List.length rest
                                , hint = Nothing
                                , log = "Você comprou 1 peça." :: props.log
                            }
                    }

                [] ->
                    model

        Pass ->
            { model | props = { props | hint = Nothing, log = "Você passou a vez." :: props.log } }

        AskHint ->
            let
                hint =
                    case List.filterMap (\p -> Maybe.map (Tuple.pair p) (firstEnd props.table p)) props.playerHand of
                        ( p, e ) :: _ ->
                            PlayHint p e

                        [] ->
                            if List.isEmpty model.boneyard then
                                PassHint

                            else
                                DrawHint
            in
            { model | props = { props | hint = Just hint } }


place : End -> Piece -> List Piece -> ( List Piece, Piece )
place end ( a, b ) table =
    case ( table, end ) of
        ( [], _ ) ->
            ( [ ( a, b ) ], ( a, b ) )

        ( ( l, _ ) :: _, LeftEnd ) ->
            let
                p =
                    if b == l then
                        ( a, b )

                    else
                        ( b, a )
            in
            ( p :: table, p )

        ( _, RightEnd ) ->
            let
                r =
                    List.reverse table |> List.head |> Maybe.map Tuple.second |> Maybe.withDefault a

                p =
                    if a == r then
                        ( a, b )

                    else
                        ( b, a )
            in
            ( table ++ [ p ], p )


firstEnd : List Piece -> Piece -> Maybe End
firstEnd table ( a, b ) =
    case ( List.head table, List.head (List.reverse table) ) of
        ( Just ( l, _ ), Just ( _, r ) ) ->
            if a == r || b == r then
                Just RightEnd

            else if a == l || b == l then
                Just LeftEnd

            else
                Nothing

        _ ->
            Just RightEnd


same : Piece -> Piece -> Bool
same ( a, b ) ( c, d ) =
    (a == c && b == d) || (a == d && b == c)


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
                    (\i s ->
                        Html.button
                            [ HA.classList [ ( "vitrine__botao", True ), ( "vitrine__botao--ativo", i == model.scenario ) ]
                            , HE.onClick (Pick i)
                            ]
                            [ Html.text s.name ]
                    )
                    scenarios
            )
        , View.view
            { onSelect = Select
            , onPlay = Play
            , onDraw = DrawPiece
            , onPass = Pass
            , onHint = AskHint
            , onNewGame = NewGame
            }
            model.props
        ]
