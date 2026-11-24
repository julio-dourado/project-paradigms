module Api exposing
    ( State, Turn(..), Action(..), Effect(..), Reply, Event, PowerEvent, Error(..)
    , newGame, play, usePower, opponentMove, hint
    , errorMessage
    )

{-| Conversa com o backend (FastAPI + Prolog).

**Provisório.** Esta é a parte 4 (Bruno). Este módulo foi escrito junto com a
parte 5 (`Main.elm`) só para a tela funcionar de ponta a ponta. A parte 4
pode reescrever tudo por dentro, desde que mantenha o que o `Main` usa:
os tipos abaixo e as funções `newGame`, `play`, `opponentMove`, `hint` e
`errorMessage`.

Os tipos de peça, ponta, dica e vencedor são os do `View.elm`, para não
haver duas versões da mesma coisa. Se a parte 4 criar o `Domino.elm`, eles
podem ir para lá.


# Contrato HTTP

Todas as rotas são `POST` e devolvem JSON. O estado vai e volta inteiro:
o backend não guarda nada entre uma chamada e outra.

| Rota             | Corpo                    | Resposta          |
|------------------|--------------------------|-------------------|
| `/new-game`      | (vazio)                  | `Reply`           |
| `/play`          | `{"state", "action"}`    | `Reply`           |
| `/power`         | `{"state", "power", "arg"}` | `Reply`        |
| `/opponent-move` | `{"state"}`              | `Reply`           |
| `/hint`          | `{"state"}`              | `{"hint": ...}`   |

`action` e `hint` têm o mesmo formato do `hint/4`: `[[2,4],"right"]`,
`"draw"` ou `"pass"`.

`Reply`:

    { "state": { "player_hand": [[0,1]], "opponent_hand": [[3,3]],
                 "table": [[6,5],[5,2]], "boneyard": [[0,0]],
                 "turn": "player",
                 "player_powers": ["freeze"], "opponent_powers": ["shield"],
                 "effects": [["freeze", "opponent", "left"]] },
      "start_piece": [6,6],                          -- só no new-game
      "result": {"winner": "player", "points": 14},  -- null enquanto há jogo
      "player_moves": [[[0,1], "left"]],             -- jogadas permitidas agora
      "must_draw": false, "usable_powers": ["freeze"], "revealed": [],
      "event": {"type": "play", "who": "opponent", "piece": [1,2], "side": "left",
                "drawn": [], "power": {"name": "time", "outcome": "applied"}}
    }

Os campos de poderes são opcionais: sem eles (um backend sem poderes) a tela
usa só a regra de encaixe simples.

Jogada inválida: HTTP 400 com `{"detail": "frase para o jogador"}`, como o
`HTTPException` do FastAPI. A frase aparece na tela.

-}

import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import View exposing (End(..), Hint(..), Piece, Power(..), PowerArg(..), Winner)



-- TIPOS


{-| A partida como o backend devolve.
-}
type alias State =
    { playerHand : List Piece
    , opponentHand : List Piece
    , table : List Piece
    , boneyard : List Piece
    , turn : Turn
    , playerPowers : List Power
    , opponentPowers : List Power
    , effects : List Effect
    }


type Turn
    = Player
    | Opponent


{-| Efeito de poder ainda ativo (`effects` no estado). O backend decide o
que cada um faz; a tela só os mostra e os devolve como recebeu.
-}
type Effect
    = Frozen Turn End
    | Burning Turn Int
    | Cursed Turn
    | CurseDue Turn
    | ExtraPlay Turn
    | Used Turn
    | Revealed Turn (List Piece)


{-| O que o jogador faz na vez dele.
-}
type Action
    = Place Piece End
    | Draw
    | Pass


{-| Resposta das rotas que mexem na partida.

  - `startPiece`: a `StartPiece` do `new_game/5` (só vem no `new-game`).
  - `outcome`: o `game_over/6`; `Nothing` enquanto a partida continua.
  - `moves`: as jogadas permitidas ao jogador agora (`legal_moves/3`), com
    congelamento e chamas; `Nothing` se o backend não manda.
  - `mustDraw`: `must_draw/2`; `usable`: poderes que dá para usar agora;
    `revealed`: buchas do computador mostradas pela Sobrecarga.
  - `event`: o que acabou de acontecer, para o lance a lance.

-}
type alias Reply =
    { state : State
    , startPiece : Maybe Piece
    , outcome : Maybe ( Winner, Int )
    , moves : Maybe (List ( Piece, End ))
    , mustDraw : Maybe Bool
    , usable : List Power
    , revealed : List Piece
    , event : Event
    }


{-| `played`: peças jogadas no lance, na ordem (duas com a Manipulação do
tempo); `drawn`: quantas o computador comprou; `power`: o poder usado.
-}
type alias Event =
    { played : List ( Piece, End )
    , drawn : Int
    , power : Maybe PowerEvent
    }


{-| Poder usado. `outcome`: `applied`, `shielded` (o Escudo anulou),
`swapped` (com `gave` e `got`, só nas trocas do jogador) ou `revealed`.
`arg` é a ponta ou o número escolhido, como texto.
-}
type alias PowerEvent =
    { who : Turn
    , power : Power
    , arg : Maybe String
    , outcome : String
    , gave : Maybe Piece
    , got : Maybe Piece
    , revealed : List Piece
    }


type Error
    = Network
    | Timeout
    | Rejected (Maybe String)
    | ServerError Int
    | BadJson String



-- ROTAS


newGame : String -> (Result Error Reply -> msg) -> Cmd msg
newGame api toMsg =
    post api "/new-game" Http.emptyBody (expectJson toMsg reply)


play : String -> State -> Action -> (Result Error Reply -> msg) -> Cmd msg
play api state action toMsg =
    post api
        "/play"
        (Http.jsonBody (Encode.object [ ( "state", encodeState state ), ( "action", encodeAction action ) ]))
        (expectJson toMsg reply)


usePower : String -> State -> Power -> PowerArg -> (Result Error Reply -> msg) -> Cmd msg
usePower api state chosen arg toMsg =
    post api
        "/power"
        (Http.jsonBody
            (Encode.object
                [ ( "state", encodeState state )
                , ( "power", Encode.string (powerCode chosen) )
                , ( "arg", encodeArg arg )
                ]
            )
        )
        (expectJson toMsg reply)


opponentMove : String -> State -> (Result Error Reply -> msg) -> Cmd msg
opponentMove api state toMsg =
    post api "/opponent-move" (stateBody state) (expectJson toMsg reply)


hint : String -> State -> (Result Error Hint -> msg) -> Cmd msg
hint api state toMsg =
    post api "/hint" (stateBody state) (expectJson toMsg (Decode.field "hint" hintDecoder))


post : String -> String -> Http.Body -> Http.Expect msg -> Cmd msg
post api path body expect =
    Http.request
        { method = "POST"
        , headers = []
        , url = api ++ path
        , body = body
        , expect = expect
        , timeout = Just 10000
        , tracker = Nothing
        }


stateBody : State -> Http.Body
stateBody state =
    Http.jsonBody (Encode.object [ ( "state", encodeState state ) ])



-- ERROS


{-| Frase para o jogador. `api` é o endereço do servidor.
-}
errorMessage : String -> Error -> String
errorMessage api error =
    case error of
        Network ->
            "Não consegui falar com o servidor em " ++ api ++ ". Ele está rodando?"

        Timeout ->
            "O servidor demorou demais para responder. Tente de novo."

        Rejected (Just detail) ->
            detail

        Rejected Nothing ->
            "O servidor recusou essa jogada."

        ServerError code ->
            "O servidor teve um problema (erro " ++ String.fromInt code ++ "). Tente de novo."

        BadJson _ ->
            "A resposta do servidor veio num formato que a tela não entende."


{-| Como `Http.expectJson`, mas guarda o `detail` das respostas 4xx.
-}
expectJson : (Result Error a -> msg) -> Decoder a -> Http.Expect msg
expectJson toMsg decoder =
    Http.expectStringResponse toMsg <|
        \response ->
            case response of
                Http.BadUrl_ _ ->
                    Err Network

                Http.Timeout_ ->
                    Err Timeout

                Http.NetworkError_ ->
                    Err Network

                Http.BadStatus_ meta body ->
                    if meta.statusCode < 500 then
                        Err (Rejected (Result.toMaybe (Decode.decodeString (Decode.field "detail" Decode.string) body)))

                    else
                        Err (ServerError meta.statusCode)

                Http.GoodStatus_ _ body ->
                    Decode.decodeString decoder body
                        |> Result.mapError (BadJson << Decode.errorToString)



-- JSON: ENTRADA


reply : Decoder Reply
reply =
    Decode.map8 Reply
        (Decode.field "state" stateDecoder)
        (optional "start_piece" (Decode.map Just piece) Nothing)
        (optional "result" (Decode.map Just outcome) Nothing)
        (optional "player_moves" (Decode.map Just (Decode.list move)) Nothing)
        (optional "must_draw" (Decode.map Just Decode.bool) Nothing)
        (optional "usable_powers" (Decode.list power) [])
        (optional "revealed" (Decode.list piece) [])
        (optional "event" eventDecoder noEvent)


stateDecoder : Decoder State
stateDecoder =
    Decode.map8 State
        (Decode.field "player_hand" (Decode.list piece))
        (Decode.field "opponent_hand" (Decode.list piece))
        (Decode.field "table" (Decode.list piece))
        (Decode.field "boneyard" (Decode.list piece))
        (Decode.field "turn" turn)
        (optional "player_powers" (Decode.list power) [])
        (optional "opponent_powers" (Decode.list power) [])
        (optional "effects" (Decode.list effect) [])


{-| `[[2,4], "right"]`: uma jogada `[peça, ponta]`.
-}
move : Decoder ( Piece, End )
move =
    Decode.map2 Tuple.pair (Decode.index 0 piece) (Decode.index 1 end)


noEvent : Event
noEvent =
    { played = [], drawn = 0, power = Nothing }


{-| O `event` que o backend manda. Quase tudo é opcional: o evento de
compra, por exemplo, não tem peça jogada.
-}
eventDecoder : Decoder Event
eventDecoder =
    optional "who" turn Opponent
        |> Decode.andThen
            (\who ->
                Decode.map3 Event
                    (Decode.map2 (\first extra -> List.filterMap identity [ first, extra ])
                        (Decode.maybe placement)
                        (optional "extra" (Decode.map Just placement) Nothing)
                    )
                    (optional "drawn" (Decode.map List.length (Decode.list piece)) 0)
                    (optional "power" (Decode.map Just (powerEventDecoder who)) Nothing)
            )


{-| Uma jogada do evento: `{"piece": [..], "side": ".."}`.
-}
placement : Decoder ( Piece, End )
placement =
    Decode.map2 Tuple.pair (Decode.field "piece" piece) (Decode.field "side" end)


powerEventDecoder : Turn -> Decoder PowerEvent
powerEventDecoder who =
    Decode.map6 (PowerEvent who)
        (Decode.field "name" power)
        (optional "arg" argText Nothing)
        (Decode.field "outcome" Decode.string)
        (optional "gave" (Decode.map Just piece) Nothing)
        (optional "got" (Decode.map Just piece) Nothing)
        (optional "revealed" (Decode.list piece) [])


{-| O argumento do poder como texto: `"left"`, `3`. Peça ou `null` viram `Nothing`.
-}
argText : Decoder (Maybe String)
argText =
    Decode.oneOf
        [ Decode.map Just Decode.string
        , Decode.map (\n -> Just (String.fromInt n)) Decode.int
        , Decode.succeed Nothing
        ]


power : Decoder Power
power =
    atom powerCodes


powerCodes : List ( String, Power )
powerCodes =
    [ ( "freeze", Freeze )
    , ( "curse", Curse )
    , ( "overload", Overload )
    , ( "shield", Shield )
    , ( "recovery", Recovery )
    , ( "teleport", Teleport )
    , ( "time", TimeWarp )
    , ( "swap", Swap )
    , ( "flames", Flames )
    ]


powerCode : Power -> String
powerCode chosen =
    case List.filter (\( _, p ) -> p == chosen) powerCodes of
        ( code, _ ) :: _ ->
            code

        [] ->
            ""


{-| Efeitos do estado, como listas: `["freeze","opponent","left"]`.
-}
effect : Decoder Effect
effect =
    Decode.index 0 Decode.string
        |> Decode.andThen
            (\kind ->
                case kind of
                    "freeze" ->
                        Decode.map2 Frozen (Decode.index 1 turn) (Decode.index 2 end)

                    "flames" ->
                        Decode.map2 Burning (Decode.index 1 turn) (Decode.index 2 Decode.int)

                    "curse" ->
                        Decode.map Cursed (Decode.index 1 turn)

                    "curse_due" ->
                        Decode.map CurseDue (Decode.index 1 turn)

                    "time" ->
                        Decode.map ExtraPlay (Decode.index 1 turn)

                    "used" ->
                        Decode.map Used (Decode.index 1 turn)

                    "revealed" ->
                        Decode.map2 Revealed (Decode.index 1 turn) (Decode.index 2 (Decode.list piece))

                    _ ->
                        Decode.fail ("efeito inesperado: " ++ kind)
            )


{-| `[3,5]` vira `( 3, 5 )`, sem mudar a ordem (na mesa ela importa).
-}
piece : Decoder Piece
piece =
    Decode.list Decode.int
        |> Decode.andThen
            (\xs ->
                case xs of
                    [ a, b ] ->
                        Decode.succeed ( a, b )

                    _ ->
                        Decode.fail "peça precisa ter dois números"
            )


turn : Decoder Turn
turn =
    atom [ ( "player", Player ), ( "opponent", Opponent ) ]


end : Decoder End
end =
    atom [ ( "left", LeftEnd ), ( "right", RightEnd ) ]


hintDecoder : Decoder Hint
hintDecoder =
    Decode.oneOf
        [ Decode.map2 PlayHint (Decode.index 0 piece) (Decode.index 1 end)
        , atom [ ( "draw", DrawHint ), ( "pass", PassHint ) ]
        ]


outcome : Decoder ( Winner, Int )
outcome =
    Decode.map2 Tuple.pair
        (Decode.field "winner" (atom [ ( "player", View.PlayerWins ), ( "opponent", View.OpponentWins ), ( "draw", View.Draw ) ]))
        (Decode.field "points" Decode.int)


{-| Um átomo do Prolog, que chega como string.
-}
atom : List ( String, a ) -> Decoder a
atom options =
    Decode.string
        |> Decode.andThen
            (\s ->
                case List.filter (\( name, _ ) -> name == s) options of
                    ( _, value ) :: _ ->
                        Decode.succeed value

                    [] ->
                        Decode.fail ("átomo inesperado: " ++ s)
            )


{-| Campo que pode faltar ou vir `null`. Se vier com outro formato, é erro.
-}
optional : String -> Decoder a -> a -> Decoder a
optional name decoder default =
    Decode.maybe (Decode.field name Decode.value)
        |> Decode.andThen
            (\found ->
                case found of
                    Nothing ->
                        Decode.succeed default

                    Just _ ->
                        Decode.field name (Decode.oneOf [ Decode.null default, decoder ])
            )



-- JSON: SAÍDA


encodeState : State -> Encode.Value
encodeState state =
    Encode.object
        [ ( "player_hand", Encode.list encodePiece state.playerHand )
        , ( "opponent_hand", Encode.list encodePiece state.opponentHand )
        , ( "table", Encode.list encodePiece state.table )
        , ( "boneyard", Encode.list encodePiece state.boneyard )
        , ( "turn", encodeTurn state.turn )
        , ( "player_powers", Encode.list (\p -> Encode.string (powerCode p)) state.playerPowers )
        , ( "opponent_powers", Encode.list (\p -> Encode.string (powerCode p)) state.opponentPowers )
        , ( "effects", Encode.list encodeEffect state.effects )
        ]


encodeTurn : Turn -> Encode.Value
encodeTurn who =
    Encode.string
        (case who of
            Player ->
                "player"

            Opponent ->
                "opponent"
        )


encodeEnd : End -> Encode.Value
encodeEnd side =
    Encode.string
        (case side of
            LeftEnd ->
                "left"

            RightEnd ->
                "right"
        )


encodeEffect : Effect -> Encode.Value
encodeEffect e =
    case e of
        Frozen who side ->
            Encode.list identity [ Encode.string "freeze", encodeTurn who, encodeEnd side ]

        Burning who n ->
            Encode.list identity [ Encode.string "flames", encodeTurn who, Encode.int n ]

        Cursed who ->
            Encode.list identity [ Encode.string "curse", encodeTurn who ]

        CurseDue who ->
            Encode.list identity [ Encode.string "curse_due", encodeTurn who ]

        ExtraPlay who ->
            Encode.list identity [ Encode.string "time", encodeTurn who ]

        Used who ->
            Encode.list identity [ Encode.string "used", encodeTurn who ]

        Revealed who pieces ->
            Encode.list identity [ Encode.string "revealed", encodeTurn who, Encode.list encodePiece pieces ]


encodeArg : PowerArg -> Encode.Value
encodeArg arg =
    case arg of
        NoArg ->
            Encode.null

        EndArg side ->
            encodeEnd side

        NumberArg n ->
            Encode.int n

        PieceArg p ->
            encodePiece p


encodePiece : Piece -> Encode.Value
encodePiece ( a, b ) =
    Encode.list Encode.int [ a, b ]


encodeAction : Action -> Encode.Value
encodeAction action =
    case action of
        Place p side ->
            Encode.list identity
                [ encodePiece p
                , Encode.string
                    (case side of
                        LeftEnd ->
                            "left"

                        RightEnd ->
                            "right"
                    )
                ]

        Draw ->
            Encode.string "draw"

        Pass ->
            Encode.string "pass"
