use std::ffi::{c_char, CStr, CString};
use std::path::Path;
use std::sync::OnceLock;

use base64::Engine;
use image::{imageops::FilterType, DynamicImage, RgbImage};
use ndarray::Array4;
use ort::{session::Session, value::Tensor};
use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Inference input resolution. 640 is the default for YOLOv8n-style models
/// converted to ONNX. Desktop uses 1280; if the mobile model was exported at
/// a different size, override via the `model_size` config field.
const MODEL_SIZE_DEFAULT: u32 = 640;
static ORT_INIT: OnceLock<Result<(), String>> = OnceLock::new();

#[derive(Debug, Error)]
pub enum RuntimeError {
    #[error("invalid request: {0}")]
    InvalidRequest(String),
    #[error("model error: {0}")]
    Model(#[from] ort::Error),
    #[error("image error: {0}")]
    Image(#[from] image::ImageError),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("base64 error: {0}")]
    Base64(#[from] base64::DecodeError),
}

#[derive(Clone, Debug, Deserialize)]
pub struct Roi {
    pub left: f32,
    pub top: f32,
    pub right: f32,
    pub bottom: f32,
}

#[derive(Clone, Debug, Deserialize)]
pub struct FrameInput {
    pub time_ms: i64,
    pub width: u32,
    pub height: u32,
    #[serde(default)]
    pub rgb_base64: Option<String>,
    #[serde(default)]
    pub image_base64: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct RuntimeConfig {
    pub model_path: String,
    pub hoop_roi: Roi,
    pub net_roi: Roi,
    #[serde(default)]
    pub duration_ms: Option<i64>,
    #[serde(default = "default_confidence")]
    pub confidence_threshold: f32,
    #[serde(default = "default_before_ms")]
    pub clip_before_ms: i64,
    #[serde(default = "default_after_ms")]
    pub clip_after_ms: i64,
    /// Inference input resolution; defaults to 640. Desktop uses 1280.
    /// Override if the ONNX model was exported at a different size.
    #[serde(default = "default_model_size")]
    pub model_size: u32,
}

fn default_model_size() -> u32 {
    MODEL_SIZE_DEFAULT
}

#[derive(Clone, Debug, Deserialize)]
pub struct AnalysisRequest {
    pub model_path: String,
    pub frames: Vec<FrameInput>,
    pub hoop_roi: Roi,
    pub net_roi: Roi,
    #[serde(default)]
    pub duration_ms: Option<i64>,
    #[serde(default = "default_confidence")]
    pub confidence_threshold: f32,
    #[serde(default = "default_before_ms")]
    pub clip_before_ms: i64,
    #[serde(default = "default_after_ms")]
    pub clip_after_ms: i64,
}

#[derive(Clone, Debug, Serialize)]
pub struct Detection {
    pub class_id: usize,
    pub confidence: f32,
    pub x1: f32,
    pub y1: f32,
    pub x2: f32,
    pub y2: f32,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct EvidencePoint {
    pub time_ms: i64,
    pub x: f32,
    pub y: f32,
    pub confidence: f32,
}

#[derive(Clone, Debug, Serialize)]
pub struct Candidate {
    pub id: String,
    pub track_id: u64,
    pub start_ms: i64,
    pub end_ms: i64,
    pub event_ms: i64,
    pub confidence: f32,
    pub trajectory_score: f32,
    pub crossing_score: f32,
    pub net_motion_score: f32,
    pub net_sequence_score: f32,
    /// Prediction score: how well the pre-crossing trajectory predicts
    /// a landing inside the rim corridor (0-1, higher = more likely).
    pub prediction_score: f32,
    /// Composite multi-signal score combining all evidence.
    /// 0.0 = all signals absent, 1.0 = all signals strong.
    pub composite_score: f32,
    pub trajectory: Vec<EvidencePoint>,
    pub above: EvidencePoint,
    pub below: EvidencePoint,
    pub crossing: EvidencePoint,
    pub reason: String,
    pub verdict: String,
    pub complete_crossing: bool,
    pub rebound: bool,
    pub lateral_exit: bool,
    pub post_crossing_lateral_recovery: bool,
    pub ball_persistence: f32,
    pub net_signal_available: bool,
    pub net_support: bool,
    pub net_no_motion: bool,
    pub net_lower_peak: f32,
    pub net_below_peak: f32,
    pub auto_export_eligible: bool,
    pub decision_time_ms: Option<i64>,
    pub algorithm_version: String,
    pub evidence_source: String,
}

type BallPoint = (i64, f32, f32, f32);

#[derive(Clone, Debug)]
struct BallTrack {
    id: u64,
    points: Vec<BallPoint>,
}

#[derive(Clone, Copy, Debug, Default)]
struct NetEvidence {
    signal_available: bool,
    no_motion: bool,
    inside_score: f32,
    sequence_score: f32,
    lower_peak: f32,
    below_peak: f32,
    support: bool,
}

#[derive(Clone, Copy, Debug, Default)]
struct PostCrossingEvidence {
    persistence: f32,
    rebound: bool,
    lateral_exit: bool,
    lateral_recovery: bool,
}

#[derive(Clone, Copy, Debug, Default)]
struct CalibratedGates {
    high_precision: bool,
    automatic_goal: bool,
}

#[derive(Clone, Debug, Serialize)]
pub struct AnalysisResponse {
    pub candidates: Vec<Candidate>,
    pub processed_frames: usize,
    pub total_frames: usize,
}

#[derive(Clone, Debug, Serialize)]
pub struct FrameResponse {
    pub detections: Vec<Detection>,
    pub candidates: Vec<Candidate>,
    pub processed_frames: u64,
}

/// ONNX-free replay request used to compare the decision layer against the
/// desktop engine. Coordinates must be normalized to the same 0..1 frame
/// space as `hoop_roi`.
#[derive(Clone, Debug, Deserialize)]
pub struct DecisionReplayRequest {
    pub hoop_roi: Roi,
    pub above: EvidencePoint,
    pub below: EvidencePoint,
    pub trajectory: Vec<EvidencePoint>,
    #[serde(default)]
    pub net_history: Vec<NetReplayPoint>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct NetReplayPoint {
    pub time_ms: i64,
    pub upper: f32,
    pub lower: f32,
    pub below: f32,
}

#[derive(Clone, Debug, Serialize)]
pub struct DecisionReplayResult {
    pub algorithm_version: String,
    pub complete_crossing: bool,
    pub ball_persistence: f32,
    pub rebound: bool,
    pub lateral_exit: bool,
    pub post_crossing_lateral_recovery: bool,
    pub net_signal_available: bool,
    pub net_support: bool,
    pub net_no_motion: bool,
    pub net_motion_score: f32,
    pub net_sequence_score: f32,
    pub verdict: String,
    pub auto_export_eligible: bool,
}

pub struct RuntimeSession {
    session: Session,
    config: RuntimeConfig,
    model_size: u32,
    tracks: Vec<BallTrack>,
    next_track_id: u64,
    candidates: Vec<Candidate>,
    processed_frames: u64,
    previous_net_signature: Option<(i64, [Vec<f32>; 3])>,
    /// Three-zone net motion history: (time_ms, upper, lower, below).
    /// Mirrors the desktop algorithm: a made basket activates the net's
    /// lower zone first, then the zone below it (ball hits net then drops).
    net_zone_history: Vec<(i64, f32, f32, f32)>,
}

impl RuntimeSession {
    pub fn new(config: RuntimeConfig) -> Result<Self, RuntimeError> {
        validate_config(&config)?;
        validate_roi(&config.hoop_roi, "hoop")?;
        validate_roi(&config.net_roi, "net")?;
        init_onnx()?;
        let model_size = config.model_size;
        let session = Session::builder()
            .map_err(|error| RuntimeError::InvalidRequest(error.to_string()))?
            .with_intra_threads(1)
            .map_err(|error| RuntimeError::InvalidRequest(error.to_string()))?
            .commit_from_file(Path::new(&config.model_path))?;
        Ok(Self {
            session,
            config,
            model_size,
            tracks: Vec::new(),
            next_track_id: 1,
            candidates: Vec::new(),
            processed_frames: 0,
            previous_net_signature: None,
            net_zone_history: Vec::new(),
        })
    }

    pub fn candidates(&self) -> &[Candidate] {
        &self.candidates
    }

    pub fn push_frame(&mut self, frame: FrameInput) -> Result<FrameResponse, RuntimeError> {
        let image = decode_rgb(&frame)?;
        self.push_image(frame.time_ms, image)
    }

    /// Processes a raw RGBA frame without any encoding/decoding overhead.
    ///
    /// This is the fast path: Android sends Bitmap pixels directly as a
    /// byte array (4 bytes per pixel, row-major), avoiding JPEG compression,
    /// base64 encoding (+33% size), JSON serialization, and JPEG decode
    /// on the Rust side. Expected speedup: 3-5x per frame.
    pub fn push_frame_raw(
        &mut self,
        time_ms: i64,
        width: u32,
        height: u32,
        rgba: &[u8],
    ) -> Result<FrameResponse, RuntimeError> {
        let expected = (width as usize) * (height as usize) * 4;
        if rgba.len() != expected {
            return Err(RuntimeError::InvalidRequest(format!(
                "raw frame has {} bytes, expected {} ({}x{}x4)",
                rgba.len(),
                expected,
                width,
                height
            )));
        }
        let mut buffer = Vec::with_capacity(expected / 4 * 3);
        for chunk in rgba.chunks_exact(4) {
            buffer.push(chunk[0]); // R
            buffer.push(chunk[1]); // G
            buffer.push(chunk[2]); // B
        }
        let image = RgbImage::from_raw(width, height, buffer).ok_or_else(|| {
            RuntimeError::InvalidRequest("raw frame dimensions are invalid".into())
        })?;
        self.push_image(time_ms, image)
    }

    fn push_image(&mut self, time_ms: i64, image: RgbImage) -> Result<FrameResponse, RuntimeError> {
        let detections = detect_image(
            &mut self.session,
            &image,
            self.config.confidence_threshold,
            self.model_size,
        )?;
        self.processed_frames += 1;
        self.update_net_motion(time_ms, &image);
        let balls = detections
            .iter()
            .filter(|detection| detection.class_id == 0)
            .map(|ball| {
                let (x, y) = center(ball);
                (
                    x / image.width() as f32,
                    y / image.height() as f32,
                    ball.confidence,
                )
            })
            .collect();
        let updated_tracks = self.push_ball_detections(time_ms, balls);
        for track_id in updated_tracks {
            self.detect_crossing(track_id);
        }
        for (track_id, points) in recover_track_points(&self.tracks, &self.config.hoop_roi) {
            if let Some(track) = self.tracks.iter_mut().find(|track| track.id == track_id) {
                track.points = points;
            }
            self.detect_crossing(track_id);
        }
        self.resolve_verdict();
        Ok(FrameResponse {
            detections,
            candidates: self.candidates.clone(),
            processed_frames: self.processed_frames,
        })
    }

    fn push_ball_detections(&mut self, time_ms: i64, detections: Vec<(f32, f32, f32)>) -> Vec<u64> {
        associate_ball_tracks(
            &mut self.tracks,
            &mut self.next_track_id,
            time_ms,
            detections,
            self.config.hoop_roi.right - self.config.hoop_roi.left,
        )
    }
}

/// Associates all detections in one frame with active ball tracks.
///
/// The association is deliberately deterministic: candidate pairs are sorted
/// by predicted distance, then assigned one-to-one. This keeps a high
/// confidence distractor from stealing a continuing track merely because it
/// appears first in the detector output.
fn associate_ball_tracks(
    tracks: &mut Vec<BallTrack>,
    next_track_id: &mut u64,
    time_ms: i64,
    detections: Vec<(f32, f32, f32)>,
    rim_width: f32,
) -> Vec<u64> {
    let rim_width = rim_width.max(0.01);
    let mut pairs = Vec::new();
    for (track_index, track) in tracks.iter().enumerate() {
        let Some(last) = track.points.last() else {
            continue;
        };
        let gap_ms = time_ms - last.0;
        if !(0..=350).contains(&gap_ms) {
            continue;
        }
        let gap_s = gap_ms as f32 / 1_000.0;
        let (predicted_x, predicted_y) = if track.points.len() >= 2 {
            let previous = track.points[track.points.len() - 2];
            let dt = ((last.0 - previous.0) as f32 / 1_000.0).max(0.001);
            (
                last.1 + (last.1 - previous.1) / dt * gap_s,
                last.2 + (last.2 - previous.2) / dt * gap_s,
            )
        } else {
            (last.1, last.2)
        };
        let gate = (1.75 * rim_width).max((12.0 * rim_width).min(45.0 * rim_width * gap_s + 0.02));
        for (detection_index, (x, y, _)) in detections.iter().enumerate() {
            let distance = ((x - predicted_x).powi(2) + (y - predicted_y).powi(2)).sqrt();
            if distance <= gate {
                pairs.push((distance, track_index, detection_index));
            }
        }
    }
    pairs.sort_by(|left, right| left.0.total_cmp(&right.0));
    let mut used_tracks = std::collections::HashSet::new();
    let mut used_detections = std::collections::HashSet::new();
    let mut updated = Vec::new();
    for (_, track_index, detection_index) in pairs {
        if !used_tracks.insert(track_index) || !used_detections.insert(detection_index) {
            continue;
        }
        let (x, y, confidence) = detections[detection_index];
        let track = &mut tracks[track_index];
        track.points.push((time_ms, x, y, confidence));
        if track.points.len() > 32 {
            track.points.remove(0);
        }
        updated.push(track.id);
    }
    for (detection_index, (x, y, confidence)) in detections.into_iter().enumerate() {
        if used_detections.contains(&detection_index) {
            continue;
        }
        let track_id = *next_track_id;
        *next_track_id += 1;
        tracks.push(BallTrack {
            id: track_id,
            points: vec![(time_ms, x, y, confidence)],
        });
        updated.push(track_id);
    }
    updated
}

/// Stitches a short detector handoff back into the original trajectory.
///
/// A ball can disappear at the rim and reappear as a new track below the net.
/// Only a below-net point whose interpolated crossing is inside the rim and
/// whose own track already has post-rim persistence is eligible. This keeps a
/// nearby player's ball from being joined merely because it is visible after
/// an occlusion.
fn recover_track_points(tracks: &[BallTrack], rim: &Roi) -> Vec<(u64, Vec<BallPoint>)> {
    let rim_y = (rim.top + rim.bottom) / 2.0;
    let rim_height = (rim.bottom - rim.top).max(0.01);
    let rim_width = (rim.right - rim.left).max(0.01);
    let above_y = rim_y - 0.6 * rim_height;
    let below_y = rim_y + 0.9 * rim_height;
    let below_depth = rim_y + (rim_width * 0.35).max(rim_height * 0.5);
    let center_x = (rim.left + rim.right) / 2.0;
    let half_width = rim_width / 2.0;
    let mut recoveries = Vec::new();

    for source in tracks {
        let mut best: Option<(f32, i64, Vec<BallPoint>)> = None;
        for above in source.points.iter().copied() {
            if above.2 > above_y {
                continue;
            }
            for target in tracks {
                if target.id == source.id {
                    continue;
                }
                let source_has_intervening_point = source
                    .points
                    .iter()
                    .any(|point| point.0 > above.0 && point.0 <= above.0 + 1_800);
                if source_has_intervening_point {
                    continue;
                }
                for below in target.points.iter().copied() {
                    let gap = below.0 - above.0;
                    if !(0..=1_800).contains(&gap) || below.2 < below_y {
                        continue;
                    }
                    let Some((_, crossing_x)) = crossing_at_rim(above, below, rim_y) else {
                        continue;
                    };
                    if !(rim.left..=rim.right).contains(&crossing_x)
                        || (below.1 - center_x).abs() > half_width * 1.35
                    {
                        continue;
                    }
                    let post: Vec<_> = target
                        .points
                        .iter()
                        .copied()
                        .filter(|point| {
                            point.0 >= below.0 && point.0 <= below.0 + 800 && point.2 >= below_depth
                        })
                        .collect();
                    if post.len() < 2
                        || post
                            .iter()
                            .any(|point| (point.1 - center_x).abs() > half_width * 2.0)
                    {
                        continue;
                    }

                    let mut stitched: Vec<_> = source
                        .points
                        .iter()
                        .copied()
                        .filter(|point| point.0 <= above.0)
                        .chain(
                            target
                                .points
                                .iter()
                                .copied()
                                .filter(|point| point.0 >= below.0),
                        )
                        .collect();
                    stitched.sort_by_key(|point| point.0);
                    stitched.dedup_by(|left, right| left.0 == right.0);
                    if !complete_rim_crossing(&stitched, above.0, below.0, rim) {
                        continue;
                    }

                    let rank = ((crossing_x - center_x).abs(), gap);
                    if best
                        .as_ref()
                        .is_none_or(|(distance, best_gap, _)| rank < (*distance, *best_gap))
                    {
                        best = Some((rank.0, rank.1, stitched));
                    }
                }
            }
        }
        if let Some((_, _, points)) = best {
            recoveries.push((source.id, points));
        }
    }
    recoveries
}

impl RuntimeSession {
    /// Three-zone net motion analysis (mirrors desktop algorithm).
    ///
    /// A made basket should produce activity in the net's lower zone
    /// followed by activity in the zone below it (ball enters net top,
    /// pushes through, drops below). Simultaneous activation suggests
    /// camera shake; reversed order (below before lower) is suspicious.
    fn update_net_motion(&mut self, time_ms: i64, image: &RgbImage) {
        let signatures = net_zone_signatures(image, &self.config.net_roi);
        let (upper, lower, below) = self
            .previous_net_signature
            .as_ref()
            .map(|(_, previous)| {
                (
                    net_motion_score(&signatures[0], &previous[0]),
                    net_motion_score(&signatures[1], &previous[1]),
                    net_motion_score(&signatures[2], &previous[2]),
                )
            })
            .unwrap_or((0.0, 0.0, 0.0));
        let (upper, lower, below) = suppress_synchronized_net_motion(upper, lower, below);
        self.net_zone_history.push((time_ms, upper, lower, below));

        // Trim history to ±2s around the newest event.
        let cutoff = time_ms - 3000;
        let first_relevant = self
            .net_zone_history
            .iter()
            .position(|(t, _, _, _)| *t >= cutoff)
            .unwrap_or(self.net_zone_history.len());
        if first_relevant > 0 {
            self.net_zone_history.drain(..first_relevant);
        }

        // Compute per-candidate net evidence with the same public semantics
        // as the desktop engine. The underlying measurement is still mobile
        // specific, but unavailable measurement is never treated as no motion.
        let history = &self.net_zone_history;
        for candidate in &mut self.candidates {
            if time_ms < candidate.event_ms || time_ms > candidate.event_ms + 1_500 {
                continue;
            }
            let evidence = net_zone_evidence(history, candidate.event_ms);
            candidate.net_signal_available |= evidence.signal_available;
            candidate.net_no_motion = evidence.no_motion;
            candidate.net_motion_score = candidate.net_motion_score.max(evidence.inside_score);
            candidate.net_sequence_score =
                candidate.net_sequence_score.max(evidence.sequence_score);
            candidate.net_lower_peak = candidate.net_lower_peak.max(evidence.lower_peak);
            candidate.net_below_peak = candidate.net_below_peak.max(evidence.below_peak);
            candidate.net_support |= evidence.support;
        }

        self.previous_net_signature = Some((time_ms, signatures));
    }

    /// Resolve verdict from accumulated evidence using the desktop decision
    /// semantics. Candidate creation stays optimistic for recall; the delayed
    /// decision requires the same post-crossing evidence categories as Python.
    fn resolve_verdict(&mut self) {
        let current_time = self
            .tracks
            .iter()
            .filter_map(|track| track.points.last().map(|point| point.0))
            .max()
            .unwrap_or(0);
        let rim = &self.config.hoop_roi;
        let tracks = self.tracks.clone();

        for candidate in &mut self.candidates {
            candidate.composite_score = composite_score(
                candidate.trajectory_score,
                candidate.crossing_score,
                candidate.net_motion_score,
                candidate.prediction_score,
                candidate.rebound,
            );

            if candidate.decision_time_ms.is_some() || current_time < candidate.below.time_ms + 800
            {
                continue;
            }
            let Some(track) = tracks.iter().find(|track| track.id == candidate.track_id) else {
                continue;
            };

            candidate.complete_crossing = complete_rim_crossing(
                &track.points,
                candidate.above.time_ms,
                candidate.below.time_ms,
                rim,
            );
            let post = post_crossing_evidence(&track.points, candidate.below.time_ms, rim);
            candidate.ball_persistence = post.persistence;
            candidate.rebound |= post.rebound;
            candidate.lateral_exit = post.lateral_exit;
            candidate.post_crossing_lateral_recovery = post.lateral_recovery;

            let gates = calibrated_gates(
                &track.points,
                candidate.above.time_ms,
                candidate.below.time_ms,
                rim,
                &net_zone_evidence(&self.net_zone_history, candidate.event_ms),
                candidate.complete_crossing,
            );
            let positive_gate = if candidate.net_signal_available {
                candidate.net_support
            } else {
                gates.high_precision
                    || candidate.net_motion_score >= 0.55
                    || candidate.composite_score >= 0.72
            };
            let strong_positive =
                candidate.ball_persistence >= 0.67 && candidate.complete_crossing && positive_gate;
            let strong_negative = candidate.rebound
                || (candidate.lateral_exit && !candidate.post_crossing_lateral_recovery);

            if strong_negative {
                candidate.verdict = "missed".into();
                candidate.reason = if candidate.rebound {
                    "rim_rebound".into()
                } else {
                    "lateral_exit".into()
                };
            } else if strong_positive {
                candidate.verdict = "made".into();
                candidate.reason = "complete_crossing+net_support".into();
            }
            candidate.auto_export_eligible = candidate.verdict == "made" && gates.automatic_goal;
            candidate.decision_time_ms = Some(candidate.below.time_ms + 800);
            candidate.trajectory = track
                .points
                .iter()
                .filter(|point| {
                    point.0 >= candidate.event_ms - 1_200 && point.0 <= candidate.event_ms + 800
                })
                .map(|point| EvidencePoint {
                    time_ms: point.0,
                    x: point.1,
                    y: point.2,
                    confidence: point.3,
                })
                .collect();
        }
        let active_track_ids: std::collections::HashSet<_> = self
            .candidates
            .iter()
            .filter(|candidate| candidate.decision_time_ms.is_none())
            .map(|candidate| candidate.track_id)
            .collect();
        self.tracks.retain(|track| {
            active_track_ids.contains(&track.id)
                || track
                    .points
                    .last()
                    .is_some_and(|point| point.0 >= current_time - 2_000)
        });
    }

    fn detect_crossing(&mut self, track_id: u64) {
        let Some(track) = self.tracks.iter().find(|track| track.id == track_id) else {
            return;
        };
        let points = track.points.clone();
        let rim_y = (self.config.hoop_roi.top + self.config.hoop_roi.bottom) / 2.0;
        let rim_left = self.config.hoop_roi.left;
        let rim_right = self.config.hoop_roi.right;
        let rim_height = self.config.hoop_roi.bottom - self.config.hoop_roi.top;
        let above_y = rim_y - 0.6 * rim_height;
        let below_y = rim_y + 0.9 * rim_height;

        // Python does not require the below point to be adjacent: at a low
        // sample rate the ball can have an intermediate rim-band point. Keep
        // the same 1.8s search horizon and select the first valid deep below
        // point, rather than fabricating a crossing from a shallow sample.
        for (index, above) in points.iter().copied().enumerate() {
            if above.2 > above_y {
                continue;
            }
            for (relative_index, below) in points[index + 1..].iter().copied().enumerate() {
                if below.0 <= above.0 {
                    continue;
                }
                if below.0 - above.0 > 1_800 {
                    break;
                }
                if below.2 < below_y || below.2 <= above.2 {
                    continue;
                }
                let Some((crossing, crossing_x)) = crossing_at_rim(above, below, rim_y) else {
                    continue;
                };
                if !(rim_left..=rim_right).contains(&crossing_x) {
                    continue;
                }

                // Check for an existing candidate at this time to avoid duplicates.
                let event_ms = above.0 + ((below.0 - above.0) as f32 * crossing) as i64;
                if self
                    .candidates
                    .iter()
                    .any(|candidate| (candidate.event_ms - event_ms).abs() <= 2_000)
                {
                    continue;
                }

                let context_end = index + relative_index + 2;
                let recent_start = context_end.saturating_sub(12);
                let recent = &points[recent_start..context_end];

                let trajectory_score = trajectory_score(recent);
                let crossing_score = (1.0
                    - ((crossing_x - (rim_left + rim_right) / 2.0).abs()
                        / ((rim_right - rim_left) / 2.0).max(1e-6)))
                .clamp(0.0, 1.0);
                let rim_center_x = (rim_left + rim_right) / 2.0;
                let rim_half_width = (rim_right - rim_left) / 2.0;
                let prediction = prediction_score(recent, rim_y, rim_center_x, rim_half_width);
                let trajectory = recent
                    .iter()
                    .rev()
                    .take(32)
                    .rev()
                    .map(|point| EvidencePoint {
                        time_ms: point.0,
                        x: point.1,
                        y: point.2,
                        confidence: point.3,
                    })
                    .collect();
                self.candidates.push(Candidate {
                    id: format!("candidate_{event_ms}"),
                    track_id,
                    start_ms: (event_ms - self.config.clip_before_ms).max(0),
                    end_ms: clip_end_ms(
                        event_ms,
                        self.config.clip_after_ms,
                        self.config.duration_ms,
                    ),
                    event_ms,
                    confidence: (0.5 * above.3 + 0.5 * below.3).clamp(0.0, 1.0),
                    trajectory_score,
                    crossing_score,
                    net_motion_score: 0.0,
                    net_sequence_score: 0.0,
                    prediction_score: prediction,
                    composite_score: composite_score(
                        trajectory_score,
                        crossing_score,
                        0.0,
                        prediction,
                        false,
                    ),
                    trajectory,
                    above: EvidencePoint {
                        time_ms: above.0,
                        x: above.1,
                        y: above.2,
                        confidence: above.3,
                    },
                    below: EvidencePoint {
                        time_ms: below.0,
                        x: below.1,
                        y: below.2,
                        confidence: below.3,
                    },
                    crossing: EvidencePoint {
                        time_ms: event_ms,
                        x: crossing_x,
                        y: rim_y,
                        confidence: (above.3 + below.3) / 2.0,
                    },
                    reason: "uncertain".into(),
                    verdict: "ambiguous".into(),
                    complete_crossing: false,
                    rebound: false,
                    lateral_exit: false,
                    post_crossing_lateral_recovery: false,
                    ball_persistence: 0.0,
                    net_signal_available: false,
                    net_support: false,
                    net_no_motion: false,
                    net_lower_peak: 0.0,
                    net_below_peak: 0.0,
                    auto_export_eligible: false,
                    decision_time_ms: None,
                    algorithm_version: "analysis-contract-v1".into(),
                    evidence_source: "rust_onnx:analysis-contract-v1".into(),
                });
                // Don't clear all ball points — the ball continues to be tracked
                // after a made shot. Only trim to prevent re-detecting the same
                // crossing (the duplicate check above handles this).
                break;
            }
        }
    }
}

fn default_confidence() -> f32 {
    0.10
}
fn default_before_ms() -> i64 {
    6_000
}
fn default_after_ms() -> i64 {
    3_000
}

fn crossing_at_rim(
    above: (i64, f32, f32, f32),
    below: (i64, f32, f32, f32),
    rim_y: f32,
) -> Option<(f32, f32)> {
    if !(above.2 < rim_y && below.2 >= rim_y && below.2 > above.2) {
        return None;
    }
    let crossing = ((rim_y - above.2) / (below.2 - above.2).max(1e-6)).clamp(0.0, 1.0);
    let crossing_x = above.1 + (below.1 - above.1) * crossing;
    Some((crossing, crossing_x))
}

#[cfg(test)]
fn complete_crossing(
    points: &[(i64, f32, f32, f32)],
    rim_y: f32,
    rim_left: f32,
    rim_right: f32,
) -> bool {
    if points.len() < 3 {
        return false;
    }
    let above = points[points.len() - 2];
    let below = points[points.len() - 1];
    if below.0 <= above.0 || below.0 - above.0 > 1_000 {
        return false;
    }
    if above.2 >= rim_y || below.2 < rim_y {
        return false;
    }
    if below.2 - above.2 < 0.012 {
        return false;
    }

    // Funnel-shaped corridor (mirrors desktop fix): near the rim plane the
    // corridor is tight; below the net it widens because the ball naturally
    // swings outward after passing through. The old fixed-width corridor
    // rejected angled shots that pass through the rim then exit sideways.
    let width = (rim_right - rim_left).max(0.01);
    let near_rim = points
        .iter()
        .filter(|point| (point.2 - rim_y).abs() <= 0.18)
        .collect::<Vec<_>>();
    if near_rim.len() < 2 {
        return false;
    }
    let corridor_padding = (width * 0.40).max(0.030);
    let corridor_left = rim_left - corridor_padding;
    let corridor_right = rim_right + corridor_padding;
    let near_violations = near_rim
        .iter()
        .filter(|point| point.1 < corridor_left || point.1 > corridor_right)
        .count();
    // Allow up to 1 outlier near the rim (angled approach can have one
    // point slightly outside the corridor).
    if near_violations > 1 {
        return false;
    }

    let above_count = near_rim.iter().filter(|point| point.2 < rim_y).count();
    let below_count = near_rim.iter().filter(|point| point.2 >= rim_y).count();
    if above_count < 1 || below_count < 1 {
        return false;
    }

    // Verify the ball was descending toward the rim before the crossing.
    let previous_above = points[..points.len() - 2]
        .iter()
        .rev()
        .find(|point| point.2 < rim_y);
    previous_above.is_some_and(|previous| above.2 + 0.06 >= previous.2)
}

fn complete_rim_crossing(
    points: &[(i64, f32, f32, f32)],
    above_time_ms: i64,
    below_time_ms: i64,
    rim: &Roi,
) -> bool {
    let rim_y = (rim.top + rim.bottom) / 2.0;
    let rim_height = (rim.bottom - rim.top).max(0.01);
    let rim_width = (rim.right - rim.left).max(0.01);
    let center_x = (rim.left + rim.right) / 2.0;
    let half_width = rim_width / 2.0;
    let Some(above) = points
        .iter()
        .copied()
        .find(|point| point.0 == above_time_ms)
    else {
        return false;
    };
    let Some(below) = points
        .iter()
        .copied()
        .find(|point| point.0 == below_time_ms)
    else {
        return false;
    };
    let Some((_, crossing_x)) = crossing_at_rim(above, below, rim_y) else {
        return false;
    };
    if !(rim.left..=rim.right).contains(&crossing_x) {
        return false;
    }

    let near_above = points.iter().any(|point| {
        point.0 <= above_time_ms && point.2 >= rim_y - 1.8 * rim_height && point.2 <= rim_y
    });
    let transition: Vec<_> = points
        .iter()
        .filter(|point| {
            point.0 >= above_time_ms
                && point.0 <= below_time_ms
                && point.2 >= rim_y - 1.5 * rim_height
                && point.2 <= rim_y + 0.5 * rim_height
        })
        .collect();
    let transition_inside = transition
        .iter()
        .filter(|point| point_in_rim_corridor(point, center_x, half_width, 0.15))
        .count();
    let below_depth = rim_y + (rim_width * 0.35).max(rim_height * 0.5);
    let post: Vec<_> = points
        .iter()
        .filter(|point| {
            point.0 >= below_time_ms && point.0 <= below_time_ms + 800 && point.2 >= below_depth
        })
        .collect();
    let post_inside = post
        .iter()
        .take(3)
        .filter(|point| {
            let fall = (point.2 - below_depth).max(0.0);
            let allowance = rim_width * 0.35 + fall * 0.35;
            (point.1 - center_x).abs() <= half_width + allowance
        })
        .count();

    near_above
        && !transition.is_empty()
        && transition_inside as f32 / transition.len() as f32 >= 0.60
        && post.len() >= 2
        && post_inside >= 2
}

fn point_in_rim_corridor(
    point: &&(i64, f32, f32, f32),
    center_x: f32,
    half_width: f32,
    tolerance_ratio: f32,
) -> bool {
    let tolerance = half_width * tolerance_ratio;
    point.1 >= center_x - half_width - tolerance && point.1 <= center_x + half_width + tolerance
}

fn post_crossing_evidence(
    points: &[(i64, f32, f32, f32)],
    below_time_ms: i64,
    rim: &Roi,
) -> PostCrossingEvidence {
    let rim_y = (rim.top + rim.bottom) / 2.0;
    let rim_height = (rim.bottom - rim.top).max(0.01);
    let rim_width = (rim.right - rim.left).max(0.01);
    let center_x = (rim.left + rim.right) / 2.0;
    let half_width = rim_width / 2.0;
    let later: Vec<_> = points
        .iter()
        .copied()
        .filter(|point| point.0 >= below_time_ms && point.0 <= below_time_ms + 800)
        .collect();
    if later.is_empty() {
        return PostCrossingEvidence::default();
    }
    let below_depth = rim_y + (rim_width * 0.35).max(rim_height * 0.5);
    let persistence_points: Vec<_> = later
        .iter()
        .copied()
        .filter(|point| point.2 >= below_depth)
        .collect();
    let rebound_zone_bottom = rim_y + (2.5 * rim_height).max(2.5 * rim_width);
    let mut previous_y = later[0].2;
    let mut rebound = false;
    for point in later.iter().skip(1) {
        if point.2 >= rebound_zone_bottom {
            break;
        }
        if point.2 < previous_y - (rim_width * 0.25).max(rim_height * 0.18) {
            rebound = true;
            break;
        }
        previous_y = point.2;
    }
    let lateral_exit = later.iter().any(|point| {
        (point.1 - center_x).abs() > 3.0 * half_width
            && point.2 <= rim_y + (4.0 * rim_height).max(4.0 * rim_width)
    });
    let deep_corridor = persistence_points
        .iter()
        .filter(|point| (point.1 - center_x).abs() <= half_width)
        .count();
    let lateral_recovery =
        lateral_exit && persistence_points.len() >= 3 && deep_corridor == 1 && !rebound;
    PostCrossingEvidence {
        persistence: (persistence_points.len() as f32 / 3.0).min(1.0),
        rebound,
        lateral_exit,
        lateral_recovery,
    }
}

pub fn evaluate_decision_replay(request: DecisionReplayRequest) -> DecisionReplayResult {
    let mut points: Vec<_> = request
        .trajectory
        .iter()
        .map(|point| (point.time_ms, point.x, point.y, point.confidence))
        .collect();
    points.push((
        request.above.time_ms,
        request.above.x,
        request.above.y,
        request.above.confidence,
    ));
    points.push((
        request.below.time_ms,
        request.below.x,
        request.below.y,
        request.below.confidence,
    ));
    points.sort_by_key(|point| point.0);
    points.dedup_by(|left, right| left.0 == right.0);

    let complete_crossing = complete_rim_crossing(
        &points,
        request.above.time_ms,
        request.below.time_ms,
        &request.hoop_roi,
    );
    let post = post_crossing_evidence(&points, request.below.time_ms, &request.hoop_roi);
    let history: Vec<_> = request
        .net_history
        .iter()
        .map(|point| (point.time_ms, point.upper, point.lower, point.below))
        .collect();
    let rim_y = (request.hoop_roi.top + request.hoop_roi.bottom) / 2.0;
    let event_ms = crossing_at_rim(
        (
            request.above.time_ms,
            request.above.x,
            request.above.y,
            request.above.confidence,
        ),
        (
            request.below.time_ms,
            request.below.x,
            request.below.y,
            request.below.confidence,
        ),
        rim_y,
    )
    .map(|(ratio, _)| {
        request.above.time_ms
            + ((request.below.time_ms - request.above.time_ms) as f32 * ratio) as i64
    })
    .unwrap_or(request.below.time_ms);
    let net = net_zone_evidence(&history, event_ms);
    let gates = calibrated_gates(
        &points,
        request.above.time_ms,
        request.below.time_ms,
        &request.hoop_roi,
        &net,
        complete_crossing,
    );
    let positive_gate = if net.signal_available {
        net.support
    } else {
        gates.high_precision
    };
    let verdict = if post.rebound || (post.lateral_exit && !post.lateral_recovery) {
        "missed"
    } else if post.persistence >= 0.67 && complete_crossing && positive_gate {
        "made"
    } else {
        "ambiguous"
    };
    DecisionReplayResult {
        algorithm_version: "analysis-contract-v1".into(),
        complete_crossing,
        ball_persistence: post.persistence,
        rebound: post.rebound,
        lateral_exit: post.lateral_exit,
        post_crossing_lateral_recovery: post.lateral_recovery,
        net_signal_available: net.signal_available,
        net_support: net.support,
        net_no_motion: net.no_motion,
        net_motion_score: net.inside_score,
        net_sequence_score: net.sequence_score,
        verdict: verdict.into(),
        auto_export_eligible: verdict == "made" && gates.automatic_goal,
    }
}

fn calibrated_gates(
    points: &[(i64, f32, f32, f32)],
    above_time_ms: i64,
    below_time_ms: i64,
    rim: &Roi,
    net: &NetEvidence,
    complete_crossing: bool,
) -> CalibratedGates {
    let Some(above) = points
        .iter()
        .copied()
        .find(|point| point.0 == above_time_ms)
    else {
        return CalibratedGates::default();
    };
    let Some(below) = points
        .iter()
        .copied()
        .find(|point| point.0 == below_time_ms)
    else {
        return CalibratedGates::default();
    };
    let rim_y = (rim.top + rim.bottom) / 2.0;
    let rim_width = (rim.right - rim.left).max(0.01);
    let gap_s = ((below.0 - above.0) as f32 / 1_000.0).max(0.001);
    let speed = ((below.2 - above.2) / gap_s) / rim_width * 30.54;
    let approach: Vec<_> = points
        .iter()
        .copied()
        .filter(|point| {
            point.0 >= above_time_ms - 800
                && point.0 <= above_time_ms
                && point.2 <= rim_y - 0.25 * rim_width
        })
        .collect();
    let span = if approach.is_empty() {
        0.0
    } else {
        let min_x = approach
            .iter()
            .map(|point| point.1)
            .fold(f32::INFINITY, f32::min);
        let max_x = approach
            .iter()
            .map(|point| point.1)
            .fold(f32::NEG_INFINITY, f32::max);
        (max_x - min_x) / rim_width * 30.54
    };
    let horizontal_ratio = (below.1 - above.1).abs() / (below.2 - above.2).max(0.001);
    let net_gate = if net.signal_available {
        net.support
    } else {
        net.inside_score >= 0.90
    };
    let high_speed_net = (150.0..=260.0).contains(&speed) && horizontal_ratio >= 0.50 && net_gate;
    let high_speed_drop = (150.0..=220.0).contains(&speed)
        && span <= 130.0
        && (!net.signal_available || net.support)
        && horizontal_ratio >= 0.55;
    let strict_low_speed = speed <= 95.0 && span <= 100.0;
    let high_precision = complete_crossing
        && (strict_low_speed || high_speed_net || high_speed_drop)
        && !net.no_motion;
    let automatic_goal = complete_crossing
        && !net.no_motion
        && (speed <= 102.0 || strict_low_speed || high_speed_net || high_speed_drop);
    CalibratedGates {
        high_precision,
        automatic_goal,
    }
}

fn validate_roi(roi: &Roi, name: &str) -> Result<(), RuntimeError> {
    if !(0.0..=1.0).contains(&roi.left)
        || !(0.0..=1.0).contains(&roi.top)
        || !(0.0..=1.0).contains(&roi.right)
        || !(0.0..=1.0).contains(&roi.bottom)
        || roi.right <= roi.left
        || roi.bottom <= roi.top
    {
        return Err(RuntimeError::InvalidRequest(format!(
            "{name} ROI is invalid"
        )));
    }
    Ok(())
}

fn validate_config(config: &RuntimeConfig) -> Result<(), RuntimeError> {
    if !config.confidence_threshold.is_finite()
        || !(0.0..=1.0).contains(&config.confidence_threshold)
    {
        return Err(RuntimeError::InvalidRequest(
            "confidence threshold is invalid".into(),
        ));
    }
    if config.clip_before_ms < 0 || config.clip_after_ms < 0 {
        return Err(RuntimeError::InvalidRequest(
            "clip duration must not be negative".into(),
        ));
    }
    if config.duration_ms.is_some_and(|duration| duration < 0) {
        return Err(RuntimeError::InvalidRequest(
            "video duration must not be negative".into(),
        ));
    }
    if config.model_size < 320 || !config.model_size.is_multiple_of(32) {
        return Err(RuntimeError::InvalidRequest(
            "model size must be a multiple of 32 and at least 320".into(),
        ));
    }
    Ok(())
}

fn clip_end_ms(event_ms: i64, after_ms: i64, duration_ms: Option<i64>) -> i64 {
    duration_ms
        .map(|duration| (event_ms + after_ms).min(duration))
        .unwrap_or(event_ms + after_ms)
}

/// Samples the upper, middle and lower thirds of the net separately. Motion
/// is calculated against the previous frame's local contrast signature rather
/// than the zone's absolute brightness.
fn net_zone_signatures(image: &RgbImage, roi: &Roi) -> [Vec<f32>; 3] {
    let height = roi.bottom - roi.top;
    let zone = |index: f32| Roi {
        left: roi.left,
        right: roi.right,
        top: roi.top + height * index / 3.0,
        bottom: roi.top + height * (index + 1.0) / 3.0,
    };
    [
        net_signature(image, &zone(0.0)),
        net_signature(image, &zone(1.0)),
        net_signature(image, &zone(2.0)),
    ]
}

/// Computes inside-motion score and sequence score from zone history.
///
/// inside_score: how much the lower zone activated above baseline during
/// the event window (ball pushing through the net).
/// sequence_score: whether lower activated before below (correct order
/// for a made basket: ball enters net, then drops below).
#[cfg(test)]
fn net_zone_scores(history: &[(i64, f32, f32, f32)], event_ms: i64) -> (f32, f32) {
    let baseline: Vec<_> = history
        .iter()
        .filter(|(t, _, _, _)| *t < event_ms - 100 && *t >= event_ms - 800)
        .collect();
    let active: Vec<_> = history
        .iter()
        .filter(|(t, _, _, _)| *t >= event_ms - 100 && *t <= event_ms + 800)
        .collect();

    if active.len() < 2 || baseline.is_empty() {
        return (0.0, 0.0);
    }

    let baseline_lower =
        baseline.iter().map(|(_, _, l, _)| *l).sum::<f32>() / baseline.len() as f32;
    let baseline_below =
        baseline.iter().map(|(_, _, _, b)| *b).sum::<f32>() / baseline.len() as f32;

    // Inside motion: how much the lower zone exceeded baseline.
    let max_lower_delta = active
        .iter()
        .map(|(_, _, l, _)| (*l - baseline_lower).abs())
        .fold(0.0f32, f32::max);
    let inside_score = (max_lower_delta / 0.08).clamp(0.0, 1.0);

    // Sequence: did lower activate before below?
    let lower_first = active
        .iter()
        .find(|(_, _, l, _)| (*l - baseline_lower).abs() > 0.03)
        .map(|(t, _, _, _)| *t);
    let below_first = active
        .iter()
        .find(|(_, _, _, b)| (*b - baseline_below).abs() > 0.03)
        .map(|(t, _, _, _)| *t);

    let sequence_score = match (lower_first, below_first) {
        (Some(lt), Some(bt)) if bt > lt => {
            // Correct order: lower first, then below.
            1.0
        }
        (Some(_), None) => 0.8,    // Only lower activated, no below yet.
        (Some(_), Some(_)) => 0.4, // Wrong order (below before lower).
        (None, _) => 0.0,          // No lower zone activation.
    };

    (inside_score, sequence_score)
}

fn net_zone_evidence(history: &[(i64, f32, f32, f32)], event_ms: i64) -> NetEvidence {
    let baseline: Vec<_> = history
        .iter()
        .filter(|(time_ms, _, _, _)| *time_ms < event_ms - 100 && *time_ms >= event_ms - 800)
        .collect();
    let active: Vec<_> = history
        .iter()
        .filter(|(time_ms, _, _, _)| *time_ms >= event_ms - 100 && *time_ms <= event_ms + 800)
        .collect();
    if active.len() < 2 || baseline.is_empty() {
        return NetEvidence::default();
    }

    let baseline_lower =
        baseline.iter().map(|(_, _, lower, _)| *lower).sum::<f32>() / baseline.len() as f32;
    let baseline_below =
        baseline.iter().map(|(_, _, _, below)| *below).sum::<f32>() / baseline.len() as f32;
    let lower_peak = active
        .iter()
        .map(|(_, _, lower, _)| (*lower - baseline_lower).abs())
        .fold(0.0_f32, f32::max);
    let below_peak = active
        .iter()
        .map(|(_, _, _, below)| (*below - baseline_below).abs())
        .fold(0.0_f32, f32::max);
    let threshold = 0.25;
    let lower_first = active
        .iter()
        .find(|(_, _, lower, _)| (*lower - baseline_lower).abs() >= threshold)
        .map(|(time_ms, _, _, _)| *time_ms);
    let below_first = active
        .iter()
        .find(|(_, _, _, below)| (*below - baseline_below).abs() >= threshold)
        .map(|(time_ms, _, _, _)| *time_ms);
    let sequence_score = match (lower_first, below_first) {
        (Some(lower), Some(below)) if below - lower >= 50 => 1.0,
        (Some(_), Some(_)) if lower_peak >= 0.4 && below_peak >= 0.4 => 0.8,
        (Some(lower), Some(below)) if below >= lower => 0.45,
        (Some(_), Some(_)) => 0.15,
        (Some(_), None) => 0.45,
        (None, Some(_)) => 0.15,
        (None, None) => 0.0,
    };
    let active_count = active
        .iter()
        .filter(|(_, _, lower, below)| {
            (*lower - baseline_lower).abs() >= threshold
                || (*below - baseline_below).abs() >= threshold
        })
        .count();
    let persistence = (active_count as f32 / 3.0).min(1.0);
    let inside_score =
        (0.55 * lower_peak + 0.25 * below_peak + 0.12 * sequence_score + 0.08 * persistence)
            .min(1.0);
    let baseline_quiet = baseline_lower < 0.35 && baseline_below < 0.35;
    let no_motion = baseline_quiet && lower_peak < 0.12 && below_peak < 0.12 && inside_score < 0.12;
    NetEvidence {
        signal_available: true,
        no_motion,
        inside_score,
        sequence_score,
        lower_peak,
        below_peak,
        support: inside_score >= 0.35 && sequence_score >= 0.80 && below_peak >= 0.25,
    }
}

fn net_motion_score(current: &[f32], previous: &[f32]) -> f32 {
    if current.is_empty() || current.len() != previous.len() {
        return 0.0;
    }
    let difference = current
        .iter()
        .zip(previous)
        .map(|(current, old)| (current - old).abs())
        .sum::<f32>()
        / current.len() as f32;
    (difference / 0.15).clamp(0.0, 1.0)
}

fn suppress_synchronized_net_motion(upper: f32, lower: f32, below: f32) -> (f32, f32, f32) {
    let minimum = upper.min(lower).min(below);
    let maximum = upper.max(lower).max(below);
    if minimum >= 0.18 && maximum - minimum <= 0.10 {
        return (0.0, 0.0, 0.0);
    }
    (upper, lower, below)
}

fn init_onnx() -> Result<(), RuntimeError> {
    let result = ORT_INIT.get_or_init(|| {
        #[cfg(feature = "dynamic-onnx")]
        {
            let library = std::env::var_os("BHE_ORT_LIBRARY");
            if let Some(path) = library {
                ort::init_from(Path::new(&path))
                    .map(|builder| {
                        builder.with_name("bhe_runtime").commit();
                    })
                    .map_err(|error| error.to_string())
            } else {
                ort::init().with_name("bhe_runtime").commit();
                Ok(())
            }
        }

        #[cfg(not(feature = "dynamic-onnx"))]
        {
            ort::init().with_name("bhe_runtime").commit();
            Ok(())
        }
    });
    result
        .as_ref()
        .map(|_| ())
        .map_err(|error| RuntimeError::InvalidRequest(format!("ONNX Runtime 初始化失败: {error}")))
}

#[cfg(feature = "dynamic-onnx")]
fn init_onnx_from_path(library: Option<&Path>) -> Result<(), RuntimeError> {
    let result = ORT_INIT.get_or_init(|| {
        if let Some(path) = library {
            ort::init_from(Path::new(&path))
                .map(|builder| {
                    builder.with_name("bhe_runtime").commit();
                })
                .map_err(|error| error.to_string())
        } else {
            ort::init().with_name("bhe_runtime").commit();
            Ok(())
        }
    });
    result
        .as_ref()
        .map(|_| ())
        .map_err(|error| RuntimeError::InvalidRequest(format!("ONNX Runtime 初始化失败: {error}")))
}

fn decode_rgb(frame: &FrameInput) -> Result<RgbImage, RuntimeError> {
    if let Some(encoded) = &frame.image_base64 {
        let bytes = base64::engine::general_purpose::STANDARD.decode(encoded)?;
        return Ok(image::load_from_memory(&bytes)?.to_rgb8());
    }
    let encoded = frame
        .rgb_base64
        .as_deref()
        .ok_or_else(|| RuntimeError::InvalidRequest("frame image is missing".into()))?;
    let bytes = base64::engine::general_purpose::STANDARD.decode(encoded)?;
    let expected = frame.width as usize * frame.height as usize * 3;
    if bytes.len() != expected {
        return Err(RuntimeError::InvalidRequest(format!(
            "frame {} has {} bytes, expected {}",
            frame.time_ms,
            bytes.len(),
            expected
        )));
    }
    RgbImage::from_raw(frame.width, frame.height, bytes)
        .ok_or_else(|| RuntimeError::InvalidRequest("RGB frame dimensions are invalid".into()))
}

fn preprocess(
    image: &RgbImage,
    model_size: u32,
) -> Result<(Array4<f32>, f32, f32, f32), RuntimeError> {
    let (width, height) = image.dimensions();
    if width == 0 || height == 0 {
        return Err(RuntimeError::InvalidRequest("empty frame".into()));
    }
    let scale = (model_size as f32 / width as f32).min(model_size as f32 / height as f32);
    let resized = DynamicImage::ImageRgb8(image.clone())
        .resize_exact(
            (width as f32 * scale).round() as u32,
            (height as f32 * scale).round() as u32,
            FilterType::Triangle,
        )
        .to_rgb8();
    let offset_x = (model_size as i32 - resized.width() as i32).max(0) / 2;
    let offset_y = (model_size as i32 - resized.height() as i32).max(0) / 2;
    let mut input = Array4::<f32>::zeros((1, 3, model_size as usize, model_size as usize));
    for (x, y, pixel) in resized.enumerate_pixels() {
        let xx = (x as i32 + offset_x) as usize;
        let yy = (y as i32 + offset_y) as usize;
        input[[0, 0, yy, xx]] = pixel[0] as f32 / 255.0;
        input[[0, 1, yy, xx]] = pixel[1] as f32 / 255.0;
        input[[0, 2, yy, xx]] = pixel[2] as f32 / 255.0;
    }
    Ok((input, scale, offset_x as f32, offset_y as f32))
}

fn net_signature(image: &RgbImage, roi: &Roi) -> Vec<f32> {
    let width = image.width() as f32;
    let height = image.height() as f32;
    let left = (roi.left.clamp(0.0, 1.0) * width).floor() as u32;
    let top = (roi.top.clamp(0.0, 1.0) * height).floor() as u32;
    let right = (roi.right.clamp(0.0, 1.0) * width)
        .ceil()
        .max((left + 1) as f32) as u32;
    let bottom = (roi.bottom.clamp(0.0, 1.0) * height)
        .ceil()
        .max((top + 1) as f32) as u32;
    let right = right.min(image.width());
    let bottom = bottom.min(image.height());
    let mut result = Vec::with_capacity(64);
    for row in 0..8 {
        for column in 0..8 {
            let x = (left + ((right.saturating_sub(left).max(1) - 1) * column / 7))
                .min(right.saturating_sub(1));
            let y = (top + ((bottom.saturating_sub(top).max(1) - 1) * row / 7))
                .min(bottom.saturating_sub(1));
            let pixel = image.get_pixel(x, y);
            result.push(
                (0.299 * pixel[0] as f32 + 0.587 * pixel[1] as f32 + 0.114 * pixel[2] as f32)
                    / 255.0,
            );
        }
    }
    // Remove a uniform luminance shift before comparing frames. A camera's
    // auto-exposure adjustment changes an entire zone at once, whereas net
    // movement changes the sampled spatial pattern within that zone.
    let mean = result.iter().sum::<f32>() / result.len().max(1) as f32;
    for value in &mut result {
        *value -= mean;
    }
    result
}

/// Predicts the landing point from the clear, above-rim descent segment.
/// Screen-space y is fit as a quadratic over time and x as a linear function
/// of time, matching the desktop prediction model. A weak fit never becomes
/// positive evidence for a candidate.
fn prediction_score(
    points: &[(i64, f32, f32, f32)],
    rim_y: f32,
    rim_center_x: f32,
    rim_half_width: f32,
) -> f32 {
    let above: Vec<_> = points
        .iter()
        .copied()
        .filter(|(_, _, y, _)| *y < rim_y - 0.01)
        .collect();
    if above.len() < 5 {
        return 0.0;
    }
    let apex = above
        .iter()
        .enumerate()
        .min_by(|(_, left), (_, right)| left.2.total_cmp(&right.2))
        .map(|(index, _)| index)
        .unwrap_or(0);
    let descent = &above[apex..];
    if descent.len() < 5 {
        return 0.0;
    }
    let descent = &descent[descent.len().saturating_sub(8)..];
    if descent
        .last()
        .is_none_or(|last| last.2 <= descent[0].2 + 0.004)
        || descent.last().unwrap().0 - descent[0].0 < 120
    {
        return 0.0;
    }

    let origin = descent.last().unwrap().0;
    let samples: Vec<_> = descent
        .iter()
        .enumerate()
        .map(|(index, point)| {
            let progress = index as f32 / (descent.len() - 1) as f32;
            (
                (point.0 - origin) as f32 / 1_000.0,
                point.1,
                point.2,
                (-0.7 + 0.7 * progress).exp(),
            )
        })
        .collect();
    let Some((a, b, c)) = fit_weighted_quadratic(&samples) else {
        return 0.0;
    };
    let Some((x_slope, x_intercept)) = fit_weighted_linear(&samples) else {
        return 0.0;
    };
    let mean_y = samples.iter().map(|(_, _, y, _)| *y).sum::<f32>() / samples.len() as f32;
    let residual = samples
        .iter()
        .map(|(time, _, y, _)| {
            let error = y - (a * time * time + b * time + c);
            error * error
        })
        .sum::<f32>();
    let total = samples
        .iter()
        .map(|(_, _, y, _)| {
            let delta = y - mean_y;
            delta * delta
        })
        .sum::<f32>();
    let r2 = if total <= 1e-9 {
        if residual <= 1e-9 {
            1.0
        } else {
            0.0
        }
    } else {
        (1.0 - residual / total).clamp(0.0, 1.0)
    };
    if r2 < 0.85 {
        return 0.0;
    }
    let roots = if a.abs() < 1e-8 {
        if b.abs() < 1e-8 {
            return 0.0;
        }
        vec![(rim_y - c) / b]
    } else {
        let discriminant = b * b - 4.0 * a * (c - rim_y);
        if discriminant < 0.0 {
            return 0.0;
        }
        let root = discriminant.sqrt();
        vec![(-b - root) / (2.0 * a), (-b + root) / (2.0 * a)]
    };
    let Some(time_to_rim) = roots
        .into_iter()
        .filter(|root| *root > 0.0)
        .min_by(|left, right| left.total_cmp(right))
    else {
        return 0.0;
    };
    let predicted_x = x_slope * time_to_rim + x_intercept;
    let distance = (predicted_x - rim_center_x).abs();
    let landing_center = (1.0 - distance / rim_half_width.max(0.01)).clamp(0.0, 1.0);
    (0.6 * r2 + 0.4 * landing_center).clamp(0.0, 1.0)
}

fn fit_weighted_linear(samples: &[(f32, f32, f32, f32)]) -> Option<(f32, f32)> {
    let (mut sw, mut st, mut stt, mut sx, mut stx) = (0.0, 0.0, 0.0, 0.0, 0.0);
    for (time, x, _, weight) in samples {
        sw += weight;
        st += weight * time;
        stt += weight * time * time;
        sx += weight * x;
        stx += weight * time * x;
    }
    let denominator = sw * stt - st * st;
    if denominator.abs() < 1e-9 {
        return None;
    }
    Some((
        (sw * stx - st * sx) / denominator,
        (sx * stt - st * stx) / denominator,
    ))
}

fn fit_weighted_quadratic(samples: &[(f32, f32, f32, f32)]) -> Option<(f32, f32, f32)> {
    let (mut s0, mut s1, mut s2, mut s3, mut s4, mut sy0, mut sy1, mut sy2) =
        (0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    for (time, _, y, weight) in samples {
        let t2 = time * time;
        s0 += weight;
        s1 += weight * time;
        s2 += weight * t2;
        s3 += weight * t2 * time;
        s4 += weight * t2 * t2;
        sy0 += weight * y;
        sy1 += weight * time * y;
        sy2 += weight * t2 * y;
    }
    solve_3x3([[s4, s3, s2], [s3, s2, s1], [s2, s1, s0]], [sy2, sy1, sy0])
}

fn solve_3x3(mut matrix: [[f32; 3]; 3], mut vector: [f32; 3]) -> Option<(f32, f32, f32)> {
    for pivot in 0..3 {
        let row = (pivot..3).max_by(|left, right| {
            matrix[*left][pivot]
                .abs()
                .total_cmp(&matrix[*right][pivot].abs())
        })?;
        if matrix[row][pivot].abs() < 1e-9 {
            return None;
        }
        matrix.swap(pivot, row);
        vector.swap(pivot, row);
        let divisor = matrix[pivot][pivot];
        let mut column = pivot;
        while column < 3 {
            matrix[pivot][column] /= divisor;
            column += 1;
        }
        vector[pivot] /= divisor;
        for other in 0..3 {
            if other == pivot {
                continue;
            }
            let factor = matrix[other][pivot];
            let mut column = pivot;
            while column < 3 {
                matrix[other][column] -= factor * matrix[pivot][column];
                column += 1;
            }
            vector[other] -= factor * vector[pivot];
        }
    }
    Some((vector[0], vector[1], vector[2]))
}

/// Composite multi-signal score combining all evidence into a single
/// confidence metric (mirrors desktop algorithm's scoring philosophy).
///
/// Weights:
/// - trajectory_score: 25% (how well the ball descended toward the rim)
/// - crossing_score:  20% (how centered the crossing was)
/// - net_motion_score: 30% (net activity = strongest independent evidence)
/// - prediction_score: 15% (pre-crossing trajectory quality)
/// - rebound penalty: -20% if detected
fn composite_score(
    trajectory: f32,
    crossing: f32,
    net_motion: f32,
    prediction: f32,
    rebound: bool,
) -> f32 {
    let mut score = 0.25 * trajectory + 0.20 * crossing + 0.30 * net_motion + 0.15 * prediction;
    if rebound {
        score -= 0.20;
    }
    score.clamp(0.0, 1.0)
}

fn trajectory_score(points: &[(i64, f32, f32, f32)]) -> f32 {
    let Some(last_pair) = points.windows(2).last() else {
        return 0.0;
    };
    let vertical = (last_pair[1].2 - last_pair[0].2).clamp(0.0, 1.0);
    let confidence = points
        .iter()
        .rev()
        .take(5)
        .map(|point| point.3)
        .sum::<f32>()
        / points.len().clamp(1, 5) as f32;
    (0.55 * (vertical * 4.0).clamp(0.0, 1.0) + 0.45 * confidence).clamp(0.0, 1.0)
}

fn iou(a: &Detection, b: &Detection) -> f32 {
    let left = a.x1.max(b.x1);
    let top = a.y1.max(b.y1);
    let right = a.x2.min(b.x2);
    let bottom = a.y2.min(b.y2);
    let intersection = (right - left).max(0.0) * (bottom - top).max(0.0);
    let area_a = (a.x2 - a.x1).max(0.0) * (a.y2 - a.y1).max(0.0);
    let area_b = (b.x2 - b.x1).max(0.0) * (b.y2 - b.y1).max(0.0);
    intersection / (area_a + area_b - intersection).max(1e-6)
}

#[allow(clippy::too_many_arguments)]
fn decode_output(
    values: &[f32],
    width: u32,
    height: u32,
    scale: f32,
    offset_x: f32,
    offset_y: f32,
    threshold: f32,
    model_size: u32,
) -> Vec<Detection> {
    // YOLO's P3/P4/P5 heads use strides 8, 16 and 32. A 640 model has
    // 80² + 40² + 20² = 8400 anchors; a 1280 model has 33600.
    let grid = [8_u32, 16, 32]
        .into_iter()
        .map(|stride| {
            let side = model_size / stride;
            (side * side) as usize
        })
        .sum::<usize>();
    if values.len() < 6 * grid {
        return Vec::new();
    }
    let mut candidates = Vec::new();
    for index in 0..grid {
        let score_ball = values[4 * grid + index];
        let score_hoop = values[5 * grid + index];
        let (class_id, confidence) = if score_ball >= score_hoop {
            (0, score_ball)
        } else {
            (1, score_hoop)
        };
        if confidence < threshold {
            continue;
        }
        let cx = values[index];
        let cy = values[grid + index];
        let w = values[2 * grid + index];
        let h = values[3 * grid + index];
        let x1 = ((cx - w / 2.0) - offset_x) / scale;
        let y1 = ((cy - h / 2.0) - offset_y) / scale;
        let x2 = ((cx + w / 2.0) - offset_x) / scale;
        let y2 = ((cy + h / 2.0) - offset_y) / scale;
        candidates.push(Detection {
            class_id,
            confidence,
            x1: x1.clamp(0.0, width as f32),
            y1: y1.clamp(0.0, height as f32),
            x2: x2.clamp(0.0, width as f32),
            y2: y2.clamp(0.0, height as f32),
        });
    }
    candidates.sort_by(|a, b| b.confidence.total_cmp(&a.confidence));
    let mut kept = Vec::new();
    for candidate in candidates {
        if kept.iter().all(|other: &Detection| {
            other.class_id != candidate.class_id || iou(other, &candidate) < 0.45
        }) {
            kept.push(candidate);
        }
    }
    kept
}

fn detect_image(
    session: &mut Session,
    image: &RgbImage,
    threshold: f32,
    model_size: u32,
) -> Result<Vec<Detection>, RuntimeError> {
    let (input, scale, offset_x, offset_y) = preprocess(image, model_size)?;
    let tensor = Tensor::from_array(input)?;
    let outputs = session.run(ort::inputs![tensor])?;
    let (_, values) = outputs[0].try_extract_tensor::<f32>()?;
    Ok(decode_output(
        values,
        image.width(),
        image.height(),
        scale,
        offset_x,
        offset_y,
        threshold,
        model_size,
    ))
}

fn center(detection: &Detection) -> (f32, f32) {
    (
        (detection.x1 + detection.x2) / 2.0,
        (detection.y1 + detection.y2) / 2.0,
    )
}

pub fn analyze(request: AnalysisRequest) -> Result<AnalysisResponse, RuntimeError> {
    if request.frames.is_empty() {
        return Ok(AnalysisResponse {
            candidates: Vec::new(),
            processed_frames: 0,
            total_frames: 0,
        });
    }
    let config = RuntimeConfig {
        model_path: request.model_path,
        hoop_roi: request.hoop_roi,
        net_roi: request.net_roi,
        duration_ms: request.duration_ms,
        confidence_threshold: request.confidence_threshold,
        clip_before_ms: request.clip_before_ms,
        clip_after_ms: request.clip_after_ms,
        model_size: MODEL_SIZE_DEFAULT,
    };
    let mut session = RuntimeSession::new(config)?;
    for frame in &request.frames {
        session.push_frame(frame.clone())?;
    }
    Ok(AnalysisResponse {
        candidates: session.candidates,
        processed_frames: request.frames.len(),
        total_frames: request.frames.len(),
    })
}

#[cfg(test)]
#[allow(clippy::items_after_test_module)]
mod tests {
    use super::*;

    fn roi() -> Roi {
        Roi {
            left: 0.4,
            top: 0.4,
            right: 0.6,
            bottom: 0.7,
        }
    }

    #[test]
    fn association_prefers_nearest_prediction_over_detection_order() {
        let mut tracks = vec![BallTrack {
            id: 1,
            points: vec![(0, 0.45, 0.45, 0.8), (100, 0.50, 0.50, 0.8)],
        }];
        let mut next_track_id = 2;

        let updated = associate_ball_tracks(
            &mut tracks,
            &mut next_track_id,
            200,
            vec![(0.58, 0.58, 0.99), (0.55, 0.55, 0.4)],
            0.20,
        );

        assert!(updated.contains(&1));
        assert_eq!(tracks[0].points.last().unwrap().1, 0.55);
        assert_eq!(tracks[0].points.last().unwrap().2, 0.55);
        assert_eq!(tracks.len(), 2);
        assert_eq!(next_track_id, 3);
    }

    #[test]
    fn association_recovers_short_gaps_but_starts_a_new_track_after_expiry() {
        let mut tracks = vec![BallTrack {
            id: 7,
            points: vec![(0, 0.50, 0.50, 0.8)],
        }];
        let mut next_track_id = 8;

        let recovered = associate_ball_tracks(
            &mut tracks,
            &mut next_track_id,
            300,
            vec![(0.54, 0.54, 0.8)],
            0.20,
        );
        assert_eq!(recovered, vec![7]);
        assert_eq!(tracks[0].points.len(), 2);

        let restarted = associate_ball_tracks(
            &mut tracks,
            &mut next_track_id,
            700,
            vec![(0.58, 0.58, 0.8)],
            0.20,
        );
        assert_eq!(restarted, vec![8]);
        assert_eq!(tracks.len(), 2);
    }

    #[test]
    fn recovery_stitches_a_rim_occlusion_between_two_tracks() {
        let tracks = vec![
            BallTrack {
                id: 1,
                points: vec![(0, 0.50, 0.25, 0.8), (100, 0.50, 0.34, 0.8)],
            },
            BallTrack {
                id: 2,
                points: vec![(300, 0.50, 0.82, 0.7), (400, 0.50, 0.88, 0.7)],
            },
        ];

        let recoveries = recover_track_points(&tracks, &roi());

        assert_eq!(recoveries.len(), 1);
        assert_eq!(recoveries[0].0, 1);
        assert_eq!(recoveries[0].1.first().unwrap().0, 0);
        assert_eq!(recoveries[0].1.last().unwrap().0, 400);
        assert!(complete_rim_crossing(&recoveries[0].1, 100, 300, &roi()));
    }

    fn roi_json() -> serde_json::Value {
        serde_json::json!({"left": 0.4, "top": 0.4, "right": 0.6, "bottom": 0.7})
    }

    #[test]
    fn empty_request_has_zero_frame_counts() {
        let result = analyze(AnalysisRequest {
            model_path: "missing.onnx".into(),
            frames: Vec::new(),
            hoop_roi: roi(),
            net_roi: roi(),
            duration_ms: None,
            confidence_threshold: 0.1,
            clip_before_ms: 6_000,
            clip_after_ms: 3_000,
        })
        .expect("empty input should not load the model");
        assert_eq!(result.processed_frames, 0);
        assert_eq!(result.total_frames, 0);
        assert!(result.candidates.is_empty());
    }

    #[test]
    fn invalid_hoop_roi_is_rejected() {
        let result = analyze(AnalysisRequest {
            model_path: "missing.onnx".into(),
            frames: vec![FrameInput {
                time_ms: 0,
                width: 10,
                height: 10,
                rgb_base64: None,
                image_base64: None,
            }],
            hoop_roi: Roi {
                left: 0.7,
                top: 0.4,
                right: 0.6,
                bottom: 0.7,
            },
            net_roi: roi(),
            duration_ms: None,
            confidence_threshold: 0.1,
            clip_before_ms: 6_000,
            clip_after_ms: 3_000,
        });
        assert!(
            matches!(result, Err(RuntimeError::InvalidRequest(message)) if message == "hoop ROI is invalid")
        );
    }

    #[test]
    fn invalid_net_roi_is_rejected_before_model_loading() {
        let result = create_session_json(
            &serde_json::json!({
                "model_path": "missing.onnx",
                "hoop_roi": roi_json(),
                "net_roi": {"left": -0.1, "top": 0.2, "right": 0.4, "bottom": 0.7}
            })
            .to_string(),
        );
        assert!(
            matches!(result, Err(RuntimeError::InvalidRequest(message)) if message == "net ROI is invalid")
        );
    }

    #[test]
    fn invalid_analysis_parameters_are_rejected_before_model_loading() {
        let result = create_session_json(
            &serde_json::json!({
                "model_path": "missing.onnx",
                "hoop_roi": roi_json(),
                "net_roi": roi_json(),
                "confidence_threshold": 1.1,
                "clip_before_ms": -1
            })
            .to_string(),
        );
        assert!(
            matches!(result, Err(RuntimeError::InvalidRequest(message)) if message == "confidence threshold is invalid")
        );
    }

    #[test]
    fn crossing_uses_interpolated_x_not_the_below_detection() {
        let result = crossing_at_rim((0, 0.2, 0.3, 0.9), (100, 0.8, 0.7, 0.9), 0.5)
            .expect("descending points should cross the rim");
        assert!((result.0 - 0.5).abs() < 1e-6);
        assert!((result.1 - 0.5).abs() < 1e-6);
    }

    #[test]
    fn lateral_pass_is_not_a_rim_crossing() {
        assert!(crossing_at_rim((0, 0.2, 0.5, 0.9), (100, 0.8, 0.5, 0.9), 0.5).is_none());
    }

    #[test]
    fn complete_crossing_requires_a_stable_vertical_path_through_the_rim() {
        let points = [
            (0, 0.48, 0.30, 0.9),
            (300, 0.49, 0.42, 0.9),
            (600, 0.50, 0.54, 0.9),
        ];
        assert!(complete_crossing(&points, 0.48, 0.42, 0.58));
    }

    #[test]
    fn complete_crossing_rejects_a_side_pass_that_only_interpolates_inside() {
        let points = [
            (0, 0.05, 0.30, 0.9),
            (300, 0.18, 0.42, 0.9),
            (600, 0.50, 0.54, 0.9),
        ];
        assert!(!complete_crossing(&points, 0.48, 0.42, 0.58));
    }

    #[test]
    fn complete_rim_crossing_requires_post_rim_persistence() {
        let points = [
            (0, 0.50, 0.34, 0.9),
            (200, 0.50, 0.84, 0.9),
            (400, 0.51, 0.90, 0.9),
        ];
        assert!(complete_rim_crossing(&points, 0, 200, &roi()));
        assert!(!complete_rim_crossing(&points[..2], 0, 200, &roi()));
    }

    #[test]
    fn post_crossing_evidence_marks_lateral_exit_as_negative_evidence() {
        let points = [
            (0, 0.50, 0.34, 0.9),
            (200, 0.50, 0.84, 0.9),
            (400, 0.10, 0.90, 0.9),
        ];
        let evidence = post_crossing_evidence(&points, 200, &roi());
        assert!(evidence.lateral_exit);
        assert!(!evidence.lateral_recovery);
    }

    #[test]
    fn net_motion_score_is_normalized_and_handles_shape_mismatch() {
        assert_eq!(net_motion_score(&[0.2, 0.2], &[0.2]), 0.0);
        assert_eq!(net_motion_score(&[0.2, 0.2], &[0.2, 0.2]), 0.0);
        assert!(net_motion_score(&[0.8, 0.8], &[0.0, 0.0]) > 0.9);
    }

    #[test]
    fn net_motion_ignores_uniform_exposure_and_detects_local_pattern_change() {
        let roi = Roi {
            left: 0.0,
            top: 0.0,
            right: 1.0,
            bottom: 1.0,
        };
        let dark = RgbImage::from_pixel(24, 24, image::Rgb([20, 20, 20]));
        let bright = RgbImage::from_pixel(24, 24, image::Rgb([220, 220, 220]));
        let dark_signature = net_zone_signatures(&dark, &roi);
        let bright_signature = net_zone_signatures(&bright, &roi);
        assert!(net_motion_score(&dark_signature[1], &bright_signature[1]) < 0.0001);

        let mut changed = dark.clone();
        for y in 8..16 {
            for x in 0..12 {
                changed.put_pixel(x, y, image::Rgb([240, 240, 240]));
            }
        }
        let changed_signature = net_zone_signatures(&changed, &roi);
        assert!(net_motion_score(&dark_signature[1], &changed_signature[1]) > 0.9);
    }

    #[test]
    fn net_sequence_contributes_only_after_lower_zone_activation() {
        let history = [
            (-800, 0.0, 0.0, 0.0),
            (-400, 0.0, 0.0, 0.0),
            (0, 0.0, 0.10, 0.0),
            (200, 0.0, 0.12, 0.10),
        ];
        let (inside, sequence) = net_zone_scores(&history, 0);
        assert!(inside > 0.9);
        assert_eq!(sequence, 1.0);
    }

    #[test]
    fn net_evidence_keeps_missing_measurement_distinct_from_no_motion() {
        assert!(!net_zone_evidence(&[(0, 0.0, 0.0, 0.0)], 0).signal_available);

        let history = [
            (-800, 0.0, 0.0, 0.0),
            (-400, 0.0, 0.0, 0.0),
            (0, 0.0, 0.0, 0.0),
            (100, 0.0, 0.0, 0.0),
        ];
        let no_motion = net_zone_evidence(&history, 0);
        assert!(no_motion.signal_available);
        assert!(no_motion.no_motion);

        let supported = [
            (-800, 0.0, 0.0, 0.0),
            (-400, 0.0, 0.0, 0.0),
            (0, 0.0, 0.50, 0.0),
            (100, 0.0, 0.60, 0.50),
        ];
        assert!(net_zone_evidence(&supported, 0).support);
    }

    #[test]
    fn decision_replay_matches_the_contract_verdict_fields() {
        let result = evaluate_decision_replay(DecisionReplayRequest {
            hoop_roi: roi(),
            above: EvidencePoint {
                time_ms: 0,
                x: 0.50,
                y: 0.34,
                confidence: 0.9,
            },
            below: EvidencePoint {
                time_ms: 200,
                x: 0.50,
                y: 0.84,
                confidence: 0.9,
            },
            trajectory: vec![
                EvidencePoint {
                    time_ms: 400,
                    x: 0.51,
                    y: 0.90,
                    confidence: 0.9,
                },
                EvidencePoint {
                    time_ms: 600,
                    x: 0.51,
                    y: 0.95,
                    confidence: 0.9,
                },
            ],
            net_history: vec![
                NetReplayPoint {
                    time_ms: -800,
                    upper: 0.0,
                    lower: 0.0,
                    below: 0.0,
                },
                NetReplayPoint {
                    time_ms: -400,
                    upper: 0.0,
                    lower: 0.0,
                    below: 0.0,
                },
                NetReplayPoint {
                    time_ms: 0,
                    upper: 0.0,
                    lower: 0.50,
                    below: 0.0,
                },
                NetReplayPoint {
                    time_ms: 100,
                    upper: 0.0,
                    lower: 0.60,
                    below: 0.50,
                },
            ],
        });
        assert_eq!(result.algorithm_version, "analysis-contract-v1");
        assert!(result.complete_crossing);
        assert!(result.net_signal_available);
        assert!(result.net_support);
        assert_eq!(result.verdict, "made");
    }

    #[test]
    fn calibrated_gates_keep_a_safe_low_speed_crossing_exportable() {
        let points = [
            (0, 0.50, 0.45, 0.9),
            (600, 0.50, 0.85, 0.9),
            (700, 0.51, 0.90, 0.9),
        ];
        let gates = calibrated_gates(&points, 0, 600, &roi(), &NetEvidence::default(), true);
        assert!(gates.automatic_goal);
    }

    #[test]
    fn synchronized_net_motion_is_suppressed_as_camera_shake() {
        assert_eq!(
            suppress_synchronized_net_motion(0.50, 0.47, 0.52),
            (0.0, 0.0, 0.0),
        );
        assert_eq!(
            suppress_synchronized_net_motion(0.04, 0.50, 0.08),
            (0.04, 0.50, 0.08),
        );
    }

    #[test]
    fn prediction_accepts_clean_above_rim_descent() {
        let points = [
            (0, 0.50, 0.292, 0.9),
            (100, 0.50, 0.338, 0.9),
            (200, 0.50, 0.388, 0.9),
            (300, 0.50, 0.442, 0.9),
            (400, 0.50, 0.500, 0.9),
        ];
        assert!(prediction_score(&points, 0.60, 0.50, 0.10) > 0.9);
    }

    #[test]
    fn prediction_rejects_non_descending_or_sparse_tracks() {
        let flat = [
            (0, 0.50, 0.30, 0.9),
            (100, 0.50, 0.30, 0.9),
            (200, 0.50, 0.30, 0.9),
            (300, 0.50, 0.30, 0.9),
            (400, 0.50, 0.30, 0.9),
        ];
        assert_eq!(prediction_score(&flat, 0.60, 0.50, 0.10), 0.0);
        assert_eq!(prediction_score(&flat[..4], 0.60, 0.50, 0.10), 0.0);
    }

    #[test]
    fn crossing_context_stays_at_the_crossing_pair_not_the_track_tail() {
        let points = [
            (0, 0.50, 0.30, 0.9),
            (100, 0.50, 0.44, 0.9),
            (200, 0.50, 0.56, 0.9),
            (300, 0.70, 0.74, 0.9),
        ];
        assert!(complete_crossing(&points[..3], 0.50, 0.42, 0.58));
        assert!(!complete_crossing(&points, 0.50, 0.42, 0.58));
    }

    #[test]
    fn model_size_is_validated_before_model_loading() {
        let result = create_session_json(
            &serde_json::json!({
                "model_path": "missing.onnx",
                "hoop_roi": roi_json(),
                "net_roi": roi_json(),
                "model_size": 319,
            })
            .to_string(),
        );
        assert!(
            matches!(result, Err(RuntimeError::InvalidRequest(message)) if message == "model size must be a multiple of 32 and at least 320")
        );
    }

    #[test]
    fn decode_output_uses_the_correct_1280_grid_size() {
        const GRID: usize = 33_600;
        let mut output = vec![0.0; 6 * GRID];
        output[4 * GRID] = 0.9;
        output[0] = 640.0;
        output[GRID] = 640.0;
        output[2 * GRID] = 100.0;
        output[3 * GRID] = 100.0;
        let detections = decode_output(&output, 1280, 1280, 1.0, 0.0, 0.0, 0.5, 1280);
        assert_eq!(detections.len(), 1);
        assert_eq!(detections[0].class_id, 0);
    }

    #[test]
    fn clip_end_is_bounded_by_video_duration() {
        assert_eq!(clip_end_ms(9_500, 3_000, Some(10_000)), 10_000);
        assert_eq!(clip_end_ms(9_500, 3_000, None), 12_500);
    }
}

pub fn analyze_json(input: &str) -> Result<String, RuntimeError> {
    let request: AnalysisRequest = serde_json::from_str(input)?;
    Ok(serde_json::to_string(&analyze(request)?)?)
}

pub fn evaluate_decision_replay_json(input: &str) -> Result<String, RuntimeError> {
    let request: DecisionReplayRequest = serde_json::from_str(input)?;
    Ok(serde_json::to_string(&evaluate_decision_replay(request))?)
}

pub fn create_session_json(input: &str) -> Result<RuntimeSession, RuntimeError> {
    RuntimeSession::new(serde_json::from_str(input)?)
}

/// Initializes ONNX Runtime from an explicit dynamic library path.
///
/// # Safety
/// `library_path` must be a non-null pointer to a valid NUL-terminated UTF-8
/// path and remains valid for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn bhe_runtime_initialize_onnx(library_path: *const c_char) -> bool {
    #[cfg(not(feature = "dynamic-onnx"))]
    {
        let _ = library_path;
        return false;
    }

    #[cfg(feature = "dynamic-onnx")]
    {
        if library_path.is_null() {
            return init_onnx_from_path(None).is_ok();
        }
        let path = CStr::from_ptr(library_path);
        let Ok(path) = path.to_str() else {
            return false;
        };
        init_onnx_from_path(Some(Path::new(path))).is_ok()
    }
}

/// Creates a native analysis session from a JSON runtime configuration.
///
/// # Safety
/// `config` must be a non-null pointer to a valid NUL-terminated UTF-8 string
/// and remains valid for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn bhe_runtime_create_session(config: *const c_char) -> *mut RuntimeSession {
    if config.is_null() {
        return std::ptr::null_mut();
    }
    let input = CStr::from_ptr(config).to_string_lossy();
    match create_session_json(&input) {
        Ok(session) => Box::into_raw(Box::new(session)),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Processes one JSON-encoded video frame in a native analysis session.
///
/// # Safety
/// `session` must be a valid pointer returned by
/// `bhe_runtime_create_session`, and `frame` must be a non-null pointer to a
/// valid NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn bhe_runtime_push_frame(
    session: *mut RuntimeSession,
    frame: *const c_char,
) -> *mut c_char {
    if session.is_null() || frame.is_null() {
        return std::ptr::null_mut();
    }
    let frame = CStr::from_ptr(frame).to_string_lossy();
    let output = match serde_json::from_str::<FrameInput>(&frame)
        .map_err(RuntimeError::from)
        .and_then(|input| (*session).push_frame(input))
        .and_then(|response| serde_json::to_string(&response).map_err(RuntimeError::from))
    {
        Ok(output) => output,
        Err(error) => serde_json::json!({"error": error.to_string()}).to_string(),
    };
    CString::new(output).unwrap().into_raw()
}

/// Processes one raw RGBA video frame in a native analysis session.
///
/// This is the fast path: no JPEG compression, no base64 encoding, no JSON
/// serialization. Android sends Bitmap pixels directly as a byte array.
/// Expected per-frame speedup: 3-5x compared to the JSON path.
///
/// # Safety
/// `session` must be a valid pointer returned by `bhe_runtime_create_session`.
/// `rgba_data` must be non-null and contain `width * height * 4` bytes in
/// RGBA row-major order, valid for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn bhe_runtime_push_frame_raw(
    session: *mut RuntimeSession,
    time_ms: i64,
    width: u32,
    height: u32,
    rgba_data: *const u8,
    rgba_len: i64,
) -> *mut c_char {
    if session.is_null() || rgba_data.is_null() || rgba_len < 0 {
        return std::ptr::null_mut();
    }
    let rgba = std::slice::from_raw_parts(rgba_data, rgba_len as usize);
    let output = match (*session)
        .push_frame_raw(time_ms, width, height, rgba)
        .and_then(|response| serde_json::to_string(&response).map_err(RuntimeError::from))
    {
        Ok(output) => output,
        Err(error) => serde_json::json!({"error": error.to_string()}).to_string(),
    };
    CString::new(output).unwrap().into_raw()
}

/// Releases a native analysis session.
///
/// # Safety
/// `session` must be null or a pointer returned by
/// `bhe_runtime_create_session` that has not already been released.
#[no_mangle]
pub unsafe extern "C" fn bhe_runtime_free_session(session: *mut RuntimeSession) {
    if !session.is_null() {
        drop(Box::from_raw(session));
    }
}

#[no_mangle]
pub extern "C" fn bhe_runtime_version() -> *mut c_char {
    CString::new("bhe_runtime/0.1.0").unwrap().into_raw()
}

/// Analyzes a complete JSON request through the native runtime.
///
/// # Safety
/// `input` must be a non-null pointer to a valid NUL-terminated UTF-8 string
/// and remains valid for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn bhe_runtime_analyze_json(input: *const c_char) -> *mut c_char {
    if input.is_null() {
        return std::ptr::null_mut();
    }
    let result = CStr::from_ptr(input).to_string_lossy().into_owned();
    let output = match analyze_json(&result) {
        Ok(value) => value,
        Err(error) => serde_json::json!({"error": error.to_string()}).to_string(),
    };
    CString::new(output).unwrap().into_raw()
}

/// Releases a string returned by this library.
///
/// # Safety
/// `value` must be null or a pointer previously returned by this library that
/// has not already been released.
#[no_mangle]
pub unsafe extern "C" fn bhe_runtime_free_string(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}
