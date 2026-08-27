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

#[derive(Clone, Debug, Serialize)]
pub struct EvidencePoint {
    pub time_ms: i64,
    pub x: f32,
    pub y: f32,
    pub confidence: f32,
}

#[derive(Clone, Debug, Serialize)]
pub struct Candidate {
    pub id: String,
    pub start_ms: i64,
    pub end_ms: i64,
    pub event_ms: i64,
    pub confidence: f32,
    pub trajectory_score: f32,
    pub crossing_score: f32,
    pub net_motion_score: f32,
    pub trajectory: Vec<EvidencePoint>,
    pub crossing: EvidencePoint,
    pub reason: String,
    pub verdict: String,
    pub complete_crossing: bool,
    pub rebound: bool,
    pub evidence_source: String,
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
    pub processed_frames: usize,
}

pub struct RuntimeSession {
    session: Session,
    config: RuntimeConfig,
    model_size: u32,
    ball_points: Vec<(i64, f32, f32, f32)>,
    candidates: Vec<Candidate>,
    processed_frames: u64,
    previous_net_signature: Option<(i64, Vec<f32>)>,
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
            ball_points: Vec::new(),
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
                rgba.len(), expected, width, height
            )));
        }
        let mut buffer = Vec::with_capacity(expected / 4 * 3);
        for chunk in rgba.chunks_exact(4) {
            buffer.push(chunk[0]); // R
            buffer.push(chunk[1]); // G
            buffer.push(chunk[2]); // B
        }
        let image = RgbImage::from_raw(width, height, buffer)
            .ok_or_else(|| RuntimeError::InvalidRequest("raw frame dimensions are invalid".into()))?;
        self.push_image(time_ms, image)
    }

    fn push_image(&mut self, time_ms: i64, image: RgbImage) -> Result<FrameResponse, RuntimeError> {
        let detections = detect_image(&mut self.session, &image, self.config.confidence_threshold, self.model_size)?;
        self.processed_frames += 1;
        self.update_net_motion(time_ms, &image);
        if let Some(ball) = detections
            .iter()
            .filter(|detection| detection.class_id == 0)
            .max_by(|a, b| a.confidence.total_cmp(&b.confidence))
        {
            let (x, y) = center(ball);
            self.push_ball_point(
                time_ms,
                x / image.width() as f32,
                y / image.height() as f32,
                ball.confidence,
            );
            self.detect_crossing();
        }
        self.detect_rebound();
        self.resolve_verdict();
        Ok(FrameResponse {
            detections,
            candidates: self.candidates.clone(),
            processed_frames: self.processed_frames,
        })
    }

    fn push_ball_point(&mut self, time_ms: i64, x: f32, y: f32, confidence: f32) {
        // Speed-gated chain (mirrors desktop algorithm): accept the point
        // only if it's within a plausible distance from the previous point.
        // A jump beyond the gate means the detector switched to a different
        // object (another ball, a player's jersey) — drop the point rather
        // than corrupting the trajectory. Unlike the old logic which cleared
        // ALL points on any gap, this preserves the valid chain.
        if let Some(previous) = self.ball_points.last() {
            let dt = time_ms - previous.0;
            if dt <= 0 {
                return;
            }
            let dx = x - previous.1;
            let dy = y - previous.2;
            let distance = (dx * dx + dy * dy).sqrt();
            // Gate: ~0.25 normalized units/sec + slack. A basketball moving
            // at 10 m/s in a 960px frame covers ~0.1 norm units in 100ms.
            // 0.30 for 300ms gap, 0.55 for 500ms gap, etc.
            let gate = 0.12 + 0.55 * (dt as f32 / 1000.0);
            if distance > gate {
                // Too far — this is a different object. Start a new chain
                // only if the current chain has no recent crossing potential.
                let has_recent_activity = self.ball_points.iter().any(|p| time_ms - p.0 < 2000);
                if has_recent_activity {
                    // Keep the old chain's last point as a bridge, replace rest
                    let last = self.ball_points.last().copied();
                    self.ball_points.clear();
                    if let Some(l) = last {
                        self.ball_points.push(l);
                    }
                }
                self.ball_points.push((time_ms, x, y, confidence));
                return;
            }
        }
        self.ball_points.push((time_ms, x, y, confidence));
        if self.ball_points.len() > 32 {
            self.ball_points.remove(0);
        }
    }

    /// Three-zone net motion analysis (mirrors desktop algorithm).
    ///
    /// A made basket should produce activity in the net's lower zone
    /// followed by activity in the zone below it (ball enters net top,
    /// pushes through, drops below). Simultaneous activation suggests
    /// camera shake; reversed order (below before lower) is suspicious.
    fn update_net_motion(&mut self, time_ms: i64, image: &RgbImage) {
        let roi = &self.config.net_roi;
        let (upper, lower, below) = net_zone_motion(image, roi);
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

        // Compute per-candidate net motion score from zone history.
        let history = &self.net_zone_history;
        for candidate in &mut self.candidates {
            if time_ms < candidate.event_ms || time_ms > candidate.event_ms + 1_500 {
                continue;
            }
            let (inside_score, sequence_score) = net_zone_scores(history, candidate.event_ms);
            candidate.net_motion_score = candidate.net_motion_score.max(inside_score);
            // Store sequence score in crossing_score if it's better evidence.
            if sequence_score > 0.5 && candidate.crossing_score < 0.5 {
                candidate.reason = format!("net_sequence:{sequence_score:.2}");
            }
        }

        // Legacy whole-ROI signature for backward compat.
        let signature = net_signature(image, roi);
        self.previous_net_signature = Some((time_ms, signature));
    }

    /// Detect rebound after a crossing: ball rises from deep below the rim
    /// back up. Depth-bounded (mirrors desktop): only counts as rebound if
    /// the ball hasn't descended past 2.5x rim height below the rim plane.
    fn detect_rebound(&mut self) {
        let rim_y = (self.config.hoop_roi.top + self.config.hoop_roi.bottom) / 2.0;
        let rim_height = self.config.hoop_roi.bottom - self.config.hoop_roi.top;
        let rebound_depth = rim_y + rim_height * 2.5;

        for candidate in &mut self.candidates {
            if candidate.rebound {
                continue;
            }
            // Find post-crossing ball points that descend then rise.
            let post_points: Vec<_> = self
                .ball_points
                .iter()
                .filter(|(t, _, _, _)| *t > candidate.event_ms)
                .collect();
            if post_points.len() < 3 {
                continue;
            }
            let mut max_y = 0.0f32;
            let mut rebounded = false;
            for (_, _, y, _) in &post_points {
                if *y > max_y {
                    max_y = *y;
                } else if max_y > rebound_depth && *y < max_y - 0.04 {
                    // Ball descended past the depth boundary then rose = landing bounce.
                    rebounded = false; // Landing bounce, not rim rebound.
                    break;
                } else if max_y <= rebound_depth && *y < max_y - 0.03 {
                    // Ball rose while still near the rim = rim rebound.
                    rebounded = true;
                    break;
                }
            }
            if rebounded {
                candidate.rebound = true;
            }
        }
    }

    /// Resolve verdict from accumulated evidence (mirrors desktop).
    fn resolve_verdict(&mut self) {
        let current_time = self
            .ball_points
            .last()
            .map(|(t, _, _, _)| *t)
            .unwrap_or(0);

        for candidate in &mut self.candidates {
            if candidate.verdict != "ambiguous" {
                continue; // Already resolved.
            }
            // Only resolve after 800ms of post-crossing observation.
            if current_time < candidate.event_ms + 800 {
                continue;
            }

            let strong_positive = candidate.complete_crossing
                && candidate.net_motion_score >= 0.35
                && candidate.trajectory_score >= 0.45;

            let strong_negative = candidate.rebound
                || candidate.crossing_score < 0.15;

            if strong_negative {
                candidate.verdict = "missed".into();
                candidate.reason = if candidate.rebound {
                    "rim_rebound".into()
                } else {
                    "crossing_outside_rim".into()
                };
            } else if strong_positive {
                candidate.verdict = "made".into();
                candidate.reason = format!(
                    "complete_crossing+net_motion:{:.2}",
                    candidate.net_motion_score
                );
            }
            // else stays "ambiguous" for human review.
        }
    }

    fn detect_crossing(&mut self) {
        let rim_y = (self.config.hoop_roi.top + self.config.hoop_roi.bottom) / 2.0;
        let rim_left = self.config.hoop_roi.left;
        let rim_right = self.config.hoop_roi.right;

        // Scan ALL adjacent pairs for a valid crossing, not just the last one.
        // Fast-falling balls may have 2+ frames between the above and below
        // points; checking only the last pair misses crossings when tracking
        // continues past the rim.
        for window in self.ball_points.windows(2) {
            let above = window[0];
            let below = window[1];
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
                .any(|candidate| (candidate.event_ms - event_ms).abs() <= 1_500)
            {
                continue;
            }

            // Use a wider context for complete_crossing (up to 12 recent points).
            let recent_start = self.ball_points.len().saturating_sub(12);
            let recent = &self.ball_points[recent_start..];
            if !complete_crossing(recent, rim_y, rim_left, rim_right) {
                continue;
            }

            let trajectory_score = trajectory_score(recent);
            let crossing_score = (1.0
                - ((crossing_x - (rim_left + rim_right) / 2.0).abs()
                    / ((rim_right - rim_left) / 2.0).max(1e-6)))
            .clamp(0.0, 1.0);
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
                start_ms: (event_ms - self.config.clip_before_ms).max(0),
                end_ms: clip_end_ms(event_ms, self.config.clip_after_ms, self.config.duration_ms),
                event_ms,
                confidence: (0.5 * above.3 + 0.5 * below.3).clamp(0.0, 1.0),
                trajectory_score,
                crossing_score,
                net_motion_score: 0.0,
                trajectory,
                crossing: EvidencePoint {
                    time_ms: event_ms,
                    x: crossing_x,
                    y: rim_y,
                    confidence: (above.3 + below.3) / 2.0,
                },
                reason: "uncertain".into(),
                verdict: "ambiguous".into(),
                complete_crossing: true,
                rebound: false,
                evidence_source: "rust_onnx".into(),
            });
            // Don't clear all ball points — the ball continues to be tracked
            // after a made shot. Only trim to prevent re-detecting the same
            // crossing (the duplicate check above handles this).
            break;
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
    Ok(())
}

fn clip_end_ms(event_ms: i64, after_ms: i64, duration_ms: Option<i64>) -> i64 {
    duration_ms
        .map(|duration| (event_ms + after_ms).min(duration))
        .unwrap_or(event_ms + after_ms)
}

/// Computes motion in the net's three zones (upper, lower, below).
///
/// The net ROI is divided vertically: top 1/3 = upper (rim area),
/// middle 1/3 = lower (net body), bottom 1/3 = below (under the net).
/// Returns motion deltas vs the previous frame for each zone.
fn net_zone_motion(image: &RgbImage, roi: &Roi) -> (f32, f32, f32) {
    let width = image.width() as f32;
    let height = image.height() as f32;
    let left = (roi.left.clamp(0.0, 1.0) * width).floor() as u32;
    let top = (roi.top.clamp(0.0, 1.0) * height).floor() as u32;
    let right = (roi.right.clamp(0.0, 1.0) * width).ceil().max(left + 1) as u32;
    let bottom = (roi.bottom.clamp(0.0, 1.0) * height).ceil().max(top + 1) as u32;
    let zone_height = (bottom.saturating_sub(top) / 3).max(1);

    let zone_motion = |zone_top: u32, zone_bottom: u32| -> f32 {
        let mut sum = 0.0f32;
        let mut count = 0u32;
        let step_x = (right.saturating_sub(left) / 4).max(1);
        let step_y = (zone_bottom.saturating_sub(zone_top) / 3).max(1);
        let mut y = zone_top;
        while y < zone_bottom.min(image.height()) {
            let mut x = left;
            while x < right.min(image.width()) {
                let pixel = image.get_pixel(x.min(image.width() - 1), y.min(image.height() - 1));
                let luminance = (0.299 * pixel[0] as f32 + 0.587 * pixel[1] as f32 + 0.114 * pixel[2] as f32) / 255.0;
                sum += luminance;
                count += 1;
                x += step_x;
            }
            y += step_y;
        }
        if count == 0 { 0.0 } else { sum / count as f32 }
    };

    let upper = zone_motion(top, top + zone_height);
    let lower = zone_motion(top + zone_height, top + 2 * zone_height);
    let below = zone_motion(top + 2 * zone_height, bottom);
    (upper, lower, below)
}

/// Computes inside-motion score and sequence score from zone history.
///
/// inside_score: how much the lower zone activated above baseline during
/// the event window (ball pushing through the net).
/// sequence_score: whether lower activated before below (correct order
/// for a made basket: ball enters net, then drops below).
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

    let baseline_lower = baseline.iter().map(|(_, _, l, _)| *l).sum::<f32>() / baseline.len() as f32;
    let baseline_below = baseline.iter().map(|(_, _, _, b)| *b).sum::<f32>() / baseline.len() as f32;

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
        (Some(_), None) => 0.8, // Only lower activated, no below yet.
        (Some(_), Some(_)) => 0.4, // Wrong order (below before lower).
        (None, _) => 0.0, // No lower zone activation.
    };

    (inside_score, sequence_score)
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

fn preprocess(image: &RgbImage, model_size: u32) -> Result<(Array4<f32>, f32, f32, f32), RuntimeError> {
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
    result
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
    // Grid size = (model_size / stride)^2, default 640/8=80, 80*80=6400.
    // For 1280: 1280/8=160, 160*160=25600. Fall back to 8400 if model
    // size is unexpected (some YOLO variants use 6400+2000 for P5 head).
    let grid = match model_size {
        640 => 8_400,
        1280 => 25_600,
        _ => 8_400,
    };
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
    fn net_motion_score_is_normalized_and_handles_shape_mismatch() {
        assert_eq!(net_motion_score(&[0.2, 0.2], &[0.2]), 0.0);
        assert_eq!(net_motion_score(&[0.2, 0.2], &[0.2, 0.2]), 0.0);
        assert!(net_motion_score(&[0.8, 0.8], &[0.0, 0.0]) > 0.9);
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
    if session.is_null() || rgba_data.is_null() {
        return std::ptr::null_mut();
    }
    let rgba = std::slice::from_raw_parts(rgba_data, rgba_len as usize);
    let output = match (*session).push_frame_raw(time_ms, width, height, rgba)
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
