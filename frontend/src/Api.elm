module Api exposing
    ( State, Turn(..), Action(..), Reply, Error(..)
    , newGame, play, opponentMove, hint
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
| `/opponent-move` | `{"state"}`              | `Reply`           |
| `/hint`          | `{"state"}`              | `{"hint": ...}`   |

`action` e `hint` têm o mesmo formato do `hint/4`: `[[2,4],"right"]`,
`"draw"` ou `"pass"`.

`Reply`:

    { "state": { "player_hand": [[0,1]], "opponent_hand": [[3,3]],
                 "table": [[6,5],[5,2]], "boneyard": [[0,0]],
                 "turn": "player" },
      "start_piece": [6,6],                          -- só no new-game
      "result": {"winner": "player", "points": 14}   -- null enquanto há jogo
    }

Jogada inválida: HTTP 400 com `{"detail": "frase para o jogador"}`, como o
`HTTPException` do FastAPI. A frase aparece na tela.

-}

import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import View exposing (End(..), Hint(..), Piece, Winner)



-- TIPOS


{-| A partida como o backend devolve.
-}
type alias State =
    { playerHand : List Piece
    , opponentHand : List Piece
    , table : List Piece
    , boneyard : List Piece
    , turn : Turn
    }


type Turn
    = Player
    | Opponent


{-| O que o jogador faz na vez dele.
-}
type Action
    = Place Piece End
    | Draw
    | Pass


{-| Resposta das rotas que mexem na partida.

  - `startPiece`: a `StartPiece` do `new_game/5` (só vem no `new-game`).
  - `outcome`: o `game_over/6`; `Nothing` enquanto a partida continua.

-}
type alias Reply =
    { state : State
    , startPiece : Maybe Piece
    , outcome : Maybe ( Winner, Int )
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
    Decode.map3 Reply
        (Decode.field "state" stateDecoder)
        (optional "start_piece" (Decode.map Just piece) Nothing)
        (optional "result" (Decode.map Just outcome) Nothing)


stateDecoder : Decoder State
stateDecoder =
    Decode.map5 State
        (Decode.field "player_hand" (Decode.list piece))
        (Decode.field "opponent_hand" (Decode.list piece))
        (Decode.field "table" (Decode.list piece))
        (Decode.field "boneyard" (Decode.list piece))
        (Decode.field "turn" turn)


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
        , ( "turn"
          , Encode.string
                (case state.turn of
                    Player ->
                        "player"

                    Opponent ->
                        "opponent"
                )
          )
        ]


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
