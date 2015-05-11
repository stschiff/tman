import Task (Task(..), tSubmit, recursiveCheckAll, tInfo, tClean, tLog, tLsfLog, tLsfKill, SubmissionType(..), 
             TaskStatus(..), TaskInfo(..))
import Project (Project(..), loadProject, checkUniqueJobNames)
import Control.Error (runScript, Script, scriptIO)
import Control.Error.Safe (tryAssert)
import Control.Applicative ((<$>), (<*>))
import qualified Options.Applicative as OP
import Data.Monoid ((<>))
import qualified Data.Map as M
import Data.List (intercalate, sortBy, groupBy)
import Control.Monad.Trans.Either (left, hoistEither)
import Text.Format (format)
import Data.List.Split (splitOn)
import Control.Monad (forM_)
import System.FilePath.GlobPattern ((~~))

data Options = Options FilePath Command
data Command = CmdSubmit SubmitOpt | CmdList ListOpt | CmdPrint PrintOpt | CmdStatus StatusOpt | CmdClean CleanOpt |
               CmdLog LogOpt | CmdKill KillOpt

data SubmitOpt = SubmitOpt {
    _suGroupName :: String,
    _suForce :: Bool,
    _suTest :: Bool,
    _suSubmissionType :: String
}

data ListOpt = ListOpt {
    _liGroupName :: String,
    _liSummary :: Int,
    _liFull :: Bool
}

data PrintOpt = PrintOpt {
    _prGroupName :: String
}

data StatusOpt = StatusOpt {
    _stGroupName :: String,
    _stSummary :: Int,
    _stInfo :: Bool
}

data CleanOpt = CleanOpt {
    _clGroupName :: String
}

data LogOpt = LogOpt {
    _loGroupName :: String,
    _loLSF :: Bool
}

data KillOpt = KillOpt {
    _kiGroupName :: String,
    _kiLSF :: Bool
}

main :: IO ()
main = OP.execParser optParser >>= runWithOptions
  where
    optParser = OP.info (OP.helper <*> options) (OP.fullDesc <> OP.progDesc "task processing tool")

runWithOptions :: Options -> IO ()
runWithOptions (Options projectFileName cmdOpts) = runScript $ do
    jobProject <- loadProject projectFileName
    tryAssert "job names must be unique" $ checkUniqueJobNames jobProject
    case cmdOpts of
        CmdSubmit opts -> runSubmit jobProject opts
        CmdList opts -> runList jobProject opts
        CmdPrint opts -> runPrint jobProject opts
        CmdStatus opts -> runStatus jobProject opts
        CmdClean opts -> runClean jobProject opts
        CmdLog opts -> runLog jobProject opts
        CmdKill opts -> runKill jobProject opts

runSubmit :: Project -> SubmitOpt -> Script ()
runSubmit jobProject (SubmitOpt groupName force test submissionType) = do
    tasks <- hoistEither $ selectTasks groupName jobProject
    let projectDir = _prLogDir jobProject
    status <- recursiveCheckAll tasks
    info <- mapM (tInfo projectDir) tasks
    submissionType <- case submissionType of
        "lsf" -> return LSFsubmission
        "standard" -> return StandardSubmission
        _ -> left "unknown submission type"
    forM_ (zip3 tasks status info) $ \(t, s, i) -> do
        if i == InfoNotFinished then do
            let msg = format "Job {0}: already running? skipping. Use --clean to reset" [_tName t]
            scriptIO . putStrLn $ msg
        else
            case s of
                StatusMissingInput -> scriptIO . putStrLn $ format "Job {0}: missing input, skipping" [_tName t] 
                StatusOutdatedR -> scriptIO . putStrLn $ format "Job {0}: outdated input, skipping" [_tName t] 
                StatusComplete -> if force then
                        tSubmit projectDir test submissionType t
                    else do
                        let msg = format "Job {0}: already complete, skipping (use --force to submit anyway)"
                                         [_tName t] 
                        scriptIO . putStrLn $ msg
                _ -> tSubmit projectDir test submissionType t
        

runList :: Project -> ListOpt -> Script ()
runList jobProject opts = do
    tasks <- hoistEither $ selectTasks (_liGroupName opts) jobProject
    let summaryLevel = _liSummary opts
    if summaryLevel > 0 then do
        let groups = map (intercalate "/" . take summaryLevel . splitOn "/" . _tName) tasks
            entries = sortBy (\(e1, _) (e2, _) -> e1 `compare` e2) . M.toList .
                      foldl (\mm k -> M.insertWith (+) k 1 mm) M.empty $ groups
        scriptIO . mapM_ putStrLn $ [format "Group {0}: {1} {2}" [g, show num, if num == 1 then "job" else "jobs"]
                                     | (g, num) <- entries]
    else do
        let indices = if (_liFull opts) then [0..6] else [0..4]
            headers = ["NAME", "MEMORY", "THREADS", "SUBMISSION-QUEUE", "SUBMISSION-GROUP", 
                                                  "INPUTFILES", "OUTPUTFILES"]
        scriptIO . putStrLn . intercalate "\t" . map (headers!!) $ indices
        scriptIO . mapM_ putStrLn . map (tMeta indices) $ tasks
  where
    tMeta indices (Task n i o _ m t q g) =
        let vals = [n, show m, show t, q, g, intercalate "," i, intercalate "," o]
        in  intercalate "\t" . map (vals!!) $ indices
        

runPrint :: Project -> PrintOpt -> Script ()
runPrint jobProject opts = do
    tasks <- hoistEither $ selectTasks (_prGroupName opts) jobProject
    scriptIO (mapM_ putStrLn . map _tCommand $ tasks)

runStatus :: Project -> StatusOpt -> Script ()
runStatus jobProject opts = do
    tasks <- hoistEither $ selectTasks (_stGroupName opts) jobProject
    labels <- if (_stInfo opts) then
            mapM (fmap show . tInfo (_prLogDir jobProject)) tasks
        else
            map show <$> recursiveCheckAll tasks
    let summaryLevel = _stSummary opts
    if summaryLevel > 0 then do
        let groups = map (intercalate "/" . take summaryLevel . splitOn "/" . _tName) tasks
            dict :: M.Map (String, String) Int
            dict = foldl (\mm k -> M.insertWith (+) k 1 mm) M.empty $ zip groups labels
            entries = map (\subList -> (fst . fst . head $ subList, [(s, c) | ((_, s), c) <- subList])) .
                      groupBy (\((e1, _), _) ((e2, _), _) -> e1 == e2) .
                      sortBy (\((e1, _), _) ((e2, _), _) -> e1 `compare` e2) . M.toList $ dict
        scriptIO . mapM_ putStrLn $ 
            ["Group " ++ g ++ ": " ++ intercalate ", " [format "{0}({1})" [s, show c] | (s, c) <- l] |
             (g, l) <- entries]
    else do
        let l = zipWith (\t l -> format "Job {0}: {1}" [_tName t, l]) tasks labels
        scriptIO $ mapM_ putStrLn l

selectTasks :: String -> Project -> Either String [Task]
selectTasks group jobProject =
    let ret = if null group then
            (_prTasks jobProject)
        else
            -- filter (startswith groupParts . splitOn "/" . _tName) $ _prTasks jobProject
            filter ((~~ group) . _tName) . _prTasks $ jobProject
     in  if null ret then Left "No Tasks found" else Right ret
  -- where
  --   groupParts = splitOn "/" group

runClean :: Project -> CleanOpt -> Script ()
runClean jobProject (CleanOpt groupName) = do
    tasks <- hoistEither $ selectTasks groupName jobProject
    mapM_ (tClean (_prLogDir jobProject)) tasks

runLog :: Project -> LogOpt -> Script ()
runLog jobProject (LogOpt groupName lsf) = do
    task <- hoistEither $ selectTasks groupName jobProject
    tryAssert "multiple tasks found, must select one" $ length task == 1
    logFunc (_prLogDir jobProject) . head $ task
  where
    logFunc = if lsf then tLsfLog else tLog

runKill :: Project -> KillOpt -> Script ()
runKill jobProject (KillOpt groupName lsf) = do
    tasks <- hoistEither $ selectTasks groupName jobProject
    if lsf then
        mapM_ tLsfKill tasks
    else
        left "killing non-LSF jobs not yet implemented"

options :: OP.Parser Options
options = Options <$> parseProjectFileName <*> parseCommand
  where
    parseProjectFileName = OP.strOption (OP.short 'p' <> OP.long "projectFile" <> OP.value "tman.project" <>
                                         OP.showDefault <> OP.metavar "<Project_file>" <>
                                         OP.help "Project file to work with")

parseCommand :: OP.Parser Command
parseCommand = OP.subparser $
    OP.command "submit" (parseSubmit `withInfo` "submit jobs") <>
    OP.command "list" (parseList `withInfo` "list job info") <>
    OP.command "print" (parsePrint `withInfo` "print commands") <>
    OP.command "status" (parseStatus `withInfo` "print status for each job") <>
    OP.command "clean" (parseClean `withInfo` "clean output and log files") <>
    OP.command "log" (parseLog `withInfo` "print log file for a task") <>
    OP.command "kill" (parseKill `withInfo` "kill jobs")

parseSubmit :: OP.Parser Command
parseSubmit = CmdSubmit <$> parseSubmitOpt
  where
    parseSubmitOpt = SubmitOpt <$> parseGroupName <*> parseForce <*> parseTest <*> parseSubmissionType
    parseForce = OP.switch $ OP.short 'f' <> OP.long "force" <> OP.help "force submission of completed tasks"
    parseTest = OP.switch $ OP.short 't' <> OP.long "test" <>
                                            OP.help "only print submission commands, do not actually submit"
    parseSubmissionType = OP.strOption $ OP.short 's' <> OP.long "submissionType" <> OP.value "standard" <>
                                         OP.showDefault <> OP.help "type of submission [standard | lsf]"

parseGroupName :: OP.Parser String
parseGroupName = OP.option OP.str $ OP.short 'g' <> OP.long "jobGroup" <> OP.metavar "<group_desc>" <> OP.value ""
                                                 <> OP.help "Job group name"

withInfo :: OP.Parser a -> String -> OP.ParserInfo a
withInfo opts desc = OP.info (OP.helper <*> opts) $ OP.progDesc desc

parseList :: OP.Parser Command
parseList = CmdList <$> parseListOpt
  where
    parseListOpt = ListOpt <$> parseGroupName <*> parseSummary <*> parseFull
    parseFull = OP.switch $ OP.short 'f' <> OP.long "full" <> OP.help "show full list"

parseSummary :: OP.Parser Int
parseSummary = OP.option OP.auto $ OP.short 's' <> OP.long "summaryLevel" <> OP.value 0 <> OP.showDefault <> 
                                     OP.metavar "<Level>" <>
                                     OP.help "summarize status for groups at given level, leave 0 for now grouping"

parsePrint :: OP.Parser Command
parsePrint = CmdPrint <$> parsePrintOpt
  where
    parsePrintOpt = PrintOpt <$> parseGroupName

parseStatus :: OP.Parser Command
parseStatus = CmdStatus <$> parseStatusOpt
  where
    parseStatusOpt = StatusOpt <$> parseGroupName <*> parseSummary <*> parseInfo
    parseInfo = OP.switch $ OP.short 'i' <> OP.long "info" <> OP.help "show runInfo"

parseClean :: OP.Parser Command
parseClean = CmdClean <$> parseCleanOpt
  where
    parseCleanOpt = CleanOpt <$> parseGroupName

parseLog :: OP.Parser Command
parseLog = CmdLog <$> parseLogOpt
  where
    parseLogOpt = LogOpt <$> parseGroupName <*> parseLogLSF
    parseLogLSF = OP.switch $ OP.short 'l' <> OP.long "lsf" <> OP.help "show lsf log file"
    
parseKill :: OP.Parser Command
parseKill = CmdKill <$> parseKillOpt
  where
    parseKillOpt = KillOpt <$> parseGroupName <*> parseKillLSF
    parseKillLSF = OP.switch $ OP.short 'l' <> OP.long "lsf" <> OP.help "via LSF"
