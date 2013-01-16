{-# LANGUAGE OverloadedStrings #-}
-- | Generic binding of keys to commands, procesing macros,
-- printing command help. No operation in this module
-- involves the 'State' or 'Action' type.
module Game.LambdaHack.Client.Binding
  ( Binding(..), stdBinding, keyHelp,
  ) where

import qualified Data.Char as Char
import qualified Data.List as L
import qualified Data.Map as M
import qualified Data.Set as S
import Data.Text (Text)
import qualified Data.Text as T
import Data.Tuple (swap)

import Game.LambdaHack.Client.CmdPlayer
import Game.LambdaHack.Client.Config
import qualified Game.LambdaHack.Client.Key as K
import Game.LambdaHack.Msg

-- | Bindings and other information about player commands.
data Binding = Binding
  { kcmd    :: M.Map K.KM (Text, Bool, CmdPlayer)
                                     -- ^ binding keys to commands
  , kmacro  :: M.Map K.Key K.Key     -- ^ macro map
  , kmajor  :: [K.KM]                -- ^ major commands
  , kminor  :: [K.KM]                -- ^ minor commands
  , krevMap :: M.Map CmdPlayer K.KM  -- ^ from cmds to their main keys
  }

-- | The associaction of commands to keys defined in config.
configCmds :: ConfigUI -> [(K.KM, CmdPlayer)]
configCmds ConfigUI{configCommands} =
  let mkCommand (key, def) = ((key, K.NoModifier), read def :: CmdPlayer)
  in map mkCommand configCommands

-- | Binding of keys to movement and other standard commands,
-- as well as commands defined in the config file.
stdBinding :: ConfigUI  -- ^ game config
           -> Binding   -- ^ concrete binding
stdBinding !config@ConfigUI{configMacros} =
  let kmacro = M.fromList $ configMacros
      heroSelect k = ((K.Char (Char.intToDigit k), K.NoModifier), SelectHero k)
      cmdList =
        configCmds config
        ++ K.moveBinding Move Run
        ++ fmap heroSelect [0..9]
        ++ [ ((K.Char 'a', K.Control), DebugArea)
           , ((K.Char 'o', K.Control), DebugOmni)
           , ((K.Char 's', K.Control), DebugSmell)
           , ((K.Char 'v', K.Control), DebugVision)
           ]
      mkDescribed cmd = (cmdDescription cmd, noRemoteCmdPlayer cmd, cmd)
      mkCommand (km, def) = (km, mkDescribed def)
      semList = L.map mkCommand cmdList
  in Binding
  { kcmd = M.fromList semList
  , kmacro
  , kmajor = L.map fst $ L.filter (majorCmdPlayer . snd) cmdList
  , kminor = L.map fst $ L.filter (minorCmdPlayer . snd) cmdList
  , krevMap = M.fromList $ map swap cmdList
  }

coImage :: M.Map K.Key K.Key -> K.Key -> [K.Key]
coImage kmacro k =
  let domain = M.keysSet kmacro
  in if k `S.member` domain
     then []
     else k : [ from | (from, to) <- M.assocs kmacro, to == k ]

-- | Produce a set of help screens from the key bindings.
keyHelp :: Binding -> Slideshow
keyHelp Binding{kcmd, kmacro, kmajor, kminor} =
  let
    movBlurb =
      [ "Move throughout the level with numerical keypad or"
      , "the Vi text editor keys (also known as \"Rogue-like keys\"):"
      , ""
      , "               7 8 9          y k u"
      , "                \\|/            \\|/"
      , "               4-5-6          h-.-l"
      , "                /|\\            /|\\"
      , "               1 2 3          b j n"
      , ""
      ,"Run ahead until anything disturbs you, with SHIFT (or CTRL) and a key."
      , "Press keypad '5' or '.' to wait a turn, bracing for blows next turn."
      , "In targeting mode the same keys move the targeting cursor."
      , ""
      , "Search, open and attack, by bumping into walls, doors and monsters."
      , ""
      , "Press SPACE to see the next page, with the list of major commands."
      ]
    majorBlurb =
      [ ""
      , "Commands marked with * take time and are blocked on remote levels."
      , "Press SPACE to see the next page, with the list of minor commands."
      ]
    minorBlurb =
      [ ""
      , "For more playing instructions see file PLAYING.md."
      , "Press SPACE to clear the messages and see the map again."
      ]
    fmt k h = T.replicate 16 " "
              <> T.justifyLeft 15 ' ' k
              <> T.justifyLeft 41 ' ' h
    fmts s  = " " <> T.justifyLeft 71 ' ' s
    blank   = fmt "" ""
    mov     = map fmts movBlurb
    major   = map fmts majorBlurb
    minor   = map fmts minorBlurb
    keyCaption = fmt "keys" "command"
    disp k  = T.concat $ map showT $ coImage kmacro k
    keys l  = [ fmt (disp k) (h <> if timed then "*" else "")
              | ((k, K.NoModifier), (h, timed, _)) <- l, h /= "" ]
    (kcMajor, kcRest) =
      L.partition ((`elem` kmajor) . fst) (M.toAscList kcmd)
    (kcMinor, _) =
      L.partition ((`elem` kminor) . fst) kcRest
  in toSlideshow $
    [ ["Basic keys. [press SPACE to advance]"] ++ [blank]
      ++ mov ++ [moreMsg]
    , ["Basic keys. [press SPACE to advance]"] ++ [blank]
      ++ [keyCaption] ++ keys kcMajor ++ major ++ [moreMsg]
    , ["Basic keys."] ++ [blank]
      ++ [keyCaption] ++ keys kcMinor ++ minor
    ]
