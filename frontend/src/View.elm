module View exposing
    ( Piece, End(..), Status(..), Winner(..), Hint(..)
    , Props, Config
    , view
    )

{-| Visual do jogo (parte 6).

Este módulo só desenha. Ele não importa `Domino` nem `Main`: recebe os dados
prontos em `Props` e devolve as ações do jogador pelas funções de `Config`.
A lógica da tela (parte 5) liga o visual com um adaptador pequeno, e o visual
pode ser visto sozinho em `Preview.elm`, sem backend.

Todas as peças são desenhadas em SVG aqui mesmo: não há imagem externa.


# Tipos

@docs Piece, End, Status, Winner, Hint


# Entrada e saída

@docs Props, Config


# Tela

@docs view

-}

import Html exposing (Html)
import Html.Attributes as HA
import Html.Events as HE
import Html.Keyed
import Json.Decode as Decode
import Svg exposing (Svg)
import Svg.Attributes as SA
import Svg.Events as SE
import Svg.Keyed



-- TIPOS


{-| Uma peça, como no contrato do backend: `[3,5]` vira `( 3, 5 )`.
Na mesa, a ordem importa: o primeiro número encosta na vizinha da esquerda.
-}
type alias Piece =
    ( Int, Int )


{-| Ponta da mesa (`left` / `right` no Prolog).
-}
type End
    = LeftEnd
    | RightEnd


{-| Em que pé está a partida.
-}
type Status
    = Loading
    | PlayerTurn
    | OpponentTurn
    | Finished Winner Int


{-| Quem ganhou (`player`, `opponent` ou `draw` no `game_over/6`).
-}
type Winner
    = PlayerWins
    | OpponentWins
    | Draw


{-| A dica do `hint/4`: uma jogada, `draw` ou `pass`.
-}
type Hint
    = PlayHint Piece End
    | DrawHint
    | PassHint


{-| Tudo o que a tela precisa para ser desenhada.

  - `opponentHand`: só aparece virada para baixo; é revelada no fim.
  - `selected`: peça escolhida que encaixa nas duas pontas (aparecem as
    "sombras" onde ela pode entrar).
  - `lastPlayed`: a peça mais nova da mesa, que ganha um contorno dourado.
  - `log`: frases do lance a lance, a mais recente primeiro.

-}
type alias Props =
    { playerHand : List Piece
    , opponentHand : List Piece
    , table : List Piece
    , boneyard : Int
    , status : Status
    , selected : Maybe Piece
    , hint : Maybe Hint
    , lastPlayed : Maybe Piece
    , log : List String
    , score : { player : Int, opponent : Int }
    , error : Maybe String
    }


{-| As mensagens que o visual manda de volta.

Clique numa peça da mão: se ela só encaixa numa ponta, já vem `onPlay`;
se encaixa nas duas, vem `onSelect (Just peça)` e o jogador escolhe a ponta.
Com a mesa vazia, a jogada vai para `RightEnd`, como no `fits/3`.

-}
type alias Config msg =
    { onSelect : Maybe Piece -> msg
    , onPlay : Piece -> End -> msg
    , onDraw : msg
    , onPass : msg
    , onHint : msg
    , onNewGame : msg
    }



-- TELA


{-| A tela inteira do jogo.
-}
view : Config msg -> Props -> Html msg
view cfg props =
    Html.div [ HA.class "domino" ]
        [ defs
        , viewHeader cfg props
        , viewError props.error
        , Html.main_ [ HA.class "jogo" ]
            [ Html.section [ HA.class "mesa", HA.attribute "aria-label" "Mesa" ]
                [ Html.div [ HA.class "feltro" ]
                    [ viewOpponent props
                    , viewTableArea cfg props
                    , viewTableFooter props
                    ]
                ]
            , viewHand cfg props
            , viewSide cfg props
            ]
        , viewGameOver cfg props
        ]



-- TOPO


viewHeader : Config msg -> Props -> Html msg
viewHeader cfg props =
    Html.header [ HA.class "topo" ]
        [ Html.div [ HA.class "marca" ]
            [ logo
            , Html.div []
                [ Html.h1 [ HA.class "marca__nome" ] [ Html.text "Dominó" ]
                , Html.p [ HA.class "marca__sub" ] [ Html.text "duplo-seis · Prolog + Elm" ]
                ]
            ]
        , viewScore props.score
        , Html.button [ HA.class "botao botao--fantasma", HE.onClick cfg.onNewGame ]
            [ Html.text "Nova partida" ]
        ]


viewScore : { player : Int, opponent : Int } -> Html msg
viewScore score =
    Html.div
        [ HA.class "placar"
        , HA.attribute "aria-label"
            ("Placar: você " ++ String.fromInt score.player ++ ", computador " ++ String.fromInt score.opponent)
        ]
        [ Html.span [ HA.class "placar__rotulo" ] [ Html.text "Você" ]
        , Html.span [ HA.class "placar__num" ] [ Html.text (String.fromInt score.player) ]
        , Html.span [ HA.class "placar__x", HA.attribute "aria-hidden" "true" ] [ Html.text "×" ]
        , Html.span [ HA.class "placar__num" ] [ Html.text (String.fromInt score.opponent) ]
        , Html.span [ HA.class "placar__rotulo" ] [ Html.text "Computador" ]
        ]


logo : Html msg
logo =
    Svg.svg [ SA.viewBox "0 0 64 64", SA.class "marca__logo", HA.attribute "aria-hidden" "true" ]
        [ Svg.rect [ SA.x "1", SA.y "1", SA.width "62", SA.height "62", SA.rx "16", SA.fill "#1f5c47" ] []
        , Svg.g [ SA.transform "translate(25 33) rotate(-24) scale(0.22) translate(-50 -100)" ] tileBack
        , Svg.g [ SA.transform "translate(37 31) rotate(14) scale(0.22) translate(-50 -100)" ] (tileFace 6 3)
        ]


viewError : Maybe String -> Html msg
viewError error =
    case error of
        Just message ->
            Html.div [ HA.class "aviso", HA.attribute "role" "alert" ]
                [ Html.strong [] [ Html.text "Algo deu errado. " ]
                , Html.text message
                ]

        Nothing ->
            Html.text ""



-- OPONENTE


viewOpponent : Props -> Html msg
viewOpponent props =
    let
        revealed =
            isFinished props.status

        n =
            List.length props.opponentHand
    in
    Html.div [ HA.class "oponente" ]
        [ Html.div [ HA.class "oponente__rotulo" ]
            [ Html.span [] [ Html.text "Computador" ]
            , Html.span [ HA.class "contador" ] [ Html.text (piecesLabel n) ]
            ]
        , Html.Keyed.node "div"
            [ HA.class "oponente__mao" ]
            (List.indexedMap (\i p -> ( pieceKey p, opponentTile revealed n i p )) props.opponentHand)
        ]


opponentTile : Bool -> Int -> Int -> Piece -> Html msg
opponentTile revealed n i ( a, b ) =
    Html.div
        [ htmlClasses [ ( "carta", True ), ( "carta--revelada", revealed ) ]
        , fan n i -1
        ]
        [ Svg.svg [ SA.viewBox "0 0 100 200" ]
            (if revealed then
                tileFace a b

             else
                tileBack
            )
        ]



-- MESA


viewTableArea : Config msg -> Props -> Html msg
viewTableArea cfg props =
    if props.status == Loading then
        Html.div [ HA.class "cadeia" ] [ viewShuffling ]

    else
        Html.div [ HA.class "cadeia" ]
            [ viewChain cfg props 20 "cadeia__svg cadeia__svg--larga"
            , viewChain cfg props 10 "cadeia__svg cadeia__svg--estreita"
            ]


viewShuffling : Html msg
viewShuffling =
    Html.div [ HA.class "embaralhar", HA.attribute "role" "status" ]
        [ Html.div [ HA.class "embaralhar__pecas" ]
            (List.range 0 4
                |> List.map
                    (\i ->
                        Html.div
                            [ HA.class "embaralhar__peca"
                            , HA.attribute "style" ("--i:" ++ String.fromInt i)
                            ]
                            [ Svg.svg [ SA.viewBox "0 0 100 200" ] tileBack ]
                    )
            )
        , Html.p [] [ Html.text "Embaralhando as peças…" ]
        ]


viewTableFooter : Props -> Html msg
viewTableFooter props =
    Html.div [ HA.class "mesa__rodape" ]
        [ viewTurn props
        , viewEnds props.table
        ]


viewTurn : Props -> Html msg
viewTurn props =
    let
        playable =
            playablePieces props

        ( modifier, label ) =
            case props.status of
                Loading ->
                    ( "espera", "Preparando a mesa" )

                PlayerTurn ->
                    if props.selected /= Nothing then
                        ( "voce", "Escolha a ponta" )

                    else if not (List.isEmpty playable) then
                        ( "voce", "Sua vez" )

                    else if props.boneyard > 0 then
                        ( "voce", "Sem jogada: compre do monte" )

                    else
                        ( "voce", "Sem jogada: passe a vez" )

                OpponentTurn ->
                    ( "oponente", "Computador pensando" )

                Finished _ _ ->
                    ( "espera", "Fim de jogo" )
    in
    Html.div [ HA.class ("vez vez--" ++ modifier), HA.attribute "role" "status" ]
        [ Html.span [ HA.class "vez__ponto" ] []
        , Html.text label
        , if props.status == OpponentTurn then
            Html.span [ HA.class "pensando", HA.attribute "aria-hidden" "true" ]
                [ Html.span [] [], Html.span [] [], Html.span [] [] ]

          else
            Html.text ""
        ]


viewEnds : List Piece -> Html msg
viewEnds table =
    case tableEnds table of
        Just ( l, r ) ->
            Html.div [ HA.class "pontas", HA.attribute "aria-label" ("Pontas da mesa: " ++ String.fromInt l ++ " e " ++ String.fromInt r) ]
                [ Html.span [] [ Html.text "Pontas" ]
                , halfTile l
                , halfTile r
                ]

        Nothing ->
            Html.text ""


halfTile : Int -> Html msg
halfTile n =
    Svg.svg [ SA.viewBox "0 0 100 100", SA.class "pontas__meia" ]
        (Svg.rect [ SA.x "2", SA.y "2", SA.width "96", SA.height "96", SA.rx "16", SA.fill "url(#g-face)", SA.class "t-corpo" ] []
            :: pips 0 n
        )



-- CADEIA (a "cobra" de peças)


{-| Tamanho de uma casa no SVG da mesa. Uma peça deitada ocupa 2 × 1 casas.
-}
cell : Float
cell =
    50


{-| Onde uma peça fica: centro (em casas) e rotação da peça em pé.
Com `angle = -90` o primeiro número fica à esquerda; com `90`, à direita;
com `0`, em cima.
-}
type alias Slot =
    { piece : Piece
    , cx : Float
    , cy : Float
    , angle : Float
    }


type alias Cursor =
    { x : Float
    , y : Float
    , dir : Float
    , turning : Bool
    }


{-| Monta a cobra. As fileiras alternam de direção; buchas ficam atravessadas;
na virada, duas peças descem em pé antes da fileira seguinte voltar.
`width` é a largura útil em casas (a primeira e a última coluna são da virada).
-}
layout : Float -> List Piece -> List Slot
layout width pieces =
    pieces
        |> List.foldl (step width) ( { x = 1, y = 0, dir = 1, turning = False }, [] )
        |> Tuple.second
        |> List.reverse


step : Float -> Piece -> ( Cursor, List Slot ) -> ( Cursor, List Slot )
step width piece ( c, acc ) =
    if c.turning then
        ( { x =
                if c.dir > 0 then
                    c.x

                else
                    c.x + 1
          , y = c.y + 3
          , dir = -c.dir
          , turning = False
          }
        , { piece = piece, cx = c.x + 0.5, cy = c.y + 2.5, angle = 0 } :: acc
        )

    else
        let
            double =
                isDouble piece

            size =
                if double then
                    1

                else
                    2

            fitsRow =
                if c.dir > 0 then
                    c.x + size <= width - 1

                else
                    c.x - size >= 1
        in
        if fitsRow then
            let
                left =
                    if c.dir > 0 then
                        c.x

                    else
                        c.x - size

                angle =
                    if double then
                        0

                    else if c.dir > 0 then
                        -90

                    else
                        90
            in
            ( { c | x = c.x + c.dir * size }
            , { piece = piece, cx = left + size / 2, cy = c.y, angle = angle } :: acc
            )

        else
            let
                column =
                    if c.dir > 0 then
                        c.x

                    else
                        c.x - 1
            in
            ( { c | x = column, turning = True }
            , { piece = piece, cx = column + 0.5, cy = c.y + 0.5, angle = 0 } :: acc
            )


halfW : Slot -> Float
halfW s =
    if s.angle == 0 then
        0.5

    else
        1


halfH : Slot -> Float
halfH s =
    if s.angle == 0 then
        1

    else
        0.5


{-| As "sombras" onde a peça selecionada pode entrar.
-}
ghostSlots : Float -> Props -> List Slot -> List ( End, Slot )
ghostSlots width props slots =
    case ( props.selected, tableEnds props.table, List.head slots ) of
        ( Just p, Just ( l, r ), Just first ) ->
            let
                fits =
                    fitsAt props.table p

                rightGhost =
                    if List.member RightEnd fits then
                        layout width (props.table ++ [ orientRight r p ])
                            |> List.reverse
                            |> List.head
                            |> Maybe.map (\s -> [ ( RightEnd, s ) ])
                            |> Maybe.withDefault []

                    else
                        []

                leftGhost =
                    if List.member LeftEnd fits then
                        let
                            size =
                                if isDouble p then
                                    1

                                else
                                    2
                        in
                        [ ( LeftEnd
                          , { piece = orientLeft l p
                            , cx = first.cx - halfW first - size / 2
                            , cy = first.cy
                            , angle =
                                if isDouble p then
                                    0

                                else
                                    -90
                            }
                          )
                        ]

                    else
                        []
            in
            leftGhost ++ rightGhost

        _ ->
            []


viewChain : Config msg -> Props -> Float -> String -> Html msg
viewChain cfg props width cls =
    let
        slots =
            layout width props.table

        ghosts =
            ghostSlots width props slots

        xs =
            List.concatMap (\s -> [ s.cx - halfW s, s.cx + halfW s ]) slots

        -- Centraliza as peças (sem as sombras, para a mesa não pular ao selecionar).
        offX =
            case ( List.minimum xs, List.maximum xs ) of
                ( Just lo, Just hi ) ->
                    (width - (hi - lo)) / 2 - lo

                _ ->
                    0

        ys =
            (slots ++ List.map Tuple.second ghosts)
                |> List.concatMap (\s -> [ s.cy - halfH s, s.cy + halfH s ])

        minY =
            Maybe.withDefault -1 (List.minimum ys)

        maxY =
            Maybe.withDefault 1 (List.maximum ys)

        contentH =
            maxY - minY

        height =
            max 5 (contentH + 2)

        offY =
            (height - contentH) / 2 - minY

        pad =
            2

        box =
            [ -pad * cell, 0, (width + 2 * pad) * cell, height * cell ]
                |> List.map String.fromFloat
                |> String.join " "
    in
    Svg.svg [ SA.viewBox box, SA.class cls ]
        [ if List.isEmpty props.table then
            emptyTable width height

          else
            Svg.text ""
        , Svg.Keyed.node "g"
            []
            (List.map
                (\s ->
                    ( pieceKey s.piece
                    , placedTile offX offY (Maybe.map (same s.piece) props.lastPlayed == Just True) s
                    )
                )
                slots
            )
        , Svg.g [] (List.map (ghostTile cfg props offX offY) ghosts)
        ]


emptyTable : Float -> Float -> Svg msg
emptyTable width height =
    let
        cx =
            width / 2 * cell

        cy =
            height / 2 * cell
    in
    Svg.g [ SA.class "mesa-vazia" ]
        [ Svg.rect
            [ SA.x (String.fromFloat (cx - cell))
            , SA.y (String.fromFloat (cy - cell / 2 - 18))
            , SA.width (String.fromFloat (2 * cell))
            , SA.height (String.fromFloat cell)
            , SA.rx "8"
            , SA.class "mesa-vazia__lugar"
            ]
            []
        , Svg.text_
            [ SA.x (String.fromFloat cx), SA.y (String.fromFloat (cy + cell / 2 + 16)), SA.textAnchor "middle", SA.class "mesa-vazia__texto" ]
            [ Svg.text "A mesa está vazia" ]
        , Svg.text_
            [ SA.x (String.fromFloat cx), SA.y (String.fromFloat (cy + cell / 2 + 38)), SA.textAnchor "middle", SA.class "mesa-vazia__sub" ]
            [ Svg.text "a maior bucha abre o jogo" ]
        ]


placement : Float -> Float -> Slot -> String
placement offX offY s =
    "transform: translate("
        ++ px ((s.cx + offX) * cell)
        ++ ", "
        ++ px ((s.cy + offY) * cell)
        ++ ")"


rotation : Slot -> String
rotation s =
    "transform: rotate(" ++ String.fromFloat s.angle ++ "deg)"


placedTile : Float -> Float -> Bool -> Slot -> Svg msg
placedTile offX offY newest s =
    let
        ( a, b ) =
            s.piece
    in
    Svg.g [ SA.class "slot", SA.style (placement offX offY s) ]
        [ Svg.g [ SA.class "slot__giro", SA.style (rotation s) ]
            [ Svg.g
                [ svgClasses [ ( "slot__in", True ), ( "slot__in--nova", newest ) ] ]
                [ Svg.g [ SA.transform "scale(0.5) translate(-50 -100)" ] (tileFace a b) ]
            ]
        ]


ghostTile : Config msg -> Props -> Float -> Float -> ( End, Slot ) -> Svg msg
ghostTile cfg props offX offY ( end, s ) =
    case props.selected of
        Just chosen ->
            let
                ( a, b ) =
                    s.piece

                hinted =
                    hintedEnd props.hint chosen == Just end

                msg =
                    cfg.onPlay chosen end
            in
            Svg.g [ SA.class "slot", SA.style (placement offX offY s) ]
                [ Svg.g [ SA.class "slot__giro", SA.style (rotation s) ]
                    [ Svg.g
                        [ svgClasses [ ( "fantasma", True ), ( "fantasma--dica", hinted ) ]
                        , SE.onClick msg
                        , onActivate msg
                        , HA.attribute "role" "button"
                        , HA.attribute "tabindex" "0"
                        , HA.attribute "aria-label" ("Jogar " ++ pieceText chosen ++ " na " ++ endName end)
                        ]
                        [ Svg.g [ SA.transform "scale(0.5) translate(-50 -100)" ]
                            [ Svg.g [ SA.class "fantasma__face" ] (tileFace a b)
                            , Svg.rect [ SA.x "2", SA.y "2", SA.width "96", SA.height "196", SA.rx "14", SA.class "fantasma__borda" ] []
                            ]
                        ]
                    ]
                ]

        Nothing ->
            Svg.text ""



-- MÃO DO JOGADOR


viewHand : Config msg -> Props -> Html msg
viewHand cfg props =
    let
        n =
            List.length props.playerHand
    in
    Html.section [ HA.class "mao", HA.attribute "aria-label" "Sua mão" ]
        [ Html.Keyed.node "div"
            [ HA.class "mao__pecas" ]
            (List.indexedMap (\i p -> ( pieceKey p, handTile cfg props n i p )) props.playerHand)
        , viewHintText props
        , viewActions cfg props
        ]


handTile : Config msg -> Props -> Int -> Int -> Piece -> Html msg
handTile cfg props n i p =
    let
        ( a, b ) =
            p

        playerTurn =
            props.status == PlayerTurn

        fits =
            fitsAt props.table p

        playable =
            playerTurn && not (List.isEmpty fits)

        selected =
            Maybe.map (same p) props.selected == Just True

        hinted =
            hintedEnd props.hint p /= Nothing

        click =
            if not playable then
                []

            else
                case fits of
                    [ end ] ->
                        [ HE.onClick (cfg.onPlay p end) ]

                    _ ->
                        [ HE.onClick
                            (cfg.onSelect
                                (if selected then
                                    Nothing

                                 else
                                    Just p
                                )
                            )
                        ]
    in
    Html.button
        ([ htmlClasses
            [ ( "peca-mao", True )
            , ( "peca-mao--jogavel", playable )
            , ( "peca-mao--travada", playerTurn && not playable )
            , ( "peca-mao--espera", not playerTurn )
            , ( "peca-mao--selecionada", selected )
            , ( "peca-mao--dica", hinted )
            ]
         , fan n i 1
         , HA.disabled (not playable)
         , HA.attribute "aria-pressed"
            (if selected then
                "true"

             else
                "false"
            )
         , HA.attribute "aria-label" ("Peça " ++ pieceText p)
         ]
            ++ click
        )
        [ Svg.svg [ SA.viewBox "0 0 100 200" ] (tileFace a b) ]


viewHintText : Props -> Html msg
viewHintText props =
    let
        line =
            case props.hint of
                Just (PlayHint p end) ->
                    Just ("Dica: jogue " ++ pieceText p ++ " na " ++ endName end ++ ".")

                Just DrawHint ->
                    Just "Dica: nenhuma peça encaixa. Compre do monte."

                Just PassHint ->
                    Just "Dica: nada encaixa e o monte acabou. Passe a vez."

                Nothing ->
                    Nothing
    in
    case line of
        Just t ->
            Html.p [ HA.class "dica-texto", HA.attribute "role" "status" ] [ Html.text t ]

        Nothing ->
            Html.text ""


viewActions : Config msg -> Props -> Html msg
viewActions cfg props =
    let
        playerTurn =
            props.status == PlayerTurn

        noMove =
            playerTurn && List.isEmpty (playablePieces props)

        canDraw =
            noMove && props.boneyard > 0

        canPass =
            noMove && props.boneyard == 0

        endButtons =
            case ( props.selected, tableEnds props.table ) of
                ( Just p, Just ( l, r ) ) ->
                    if List.length (fitsAt props.table p) > 1 then
                        [ endButton cfg props p LeftEnd ("◀ Ponta " ++ String.fromInt l)
                        , endButton cfg props p RightEnd ("Ponta " ++ String.fromInt r ++ " ▶")
                        ]

                    else
                        []

                _ ->
                    []
    in
    Html.div [ HA.class "acoes" ]
        (endButtons
            ++ [ actionButton (playerTurn && props.hint == Nothing) False "" cfg.onHint "Dica"
               , actionButton canDraw (props.hint == Just DrawHint) "botao--primario" cfg.onDraw "Comprar"
               , actionButton canPass (props.hint == Just PassHint) "botao--primario" cfg.onPass "Passar a vez"
               ]
        )


endButton : Config msg -> Props -> Piece -> End -> String -> Html msg
endButton cfg props p end label =
    Html.button
        [ htmlClasses
            [ ( "botao botao--ponta", True )
            , ( "botao--dica", hintedEnd props.hint p == Just end )
            ]
        , HE.onClick (cfg.onPlay p end)
        ]
        [ Html.text label ]


actionButton : Bool -> Bool -> String -> msg -> String -> Html msg
actionButton enabled hinted extra msg label =
    Html.button
        ([ htmlClasses [ ( "botao", True ), ( extra, extra /= "" ), ( "botao--dica", hinted ) ]
         , HA.disabled (not enabled)
         ]
            ++ (if enabled then
                    [ HE.onClick msg ]

                else
                    []
               )
        )
        [ Html.text label ]



-- LATERAL: MONTE E LANCE A LANCE


viewSide : Config msg -> Props -> Html msg
viewSide cfg props =
    Html.aside [ HA.class "lateral" ]
        [ viewBoneyard cfg props
        , viewLog props.log
        ]


viewBoneyard : Config msg -> Props -> Html msg
viewBoneyard cfg props =
    let
        canDraw =
            props.status == PlayerTurn && List.isEmpty (playablePieces props) && props.boneyard > 0

        pile =
            List.take (min 7 props.boneyard) pileSpots
    in
    Html.div [ HA.class "cartao monte" ]
        [ Html.h2 [ HA.class "lateral__titulo" ] [ Html.text "Monte" ]
        , Html.button
            ([ htmlClasses
                [ ( "monte__pilha", True )
                , ( "monte__pilha--ativo", canDraw )
                , ( "monte__pilha--dica", props.hint == Just DrawHint )
                ]
             , HA.disabled (not canDraw)
             , HA.attribute "aria-label" ("Comprar do monte (" ++ piecesLabel props.boneyard ++ ")")
             ]
                ++ (if canDraw then
                        [ HE.onClick cfg.onDraw ]

                    else
                        []
                   )
            )
            [ Svg.svg [ SA.viewBox "0 0 240 150", SA.class "monte__svg" ]
                (if List.isEmpty pile then
                    [ Svg.rect [ SA.x "70", SA.y "50", SA.width "100", SA.height "50", SA.rx "8", SA.class "monte__vazio" ] [] ]

                 else
                    List.map pileTile pile
                )
            ]
        , Html.p [ HA.class "monte__conta" ]
            [ Html.strong [] [ Html.text (String.fromInt props.boneyard) ]
            , Html.text
                (if props.boneyard == 1 then
                    " peça para comprar"

                 else
                    " peças para comprar"
                )
            ]
        ]


pileSpots : List ( Float, Float, Float )
pileSpots =
    [ ( 120, 112, -4 ), ( 108, 98, 7 ), ( 130, 86, -10 ), ( 114, 72, 3 ), ( 124, 58, -6 ), ( 110, 44, 9 ), ( 120, 32, -2 ) ]


pileTile : ( Float, Float, Float ) -> Svg msg
pileTile ( x, y, r ) =
    Svg.g
        [ SA.class "monte__peca"
        , SA.transform
            ("translate("
                ++ String.fromFloat x
                ++ " "
                ++ String.fromFloat y
                ++ ") rotate("
                ++ String.fromFloat (r - 90)
                ++ ") scale(0.48) translate(-50 -100)"
            )
        ]
        tileBack


viewLog : List String -> Html msg
viewLog log =
    let
        total =
            List.length log
    in
    Html.div [ HA.class "cartao registro" ]
        [ Html.h2 [ HA.class "lateral__titulo" ] [ Html.text "Lance a lance" ]
        , if List.isEmpty log then
            Html.p [ HA.class "registro__vazio" ] [ Html.text "Nenhum lance ainda." ]

          else
            Html.Keyed.node "ol"
                [ HA.class "registro__lista", HA.attribute "aria-live" "polite" ]
                (List.indexedMap (\i line -> ( String.fromInt (total - i), Html.li [] [ Html.text line ] )) log)
        ]



-- FIM DE JOGO


viewGameOver : Config msg -> Props -> Html msg
viewGameOver cfg props =
    case props.status of
        Finished winner points ->
            let
                domino =
                    List.isEmpty props.playerHand || List.isEmpty props.opponentHand

                ( badge, title, sub ) =
                    case ( winner, domino ) of
                        ( PlayerWins, True ) ->
                            ( "Batida", "Você bateu!", "Jogou a última peça antes do computador." )

                        ( PlayerWins, False ) ->
                            ( "Jogo trancado", "Você venceu", "Ninguém tinha jogada e a sua mão pesava menos." )

                        ( OpponentWins, True ) ->
                            ( "Batida", "O computador bateu", "Ele jogou a última peça primeiro." )

                        ( OpponentWins, False ) ->
                            ( "Jogo trancado", "O computador venceu", "Ninguém tinha jogada e a mão dele pesava menos." )

                        ( Draw, _ ) ->
                            ( "Jogo trancado", "Empate", "As duas mãos somaram o mesmo. Ninguém marca." )

                pointsLine =
                    case winner of
                        PlayerWins ->
                            "pontos para você"

                        OpponentWins ->
                            "pontos para o computador"

                        Draw ->
                            "pontos"
            in
            Html.div [ HA.class "fim", HA.attribute "role" "dialog", HA.attribute "aria-modal" "true", HA.attribute "aria-labelledby" "fim-titulo" ]
                [ if winner == PlayerWins then
                    confetti

                  else
                    Html.text ""
                , Html.div [ HA.class ("fim__cartao fim__cartao--" ++ winnerClass winner) ]
                    [ Html.p [ HA.class "fim__selo" ] [ Html.text badge ]
                    , Html.h2 [ HA.class "fim__titulo", HA.id "fim-titulo" ] [ Html.text title ]
                    , Html.p [ HA.class "fim__sub" ] [ Html.text sub ]
                    , Html.p [ HA.class "fim__pontos" ]
                        [ Html.strong [] [ Html.text ("+" ++ String.fromInt points) ]
                        , Html.span [] [ Html.text pointsLine ]
                        ]
                    , Html.div [ HA.class "fim__maos" ]
                        [ handSummary "Sobrou com você" props.playerHand
                        , handSummary "Sobrou com o computador" props.opponentHand
                        ]
                    , Html.button [ HA.class "botao botao--primario botao--grande", HE.onClick cfg.onNewGame ]
                        [ Html.text "Jogar de novo" ]
                    ]
                ]

        _ ->
            Html.text ""


winnerClass : Winner -> String
winnerClass winner =
    case winner of
        PlayerWins ->
            "vitoria"

        OpponentWins ->
            "derrota"

        Draw ->
            "empate"


handSummary : String -> List Piece -> Html msg
handSummary label hand =
    Html.div [ HA.class "fim__mao" ]
        [ Html.span [ HA.class "fim__mao-rotulo" ] [ Html.text label ]
        , Html.span [ HA.class "fim__mao-pecas" ]
            (if List.isEmpty hand then
                [ Html.span [ HA.class "fim__nada" ] [ Html.text "nada" ] ]

             else
                List.map miniTile hand
            )
        , Html.span [ HA.class "fim__mao-soma" ] [ Html.text (String.fromInt (handPoints hand) ++ " pts") ]
        ]


miniTile : Piece -> Html msg
miniTile ( a, b ) =
    Svg.svg [ SA.viewBox "0 0 200 100", SA.class "mini" ]
        [ Svg.g [ SA.transform "translate(100 50) rotate(-90) translate(-50 -100)" ] (tileFace a b) ]


confetti : Html msg
confetti =
    Html.div [ HA.class "festa", HA.attribute "aria-hidden" "true" ]
        (List.range 0 23
            |> List.map
                (\i ->
                    Html.span
                        [ HA.attribute "style"
                            ("--x:"
                                ++ String.fromInt (modBy 100 (i * 37 + 11))
                                ++ "vw;--d:"
                                ++ String.fromFloat (toFloat (modBy 12 (i * 7)) * 0.18)
                                ++ "s;--t:"
                                ++ String.fromFloat (2.6 + toFloat (modBy 5 i) * 0.35)
                                ++ "s;--r:"
                                ++ String.fromInt (modBy 360 (i * 53))
                                ++ "deg"
                            )
                        ]
                        []
                )
        )



-- DESENHO DAS PEÇAS
-- Peça em pé num quadro de 100 × 200: número de cima em y 0–100, de baixo em 100–200.


defs : Html msg
defs =
    Svg.svg [ SA.class "defs", SA.width "0", SA.height "0", HA.attribute "aria-hidden" "true" ]
        [ Svg.defs []
            [ Svg.linearGradient [ SA.id "g-face", SA.x1 "0", SA.y1 "0", SA.x2 "1", SA.y2 "1" ]
                [ stop "0%" "#fffaf0", stop "55%" "#f2e9d6", stop "100%" "#dccfb2" ]
            , Svg.radialGradient [ SA.id "g-pip", SA.cx "38%", SA.cy "32%", SA.r "70%" ]
                [ stop "0%" "#4d433a", stop "55%" "#1d1813", stop "100%" "#0b0907" ]
            , Svg.radialGradient [ SA.id "g-pin", SA.cx "35%", SA.cy "30%", SA.r "75%" ]
                [ stop "0%" "#fff3c8", stop "45%" "#d6af58", stop "100%" "#7a5a1c" ]
            , Svg.linearGradient [ SA.id "g-back", SA.x1 "0", SA.y1 "0", SA.x2 "1", SA.y2 "1" ]
                [ stop "0%" "#7a2a37", stop "100%" "#3f121b" ]
            , Svg.pattern [ SA.id "p-back", SA.width "16", SA.height "16", SA.patternUnits "userSpaceOnUse", SA.patternTransform "rotate(45)" ]
                [ Svg.rect [ SA.width "6", SA.height "16", SA.fill "rgba(255,255,255,0.06)" ] [] ]
            ]
        ]


stop : String -> String -> Svg msg
stop offset color =
    Svg.stop [ SA.offset offset, SA.stopColor color ] []


tileFace : Int -> Int -> List (Svg msg)
tileFace top bottom =
    [ Svg.rect [ SA.x "2", SA.y "2", SA.width "96", SA.height "196", SA.rx "14", SA.fill "url(#g-face)", SA.class "t-corpo" ] []
    , Svg.rect [ SA.x "7", SA.y "7", SA.width "86", SA.height "186", SA.rx "10", SA.class "t-bisel" ] []
    , Svg.line [ SA.x1 "16", SA.y1 "100", SA.x2 "84", SA.y2 "100", SA.class "t-meio" ] []
    , Svg.g [] (pips 0 top ++ pips 100 bottom)
    , Svg.circle [ SA.cx "50", SA.cy "100", SA.r "5.5", SA.fill "url(#g-pin)" ] []
    ]


tileBack : List (Svg msg)
tileBack =
    [ Svg.rect [ SA.x "2", SA.y "2", SA.width "96", SA.height "196", SA.rx "14", SA.fill "url(#g-back)", SA.class "t-costas" ] []
    , Svg.rect [ SA.x "2", SA.y "2", SA.width "96", SA.height "196", SA.rx "14", SA.fill "url(#p-back)" ] []
    , Svg.rect [ SA.x "8", SA.y "8", SA.width "84", SA.height "184", SA.rx "10", SA.class "t-costas-filete" ] []
    , Svg.path [ SA.d "M50 66 L70 100 L50 134 L30 100 Z", SA.class "t-costas-losango" ] []
    , Svg.circle [ SA.cx "50", SA.cy "100", SA.r "6", SA.fill "url(#g-pin)" ] []
    ]


pips : Float -> Int -> List (Svg msg)
pips dy n =
    pipSpots n
        |> List.map
            (\( x, y ) ->
                Svg.circle
                    [ SA.cx (String.fromFloat x)
                    , SA.cy (String.fromFloat (y + dy))
                    , SA.r "8.6"
                    , SA.fill "url(#g-pip)"
                    ]
                    []
            )


pipSpots : Int -> List ( Float, Float )
pipSpots n =
    let
        ( l, c, r ) =
            ( 28, 50, 72 )

        ( t, m, b ) =
            ( 28, 50, 72 )
    in
    case n of
        0 ->
            []

        1 ->
            [ ( c, m ) ]

        2 ->
            [ ( r, t ), ( l, b ) ]

        3 ->
            [ ( r, t ), ( c, m ), ( l, b ) ]

        4 ->
            [ ( l, t ), ( r, t ), ( l, b ), ( r, b ) ]

        5 ->
            [ ( l, t ), ( r, t ), ( c, m ), ( l, b ), ( r, b ) ]

        _ ->
            [ ( l, t ), ( r, t ), ( l, m ), ( r, m ), ( l, b ), ( r, b ) ]



-- AUXILIARES


{-| Pontas da mesa, como no `table_ends/3`.
-}
tableEnds : List Piece -> Maybe ( Int, Int )
tableEnds table =
    case ( List.head table, List.head (List.reverse table) ) of
        ( Just ( l, _ ), Just ( _, r ) ) ->
            Just ( l, r )

        _ ->
            Nothing


{-| Em que pontas a peça entra. Serve só para destacar peças e desenhar as
sombras: quem valida a jogada de verdade é o `play_piece/6` no Prolog.
-}
fitsAt : List Piece -> Piece -> List End
fitsAt table ( a, b ) =
    case tableEnds table of
        Nothing ->
            [ RightEnd ]

        Just ( l, r ) ->
            (if a == l || b == l then
                [ LeftEnd ]

             else
                []
            )
                ++ (if a == r || b == r then
                        [ RightEnd ]

                    else
                        []
                   )


playablePieces : Props -> List Piece
playablePieces props =
    List.filter (\p -> not (List.isEmpty (fitsAt props.table p))) props.playerHand


orientRight : Int -> Piece -> Piece
orientRight r ( a, b ) =
    if a == r then
        ( a, b )

    else
        ( b, a )


orientLeft : Int -> Piece -> Piece
orientLeft l ( a, b ) =
    if b == l then
        ( a, b )

    else
        ( b, a )


hintedEnd : Maybe Hint -> Piece -> Maybe End
hintedEnd hint p =
    case hint of
        Just (PlayHint hp end) ->
            if same hp p then
                Just end

            else
                Nothing

        _ ->
            Nothing


same : Piece -> Piece -> Bool
same ( a, b ) ( c, d ) =
    (a == c && b == d) || (a == d && b == c)


isDouble : Piece -> Bool
isDouble ( a, b ) =
    a == b


isFinished : Status -> Bool
isFinished status =
    case status of
        Finished _ _ ->
            True

        _ ->
            False


handPoints : List Piece -> Int
handPoints =
    List.foldl (\( a, b ) acc -> acc + a + b) 0


pieceKey : Piece -> String
pieceKey ( a, b ) =
    String.fromInt (min a b) ++ "-" ++ String.fromInt (max a b)


pieceText : Piece -> String
pieceText ( a, b ) =
    String.fromInt a ++ "|" ++ String.fromInt b


endName : End -> String
endName end =
    case end of
        LeftEnd ->
            "ponta esquerda"

        RightEnd ->
            "ponta direita"


piecesLabel : Int -> String
piecesLabel n =
    if n == 1 then
        "1 peça"

    else
        String.fromInt n ++ " peças"


px : Float -> String
px f =
    String.fromFloat f ++ "px"


{-| Leque das mãos: inclinação e altura de cada peça viram variáveis CSS.
`sign` é 1 para a mão de baixo e -1 para a do computador, que fica espelhada.
-}
fan : Int -> Int -> Float -> Html.Attribute msg
fan n i sign =
    let
        d =
            toFloat i - toFloat (n - 1) / 2

        spread =
            min 4 (30 / toFloat (max n 1))
    in
    HA.attribute "style"
        ("--rot:"
            ++ String.fromFloat (d * spread * sign)
            ++ "deg;--lift:"
            ++ String.fromFloat (d * d * spread * 0.45)
            ++ "px;--i:"
            ++ String.fromInt i
        )


htmlClasses : List ( String, Bool ) -> Html.Attribute msg
htmlClasses list =
    HA.class (joinClasses list)


svgClasses : List ( String, Bool ) -> Svg.Attribute msg
svgClasses list =
    SA.class (joinClasses list)


joinClasses : List ( String, Bool ) -> String
joinClasses list =
    list
        |> List.filter Tuple.second
        |> List.map Tuple.first
        |> String.join " "


{-| Enter ou espaço ativam as sombras da mesa pelo teclado.
-}
onActivate : msg -> Svg.Attribute msg
onActivate msg =
    HE.on "keydown"
        (Decode.field "key" Decode.string
            |> Decode.andThen
                (\key ->
                    if key == "Enter" || key == " " then
                        Decode.succeed msg

                    else
                        Decode.fail key
                )
        )
