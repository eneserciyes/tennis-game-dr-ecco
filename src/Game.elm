module Game exposing (..)

{-| This file handles all the game logic and provides the Gameplay interface to the Main application.alias.

The core parts you need to implement are:

1.  A type for your Game model
2.  An initialisation function that takes a Settings record and returns a Game record
3.  A Msg type that represents all the possible messages that can be sent from the interface to the game logic
4.  An update function that takes a Msg and a Game and returns a new Game
5.  A view function that takes a Game and returns Html Msg (the interface for the game)

You'll probably want to implement a lot of helper functions to make the above easier.

-}

import Array exposing (Array)
import Common exposing (..)
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Json.Decode as Decode exposing (Decoder)
import List exposing (..)
import List.Extra
import Random exposing (Generator)
import Random.Char exposing (special)
import Settings exposing (..)
import Html.Lazy
import Browser.Dom as Dom
import Task
import String exposing (left)
import Icons
import Svg



--------------------------------------------------------------------------------
-- GAME MODEL
--------------------------------------------------------------------------------



{-| The board size.
It doesn't really matter what this is since the coordinates are floats. It only
matters relative to the size of the spy and antispy device radiuses.
-}
defaultBoardSize : Float
defaultBoardSize =
    100.0


{-| Render 100 x 100 squares on the heatmap
-}
defaultHeatmapSize : Int
defaultHeatmapSize =
    round defaultBoardSize


{-| An EVIL member is a coordinate on the board with a value.
-}
type alias EvilMember =
    { coord : Coord
    , value : Int
    }


{-| A spy is represented as a coordinate
-}
type alias Spy =
    Coord


{-| An antispy device is represented as a coordinate
-}
type alias AntispyDevice =
    Coord


{-| A generic person is also a coordinate on the board with a value
(a person could be either a spy or an evil member)
-}
type alias Person =
    { coord : Coord
    , value : Int
    }


{-| The game proceeds into two phases:

1.  GOOD phase: GOOD places spies on the board.let
2.  EVIL phase: EVIL places antispy devices on the board.
    Each phase only has one valid move (placing).

-}
type Phase
    = GoodPhase GoodData
    | EvilPhase EvilData
    | Complete EvilData FinalScore


{-| Information to supply on each cursor movement
-}
type alias CursorData =
    { coord : Coord
    , included : List EvilMember
    , value : Int
    }


{-| The data model for the good phase.
-}
type alias GoodData =
    -- 2D heatmap to superimpose (stored as flattened 2D array)
    { heatmap : List Int
    , minValue : Int 
    , maxValue : Int

    -- A cursor (if on the map) and the data to render
    , cursorData : Maybe CursorData
    , boardElement : Maybe Dom.Element

    -- Canonical list of spies and included members
    , spies : List Spy
    , allIncluded : List EvilMember
    , totalValue : Int
    }


{-| The data model for the evil phase.
-}
type alias EvilData =
    { heatmap : List Int
    , minValue : Int
    , maxValue : Int
    , cursorData : Maybe CursorData
    , boardElement : Maybe Dom.Element
    , antispyDevices : List AntispyDevice
    , undetectedSpies : List Spy
    , detectedSpies : List Spy
    , goodInitialScore : Int
    }


{-| Useful information for rendering the final scores
-}
type alias FinalScore =
    { goodInitialScore : Int
    , numSpiesFound : Int
    , includedEvilMembers : List EvilMember
    , goodFinalScore : Int
    }


{-| A record type which contains all of the game state.
-}
type alias Game =
    { settings : Settings
    , evilMembers : List EvilMember
    , showHeatmap : Bool
    , phase : Phase
    }


{-| Create the initial game data given the settings.
-}
init : Settings -> ( Game, Cmd Msg )
init settings =
    let
        evilMembers = 
            Random.initialSeed settings.randomSeed 
            |> Random.step (generateEvilMembers defaultBoardSize settings.numEvilMembers)
            |> Tuple.first
        heatmap =
            calculateHeatmap settings.spyRadius defaultHeatmapSize evilMembers


        initialGame =
            { settings = settings
            , evilMembers = evilMembers
            , showHeatmap = False
            , phase =
                GoodPhase
                    { heatmap = heatmap
                    , minValue = List.minimum heatmap |> Maybe.withDefault 0
                    , maxValue = List.maximum heatmap |> Maybe.withDefault 0
                    , cursorData = Nothing
                    , boardElement = Nothing
                    , spies = []
                    , allIncluded = []
                    , totalValue = 0
                    }
            }
    in
    ( initialGame, Task.attempt ReceivedBoardElement (Dom.getElement "good-board") )



--------------------------------------------------------------------------------
-- GAME LOGIC
--------------------------------------------------------------------------------


{-| The possible moves that a player can make.
-}
type Move
    = PlaceSpy Spy
    | PlaceAntispyDevice AntispyDevice


{-| Apply a move to a game state, returning a new game state.
-}
applyMove : Move -> Game -> Game
applyMove move game =
    case ( game.phase, move ) of
        ( GoodPhase data, PlaceSpy spy ) ->
            placeSpy spy game data

        ( EvilPhase data, PlaceAntispyDevice antispyDevice ) ->
            placeAntispy antispyDevice game data

        -- Ignore any other moves occuring during the wrong phase
        _ ->
            game


{-| Returns the new game state after placing a spy on the board during the good phase.
-}
placeSpy : Spy -> Game -> GoodData -> Game
placeSpy spy game data =
    let
        newSpies =
            spy :: data.spies

        newAllIncluded =
            game.evilMembers
                |> List.filter (inRadius spy game.settings.spyRadius)
                |> List.append data.allIncluded
                |> List.Extra.unique

        newTotalValue =
            newAllIncluded
                |> List.map .value
                |> List.sum
    in
    if List.length newSpies < game.settings.numSpies then
        { game
            | phase =
                GoodPhase
                    { data
                        | spies = newSpies
                        , allIncluded = newAllIncluded
                        , totalValue = newTotalValue
                    }
        }

    else 
        let
            heatmap =
                calculateHeatmap game.settings.spyRadius defaultHeatmapSize (game.evilMembers ++ List.map spyToPerson newSpies)
        in
        { game
            | phase =
                EvilPhase
                    { heatmap = heatmap
                    , minValue = List.minimum heatmap |> Maybe.withDefault 0
                    , maxValue = List.maximum heatmap |> Maybe.withDefault 0
                    , cursorData = Nothing
                    , boardElement = Nothing
                    , antispyDevices = []
                    , undetectedSpies = newSpies
                    , detectedSpies = []
                    , goodInitialScore = newTotalValue
                    }
        }


{-| Returns the new game state after placing an antispy device on the board during the evil phase
-}
placeAntispy : AntispyDevice -> Game -> EvilData -> Game
placeAntispy antispyDevice game data =
    let
        newAntiSpyDevices =
            antispyDevice :: data.antispyDevices

        newDetectedSpiesThisRound =
            detectedSpies antispyDevice game.settings.deviceRadius data.undetectedSpies

        newDetectedSpied =
            newDetectedSpiesThisRound
                |> List.append data.detectedSpies
                |> List.Extra.unique

        newUndetectedSpies =
            data.undetectedSpies
                |> List.filter (\spy -> not (List.member spy newDetectedSpiesThisRound))

        newEvilData =
            { data
                | antispyDevices = newAntiSpyDevices
                , undetectedSpies = newUndetectedSpies
                , detectedSpies = newDetectedSpied
                , cursorData = Nothing
            }
    in
    if List.length newAntiSpyDevices < game.settings.numDevices && List.length newUndetectedSpies > 0 then
        { game
            | phase =
                EvilPhase newEvilData
        }

    else
        let
            allIncluded =
                game.evilMembers
                    |> List.filter (\member -> List.any (\spy -> inRadius spy game.settings.spyRadius member) newUndetectedSpies)
                    |> List.Extra.unique

            finalScore =
                allIncluded
                    |> List.map .value
                    |> List.sum
        in
        { game
            | phase =
                Complete
                    newEvilData
                    { goodInitialScore = data.goodInitialScore
                    , numSpiesFound = List.length newDetectedSpied
                    , includedEvilMembers = allIncluded
                    , goodFinalScore = finalScore
                    }
        }



--------------------------------------------------------------------------------
-- GAME LOGIC HELPERS
--------------------------------------------------------------------------------


{-| Generate a random coordinate given the board size.
-}
generateRandomCoord : BoardSize -> Generator Coord
generateRandomCoord boardSize =
    Random.map2 Coord (Random.float 0.0 boardSize) (Random.float 0.0 boardSize)


{-| Generate a list of random coordinates given the board size the number of coordinates to generate.
-}
generateRandomCoords : BoardSize -> Int -> Generator (List Coord)
generateRandomCoords boardSize numCoords =
    Random.list numCoords (generateRandomCoord boardSize)


{-| Special values of high-ranking members of Evil (which provide more points)
-}
specialValues : List Int
specialValues =
    [ 9, 8, 7, 6, 5 ]
    -- []


{-| Generate the initial people in the grid.
The first X coordinates get higher values; the remainder get a value of 1.
-}
generateEvilMembers : BoardSize -> Int -> Generator (List EvilMember)
generateEvilMembers boardSize numEvilMembers =
    let
        randomCoords =
            generateRandomCoords boardSize numEvilMembers

        values =
            List.append specialValues (List.repeat (numEvilMembers - List.length specialValues) 1)
    in
    randomCoords
        |> Random.map (\coords -> List.map2 EvilMember coords values)


inRadius : Coord -> Float -> EvilMember -> Bool
inRadius coord radius evilMember =
    distance coord evilMember.coord < radius

inRadiusCoord : Coord -> Float -> Coord -> Bool
inRadiusCoord center radius other =
    distance center other < radius


{-| Return the sum of the values of all the evil members within the spy's radius.
-}
spySumValue : Spy -> Float -> List EvilMember -> Int
spySumValue spy listeningRadius evilMembers =

    evilMembers
        |> List.filter (inRadius spy listeningRadius)
        |> List.map .value
        |> List.sum


{-| Return all the spies within a antispy device radius
-}
detectedSpies : AntispyDevice -> Float -> List Coord -> List Coord
detectedSpies antispyDevice antispyRadius spies =
    spies
        |> List.filter (\spy -> distance antispyDevice spy < antispyRadius)


spyToPerson : Spy -> Person
spyToPerson spy =
    { coord = spy
    , value = 1
    }


calculateHeatmap : Float -> Int -> List EvilMember -> List Int
calculateHeatmap listeningRadius heatmapSize evilMembers =
    let
        -- Default to checking every 1 unit
        range =
            List.range 0 (heatmapSize - 1)

        -- Add 0.5 to check the centre of the square
        coordsToCheck =
            range
                |> List.map (\y -> List.map (\x -> Coord (toFloat x + 0.5) (toFloat y + 0.5)) range)
                |> List.concat

        values =
            coordsToCheck
                |> List.map (\coord -> spySumValue coord listeningRadius evilMembers)
    in
    values



--------------------------------------------------------------------------------
-- INTERFACE LOGIC
--
-- This section deals with how to map the interface to the game logic.
--
-- Msg contains messages that can be sent from the game interface. You should then
-- choose how to handle them in terms of game logic.
--
-- This also sets scaffolding for the computer players - when a computer player
-- makes a move, they generate a message (ReceivedComputerMove) which is then handled
-- just like a player interacting with the interface.
--------------------------------------------------------------------------------


{-| The type of mouse movement data
-}
type alias MouseMoveData =
    { offsetX : Int
    , offsetY : Int
    }


{-| Decode mouse move data on mouse move
-}
mouseMoveDecoder : Decoder MouseMoveData
mouseMoveDecoder =
    Decode.map2 MouseMoveData
        (Decode.at [ "clientX" ] Decode.int)
        (Decode.at [ "clientY" ] Decode.int)


{-| Convert mouse move data to a coordinate
-}
mouseMoveDataToCoord : Dom.Element -> MouseMoveData -> Maybe Coord
mouseMoveDataToCoord boardElement data =
    let
        x =
            data.offsetX

        y =
            data.offsetY

        dx = 
            toFloat x - boardElement.element.x
        
        dy = 
            toFloat y - boardElement.element.y

        height =
            boardElement.element.height

        width =
            boardElement.element.width
        coord = 
            Coord (dx / width * defaultBoardSize) (dy / height * defaultBoardSize)
    in
    if strictWithin defaultBoardSize coord then 
        Just coord
    else
        Nothing


{-| An enumeration of all messages that can be sent from the interface to the game
-}
type Msg
    = GoodClickedSpyCoord
    | GoodMovedMouse MouseMoveData
    | ReceivedBoardElement (Result Dom.Error Dom.Element)
    | EvilClickedAntispyCoord
    | EvilMovedMouse MouseMoveData
    | ResizedWindow Int Int
    | ToggleHeatmap 
    | NoOp 


{-| A convenience function to pipe a command into a (Game, Cmd Msg) tuple.
-}
withCmd : Cmd Msg -> Game -> ( Game, Cmd Msg )
withCmd cmd game =
    ( game, cmd )


{-| The main update function for the game, which takes an interface message and returns
a new game state as well as any additional commands to be run.
-}
update : Msg -> Game -> ( Game, Cmd Msg )
update msg game =
    case ( game.phase, msg ) of
        ( GoodPhase data, GoodClickedSpyCoord ) ->
            case data.cursorData of
                Just coordData ->
                    let
                        newGame = 
                            game |> applyMove (PlaceSpy coordData.coord)
                    in 
                    case newGame.phase of 
                        EvilPhase newData ->
                            newGame |> withCmd (Task.attempt ReceivedBoardElement (Dom.getElement "evil-board"))
                        _ -> 
                            newGame |> withCmd Cmd.none

                Nothing ->
                    ( game, Cmd.none )

        ( GoodPhase data, GoodMovedMouse mouseMoveData ) ->
            case data.boardElement of 
                Just boardElement -> 
                    case mouseMoveDataToCoord boardElement mouseMoveData of 
                        Just newCoord -> 
                            let

                                newIncluded =
                                    game.evilMembers
                                        |> List.filter (inRadius newCoord game.settings.spyRadius)

                                newValue =
                                    newIncluded
                                        |> List.map .value
                                        |> List.sum

                                newCursorData =
                                    { coord = newCoord
                                    , included = newIncluded
                                    , value = newValue
                                    }
                            in
                            { game | phase = GoodPhase { data | cursorData = Just newCursorData } }
                            |> withCmd Cmd.none
                        Nothing -> 
                            { game | phase = GoodPhase { data | cursorData = Nothing }}
                            |> withCmd Cmd.none
                Nothing -> 
                    { game | phase = GoodPhase { data | cursorData = Nothing }}
                    |> withCmd Cmd.none

        (GoodPhase data , ReceivedBoardElement result) -> 
                case result of 
                    Ok element -> 
                        { game | phase = GoodPhase { data | boardElement = Just element }}
                        |> withCmd Cmd.none
                    Err _ ->
                        ( game, Cmd.none )

        (GoodPhase data, ResizedWindow x y) -> 
            game 
                |> withCmd (Task.attempt ReceivedBoardElement (Dom.getElement "good-board"))

        (EvilPhase data, EvilClickedAntispyCoord) ->
            case data.cursorData of
                Just coordData ->
                    game
                        |> applyMove (PlaceAntispyDevice coordData.coord)
                        |> withCmd Cmd.none

                Nothing ->
                    ( game, Cmd.none )

        (EvilPhase data, EvilMovedMouse mouseMoveData) -> 
            case data.boardElement of 
                Just boardElement -> 
                    case mouseMoveDataToCoord boardElement mouseMoveData of 
                        Just newCoord -> 
                            let

                                allPeople = 
                                    data.undetectedSpies
                                    |> List.map spyToPerson
                                    |> List.append game.evilMembers

                                newIncluded =
                                    allPeople
                                        |> List.filter (inRadius newCoord game.settings.deviceRadius)

                                newValue =
                                    newIncluded
                                        |> List.map .value
                                        |> List.sum

                                newCursorData =
                                    { coord = newCoord
                                    , included = newIncluded
                                    , value = newValue
                                    }
                            in
                            { game | phase = EvilPhase { data | cursorData = Just newCursorData } }
                            |> withCmd Cmd.none
                        Nothing -> 
                            { game | phase = EvilPhase { data | cursorData = Nothing }}
                            |> withCmd Cmd.none
                Nothing -> 
                    { game | phase = EvilPhase { data | cursorData = Nothing }}
                    |> withCmd Cmd.none

        ( EvilPhase data, ReceivedBoardElement result ) ->
            case result of 
                Ok element -> 
                    { game | phase = EvilPhase { data | boardElement = Just element }}
                    |> withCmd Cmd.none
                Err _ ->
                    ( game, Cmd.none )

        ( EvilPhase data, ResizedWindow x y ) ->
            game 
                |> withCmd (Task.attempt ReceivedBoardElement (Dom.getElement "evil-board"))
        (_, ToggleHeatmap) -> 
            { game | showHeatmap = not game.showHeatmap }
            |> withCmd Cmd.none


        _ ->
            ( game, Cmd.none )



--------------------------------------------------------------------------------
-- GAME VIEW FUNCTION
--------------------------------------------------------------------------------

-- SVGS


{-| The main view function that gets called from the Main application.

Essentially, takes a game and projects it into a HTML interface where Messages
can be sent from.

-}
view : Game -> Html Msg
view game =
    let
        (phaseView, cursorMsg) = 
            case game.phase of
                GoodPhase goodData ->
                    (viewGoodPhase game goodData, GoodMovedMouse)

                EvilPhase evilData ->
                    (viewEvilPhase game evilData, EvilMovedMouse)

                Complete evilData finalScore ->
                    (viewComplete game evilData finalScore, (\_ -> NoOp))



    in
    div [ id "attached-cursor-layer", on "mousemove" (Decode.map cursorMsg mouseMoveDecoder) ] 
        [ div [id "game-screen-container", class "screen-container"]
            [phaseView ]
        ]

{-| View the good phase screen
-}
viewGoodPhase : Game -> GoodData -> Html Msg
viewGoodPhase game data =
    div [ id "view-good-phase", class "phase"]
        [ viewGoodPhaseBoard game data
        , viewGoodPhaseStatus game data ]

viewGoodPhaseStatus : Game -> GoodData -> Html Msg
viewGoodPhaseStatus game data = 
    div [id "good-status", class "status"]
        [ div [id "good-status-spy-count", class "status-item"]
            [ text ("Spies: " ++ String.fromInt (List.length data.spies) ++ "/" ++ String.fromInt game.settings.numSpies)]
        , div [id "good-status-total-value", class "status-item"]
            [ text ("Total value: " ++ String.fromInt data.totalValue)]
        , div [id "good-status-cursor-container", class "status-item"]
            [ viewGoodCursorInfo game data ]
        , button [onClick ToggleHeatmap, classList [("is-selected", game.showHeatmap)]] [text "Toggle Heatmap"]
        ]

viewGoodCursorInfo : Game -> GoodData -> Html Msg
viewGoodCursorInfo game data = 
    case data.cursorData of 
        Just cursorData -> 
            div [id "good-status-cursor-information"]
                [ text ("Cursor value: " ++ String.fromInt cursorData.value)]
        Nothing -> 
            div [] []

{-| Turn a heatmap size into a string for grid template css -}
gridTemplateString : String
gridTemplateString = 
        "repeat(" ++ String.fromInt defaultHeatmapSize ++ ", 1fr)"


{-| View the board for the good phase.
-}
viewGoodPhaseBoard : Game -> GoodData -> Html Msg
viewGoodPhaseBoard game data =
    div [ id "good-board-container", class "board-container" ]
        [ img [id "board-background", src "map.png"] []
        , div [ id "good-board", class "board", onClick GoodClickedSpyCoord ]
            [ -- The heatmap
            div [ classList [("is-visible", game.showHeatmap)], class "board-layer-container heatmap-container"]
                [Html.Lazy.lazy3 viewHeatmapLazy data.minValue data.maxValue data.heatmap]

            -- The evil members
            , div [ id "good-board-evil-members", class "board-layer evil-members" ]
                (List.map (viewEvilMember "" defaultBoardSize) game.evilMembers)

            -- The included evil members
            , div [ id "good-board-included-evil-members", class "board-layer" ]
                (List.map (viewEvilMember "included" defaultBoardSize) data.allIncluded)


            -- The cursor evil members
            , viewCursorIncluded data.cursorData

            -- The cursor hover
            , div [ id "good-board-cursor-hover", class "board-layer"]
                [ viewCursorHover "good-cursor" game.settings.spyRadius data.cursorData]

            -- The spies
            , div [ id "good-board-spies", class "board-layer" ]
                (List.map (viewSpy "" game.settings.spyRadius defaultBoardSize) data.spies)


            -- The cursor layer
            ]
        , div [id "good-phase-transition-card", class "phase-transition"] [ h1 [] [text "GOOD Phase"], h2 [] [text "GOOD: Place your spies!"], h2 [] [text "EVIL: Look away!"], div [] [text "The phase will start in 5 seconds."]]
        ]

{-| Lazily view the heatmap -}
viewHeatmapLazy : Int -> Int -> List Int -> Html Msg
viewHeatmapLazy minValue maxValue heatmap =
    div [class "board-layer heatmap",  style "grid-template-columns" gridTemplateString, style "grid-template-rows" gridTemplateString ] (List.map (viewHeatmapSquare minValue maxValue) heatmap)

{-| Convert a heatmap value to a colour string
-}
heatmapColour : Int -> Int -> Int -> String
heatmapColour minValue maxValue value =
    let
        normalisedValue =
            toFloat (value - minValue)  / toFloat ( maxValue - minValue)
    in
    "rgba(0, 0, 0, " ++ String.fromFloat normalisedValue ++ ")"


{-| View a single heatmap square
-}
viewHeatmapSquare : Int -> Int -> Int -> Html Msg
viewHeatmapSquare minValue maxValue value =
    div [ class "heatmap-square", style "background" (heatmapColour minValue maxValue value) ] []


{-| Convert a value in range [0, 1] to a percentage string
-}
toPct : Float -> String
toPct value =
    String.fromFloat (value * 100) ++ "%"


viewEvilMember : String -> BoardSize -> EvilMember -> Html Msg
viewEvilMember extraClasses boardSize member =
    let
        -- Width as proportion in range [0,1]
        width =
            0.02

        left =
            toPct (member.coord.x / boardSize - width / 2)

        top =
            toPct (member.coord.y / boardSize- width / 2)

        (extraClass2, icon) = 
            case member.value of 
                5 -> ("special", Icons.icon5)
                6 -> ("special", Icons.icon6)
                7 -> ("special", Icons.icon7)
                8 -> ("special", Icons.icon8)
                9 -> ("special", Icons.icon9)
                _ -> ("", Icons.icon1)
    in
    div [ class "evil-member", class extraClass2, class extraClasses, style "left" left, style "top" top, style "width" (toPct width), style "height" (toPct width) ]
        [ icon [] ]

viewCursorIncluded : Maybe CursorData -> Html Msg
viewCursorIncluded maybe = 
    case maybe of 
        Just data -> 
            div [ id "good-board-cursor-included", class "board-layer"]
                (List.map (viewEvilMember "cursor-included" defaultBoardSize) data.included)
        Nothing -> 
            div [] []


viewSpy : String -> Float -> BoardSize -> Spy -> Html Msg
viewSpy extraClasses radius boardSize spy =
    let
        width =
            0.01

        left =
            toPct (spy.x / boardSize - width / 2)

        top =
            toPct (spy.y / boardSize- width / 2)
        widthCircle = 
            2 * radius / defaultBoardSize

        leftCircle = 
            toPct (spy.x / defaultBoardSize - widthCircle / 2)
        topCircle = 
            toPct (spy.y / defaultBoardSize - widthCircle / 2)

    in
    div [class "spy-container"] 
    [ div [ class "spy", class extraClasses, style "left" left, style "top" top, style "width" (toPct width), style "height" (toPct width) ] [ ]
    , div [class "spy-circle", class extraClasses, style "left" leftCircle, style "top" topCircle, style "width" (toPct widthCircle), style "height" (toPct widthCircle)] []
    ]

viewCursorHover : String -> Float -> Maybe CursorData -> Html Msg
viewCursorHover extraClass radius maybeData = 
    case maybeData of 
        Nothing -> 
            div [] []
        Just data -> 
            let
                widthPoint = 
                    0.01

                leftPoint = 
                    toPct (data.coord.x / defaultBoardSize - widthPoint / 2)

                topPoint = 
                    toPct (data.coord.y / defaultBoardSize - widthPoint / 2)

                widthCircle = 
                    2 * radius / defaultBoardSize

                leftCircle = 
                    toPct (data.coord.x / defaultBoardSize - widthCircle / 2)
                topCircle = 
                    toPct (data.coord.y / defaultBoardSize - widthCircle / 2)

                pointText = 
                    if extraClass == "good-cursor" then 
                        div [class "cursor-hover-point-text"] [text (String.fromInt data.value)]
                    else 
                        div [] []

            in 
            div [class extraClass]
                [ div [class "cursor-hover-circle", style "left" leftCircle, style "top" topCircle, style "width" (toPct widthCircle), style "height" (toPct widthCircle)] []
                , div [class "cursor-hover-point", style "left" leftPoint, style "top" topPoint, style "width" (toPct widthPoint), style "height" (toPct widthPoint)] [pointText]
                ]


{-| View the evil phase screen
-}
viewEvilPhase : Game -> EvilData -> Html Msg
viewEvilPhase game data =
   div [ id "view-evil-phase", class "phase"]
        [ viewEvilPhaseBoard game data
        , viewEvilPhaseStatus game data ]

viewEvilPhaseBoard : Game -> EvilData -> Html Msg
viewEvilPhaseBoard game data = 
    let
        allPeople = 
            data.undetectedSpies
            |> List.map spyToPerson
            |> List.append game.evilMembers

    in
    div [ id "evil-board-container", class "board-container" ]
        [ img [id "board-background", src "map.png"] []
        , div [ id "evil-board", class "board", onClick EvilClickedAntispyCoord ]
            [ -- The heatmap

            div [ classList [("is-visible", game.showHeatmap)], class "board-layer-container heatmap-container"]
                [ Html.Lazy.lazy3 viewHeatmapLazy data.minValue data.maxValue data.heatmap ] 

            -- ALL people
            , div [ id "evil-board-evil-members", class "board-layer evil-members" ]
                (List.map (viewEvilMember "" defaultBoardSize) allPeople)

            -- The detected spies
            , div [ id "evil-board-detected-spies", class "board-layer" ]
                (List.map (viewSpy "detected" game.settings.spyRadius defaultBoardSize) data.detectedSpies)

            -- The cursor evil members
            , viewCursorIncluded data.cursorData

            -- The cursor hover
            , div [ id "evil-board-cursor-hover", class "board-layer"]
                [ viewCursorHover "evil-cursor" game.settings.deviceRadius data.cursorData]

            -- The devices
            , div [ id "evil-board-devices", class "board-layer" ]
                (List.map (viewAntispyDevice "" game.settings.deviceRadius defaultBoardSize) data.antispyDevices)


            -- The cursor layer
            ]


        , div [id "good-phase-transition-card", class "phase-transition"]  []
        , div [id "evil-phase-transition-card", class "phase-transition"] 
            [ h1 [] [text "EVIL Phase"], h2 [] [text "GOOD has placed their spies."], h2 [] [text "EVIL: Place your devices."], div [] [text "The phase will start in 5 seconds."]]

        ]

viewAntispyDevice : String -> Float -> BoardSize -> Spy -> Html Msg
viewAntispyDevice extraClasses radius boardSize spy =
    let
        width =
            0.01

        left =
            toPct (spy.x / boardSize - width / 2)

        top =
            toPct (spy.y / boardSize- width / 2)
        widthCircle = 
            2 * radius / defaultBoardSize

        leftCircle = 
            toPct (spy.x / defaultBoardSize - widthCircle / 2)
        topCircle = 
            toPct (spy.y / defaultBoardSize - widthCircle / 2)

    in
    div [class "device-container"] 
    [ div [ class "device", class extraClasses, style "left" left, style "top" top, style "width" (toPct width) ] [ text "D" ]
    , div [class "device-circle", class extraClasses, style "left" leftCircle, style "top" topCircle, style "width" (toPct widthCircle), style "height" (toPct widthCircle)] []
    ]

viewEvilPhaseStatus: Game -> EvilData -> Html Msg
viewEvilPhaseStatus game data = 
    div [id "evil-status", class "status"]
        [ div [id "evil-status-device-count", class "status-item"]
            [ text ("Devices: " ++ String.fromInt (List.length data.antispyDevices) ++ "/" ++ String.fromInt game.settings.numDevices)]
        , div [id "evil-status-detected-spies", class "status-item"]
            [ text ("Spies detected: " ++ String.fromInt (List.length data.detectedSpies) ++ "/" ++ String.fromInt game.settings.numSpies )]
        , div [id "evil-status-cursor-container", class "status-item"]
            [ viewEvilCursorInfo game data ]
        , button [onClick ToggleHeatmap, classList [("is-selected", game.showHeatmap)]] [text "Toggle Heatmap"]
        ]

viewEvilCursorInfo : Game -> EvilData -> Html Msg
viewEvilCursorInfo game data = 
    case data.cursorData of 
        Just cursorData -> 
            div [id "good-status-cursor-information"]
                [ text ("Number probed: " ++ String.fromInt (List.length cursorData.included))]
        Nothing -> 
            div [] []




{-| View the completion screen at the end of the game.
-}
viewComplete : Game -> EvilData -> FinalScore -> Html Msg
viewComplete game data finalScore =
    div [ id "view-complete-phase", class "phase"]
        [ viewCompletePhaseBoard game data finalScore
        , viewCompletePhaseStatus game data finalScore]
   
viewCompletePhaseBoard : Game -> EvilData -> FinalScore -> Html Msg
viewCompletePhaseBoard game data score = 
    div [ id "complete-board-container", class "board-container" ]
        [ img [id "board-background", src "map.png"] []
        , div [ id "complete-board", class "board", onClick EvilClickedAntispyCoord ]
            [ -- The heatmap
            div [ classList [("is-visible", game.showHeatmap)], class "board-layer-container heatmap-container"]
                [ Html.Lazy.lazy3 viewHeatmapLazy data.minValue data.maxValue data.heatmap] 


            -- Evil members
            , div [ id "complete-board-evil-members", class "board-layer evil-members" ]
                (List.map (viewEvilMember "" defaultBoardSize) game.evilMembers)

            -- The included evil members
            , div [ id "complete-board-included-evil-members", class "board-layer evil-members" ]
                (List.map (viewEvilMember "" defaultBoardSize) score.includedEvilMembers)

            -- The detected spies
            , div [ id "complete-board-detected-spies", class "board-layer" ]
                (List.map (viewSpy "detected" game.settings.spyRadius defaultBoardSize) data.detectedSpies)

            -- The undetected spies
            , div [ id "complete-board-undetected-spies", class "board-layer" ]
                (List.map (viewSpy "undetected" game.settings.spyRadius defaultBoardSize) data.undetectedSpies)

            -- The devices
            , div [ id "complete-board-devices", class "board-layer" ]
                (List.map (viewAntispyDevice "" game.settings.deviceRadius defaultBoardSize) data.antispyDevices)

            ]

        , div [id "good-phase-transition-card", class "phase-transition", style "display" "none"]  []
        , div [id "evil-phase-transition-card", class "phase-transition", style "display" "none"]  []
        , div [id "complete-phase-transition-card", class "phase-transition"] []
        ]

viewCompletePhaseStatus : Game -> EvilData -> FinalScore -> Html Msg
viewCompletePhaseStatus game data score = 
    div [id "complete-status", class "status"]
        [ div [id "complete-status-good-initial-score", class "status-item"]
            [ text ("Good initial score: " ++ String.fromInt score.goodInitialScore)]
        , div [id "complete-status-good-final-score", class "status-item"]
            [ text ("Good final score: " ++ String.fromInt score.goodFinalScore)]
        , div [id "complete-status-spies-found", class "status-item"]
            [ text ("Spies found: " ++ String.fromInt score.numSpiesFound ++ "/" ++ String.fromInt game.settings.numSpies)]
        , button [onClick ToggleHeatmap, classList [("is-selected", game.showHeatmap)]] [text "Toggle Heatmap"]
        ]