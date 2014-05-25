module Game.Pong where

import System.Random

import Control.Monad
import Data.Maybe
import Game.Event
import Game.Util (sfVec2f)
import Game.Vector
import Game.Kinematics (runKinematics)
import Control.Monad.SFML (SFML)
import qualified SFML.Graphics as G
import qualified SFML.Window as W
import SFML.Window.Event
import qualified Control.Monad.SFML.Window as WM
import qualified Control.Monad.SFML.Graphics as GM
import SFML.Graphics.Color (black,white)

bound :: (Num a,Ord a) => a -> a -> a -> a
bound low range = min (low+range) . max low

inward :: (Num a,Ord a) => a -> a -> a -> a -> a
inward low range def x
    | x < low       =  1
    | x > low+range = -1
    | otherwise     = def

data Direction = Up | Down | Stop deriving(Show,Read)
data Side = LeftSide | RightSide deriving(Show,Read)

dirToSignum :: Num a => Direction -> a
dirToSignum d = case d of
                    Up -> -1
                    Down -> 1
                    _ -> 0

data Paddle = Paddle { paddleLoc :: Vec2f } deriving(Show,Read)

boundPaddle :: Float -> Float -> Float -> Paddle -> Paddle
boundPaddle low height ph (Paddle (Vec2 x y)) = Paddle (Vec2 x y')
    where
        y' = bound (low+ph/2) (height-ph) y

tickPaddle :: Direction -> Float -> Float -> Paddle -> Paddle
tickPaddle d h dt (Paddle loc) = Paddle $ loc +. (dt *. Vec2 0 vy)
    where
        vy = 1.0*h*dirToSignum d

data Ball = Ball { ballLoc :: Vec2f, ballVel :: Vec2f }
    deriving(Show,Read)

boundBall :: Vec2f -> Vec2f -> Float -> Ball -> Ball
boundBall (Vec2 ox oy) (Vec2 w h) size (Ball (Vec2 lx ly)
                                             (Vec2 vx vy))
        = Ball newLoc newVel
    where
        newLoc = Vec2 (bound minx realw lx) (bound miny realh ly)
        newVel = Vec2 (xBounce*abs vx) (yBounce*abs vy)
        xBounce = inward minx realw (signum vx) lx
        yBounce = inward miny realh (signum vy) ly
        minx = ox+size/2
        miny = oy+size/2
        realw = w-size
        realh = h-size

tickBall :: Float -> Ball -> Ball
tickBall dt (Ball loc vel) = Ball newLoc newVel
    where
        (newVel,newLoc) = runKinematics vzero vel loc dt

data Line v = Line { lPoint :: v,lNormal :: v }

-- Returns t in [0,1] such that the point (t*(p2-p1) + p1) is on line
-- l.
segLineIntersect :: Vec2f -> Vec2f -> Line Vec2f -> Maybe Float
segLineIntersect p1 p2 (Line point normal) = intersect
    where
        intersect = do
            let relP1 = p1 -. point
                relP2 = p2 -. point
            -- If both endpoints are within 90 degrees of the normal, they do
            -- not intersect.
            when ((relP1 `vdot` normal)*(relP2 `vdot` normal) > 0)
                 Nothing
            -- Define the segment as p = p1 + (p2-p1)*t, 0 <= t <= 1
            let diff = p2 -. p1
            -- (p - point) `dot` normal = 0 at intersection
            -- (p1 + diff*t - point) `dot` normal = 0
            -- (p1 - point) `dot` normal + t*(diff `dot` normal) = 0
            -- t = -(relP1 `dot` normal)/(diff `dot` normal)
            return $ negate $ (relP1 `vdot` normal)
                              /(diff `vdot` normal)

data Pong = Pong {
    pScreenSize :: Vec2f,
    pPaddleSize :: Vec2f,
    pBallSize   :: Vec2f,

    pLeftPaddle  :: Paddle,
    pRightPaddle :: Paddle,
    pBall        :: Ball,

    pLeftDir,pRightDir :: Direction,
    pHasFocus :: Bool,

    pRandom :: StdGen,
    pFactor :: Maybe Float,

    pDone :: Bool
} deriving(Show,Read)

pongRand :: (StdGen -> (a,StdGen)) -> Pong -> (a,Pong)
pongRand f p = (r,p{pRandom=newRand})
    where
        (r,newRand) = f $ pRandom p

data PongParams = PongParams {
    ppScreenSize :: Vec2f,
    ppRandom :: StdGen
}

recalcSize :: Vec2f -> Pong -> Pong
recalcSize size p = p{pScreenSize  = size,
                      pPaddleSize  = psize,
                      pBallSize    = bsize,
                      pLeftPaddle  = lp,
                      pRightPaddle = rp,
                      pBall        = b}
    where
        psize = Vec2 pw ph
        pw = ph/3
        ph = 0.1 * v2y size
        bsize = Vec2 bs bs
        bs = 0.2 * v2y psize
        lp = Paddle $ Vec2 px $ v2y rescale
                                *v2y (paddleLoc $ pLeftPaddle p)
        rp = Paddle $ Vec2 (v2x size - px) -- - (pw/2))
                              $ v2y rescale
                                *v2y (paddleLoc $ pRightPaddle p)
        b = Ball (rescale .*. ballLoc (pBall p))
                 (rescale .*. ballVel (pBall p))
        (Vec2 a b) .*. (Vec2 c d) = Vec2 (a*c) (b*d)
        rescale = Vec2 (v2x size/v2x (pScreenSize p))
                       (v2y size/v2y (pScreenSize p))
        px = 0.1 * v2x size

randVec2 :: (Random a,Floating a) => (a,a) -> StdGen
                                           -> (Vec2 a,StdGen)
randVec2 (low,high) rand = (polarVec mag theta,r2)
    where
        (theta,r1) = randomR (0,2*pi) rand
        (mag,r2)   = randomR (low,high) r1

randBallVel :: (Random a,Floating a) =>
               Vec2 a -> StdGen -> (Vec2 a,StdGen)
randBallVel v r = (v .*. rVec,r3)
    where
        rVec = polarVec mag (theta + (if flip then 180 else 0))
        (flip,r3) = random r2
        (theta,r2) = randomR (-pi/4,pi/4) r1
        (mag,r1) = randomR (0.2,0.4) r
        (Vec2 a b) .*. (Vec2 c d) = Vec2 (a*c) (b*d)

mkPong :: PongParams -> Pong
mkPong (PongParams size@(Vec2 w h) rand)
        = recalcSize size $ Pong (Vec2 1 1) vzero vzero lp rp b
                                 Stop Stop True newRand Nothing False
    where
        lp = Paddle (Vec2 0 (v2y mid))
        rp = Paddle (Vec2 0 (v2y mid))
        b = Ball mid startVel
        (startVel,newRand) = randBallVel (Vec2 1 1) rand
        mid = Vec2 0.5 0.5

isPongOver :: Pong -> Bool
isPongOver = pDone

drawPong :: Pong -> G.RenderWindow -> SFML ()
drawPong p wnd = do
    let (Vec2 w h) = pScreenSize p
    view <- GM.viewFromRect (G.FloatRect 0 0 w h)
    GM.setView wnd view
    GM.clearRenderWindow wnd black

    rectShape <- GM.createRectangleShape
    GM.setSize rectShape (sfVec2f $ pPaddleSize p)

    let halfsize = 0.5 *. pPaddleSize p
    GM.setPosition rectShape $ sfVec2f
                    $ paddleLoc (pLeftPaddle p) -. halfsize
    GM.drawRectangle wnd rectShape Nothing

    GM.setPosition rectShape $ sfVec2f
                    $ paddleLoc (pRightPaddle p) -. halfsize
    GM.drawRectangle wnd rectShape Nothing

    GM.setSize rectShape (sfVec2f $ pBallSize p)
    let halfsize = 0.5 *. pBallSize p
    GM.setPosition rectShape $ sfVec2f
                    $ ballLoc (pBall p) -. halfsize
    GM.drawRectangle wnd rectShape Nothing

data PongInput = PongInput {
    piEvents :: [Event],
    piLeft,piRight,piUp,piDown :: Bool,
    piA,piD,piW,piS :: Bool
}

grabPongInput :: G.RenderWindow -> SFML PongInput
grabPongInput w = do
    events <- allAvailableEvents w
    up <- WM.isKeyPressed W.KeyUp
    down <- WM.isKeyPressed W.KeyDown
    w <- WM.isKeyPressed W.KeyW
    s <- WM.isKeyPressed W.KeyS
    return $ PongInput events False False up down
                              False False w  s

processPongInput :: PongInput -> Pong -> Pong
processPongInput pi p = inputDir $ foldl processOne p $ piEvents pi
    where
        inputDir p = let focus = pHasFocus p in
                     p{pLeftDir  = if focus then ldir else Stop,
                       pRightDir = if focus then rdir else Stop}
        ldir = case (piW pi,piS pi) of
                (True,True) -> Stop
                (True,_)    -> Up
                (_,True)    -> Down
                _           -> Stop
        rdir = case (piUp pi,piDown pi) of
                (True,True) -> Stop
                (True,_)    -> Up
                (_,True)    -> Down
                _           -> Stop
        processOne p e = case e of
            SFEvent SFEvtClosed -> p{pDone = True}
            SFEvent (SFEvtResized w h) ->
                let fw = fromIntegral w
                    fh = fromIntegral h in
                recalcSize (Vec2 fw fh) p
            SFEvent SFEvtLostFocus -> p{pHasFocus = False}
            SFEvent SFEvtGainedFocus -> p{pHasFocus = True}
            _ -> p

shiftLineToEdgeOnAxis :: Vec2f -> Vec2f
                               -> (Vec2f,Vec2f) -> (Vec2f,Vec2f)
shiftLineToEdgeOnAxis axis size (cStart,cEnd) = (start,end)
    where
        start = cStart +. offset
        end = cEnd +. offset
        offset = factor *. diff
        factor = axisSize / axisDiff
        axisDiff = vmag $ diff `vproject` axis
        axisSize = vmag $ (0.5*.size) `vproject` axis
        diff = cEnd -. cStart

checkGoal :: Vec2f -> Vec2f -> Vec2f -> (Paddle,Paddle) -> Ball -> Ball -> (Ball,Maybe Float,Maybe Side)
checkGoal ssize paddleSize ballSize (leftPaddle,rightPaddle)
          startBall endBall
        = (newBall,bounceFactor,scoreChange)
    where

        newBall
            | scored    = Ball (0.5 *. ssize) vzero
            | bounced   = Ball bounceLoc bounceVel -- Make this recurse?
            | otherwise = endBall
        scored = case scoreChange of
                    Nothing -> False
                    _       -> True
        scoreChange = case bounceLeft of
            Just True  -> Nothing
            Just False -> Just LeftSide
            _ -> case bounceRight of
                    Just False -> Just RightSide
                    _ -> Nothing
        bounceVel = (1.25*vmag (ballVel startBall))
                    *.vnorm (bounceLoc -. paddleLoc bouncePaddle)
        bounceLoc = maybe (ballLoc endBall)
                          (interp (ballLoc startBall)
                                  (ballLoc endBall))
                          bounceFactor
        bounceFactor = listToMaybe $ catMaybes [check bouncedLeft
                                                      leftFactor,
                                                check bouncedRight
                                                      rightFactor]

        check b m = if b then m else Nothing
        firstJust = foldr $ flip fromMaybe
        bouncePaddle = if bouncedLeft then leftPaddle
                                      else rightPaddle
        bounced = bouncedLeft || bouncedRight
        bouncedLeft = bounceLeft == Just True
        bouncedRight = bounceRight == Just True
        bounceLeft = fmap (onPaddle leftPaddle) leftIntLoc
        bounceRight = fmap (onPaddle rightPaddle) rightIntLoc
        onPaddle paddle (Vec2 x y) =
            let py = v2y $ paddleLoc paddle
                h  = v2y paddleSize
                bs = v2y ballSize in
            y + 0.5*bs >= py - h/2 && y - 0.5*bs <= py + h/2
        leftIntLoc = fmap (interp (ballLoc startBall)
                                  (ballLoc endBall)) leftFactor
        rightIntLoc = fmap (interp (ballLoc startBall)
                                   (ballLoc endBall)) rightFactor

        interp start end t = start +. t *. (end -. start)
        leftFactor = ballIntersect leftLine
        rightFactor = ballIntersect rightLine
        ballIntersect = segLineIntersect
                            edgeStart
                            edgeEnd
        (edgeStart,edgeEnd) = shiftLineToEdgeOnAxis
                                    (Vec2 1 0)
                                    ballSize
                                    (ballLoc startBall,
                                     ballLoc endBall)
        ballOffset = abs (ballSize `vdot` ballChange) *. ballChange
        -- ballsgn = negate $ signum $ pBallSize p `vdot` ballChange
        ballChange = ballLoc endBall -. ballLoc startBall
        leftLine = Line (paddleLoc leftPaddle+. Vec2 (v2x paddleHalfSize) 0)
                        (Vec2 1 0)
        rightLine = Line (paddleLoc rightPaddle-. Vec2 (v2x paddleHalfSize) 0)
                        (Vec2 (-1) 0)
        paddleHalfSize = 0.5 *. paddleSize

tickPong :: Float -> Pong -> Pong
tickPong dt p@Pong{pScreenSize=ssize,
                   pPaddleSize=psize,
                   pBallSize=bsize,
                   pBall=ball,
                   pLeftPaddle=lPaddle,
                   pRightPaddle=rPaddle,
                   pLeftDir=ldir,
                   pRightDir=rdir,
                   pRandom=rand} = p{pBall=newBall,
                                     pLeftPaddle=newLPaddle,
                                     pRightPaddle=newRPaddle,
                                     pRandom=newRand,
                                     pFactor = fact}
    where
        (newBall,newRand) = case score of
            Nothing -> (scoredBall,rand)
            _ -> let (vel,r) = randBallVel ssize rand in
                 (scoredBall{ballVel=vel},r)
        (scoredBall,fact,score) = checkGoal ssize psize bsize
                                         (lPaddle,rPaddle) ball ball1
        ball1 = boundBall vzero ssize (v2x bsize) $ tickBall dt ball
        newLPaddle = boundPaddle 0 h (v2y psize)
                     $ tickPaddle ldir h dt lPaddle
        newRPaddle = boundPaddle 0 h (v2y psize)
                     $ tickPaddle rdir h dt rPaddle
        h = v2y ssize

pongTitle :: Pong -> String
pongTitle _ = "Pong!"

