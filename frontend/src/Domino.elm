module Domino exposing
    ( Table
    , canPlay
    , canPlayOn
    , ends
    , handPoints
    , isDouble
    , mustDraw
    , pips
    , place
    , playable
    , rotate
    , validEnds
    )

{-| Regras instantâneas do dominó (parte 4).

São regras que o Elm resolve sozinho, sem perguntar ao backend: servem
para a tela destacar as peças que encaixam, mostrar só as pontas válidas
e avisar quando é hora de comprar. Quem decide de verdade continua sendo o
Prolog: o estado que volta do backend sempre substitui o local.

Os tipos `Piece` e `End` vêm do `View.elm` (peça = `( a, b )`), para não
haver duas versões da mesma coisa.

-}

import View exposing (End(..), Piece)



-- TIPOS


{-| A mesa: peças em ordem, da ponta esquerda para a direita.
Na mesa a peça pode estar girada, então `( 5, 3 )` é válido.
-}
type alias Table =
    List Piece



-- PONTAS


{-| Os números livres nas duas pontas. `Nothing` com a mesa vazia.

    ends [ ( 6, 6 ), ( 6, 3 ) ] == Just ( 6, 3 )

-}
ends : Table -> Maybe ( Int, Int )
ends table =
    case ( List.head table, List.head (List.reverse table) ) of
        ( Just ( left, _ ), Just ( _, right ) ) ->
            Just ( left, right )

        _ ->
            Nothing



-- QUEM ENCAIXA


{-| A peça encaixa nessa ponta? Com a mesa vazia, qualquer uma serve.
-}
canPlayOn : End -> Table -> Piece -> Bool
canPlayOn end table piece =
    case ends table of
        Nothing ->
            True

        Just ( left, right ) ->
            case end of
                LeftEnd ->
                    hasNumber left piece

                RightEnd ->
                    hasNumber right piece


{-| A peça encaixa em alguma ponta?
-}
canPlay : Table -> Piece -> Bool
canPlay table piece =
    canPlayOn LeftEnd table piece || canPlayOn RightEnd table piece


{-| As pontas onde a peça encaixa (para a tela mostrar só esses botões).
-}
validEnds : Table -> Piece -> List End
validEnds table piece =
    List.filter (\end -> canPlayOn end table piece) [ LeftEnd, RightEnd ]


{-| As peças da mão que podem ser jogadas agora.
-}
playable : Table -> List Piece -> List Piece
playable table hand =
    List.filter (canPlay table) hand


{-| Nenhuma peça da mão encaixa: o jogador tem que comprar (ou passar,
se o monte estiver vazio).
-}
mustDraw : Table -> List Piece -> Bool
mustDraw table hand =
    List.isEmpty (playable table hand)



-- JOGAR NA MESA


{-| Gira a peça: `( 3, 5 )` vira `( 5, 3 )`.
-}
rotate : Piece -> Piece
rotate ( a, b ) =
    ( b, a )


{-| Coloca a peça na ponta escolhida, girando se preciso.
`Nothing` se ela não encaixa ali. Serve para uma prévia da jogada.

    place RightEnd ( 3, 5 ) [ ( 6, 3 ) ] == Nothing
    place RightEnd ( 5, 3 ) [ ( 6, 3 ) ] == Just [ ( 6, 3 ), ( 3, 5 ) ]

-}
place : End -> Piece -> Table -> Maybe Table
place end (( a, b ) as piece) table =
    case ends table of
        Nothing ->
            Just [ piece ]

        Just ( left, right ) ->
            case end of
                LeftEnd ->
                    if b == left then
                        Just (piece :: table)

                    else if a == left then
                        Just (rotate piece :: table)

                    else
                        Nothing

                RightEnd ->
                    if a == right then
                        Just (table ++ [ piece ])

                    else if b == right then
                        Just (table ++ [ rotate piece ])

                    else
                        Nothing



-- PONTOS


isDouble : Piece -> Bool
isDouble ( a, b ) =
    a == b


{-| Pontinhos de uma peça.
-}
pips : Piece -> Int
pips ( a, b ) =
    a + b


{-| Soma dos pontinhos de uma mão.
-}
handPoints : List Piece -> Int
handPoints hand =
    List.sum (List.map pips hand)



-- AUXILIAR


hasNumber : Int -> Piece -> Bool
hasNumber n ( a, b ) =
    a == n || b == n