"""Optional export-only ball tracking; original-aspect exports never load a model."""
from __future__ import annotations

import math
import os
from pathlib import Path

from .analysis import PipelineCancelled

SAMPLE_FPS = 10
MAX_SPEED = .6  # crop widths / second
MAX_ACCELERATION = .8  # crop widths / second squared
FAST_SPEED = 1.6
FAST_ACCELERATION = 3.6
PEOPLE_STRIDE = 2  # 5 Hz person detections


def clean_observations(observations: list[float | None], crop_width: float) -> list[float | None]:
    """Reject isolated jumps using both neighbours; missing detections are not negatives."""
    values = [x if x is not None and math.isfinite(x) else None for x in observations]
    known = [(i, x) for i, x in enumerate(values) if x is not None]
    for n, (i, x) in enumerate(known):
        neighbours = known[max(0, n - 2):n] + known[n + 1:n + 3]
        # A lone detection cannot establish a reliable ball track.
        if not any(abs(x - y) <= crop_width * (min(.5, .12 + 2.2 * abs(i - j) / SAMPLE_FPS))
                   for j, y in neighbours if abs(i - j) <= SAMPLE_FPS):
            values[i] = None
        elif 0 < n < len(known) - 1:
            left, right = known[n - 1], known[n + 1]
            if right[0] - left[0] <= SAMPLE_FPS:
                expected = left[1] + (right[1] - left[1]) * (i - left[0]) / (right[0] - left[0])
                if abs(x - expected) > .35 * crop_width and abs(left[1] - right[1]) < .25 * crop_width:
                    values[i] = None
    return values


def _safe_path(centers, values, half, width, speed_limit, acceleration_limit, margin,
               hoop_bounds=None, *, keep_partial=False):
    """Project the offline path onto framing and pan constraints, when feasible.

    Disjoint pairs/triples can be projected together. Boundaries are clipped:
    a ball at the source edge cannot physically occupy the central safe zone.
    """
    import numpy as np

    lower = np.full(len(centers), half)
    upper = np.full(len(centers), width - half)
    for i, x in enumerate(values):
        if x is not None:
            lower[i] = np.clip(x - margin * 2 * half, half, width - half)
            upper[i] = np.clip(x + margin * 2 * half, half, width - half)
    if hoop_bounds is not None:
        guarded, minimum, maximum = hoop_bounds
        lower[guarded], upper[guarded] = minimum, maximum
    path = centers.copy()
    speed_limit = np.broadcast_to(speed_limit, (max(0, len(path) - 1),))
    acceleration_limit = np.broadcast_to(acceleration_limit, (max(0, len(path) - 2),))
    pairs = [np.arange(phase, len(path) - 1, 2) for phase in range(2)]
    triples = [np.arange(phase, len(path) - 2, 3) for phase in range(3)]
    # A distant track can need several passes to move the guard correction
    # through neighbouring samples without introducing a sharp pan.
    for _ in range(4000 if hoop_bounds is not None else 400):
        path = np.clip(path, lower, upper)
        for i in pairs:
            delta = path[i + 1] - path[i]
            change = (delta - np.clip(delta, -speed_limit[i], speed_limit[i])) / 2
            path[i] += change
            path[i + 1] -= change
        for i in triples:
            delta = path[i] - 2 * path[i + 1] + path[i + 2]
            change = (delta - np.clip(delta, -acceleration_limit[i], acceleration_limit[i])) / 6
            path[i] -= change
            path[i + 1] += 2 * change
            path[i + 2] -= change
        if (np.all(path >= lower - .01) and np.all(path <= upper + .01) and
                np.all(np.abs(np.diff(path)) <= speed_limit + .01) and
                np.all(np.abs(np.diff(path, n=2)) <= acceleration_limit + .01)):
            return np.clip(path, half, width - half)
    # The unconstrained-ball pass has a feasible solution. Its last projection
    # gives a better starting point for the final bounds correction.
    return np.clip(path, half, width - half) if keep_partial else None


def _crop_size(width: int, height: int) -> tuple[int, int]:
    crop_height = min(height, int(width * 16 / 9)) // 2 * 2
    return int(crop_height * 9 / 16) // 2 * 2, crop_height


def portrait_filter(centers: list[float], width: int, height: int) -> str:
    crop_width, crop_height = _crop_size(width, height)
    if crop_width < 2 or crop_height < 2 or not centers:
        raise ValueError("INVALID_PORTRAIT_DIMENSIONS")
    xs = [min(width - crop_width, max(0, x - crop_width / 2)) for x in centers]
    # Branch on time so FFmpeg evaluates one interpolation per frame and the
    # expression parser only descends logarithmically in the number of samples.
    def interpolate(start, end):
        if start + 1 == end:
            left, right = xs[start], xs[end]
            if abs(right - left) <= .0001:
                return f"{left:.4f}"
            return f"{left:.4f}+({right - left:.4f})*clip((t-{start/SAMPLE_FPS:.3f})*{SAMPLE_FPS},0,1)"
        middle = (start + end) // 2
        left = interpolate(start, middle)
        right = interpolate(middle, end)
        return left if left == right else f"if(lt(t,{middle/SAMPLE_FPS:.3f}),{left},{right})"

    expression = interpolate(0, len(xs) - 1) if len(xs) > 1 else f"{xs[0]:.4f}"
    return f"crop={crop_width}:{crop_height}:x='{expression}':y=(ih-oh)/2,scale=1080:1920,setsar=1"


def plausible_ball(box, width):
    """Reject stretched floor logos and boxes too large to be a distant ball."""
    w, h = box[2] - box[0], box[3] - box[1]
    return (all(math.isfinite(v) for v in box) and w > 0 and h > 0
            and .6 <= w / h <= 1.6 and max(w, h) <= .08 * width)


def _center(box):
    return (box[0] + box[2]) / 2, (box[1] + box[3]) / 2


def _hoop_candidates(frames, width, crop_width):
    """Group rim detections and count distinct supporting samples."""
    from statistics import median

    groups = []
    for i, boxes in enumerate(frames):
        for box in boxes:
            x1, y1, x2, y2 = box
            w, h = x2 - x1, y2 - y1
            if not (all(map(math.isfinite, box)) and h > 0 and .75 <= w/h <= 6
                    and 0 <= x1 < x2 <= width and .008 * width <= w <= min(.12 * width, crop_width)):
                continue
            center = _center(box)
            distance, index = min(((math.dist(center, anchor), j)
                                   for j, (anchor, _) in enumerate(groups)), default=(math.inf, -1))
            if distance <= min(.035 * width, max(.016 * width, w)):
                groups[index][1].setdefault(i, box)
            else:
                groups.append((center, {i: box}))

    candidates = []
    for _, samples in groups:
        if len(samples) < max(3, math.ceil(.025 * len(frames))):
            continue
        box = [median(b[k] for b in samples.values()) for k in range(4)]
        jitter = median(math.dist(_center(b), _center(box)) for b in samples.values())
        support = len(samples) / (1 + jitter / (box[2] - box[0]))
        candidates.append((support, box))
    return sorted(candidates, reverse=True)


def _rim_crossings(boxes_by_frame, rim):
    """Find descending ball sequences through the rim, including unlabelled shots."""
    x, _ = _center(rim)
    w, h = rim[2]-rim[0], rim[3]-rim[1]
    # A detection of the rim often covers the net as well. Use its upper
    # portion as the crossing plane, and require evidence below it.
    plane = rim[1] + .3*h
    nearby = [[(bx,by,box) for box in boxes for bx,by in [_center(box)]
               if abs(bx-x) <= w and plane-1.6*h <= by <= plane+1.8*h]
              for boxes in boxes_by_frame]
    crossings = {}
    last = -SAMPLE_FPS
    for i, boxes in enumerate(nearby):
        if i-last < SAMPLE_FPS:
            continue
        for bx,by,box in boxes:
            if abs(bx-x) > .75*w or not (plane-.55*h <= by <= plane+.6*h):
                continue
            before = next(((t,b) for t in range(i-1,max(-1,i-6),-1) for px,py,b in nearby[t]
                           if abs(px-bx) <= w and py <= min(plane,by-.15*h)), None)
            after = next(((t,b) for t in range(i+1,min(len(nearby),i+6)) for px,py,b in nearby[t]
                          if abs(px-bx) <= w and py >= max(plane+.45*h,by+.25*h)), None)
            if before and after:
                crossings[i] = dict((before,(i,box),after))
                last = i
                break
    return crossings


def _rim_regions(candidates, width, height):
    """Bound the extra inference to up to three persistent hoop neighbourhoods."""
    boxes = [box for _,box in candidates[:3]]
    regions = []
    for box in boxes:
        x,y = _center(box)
        radius = max(.085*width, 2.75*(box[2]-box[0]))
        a,b = max(0,int(x-radius)), max(0,int(y-radius))
        c,d = min(width,math.ceil(x+radius)), min(height,math.ceil(y+radius))
        if (c-a)*(d-b) > .28*width*height:
            continue
        for j, (l,t,r,z) in enumerate(regions):
            if a < r and c > l and b < z and d > t:
                regions[j] = (min(a,l),min(b,t),max(c,r),max(d,z))
                break
        else:
            regions.append((a,b,c,d))
    return regions


def _crowd_observations(people, rim, width, height):
    """Find a court-side group center from boxes and short-term motion."""
    centers = []
    previous = []
    for boxes in people:
        if boxes is None:  # person model runs on alternate samples
            centers.append(None)
            continue
        players = []
        for x1, y1, x2, y2 in boxes:
            if not (0 < x2-x1 <= .35 * width and .035 * height <= y2-y1 <= .72 * height):
                continue
            if y2 < (rim[3] if rim else height * .45):
                continue
            players.append(((x1+x2)/2, y2))
        weighted = []
        for x, y in players:
            distance = math.dist((x, y), (_center(rim)[0], rim[3])) if rim else 0.
            movement = min((math.dist((x, y), other) for other in previous), default=0.)
            # Distant non-matching boxes do not create phantom fast players.
            movement = min(1., movement / (.035 * width)) if movement <= .09 * width else 0.
            weight = (1. + movement) / (1. + (distance / (.27 * width)) ** 2)
            weighted.append((x, weight))
        centers.append(sum(x*w for x,w in weighted) / sum(w for _,w in weighted)
                       if len(weighted) >= 2 else None)
        previous = players
    return centers


def _supported_positions(values, max_gap):
    """Interpolate nearby evidence only; long gaps need another target."""
    import numpy as np

    known = np.flatnonzero([x is not None for x in values])
    if not len(known):
        return [None] * len(values)
    indices = np.arange(len(values))
    left = known[np.maximum(0, np.searchsorted(known, indices, side="right") - 1)]
    right = known[np.minimum(len(known)-1, np.searchsorted(known, indices))]
    nearby = np.minimum(abs(indices-left), abs(right-indices)) <= max_gap
    # Across a long gap, briefly hold each endpoint instead of chasing a phantom.
    interpolated = np.interp(indices, known, [values[i] for i in known])
    nearest = np.where(abs(indices-left) <= abs(right-indices), left, right)
    return [float(x) if ok and r-l <= 2*max_gap else values[j] if ok else None
            for x,ok,l,r,j in zip(interpolated,nearby,left,right,nearest)]


def _pan_path(target, ball, sources, width, crop_width, fallback, hoop_bounds):
    import numpy as np

    def blur(values, seconds):
        sigma = seconds * SAMPLE_FPS
        radius = math.ceil(3*sigma)
        offsets = np.arange(-radius, radius+1)
        kernel = np.exp(-.5 * (offsets/sigma)**2)
        return np.convolve(np.pad(values,radius,mode="edge"),kernel/kernel.sum(),mode="valid")

    # Require two short, same-direction intervals before allowing a fast pan.
    fast = np.zeros(len(target))
    points = [(i,x) for i,x in enumerate(ball) if x is not None and sources[i] == "ball"]
    for (i,a),(j,b),(k,c) in zip(points,points[1:],points[2:]):
        v1, v2 = (b-a)*SAMPLE_FPS/(j-i), (c-b)*SAMPLE_FPS/(k-j)
        if j-i <= 4 and k-j <= 4 and v1*v2 > 0 and min(abs(v1),abs(v2)) >= .65*crop_width:
            fast[max(0,i-5):k+6] = 1.
    fast = blur(fast,.18)
    crowd = np.asarray(sources) == "crowd"
    fast[crowd] = 0.
    half = crop_width/2
    target = np.clip(target,half,width-half)
    # Keep the L438 symmetric dead zone for normal moves; shrink it for fast balls.
    forward, backward = target.copy(), target.copy()
    dead = crop_width * (.06 - .035*fast)
    for i in range(1,len(target)):
        forward[i] = np.clip(forward[i-1],target[i]-dead[i],target[i]+dead[i])
    for i in range(len(target)-2,-1,-1):
        backward[i] = np.clip(backward[i+1],target[i]-dead[i],target[i]+dead[i])
    target = (forward+backward)/2
    path = (1-fast)*blur(target,.45) + fast*blur(target,.18)
    edge_fast = np.where(crowd[:-1] | crowd[1:],0.,(fast[:-1]+fast[1:])/2)
    speed = crop_width / SAMPLE_FPS * (MAX_SPEED + (FAST_SPEED-MAX_SPEED)*edge_fast)
    accel = crop_width / SAMPLE_FPS**2 * (MAX_ACCELERATION + (FAST_ACCELERATION-MAX_ACCELERATION)*fast[1:-1])
    ball_support = [x if source == "ball" else None for x,source in zip(ball,sources)]
    solved = _safe_path(path,ball_support,half,width,speed,accel,.42,hoop_bounds)
    if solved is not None:
        return solved.tolist(), fast.tolist()
    path = _safe_path(path,[None]*len(path),half,width,speed,accel,.5,hoop_bounds,keep_partial=True)
    # Correct the remaining numerical error on the projected path instead of
    # reducing every movement to accommodate the unprojected shot conflict.
    offsets = path-fallback
    weight = min(1., np.min(speed/np.maximum(1e-9,abs(np.diff(path))),initial=1.),
                 np.min(accel/np.maximum(1e-9,abs(np.diff(path,n=2))),initial=1.))
    if hoop_bounds is not None:
        guarded, lower, upper = hoop_bounds
        required = offsets[guarded]
        weight = min(weight, np.min((upper-fallback)/required[required>0],initial=1.),
                     np.min((lower-fallback)/required[required<0],initial=1.))
    return (fallback+weight*offsets).tolist(), fast.tolist()


def compose_portrait(balls, hoops, width, height, goal_seconds, *, people=None, local_balls=None):
    """Pick a local target, smooth the pan and constrain it near each shot."""
    import numpy as np

    crop_width, crop_height = _crop_size(width,height)
    if crop_width < 2 or crop_height < 2:
        raise ValueError("INVALID_PORTRAIT_DIMENSIONS")
    goals = [goal_seconds] if isinstance(goal_seconds,(float,int)) else goal_seconds
    balls = [b if b is not None and plausible_ball(b,width) else None for b in balls] or [None]
    options = [[b] if b else [] for b in balls]
    if local_balls is not None:
        options = [local + full for local,full in zip(local_balls,options)]
    rim, crossings = None, {}
    best = (0, 0.)
    for support, candidate in _hoop_candidates(hoops,width,crop_width):
        hits = _rim_crossings(options,candidate)
        score = (len(hits),support)
        if score > best:
            best, rim, crossings = score, candidate, hits
    for points in crossings.values():
        for i,box in points.items():
            balls[i] = box
    clean = clean_observations([_center(b)[0] if b is not None else None for b in balls],crop_width)
    # A geometric crossing's recovery points take precedence over a distant
    # full-frame false positive, both at the crossing and in its small gaps.
    for points in crossings.values():
        first, last = min(points), max(points)
        for i in range(first,last+1):
            clean[i] = _center(points[i])[0] if i in points else None
    half = crop_width/2
    anchor = min(width-half,max(half,_center(rim)[0] if rim else width/2))
    rim_width = rim[2] - rim[0] if rim else 0.
    observed = np.asarray([x is not None for x in clean],dtype=int)
    indices = np.arange(len(clean))
    start = np.maximum(0,indices-15)
    end = np.minimum(len(clean),indices+15)
    counts = np.r_[0,np.cumsum(observed)]
    good = (counts[end]-counts[start]) >= .25*(end-start)
    ball_targets = _supported_positions(clean,4)
    crowds = (_supported_positions(_crowd_observations(people,rim,width,height),3)
              if people is not None and len(people) == len(balls) else [None]*len(balls))

    targets, sources = [], []
    recent = []
    hold_until = -1
    last_observation = None
    inferred = set(crossings)
    crossing_points = {i for points in crossings.values() for i in points}
    last = anchor
    for i,(ok,x,crowd) in enumerate(zip(good,ball_targets,crowds)):
        raw = clean[i]
        trusted = raw is not None and (ok or i in crossing_points)
        point = _center(balls[i]) if trusted else None
        near = point is not None and rim is not None and math.dist(point,_center(rim)) <= 2*rim_width
        continuous = (point is not None and last_observation is not None
                      and i-last_observation[0] <= 2
                      and math.dist(point,last_observation[1]) <= .15*crop_width)
        # Keep an established rim lock through the detector gap, including
        # when a competing full-frame ball appears on the other side.
        if near:
            hold_until = i + 2*SAMPLE_FPS
        if i in inferred:
            hold_until = max(hold_until,i + 2*SAMPLE_FPS)
        if i <= hold_until and not (near or continuous or i in crossing_points):
            source, last = "hoop", anchor
        elif (ok and x is not None) or near or i in crossing_points:
            source, last = "ball", x
            if trusted:
                recent = (recent + [(i,raw)])[-4:]
                last_observation = i,point
        elif i >= len(balls)-2*SAMPLE_FPS and recent and i-recent[-1][0] <= 2*SAMPLE_FPS:
            j, position = recent[-1]
            k, previous = recent[0]
            velocity = ((position-previous)/(j-k) if 0 < j-k <= .6*SAMPLE_FPS else 0.)
            speed = MAX_SPEED*crop_width/SAMPLE_FPS
            source, last = "tail", position + (i-j)*max(-speed,min(speed,velocity))
        elif crowd is not None:
            source, last = "crowd", crowd
        else:
            source, last = "hoop", anchor if rim else last
        targets.append(last)
        sources.append(source)
    hoop_bounds = None
    guarded = np.zeros(len(clean),dtype=bool)
    if rim and (goals or crossings):
        for goal in [*goals, *(i/SAMPLE_FPS for i in crossings)]:
            guarded |= (indices >= math.floor((goal-1.5)*SAMPLE_FPS)) & (indices <= math.ceil((goal+2.)*SAMPLE_FPS))
        margin = min(crop_width*.06,(crop_width-rim_width)/2)
        lower = min(width-half,max(half,rim[2]-half+margin))
        upper = max(half,min(width-half,rim[0]+half-margin))
        hoop_bounds = guarded,lower,upper
    centers, fast = _pan_path(targets,clean,sources,width,crop_width,anchor,hoop_bounds)
    return {"mode":"crop", "filter":portrait_filter(centers,width,height),
            "crop_width":crop_width, "crop_height":crop_height, "crop_y":(height-crop_height)/2,
            "centers":centers, "rim":rim, "tracking_coverage":float(observed.mean()),
            "sources":sources, "fast":fast, "crossings":[i/SAMPLE_FPS for i in crossings],
            "guarded":guarded.tolist()}


class PortraitTracker:
    def __init__(self, model_path: Path):
        from basketball_highlight.inference import load_detector, select_device, current_device

        select_device("auto", model_path)
        self.model = load_detector(model_path)
        self.device = current_device()
        configured = os.environ.get("BHE_PORTRAIT_PERSON_MODEL")
        person_path = Path(configured).expanduser() if configured else model_path.parent / "local" / "yolo11n.pt"
        self.person_model = load_detector(person_path, self.device) if person_path.is_file() else None
        self.person_device = current_device()

    @staticmethod
    def _sample_frames(capture, start, count, fps, cancel_check):
        import cv2

        capture.set(cv2.CAP_PROP_POS_MSEC, start * 1000)
        frame_index = 0
        frame = None
        timestamp = None
        for index in range(count):
            if cancel_check and cancel_check():
                raise PipelineCancelled("JOB_CANCELLED")
            target_time = start + index / SAMPLE_FPS
            if timestamp is not None:
                # Read along the source PTS (presentation timestamp). A
                # constant index step drifts when the source varies its FPS.
                grabbed = False
                while timestamp + min(.02, .5 / fps) < target_time:
                    if cancel_check and cancel_check():
                        raise PipelineCancelled("JOB_CANCELLED")
                    if not capture.grab():
                        if target_time - timestamp <= .15:
                            break
                        raise OSError("竖屏跟球源视频提前结束")
                    grabbed = True
                    frame_index += 1
                    current = capture.get(cv2.CAP_PROP_POS_MSEC) / 1000
                    if not math.isfinite(current) or current <= timestamp:
                        timestamp = None
                        break
                    timestamp = current
                if grabbed:
                    ok, decoded = capture.retrieve()
                    if ok:
                        frame = decoded
                    elif timestamp is None or target_time - timestamp > .15:
                        raise OSError("竖屏跟球源视频读取失败")
            else:
                target_frame = math.floor(index * fps / SAMPLE_FPS)
                while frame_index < target_frame:
                    if cancel_check and cancel_check():
                        raise PipelineCancelled("JOB_CANCELLED")
                    if not capture.grab():
                        raise OSError("竖屏跟球源视频提前结束")
                    frame_index += 1
                # Low frame rates and backends without usable PTS keep
                # frame-index sampling, reusing frames when necessary.
                if frame_index <= target_frame:
                    ok, frame = capture.read()
                    frame_index += 1
                    if not ok:
                        raise OSError("竖屏跟球源视频读取失败")
                if index == 0 and fps >= SAMPLE_FPS:
                    current = capture.get(cv2.CAP_PROP_POS_MSEC) / 1000
                    if math.isfinite(current) and abs(current - start) <= .25:
                        timestamp = current
            yield index, frame

    def track(self, candidate: dict, cancel_check=None, progress_callback=None) -> str:
        import cv2

        capture = cv2.VideoCapture(str(candidate["source_path"]))
        try:
            if not capture.isOpened():
                raise OSError("竖屏跟球无法读取源视频")
            width = int(capture.get(cv2.CAP_PROP_FRAME_WIDTH))
            height = int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT))
            fps = capture.get(cv2.CAP_PROP_FPS)
            if width <= 0 or height <= 0 or fps <= 0:
                raise ValueError("INVALID_PORTRAIT_DIMENSIONS")
            start = candidate["review_start_ms"] / 1000
            duration = (candidate["review_end_ms"] - candidate["review_start_ms"]) / 1000
            count = max(1, math.ceil(duration * SAMPLE_FPS))
            previous = None
            ball_boxes, hoop_frames, people = [], [], []
            person_model = getattr(self, "person_model", None)
            for index, frame in self._sample_frames(capture, start, count, fps, cancel_check):
                result = self.model.predict(frame, device=self.device, conf=.15, imgsz=640,
                                            rect=False, verbose=False)[0]
                balls = []
                hoops = []
                for box in result.boxes:
                    name = result.names[int(box.cls[0])]
                    xyxy = box.xyxy[0].tolist()
                    x = (xyxy[0] + xyxy[2]) / 2
                    if name in {"ball", "basketball"} and plausible_ball(xyxy, width):
                        score = float(box.conf[0])
                        if previous is not None:
                            score -= .25 * abs(x - previous) / width
                        balls.append((score, x, xyxy))
                    elif name in {"hoop", "rim"}:
                        hoops.append(xyxy)
                hoop_frames.append(hoops)
                value = max(balls)[1] if balls else None
                if value is not None:
                    previous = value
                ball_boxes.append(max(balls)[2] if balls else None)
                persons = None
                if person_model is not None and index % PEOPLE_STRIDE == 0:
                    detected = person_model.predict(frame, device=self.person_device, conf=.25, imgsz=640,
                                                    rect=False, classes=[0], verbose=False)[0]
                    persons = [box.xyxy[0].tolist() for box in detected.boxes
                               if detected.names[int(box.cls[0])] == "person"]
                people.append(persons)
                if progress_callback:
                    progress_callback("portrait_tracking", .5 * (index + 1) / count)
            crop_width, _ = _crop_size(width,height)
            regions = _rim_regions(_hoop_candidates(hoop_frames,width,crop_width), width, height)
            local_balls = [[] for _ in ball_boxes]
            if regions:
                for index, frame in self._sample_frames(capture,start,count,fps,cancel_check):
                    local_hoops = []
                    for x1,y1,x2,y2 in regions:
                        result = self.model.predict(frame[y1:y2,x1:x2], device=self.device, conf=.35,
                                                    imgsz=640, rect=False, verbose=False)[0]
                        for box in result.boxes:
                            name = result.names[int(box.cls[0])]
                            a,b,c,d = box.xyxy[0].tolist()
                            bounds = [a+x1,b+y1,c+x1,d+y1]
                            if name in {"hoop", "rim"}:
                                local_hoops.append(bounds)
                            elif name in {"ball", "basketball"} and plausible_ball(bounds,width):
                                local_balls[index].append(bounds)
                    hoop_frames[index] = local_hoops + hoop_frames[index]
                    if progress_callback:
                        progress_callback("portrait_tracking", .5 + .5 * (index+1) / count)
            elif progress_callback:
                progress_callback("portrait_tracking", 1.)
            if cancel_check and cancel_check():
                raise PipelineCancelled("JOB_CANCELLED")
            single_event = None if candidate.get("manual") else candidate.get("event_time_ms")
            events = candidate.get("portrait_events_ms", [single_event])
            goals = [(event - candidate["review_start_ms"]) / 1000
                     for event in events if event is not None]
            self.last_composition = compose_portrait(ball_boxes, hoop_frames, width, height, goals,
                                                     people=people, local_balls=local_balls)
            return self.last_composition["filter"]
        finally:
            capture.release()
