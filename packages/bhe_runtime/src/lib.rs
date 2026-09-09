use std::ffi::{c_char, CStr, CString};
use std::path::Path;
use std::sync::OnceLock;
use std::time::Instant;

use base64::Engine;
use image::{
    imageops::{resize, rotate180, rotate270, rotate90, FilterType},
    RgbImage,
};
#[cfg(test)]
use ndarray::Array4;
use ndarray::ArrayView4;
use ort::{
    session::{builder::GraphOptimizationLevel, Session},
    value::TensorRef,
};
use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Inference input resolution. 640 is the default for YOLOv8n-style models
/// converted to ONNX. Desktop uses 1280; if the mobile model was exported at
/// a different size, override via the `model_size` config field.
const MODEL_SIZE_DEFAULT: u32 = 640;
const ANALYSIS_CONTRACT_VERSION: &str = "analysis-contract-v1";
const RUNTIME_VERSION: &str = "bhe_runtime/0.1.0";
// Ultralytics' default `predict(..., iou=0.7)` value. Keep this explicit on
// both sides so ONNX post-processing does not silently use a different NMS
// (non-maximum suppression) threshold than the desktop engine.
const DETECTION_NMS_IOU: f32 = 0.7;
// Ultralytics applies `max_det=300` after class-aware NMS. Keeping the same
// cap matters for crowded frames and makes the native detector's output size
// deterministic instead of depending on how many low-confidence boxes the
// ONNX graph emits.
const DETECTION_MAX_COUNT: usize = 300;
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

#[derive(Clone, Debug, Deserialize, PartialEq)]
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
    /// Large ball-search region. Older clients used `hoop_roi` for this too.
    #[serde(default)]
    pub analysis_roi: Option<Roi>,
    /// Tight physical rim box. If omitted, it is calibrated from hoop
    /// detections produced inside `analysis_roi`.
    #[serde(default)]
    pub rim: Option<Roi>,
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
    /// Scale the analysis crop before the model letterbox, matching the
    /// desktop `--scale 4` crop path.
    #[serde(default = "default_crop_scale")]
    pub crop_scale: f32,
    /// Maximum gap allowed when looking for a crossing, matching Python's
    /// `find_refined_crossings(..., max_cross_gap_sec=1.8)`.
    #[serde(default = "default_max_cross_gap_ms")]
    pub max_cross_gap_ms: i64,
    /// Candidate deduplication window, matching Python's `dedupe_sec=2.0`.
    #[serde(default = "default_dedupe_ms")]
    pub dedupe_ms: i64,
    #[serde(default = "default_intra_threads")]
    pub intra_threads: usize,
    #[serde(default = "default_inference_batch_size")]
    pub inference_batch_size: usize,
    #[serde(default)]
    pub execution_provider: Option<String>,
    #[serde(default)]
    pub execution_provider_backend: Option<String>,
    #[serde(default)]
    pub optimized_model_path: Option<String>,
    /// Optional maximum dimension for low-cost scans. The YUV path samples
    /// directly into this size instead of materializing the full ROI.
    #[serde(default)]
    pub input_max_dimension: Option<u32>,
    #[serde(default)]
    pub detection_only: bool,
    /// Coarse discovery follows the desktop candidate-crossing contract:
    /// emit a crossing from the trajectory geometry without waiting for the
    /// fine pass's post-crossing verification window.
    #[serde(default)]
    pub coarse_mode: bool,
}

fn default_model_size() -> u32 {
    MODEL_SIZE_DEFAULT
}

fn default_crop_scale() -> f32 {
    // Desktop's production pipeline passes `refine_scale=2`. Keep the
    // mobile default identical; callers can still override it explicitly.
    2.0
}

fn default_max_cross_gap_ms() -> i64 {
    1_800
}

fn default_dedupe_ms() -> i64 {
    2_000
}

fn default_intra_threads() -> usize {
    1
}

fn default_inference_batch_size() -> usize {
    1
}

#[derive(Clone, Debug, Deserialize)]
pub struct AnalysisRequest {
    pub model_path: String,
    pub frames: Vec<FrameInput>,
    pub hoop_roi: Roi,
    pub net_roi: Roi,
    #[serde(default)]
    pub analysis_roi: Option<Roi>,
    #[serde(default)]
    pub rim: Option<Roi>,
    #[serde(default)]
    pub duration_ms: Option<i64>,
    #[serde(default = "default_confidence")]
    pub confidence_threshold: f32,
    #[serde(default = "default_before_ms")]
    pub clip_before_ms: i64,
    #[serde(default = "default_after_ms")]
    pub clip_after_ms: i64,
    #[serde(default = "default_model_size")]
    pub model_size: u32,
    #[serde(default = "default_crop_scale")]
    pub crop_scale: f32,
    #[serde(default = "default_max_cross_gap_ms")]
    pub max_cross_gap_ms: i64,
    #[serde(default = "default_dedupe_ms")]
    pub dedupe_ms: i64,
    #[serde(default = "default_intra_threads")]
    pub intra_threads: usize,
    #[serde(default = "default_inference_batch_size")]
    pub inference_batch_size: usize,
    #[serde(default)]
    pub execution_provider: Option<String>,
    #[serde(default)]
    pub execution_provider_backend: Option<String>,
    #[serde(default)]
    pub optimized_model_path: Option<String>,
    #[serde(default)]
    pub input_max_dimension: Option<u32>,
    #[serde(default)]
    pub detection_only: bool,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub width: Option<f32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub height: Option<f32>,
}

#[derive(Clone, Debug, Serialize)]
pub struct PredictionEvidence {
    pub landing_x: f32,
    pub landing_y: f32,
    pub landing_center: f32,
    pub fit_r2: f32,
    pub point_count: usize,
    pub predict_score: f32,
}

#[derive(Clone, Debug, Serialize)]
pub struct Candidate {
    pub id: String,
    pub track_id: u64,
    pub start_ms: i64,
    pub end_ms: i64,
    pub event_ms: i64,
    pub confidence: f32,
    pub confidence_label: String,
    pub speed_px_s: f32,
    pub horizontal_ratio: f32,
    pub approach_horizontal_span_px: f32,
    pub speed_per_rim: f32,
    pub approach_span_per_rim: f32,
    pub trajectory_score: f32,
    pub crossing_score: f32,
    pub net_score: f32,
    pub net_motion_score: f32,
    pub net_changed_ratio: f32,
    pub net_inside_motion_score: f32,
    pub net_sequence_score: f32,
    /// Prediction score: how well the pre-crossing trajectory predicts
    /// a landing inside the rim corridor (0-1, higher = more likely).
    pub prediction_score: f32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prediction: Option<PredictionEvidence>,
    pub prediction_review: bool,
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
    pub post_crossing_points: usize,
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
    /// Keep the decision evidence in the same nested shape as the desktop
    /// candidate. The scalar fields above remain for older mobile clients.
    pub signals: serde_json::Value,
    pub gates: serde_json::Value,
    pub verification: serde_json::Value,
}

// (time_ms, x, y, confidence, width, height); x/y and box dimensions are
// normalized to the decoded frame so all geometry remains resolution aware.
type BallPoint = (i64, f32, f32, f32, f32, f32);

#[derive(Clone, Debug)]
struct BallTrack {
    id: u64,
    points: Vec<BallPoint>,
    last_width: f32,
    last_height: f32,
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
    /// Python's `_multi_signal_features(...)["net_score"]` equivalent.
    score: f32,
    /// Python's legacy global motion score. The native zone path has no
    /// equivalent global changed-ratio measurement, so it remains zero.
    motion_score: f32,
    changed_ratio: f32,
}

#[derive(Clone, Copy, Debug, Default)]
struct PostCrossingEvidence {
    persistence: f32,
    post_crossing_points: usize,
    rebound: bool,
    lateral_exit: bool,
    lateral_recovery: bool,
}

#[derive(Clone, Copy, Debug, Default)]
struct CalibratedGates {
    high_precision: bool,
    automatic_goal: bool,
    review: bool,
    recall_review: bool,
    strict_low_speed: bool,
    high_speed_net: bool,
    high_speed_drop: bool,
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
    #[serde(default)]
    pub frame_width: Option<u32>,
    #[serde(default)]
    pub frame_height: Option<u32>,
    #[serde(default)]
    pub candidate_speed_per_rim: Option<f32>,
    #[serde(default)]
    pub candidate_approach_span_per_rim: Option<f32>,
    #[serde(default)]
    pub candidate_horizontal_ratio: Option<f32>,
    #[serde(default)]
    pub candidate_complete_crossing: Option<bool>,
    #[serde(default)]
    pub candidate_ball_persistence: Option<f32>,
    #[serde(default)]
    pub candidate_rebound: Option<bool>,
    #[serde(default)]
    pub candidate_lateral_exit: Option<bool>,
    #[serde(default)]
    pub candidate_post_crossing_lateral_recovery: Option<bool>,
    #[serde(default)]
    pub candidate_score: Option<f32>,
    #[serde(default)]
    pub candidate_net_score: Option<f32>,
    #[serde(default)]
    pub candidate_net_motion_score: Option<f32>,
    #[serde(default)]
    pub candidate_net_changed_ratio: Option<f32>,
    #[serde(default)]
    pub candidate_net_signal_available: Option<bool>,
    #[serde(default)]
    pub candidate_net_no_motion: Option<bool>,
    #[serde(default)]
    pub candidate_net_support: Option<bool>,
    #[serde(default)]
    pub candidate_net_inside_motion_score: Option<f32>,
    #[serde(default)]
    pub candidate_net_sequence_score: Option<f32>,
    #[serde(default)]
    pub candidate_net_lower_peak: Option<f32>,
    #[serde(default)]
    pub candidate_net_below_peak: Option<f32>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct NetReplayPoint {
    pub time_ms: i64,
    /// Whether the source frame produced a usable net measurement. Missing
    /// measurements must not be interpreted as measured no-motion frames.
    #[serde(default)]
    pub measurement_valid: Option<bool>,
    pub upper: f32,
    pub lower: f32,
    pub below: f32,
    /// Effective zone signal used by Python's inside-motion path. It also
    /// includes changed-ratio evidence, unlike upper/lower/below above.
    #[serde(default)]
    pub lower_inside: f32,
    #[serde(default)]
    pub below_inside: f32,
    /// The four component signals used by Python's multi-signal path.
    #[serde(default)]
    pub upper_components: [f32; 4],
    #[serde(default)]
    pub lower_components: [f32; 4],
    #[serde(default)]
    pub below_components: [f32; 4],
    /// The whole-net signal used by Python's legacy motion feature.
    #[serde(default)]
    pub motion: f32,
    #[serde(default)]
    pub changed_ratio: f32,
    /// Python whole-net signal before event-window aggregation.
    #[serde(default)]
    pub whole: f32,
}

#[derive(Clone, Copy, Debug, Default)]
struct NetHistoryPoint {
    time_ms: i64,
    measurement_valid: bool,
    lower_inside: f32,
    below_inside: f32,
    upper_components: [f32; 4],
    lower_components: [f32; 4],
    below_components: [f32; 4],
    motion: f32,
    changed_ratio: f32,
    whole: f32,
}

#[derive(Clone, Debug, Serialize)]
pub struct DecisionReplayResult {
    pub algorithm_version: String,
    pub event_ms: i64,
    pub complete_crossing: bool,
    pub ball_persistence: f32,
    pub rebound: bool,
    pub lateral_exit: bool,
    pub post_crossing_lateral_recovery: bool,
    pub net_signal_available: bool,
    pub net_support: bool,
    pub net_no_motion: bool,
    pub net_score: f32,
    pub net_motion_score: f32,
    pub net_changed_ratio: f32,
    pub net_inside_motion_score: f32,
    pub net_sequence_score: f32,
    pub net_lower_peak: f32,
    pub net_below_peak: f32,
    pub strict_low_speed: bool,
    pub high_speed_net: bool,
    pub high_speed_drop: bool,
    pub high_precision: bool,
    pub automatic_goal: bool,
    pub review: bool,
    pub recall_review: bool,
    pub verdict: String,
    pub auto_export_eligible: bool,
}

pub struct RuntimeSession {
    session: Session,
    config: RuntimeConfig,
    analysis_roi: Roi,
    /// Global net-motion ROI after applying the same analysis-ROI clipping as
    /// the desktop refiner. Zone ROIs intentionally remain based on the
    /// configured net ROI, matching the desktop signal regions.
    net_motion_roi: Option<Roi>,
    rim_roi: Roi,
    rim_calibrated: bool,
    rim_observations: Vec<Detection>,
    frame_width: u32,
    frame_height: u32,
    last_time_ms: i64,
    model_size: u32,
    crop_scale: f32,
    tracks: Vec<BallTrack>,
    /// Raw detections are kept separately because Python recovery searches
    /// every ball detection, including points not retained by the main track.
    ball_history: Vec<BallPoint>,
    /// One highest-confidence ball per sample. Python's coarse pass does not
    /// associate tracks: `find_candidate_crossings` evaluates this flattened
    /// sequence directly. Keep it separate from the refined-track state.
    coarse_points: Vec<BallPoint>,
    next_track_id: u64,
    legacy_track_id: Option<u64>,
    candidates: Vec<Candidate>,
    processed_frames: u64,
    /// Raw grayscale zones used by the native net measurement path. Keeping
    /// pixels instead of only an 8x8 signature preserves small white-net
    /// changes and uses the same threshold semantics as Python.
    net_gray_history: Vec<(i64, [Vec<u8>; 3])>,
    previous_net_gray: Vec<u8>,
    /// Three-zone net motion history: (time_ms, upper, lower, below).
    /// Mirrors the desktop algorithm: a made basket activates the net's
    /// lower zone first, then the zone below it (ball hits net then drops).
    net_zone_history: Vec<NetHistoryPoint>,
    /// Reusable RGB storage for decoded analysis crops. It is resized only
    /// when the crop dimensions change and is returned after each frame.
    rgb_work_buffer: Vec<u8>,
    /// Reusable RGB crop after the configured analysis ROI.
    roi_work_buffer: Vec<u8>,
    roi_work_dimensions: (u32, u32),
    /// Reusable RGB buffer for scaled model input crops.
    resized_work_buffer: Vec<u8>,
    resized_work_dimensions: (u32, u32),
    /// Reusable NCHW float input for the fixed-size ONNX model tensor.
    model_input_buffer: Vec<f32>,
    batch_model_input_buffer: Vec<f32>,
    pending_frames: Vec<PendingFrame>,
    batch_failed: bool,
    /// Maximum decoded analysis-crop dimension for coarse scans.
    input_max_dimension: Option<u32>,
    provider_requested: String,
    provider_registered: String,
    provider_precision: String,
    session_init_ms: u64,
}

#[derive(Clone, Debug, Serialize)]
struct RuntimeSessionInfo {
    provider_requested: String,
    provider_registered: String,
    provider_precision: String,
    inference_batch_size: usize,
    batch_failed: bool,
    processed_frames: u64,
    session_init_ms: u64,
}

struct PendingFrame {
    time_ms: i64,
    analysis_frame: RgbImage,
    source_width: u32,
    source_height: u32,
    offset_x: u32,
    offset_y: u32,
    coordinate_scale: f32,
    scale: f32,
    net_roi: Roi,
    net_motion_roi: Option<Roi>,
}

impl RuntimeSession {
    pub fn new(config: RuntimeConfig) -> Result<Self, RuntimeError> {
        let session_started = Instant::now();
        validate_config(&config)?;
        validate_roi(&config.hoop_roi, "hoop")?;
        validate_roi(&config.net_roi, "net")?;
        let analysis_roi = config
            .analysis_roi
            .clone()
            .unwrap_or_else(|| config.hoop_roi.clone());
        validate_roi(&analysis_roi, "analysis")?;
        // Python disables the whole-net measurement when the configured net
        // ROI does not overlap the analysis crop; it does not fail analysis.
        // Keep that distinction so a bad optional net zone cannot make the
        // mobile pipeline behave differently from desktop.
        let net_motion_roi = intersect_roi(&config.net_roi, &analysis_roi);
        let rim_roi = config
            .rim
            .clone()
            .unwrap_or_else(|| config.hoop_roi.clone());
        validate_roi(&rim_roi, "rim")?;
        let rim_calibrated = config.rim.is_some();
        init_onnx()?;
        let model_size = config.model_size;
        let crop_scale = config.crop_scale;
        let inference_batch_size = config.inference_batch_size;
        let input_max_dimension = config.input_max_dimension;
        let provider_requested = config
            .execution_provider
            .clone()
            .unwrap_or_else(|| "cpu".to_string())
            .to_ascii_lowercase();
        #[allow(unused_mut)]
        let mut provider_registered = "cpu".to_string();
        #[allow(unused_mut)]
        let mut provider_precision = "fp32".to_string();
        #[allow(unused_mut)]
        let mut session_builder = Session::builder()
            .map_err(|error| RuntimeError::InvalidRequest(error.to_string()))?
            .with_optimization_level(GraphOptimizationLevel::All)
            .map_err(|error| RuntimeError::InvalidRequest(error.to_string()))?
            .with_parallel_execution(false)
            .map_err(|error| RuntimeError::InvalidRequest(error.to_string()))?
            .with_intra_threads(config.intra_threads)
            .map_err(|error| RuntimeError::InvalidRequest(error.to_string()))?;
        #[cfg(all(target_os = "android", feature = "android-ep"))]
        {
            use core::num::NonZeroUsize;
            use ort::ep::{ExecutionProvider, NNAPI, QNN, XNNPACK};
            let provider_name = config
                .execution_provider
                .clone()
                .or_else(|| std::env::var("BHE_ANDROID_EP").ok())
                .unwrap_or_else(|| "cpu".to_string())
                .to_ascii_lowercase();
            let nnapi = NNAPI::default();
            let nnapi_available = nnapi.is_available().unwrap_or(false);
            match provider_name.as_str() {
                "auto" if nnapi_available => provider_registered = "nnapi".to_string(),
                "auto" => provider_registered = "xnnpack".to_string(),
                "nnapi" | "nnapi_fp32" | "nnapi_fp32_no_cpu" => {
                    provider_registered = "nnapi".to_string()
                }
                "nnapi_fp16" | "nnapi_fp16_no_cpu" => {
                    provider_registered = "nnapi".to_string();
                    provider_precision = "fp16".to_string();
                }
                "qnn" => {
                    provider_registered = "qnn_htp".to_string();
                    provider_precision = "fp16".to_string();
                }
                "xnnpack" => provider_registered = "xnnpack".to_string(),
                _ => {}
            }
            session_builder = match provider_name.as_str() {
                "auto" if nnapi_available => session_builder
                    // Keep FP32 for parity with the desktop model. FP16 is
                    // faster on some phones but can change low-confidence
                    // detections at the decision boundary.
                    .with_execution_providers([nnapi.with_fp16(false).build()])
                    .map_err(|error| RuntimeError::InvalidRequest(error.to_string()))?,
                "auto" => session_builder
                    .with_execution_providers([XNNPACK::default()
                        .with_intra_op_num_threads(
                            NonZeroUsize::new(config.intra_threads)
                                .unwrap_or(NonZeroUsize::new(1).unwrap()),
                        )
                        .build()])
                    .map_err(|error| RuntimeError::InvalidRequest(error.to_string()))?,
                "nnapi" | "nnapi_fp32" => session_builder
                    .with_execution_providers([nnapi.with_fp16(false).build().error_on_failure()])
                    .map_err(|error| RuntimeError::InvalidRequest(error.to_string()))?,
                "nnapi_fp16" => session_builder
                    .with_execution_providers([NNAPI::default()
                        .with_fp16(true)
                        .build()
                        .error_on_failure()])
                    .map_err(|error| RuntimeError::InvalidRequest(error.to_string()))?,
                "nnapi_fp32_no_cpu" => session_builder
                    .with_execution_providers([NNAPI::default()
                        .with_fp16(false)
                        .with_disable_cpu(true)
                        .build()
                        .error_on_failure()])
                    .map_err(|error| RuntimeError::InvalidRequest(error.to_string()))?,
                "nnapi_fp16_no_cpu" => session_builder
                    .with_execution_providers([NNAPI::default()
                        .with_fp16(true)
                        .with_disable_cpu(true)
                        .build()
                        .error_on_failure()])
                    .map_err(|error| RuntimeError::InvalidRequest(error.to_string()))?,
                "qnn" => session_builder
                    .with_execution_providers([QNN::default()
                        .with_backend_path(
                            config
                                .execution_provider_backend
                                .clone()
                                .or_else(|| std::env::var("BHE_ANDROID_QNN_BACKEND").ok())
                                .unwrap_or_else(|| "libQnnHtp.so".to_string()),
                        )
                        .with_htp_fp16_precision(true)
                        .with_performance_mode(
                            ort::ep::qnn::PerformanceMode::SustainedHighPerformance,
                        )
                        .build()
                        .error_on_failure()])
                    .map_err(|error| RuntimeError::InvalidRequest(error.to_string()))?,
                "xnnpack" => session_builder
                    .with_execution_providers([XNNPACK::default()
                        .with_intra_op_num_threads(
                            NonZeroUsize::new(config.intra_threads)
                                .unwrap_or(NonZeroUsize::new(1).unwrap()),
                        )
                        .build()
                        .error_on_failure()])
                    .map_err(|error| RuntimeError::InvalidRequest(error.to_string()))?,
                _ => session_builder,
            };
        }
        #[cfg(all(target_os = "ios", feature = "ios-ep"))]
        {
            use ort::ep::coreml::{ComputeUnits, ModelFormat, SpecializationStrategy};
            use ort::ep::{CoreML, ExecutionProvider};
            let provider_name = config
                .execution_provider
                .clone()
                .unwrap_or_else(|| "coreml".to_string())
                .to_ascii_lowercase();
            if provider_name == "auto" || provider_name == "coreml" {
                let coreml = CoreML::default();
                if coreml.is_available().unwrap_or(false) {
                    provider_registered = "coreml".to_string();
                    provider_precision = "mixed".to_string();
                    session_builder = session_builder
                        .with_execution_providers([CoreML::default()
                            .with_compute_units(ComputeUnits::All)
                            .with_model_format(ModelFormat::MLProgram)
                            .with_specialization_strategy(SpecializationStrategy::FastPrediction)
                            .build()
                            .error_on_failure()])
                        .map_err(|error| RuntimeError::InvalidRequest(error.to_string()))?;
                }
            }
        }
        let session = if let Some(optimized_model_path) = config.optimized_model_path.as_deref() {
            if Path::new(optimized_model_path).is_file() {
                session_builder
                    .with_optimization_level(GraphOptimizationLevel::Disable)
                    .map_err(|error| RuntimeError::InvalidRequest(error.to_string()))?
                    .commit_from_file(Path::new(optimized_model_path))?
            } else {
                session_builder
                    .with_optimized_model_path(Path::new(optimized_model_path))
                    .map_err(|error| RuntimeError::InvalidRequest(error.to_string()))?
                    .commit_from_file(Path::new(&config.model_path))?
            }
        } else {
            session_builder.commit_from_file(Path::new(&config.model_path))?
        };
        validate_model_input_shape(&session, model_size)?;
        Ok(Self {
            session,
            config,
            analysis_roi,
            net_motion_roi,
            rim_roi,
            rim_calibrated,
            rim_observations: Vec::new(),
            frame_width: 1,
            frame_height: 1,
            last_time_ms: 0,
            model_size,
            crop_scale,
            tracks: Vec::new(),
            ball_history: Vec::new(),
            coarse_points: Vec::new(),
            next_track_id: 1,
            legacy_track_id: None,
            candidates: Vec::new(),
            processed_frames: 0,
            net_gray_history: Vec::new(),
            previous_net_gray: Vec::new(),
            net_zone_history: Vec::new(),
            rgb_work_buffer: Vec::new(),
            roi_work_buffer: Vec::new(),
            roi_work_dimensions: (0, 0),
            resized_work_buffer: Vec::new(),
            resized_work_dimensions: (0, 0),
            model_input_buffer: Vec::new(),
            batch_model_input_buffer: Vec::new(),
            pending_frames: Vec::with_capacity(inference_batch_size),
            batch_failed: false,
            input_max_dimension,
            provider_requested,
            provider_registered,
            provider_precision,
            session_init_ms: session_started.elapsed().as_millis() as u64,
        })
    }

    fn session_info(&self) -> RuntimeSessionInfo {
        RuntimeSessionInfo {
            provider_requested: self.provider_requested.clone(),
            provider_registered: self.provider_registered.clone(),
            provider_precision: self.provider_precision.clone(),
            inference_batch_size: self.config.inference_batch_size,
            batch_failed: self.batch_failed,
            processed_frames: self.processed_frames,
            session_init_ms: self.session_init_ms,
        }
    }

    pub fn candidates(&self) -> &[Candidate] {
        &self.candidates
    }

    /// Flushes the short post-crossing verification window after the last
    /// decoded frame. Streaming callers otherwise leave a candidate near the
    /// analysis end in `pending`, while the desktop batch engine resolves the
    /// same candidate from all available records.
    pub fn finish(&mut self) -> Result<FrameResponse, RuntimeError> {
        if !self.pending_frames.is_empty() {
            self.flush_pending_frames()?;
        }
        if self.config.coarse_mode {
            // `generate_candidates.py` uses the median of every hoop
            // detection from the complete proxy scan.  The coarse rim plane
            // is the detector-box centre, not the refined physical rim plane
            // used by the native-frame verifier.
            let coarse_rim = coarse_rim_from_observations(
                &self.rim_observations,
                self.frame_width,
                self.frame_height,
            )
            .unwrap_or_else(|| self.rim_roi.clone());
            return Ok(FrameResponse {
                detections: Vec::new(),
                candidates: coarse_crossing_candidates(
                    &self.coarse_points,
                    &coarse_rim,
                    self.frame_width,
                    self.frame_height,
                    &self.config,
                ),
                processed_frames: self.processed_frames,
            });
        }
        if self.processed_frames > 0 {
            self.last_time_ms = self.last_time_ms.saturating_add(800);
            self.resolve_verdict();
        }
        Ok(FrameResponse {
            detections: Vec::new(),
            candidates: dedupe_runtime_candidates(self.candidates.clone(), self.config.dedupe_ms),
            processed_frames: self.processed_frames,
        })
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
        self.push_frame_raw_strided(time_ms, width, height, rgba, width as usize * 4)
    }

    pub fn push_frame_yuv(
        &mut self,
        time_ms: i64,
        width: u32,
        height: u32,
        y: &[u8],
        y_row_stride: usize,
        y_pixel_stride: usize,
        u: &[u8],
        u_row_stride: usize,
        u_pixel_stride: usize,
        v: &[u8],
        v_row_stride: usize,
        v_pixel_stride: usize,
        rotation_degrees: i32,
    ) -> Result<FrameResponse, RuntimeError> {
        if width == 0
            || height == 0
            || y_row_stride == 0
            || u_row_stride == 0
            || v_row_stride == 0
            || y_pixel_stride == 0
            || u_pixel_stride == 0
            || v_pixel_stride == 0
        {
            return Err(RuntimeError::InvalidRequest(
                "YUV frame dimensions are invalid".into(),
            ));
        }
        let chroma_width = (width as usize).div_ceil(2);
        let chroma_height = (height as usize).div_ceil(2);
        let required_plane_len = |plane_width: usize,
                                  plane_height: usize,
                                  row_stride: usize,
                                  pixel_stride: usize|
         -> Option<usize> {
            plane_height
                .checked_sub(1)?
                .checked_mul(row_stride)?
                .checked_add(plane_width.checked_sub(1)?.checked_mul(pixel_stride)?)
                .and_then(|offset| offset.checked_add(1))
        };
        let required_y = required_plane_len(
            width as usize,
            height as usize,
            y_row_stride,
            y_pixel_stride,
        )
        .ok_or_else(|| RuntimeError::InvalidRequest("YUV plane dimensions are too large".into()))?;
        let required_chroma =
            required_plane_len(chroma_width, chroma_height, u_row_stride, u_pixel_stride)
                .ok_or_else(|| {
                    RuntimeError::InvalidRequest("YUV plane dimensions are too large".into())
                })?;
        let required_v =
            required_plane_len(chroma_width, chroma_height, v_row_stride, v_pixel_stride)
                .ok_or_else(|| {
                    RuntimeError::InvalidRequest("YUV plane dimensions are too large".into())
                })?;
        if y.len() < required_y || u.len() < required_chroma || v.len() < required_v {
            return Err(RuntimeError::InvalidRequest(format!(
                "YUV plane buffer is too small: y={}<{} u={}<{} v={}<{}",
                y.len(),
                required_y,
                u.len(),
                required_chroma,
                v.len(),
                required_v
            )));
        }
        // MediaCodec exposes the encoded YUV planes before applying the
        // track's rotation metadata. Flutter's ROI, however, is drawn on the
        // display-oriented frame. Resolve the ROI in that same logical space
        // and map each sampled pixel back to the encoded planes. This keeps
        // the YUV fast path identical to the rotated Bitmap fallback.
        let rotation = rotation_degrees.rem_euclid(360);
        let (logical_width, logical_height) = if matches!(rotation, 90 | 270) {
            (height, width)
        } else {
            (width, height)
        };
        let (roi_left, roi_top, roi_right, roi_bottom) =
            roi_pixel_bounds_for_dimensions(logical_width, logical_height, &self.analysis_roi);
        let source_width = roi_right - roi_left;
        let source_height = roi_bottom - roi_top;
        // The desktop coarse pass enlarges the configured analysis crop by
        // `crop_scale` before the 640px letterbox.  Downsampling the crop
        // before that enlargement changes the ball's apparent size and can
        // make the ONNX detector miss the same shot that Ultralytics finds.
        // Keep the full crop for coarse mode; the model input is still capped
        // at `model_size`, so this only preserves the detector's input scale.
        let input_limit = if self.config.coarse_mode {
            u32::MAX
        } else {
            self.input_max_dimension.unwrap_or(u32::MAX)
        }
        .max(1);
        let downsample = (source_width.max(source_height) as f32 / input_limit as f32).max(1.0);
        let output_width = ((source_width as f32 / downsample).ceil() as u32).max(1);
        let output_height = ((source_height as f32 / downsample).ceil() as u32).max(1);
        let scale = self.crop_scale.max(1.0);
        let coordinate_scale = scale * downsample;
        if self.config.detection_only && self.input_max_dimension.is_some() {
            let crop_detections = detect_yuv_sampled(
                &mut self.session,
                width,
                height,
                y,
                y_row_stride,
                y_pixel_stride,
                u,
                u_row_stride,
                u_pixel_stride,
                v,
                v_row_stride,
                v_pixel_stride,
                rotation,
                roi_left,
                roi_top,
                roi_right,
                roi_bottom,
                output_width,
                output_height,
                downsample,
                self.config.confidence_threshold,
                self.model_size,
                &mut self.model_input_buffer,
            )?;
            let detections = remap_detections(
                crop_detections,
                roi_left,
                roi_top,
                logical_width,
                logical_height,
                coordinate_scale,
            );
            self.processed_frames += 1;
            return Ok(FrameResponse {
                detections,
                candidates: Vec::new(),
                processed_frames: self.processed_frames,
            });
        }
        let buffer_len = (output_width as usize)
            .checked_mul(output_height as usize)
            .and_then(|size| size.checked_mul(3))
            .ok_or_else(|| {
                RuntimeError::InvalidRequest("YUV frame dimensions are too large".into())
            })?;
        if buffer_len > 64 * 1024 * 1024 {
            return Err(RuntimeError::InvalidRequest(
                "YUV analysis crop is too large".into(),
            ));
        }
        if self.rgb_work_buffer.len() != buffer_len {
            self.rgb_work_buffer.resize(buffer_len, 0);
        }
        let buffer = &mut self.rgb_work_buffer;
        for local_y in 0..output_height as usize {
            let logical_y = (local_y as f32 * downsample).floor() as u32 + roi_top;
            let logical_y = logical_y.min(roi_bottom - 1);
            for local_x in 0..output_width as usize {
                let logical_x = (local_x as f32 * downsample).floor() as u32 + roi_left;
                let logical_x = logical_x.min(roi_right - 1);
                let (col, row) =
                    source_coordinates_for_rotation(logical_x, logical_y, width, height, rotation);
                let y_index = row as usize * y_row_stride + col as usize * y_pixel_stride;
                let uv_row = row as usize / 2;
                let uv_col = col as usize / 2;
                let u_index = uv_row * u_row_stride + uv_col * u_pixel_stride;
                let v_index = uv_row * v_row_stride + uv_col * v_pixel_stride;
                if y_index >= y.len() || u_index >= u.len() || v_index >= v.len() {
                    return Err(RuntimeError::InvalidRequest(
                        "YUV plane buffer is too small".into(),
                    ));
                }
                let y_value = (y[y_index] as f32 - 16.0).max(0.0);
                let u_value = u[u_index] as f32 - 128.0;
                let v_value = v[v_index] as f32 - 128.0;
                let red = (1.164 * y_value + 1.596 * v_value)
                    .round()
                    .clamp(0.0, 255.0) as u8;
                let green = (1.164 * y_value - 0.391 * u_value - 0.813 * v_value)
                    .round()
                    .clamp(0.0, 255.0) as u8;
                let blue = (1.164 * y_value + 2.018 * u_value)
                    .round()
                    .clamp(0.0, 255.0) as u8;
                let offset = (local_y * output_width as usize + local_x) * 3;
                buffer[offset] = red;
                buffer[offset + 1] = green;
                buffer[offset + 2] = blue;
            }
        }
        let image = RgbImage::from_raw(
            output_width,
            output_height,
            std::mem::take(&mut self.rgb_work_buffer),
        )
        .ok_or_else(|| RuntimeError::InvalidRequest("YUV frame dimensions are invalid".into()))?;
        let local_net_roi = relative_roi(&self.config.net_roi, &self.analysis_roi);
        let local_net_motion_roi = self
            .net_motion_roi
            .as_ref()
            .map(|roi| relative_roi(roi, &self.analysis_roi));
        self.push_image_with_source(
            time_ms,
            image,
            logical_width,
            logical_height,
            roi_left,
            roi_top,
            coordinate_scale,
            scale,
            &local_net_roi,
            local_net_motion_roi.as_ref(),
        )
    }

    pub fn push_frame_raw_strided(
        &mut self,
        time_ms: i64,
        width: u32,
        height: u32,
        rgba: &[u8],
        row_stride: usize,
    ) -> Result<FrameResponse, RuntimeError> {
        self.push_frame_4channel_strided(time_ms, width, height, rgba, row_stride, false, 0)
    }

    pub fn push_frame_bgra_strided(
        &mut self,
        time_ms: i64,
        width: u32,
        height: u32,
        bgra: &[u8],
        row_stride: usize,
        rotation_degrees: i32,
    ) -> Result<FrameResponse, RuntimeError> {
        self.push_frame_4channel_strided(
            time_ms,
            width,
            height,
            bgra,
            row_stride,
            true,
            rotation_degrees,
        )
    }

    fn push_frame_4channel_strided(
        &mut self,
        time_ms: i64,
        width: u32,
        height: u32,
        pixels: &[u8],
        row_stride: usize,
        bgra: bool,
        rotation_degrees: i32,
    ) -> Result<FrameResponse, RuntimeError> {
        let row_bytes = (width as usize).checked_mul(4).ok_or_else(|| {
            RuntimeError::InvalidRequest("raw frame dimensions are too large".into())
        })?;
        let max_frame_bytes = 64usize * 1024 * 1024;
        let required = row_stride
            .checked_mul(height.saturating_sub(1) as usize)
            .and_then(|offset| offset.checked_add(row_bytes))
            .ok_or_else(|| RuntimeError::InvalidRequest("raw frame stride is invalid".into()))?;
        if width == 0
            || height == 0
            || row_stride < row_bytes
            || required > max_frame_bytes
            || pixels.len() < required
        {
            return Err(RuntimeError::InvalidRequest(format!(
                "raw frame has {} bytes, requires at least {} ({}x{} stride {})",
                pixels.len(),
                required,
                width,
                height,
                row_stride
            )));
        }
        let buffer_len = (width as usize)
            .checked_mul(height as usize)
            .and_then(|size| size.checked_mul(3))
            .ok_or_else(|| {
                RuntimeError::InvalidRequest("raw frame dimensions are too large".into())
            })?;
        if self.rgb_work_buffer.len() != buffer_len {
            self.rgb_work_buffer.resize(buffer_len, 0);
        }
        {
            let buffer = &mut self.rgb_work_buffer;
            for row_index in 0..height as usize {
                let source_row =
                    &pixels[row_index * row_stride..row_index * row_stride + row_bytes];
                let destination_row = &mut buffer
                    [row_index * width as usize * 3..(row_index + 1) * width as usize * 3];
                for (chunk, output) in source_row
                    .chunks_exact(4)
                    .zip(destination_row.chunks_exact_mut(3))
                {
                    if bgra {
                        output[0] = chunk[2]; // R
                        output[1] = chunk[1]; // G
                        output[2] = chunk[0]; // B
                    } else {
                        output[0] = chunk[0]; // R
                        output[1] = chunk[1]; // G
                        output[2] = chunk[2]; // B
                    }
                }
            }
        }
        let image = RgbImage::from_raw(width, height, std::mem::take(&mut self.rgb_work_buffer))
            .ok_or_else(|| {
                RuntimeError::InvalidRequest("raw frame dimensions are invalid".into())
            })?;
        let image = if bgra {
            match rotation_degrees.rem_euclid(360) {
                90 => rotate90(&image),
                180 => rotate180(&image),
                270 => rotate270(&image),
                _ => image,
            }
        } else {
            image
        };
        self.push_image(time_ms, image)
    }

    fn push_image(&mut self, time_ms: i64, image: RgbImage) -> Result<FrameResponse, RuntimeError> {
        self.frame_width = image.width();
        self.frame_height = image.height();
        self.last_time_ms = time_ms;
        let (analysis_frame, offset_x, offset_y) = crop_analysis_roi_reuse(
            &image,
            &self.analysis_roi,
            &mut self.roi_work_buffer,
            &mut self.roi_work_dimensions,
        )?;
        let local_net_roi = relative_roi(&self.config.net_roi, &self.analysis_roi);
        let local_net_motion_roi = self
            .net_motion_roi
            .as_ref()
            .map(|roi| relative_roi(roi, &self.analysis_roi));
        self.push_image_with_source(
            time_ms,
            analysis_frame,
            image.width(),
            image.height(),
            offset_x,
            offset_y,
            self.crop_scale,
            self.crop_scale,
            &local_net_roi,
            local_net_motion_roi.as_ref(),
        )
    }

    fn push_image_with_source(
        &mut self,
        time_ms: i64,
        analysis_frame: RgbImage,
        source_width: u32,
        source_height: u32,
        offset_x: u32,
        offset_y: u32,
        coordinate_scale: f32,
        scale: f32,
        net_roi: &Roi,
        net_motion_roi: Option<&Roi>,
    ) -> Result<FrameResponse, RuntimeError> {
        if self.config.inference_batch_size > 1 && !self.batch_failed {
            self.pending_frames.push(PendingFrame {
                time_ms,
                analysis_frame,
                source_width,
                source_height,
                offset_x,
                offset_y,
                coordinate_scale,
                scale,
                net_roi: net_roi.clone(),
                net_motion_roi: net_motion_roi.cloned(),
            });
            if self.pending_frames.len() < self.config.inference_batch_size {
                return Ok(FrameResponse {
                    detections: Vec::new(),
                    candidates: Vec::new(),
                    processed_frames: self.processed_frames,
                });
            }
            return self.flush_pending_frames();
        }
        self.frame_width = source_width;
        self.frame_height = source_height;
        self.last_time_ms = time_ms;
        if !self.config.detection_only {
            self.update_net_motion(time_ms, &analysis_frame, net_roi, net_motion_roi);
        }
        let resized_frame = if (scale - 1.0).abs() < f32::EPSILON {
            None
        } else {
            let width = (analysis_frame.width() as f32 * scale).round() as u32;
            let height = (analysis_frame.height() as f32 * scale).round() as u32;
            Some(resize_reuse(
                &analysis_frame,
                width.max(1),
                height.max(1),
                FilterType::CatmullRom,
                &mut self.resized_work_buffer,
                &mut self.resized_work_dimensions,
            ))
        };
        let inference_frame = resized_frame.as_ref().unwrap_or(&analysis_frame);
        let crop_detections = detect_image(
            &mut self.session,
            inference_frame,
            self.config.confidence_threshold,
            self.model_size,
            &mut self.model_input_buffer,
        );
        if let Some(resized_frame) = resized_frame {
            self.resized_work_buffer = resized_frame.into_raw();
        }
        let crop_detections = crop_detections?;
        let detections = remap_detections(
            crop_detections,
            offset_x,
            offset_y,
            source_width,
            source_height,
            coordinate_scale,
        );
        self.processed_frames += 1;
        if self.config.detection_only {
            self.rgb_work_buffer = analysis_frame.into_raw();
            return Ok(FrameResponse {
                detections,
                candidates: Vec::new(),
                processed_frames: self.processed_frames,
            });
        }
        self.update_rim_from_detections(&detections, source_width, source_height);
        let balls: Vec<_> = detections
            .iter()
            .filter(|detection| detection.class_id == 0)
            .map(|ball| {
                let (x, y) = center(ball);
                (
                    x / source_width as f32,
                    y / source_height as f32,
                    ball.confidence,
                    (ball.x2 - ball.x1).max(1.0) / source_width as f32,
                    (ball.y2 - ball.y1).max(1.0) / source_height as f32,
                )
            })
            .collect();
        if self.config.coarse_mode {
            if let Some(point) = balls
                .iter()
                .copied()
                .max_by(|left, right| left.2.total_cmp(&right.2))
            {
                self.coarse_points
                    .push((time_ms, point.0, point.1, point.2, point.3, point.4));
            }
            self.rgb_work_buffer = analysis_frame.into_raw();
            return Ok(FrameResponse {
                detections,
                candidates: Vec::new(),
                processed_frames: self.processed_frames,
            });
        }
        self.ball_history
            .extend(balls.iter().map(|(x, y, confidence, width, height)| {
                (time_ms, *x, *y, *confidence, *width, *height)
            }));
        self.ball_history.retain(|point| point.0 >= time_ms - 5_000);
        let updated_tracks = self.push_ball_detections(time_ms, balls);
        let legacy_track_id = self.update_legacy_track();
        for track_id in updated_tracks.into_iter().chain(legacy_track_id) {
            self.detect_crossing(track_id);
        }
        for (source_track_id, points) in recover_track_points(
            &self.tracks,
            &self.ball_history,
            &self.rim_roi,
            self.frame_width,
            self.frame_height,
            self.config.max_cross_gap_ms,
        ) {
            let already_present = self.tracks.iter().any(|track| {
                track.id != source_track_id
                    && track.points.len() >= points.len()
                    && track
                        .points
                        .last()
                        .zip(points.last())
                        .is_some_and(|(left, right)| {
                            left.0 == right.0
                                && (left.1 - right.1).abs() < 0.1 / self.frame_width.max(1) as f32
                                && (left.2 - right.2).abs() < 0.1 / self.frame_height.max(1) as f32
                        })
            });
            if already_present {
                continue;
            }
            let last = points.last().copied().expect("recovery track is non-empty");
            let track_id = self.next_track_id;
            self.next_track_id += 1;
            self.tracks.push(BallTrack {
                id: track_id,
                points,
                last_width: last.4,
                last_height: last.5,
            });
            self.detect_crossing(track_id);
        }
        self.resolve_verdict();
        // Keep every resolved crossing in the review queue. Python exposes
        // missed/rebound crossings for manual review as well; only the
        // automatic-export gate excludes them.
        let visible_candidates =
            dedupe_runtime_candidates(self.candidates.clone(), self.config.dedupe_ms);
        self.rgb_work_buffer = analysis_frame.into_raw();
        Ok(FrameResponse {
            detections,
            candidates: visible_candidates,
            processed_frames: self.processed_frames,
        })
    }

    fn flush_pending_frames(&mut self) -> Result<FrameResponse, RuntimeError> {
        let pending = std::mem::take(&mut self.pending_frames);
        if pending.is_empty() {
            return Ok(FrameResponse {
                detections: Vec::new(),
                candidates: Vec::new(),
                processed_frames: self.processed_frames,
            });
        }
        let batch_result = detect_pending_frames_batch(
            &mut self.session,
            &pending,
            self.config.confidence_threshold,
            self.model_size,
            &mut self.model_input_buffer,
            &mut self.batch_model_input_buffer,
        );
        let detections_by_frame = match batch_result {
            Ok(value) => value,
            Err(_) => {
                self.batch_failed = true;
                let mut fallback = Vec::with_capacity(pending.len());
                for frame in &pending {
                    let resized;
                    let image = if (frame.scale - 1.0).abs() < f32::EPSILON {
                        &frame.analysis_frame
                    } else {
                        resized = resize(
                            &frame.analysis_frame,
                            (frame.analysis_frame.width() as f32 * frame.scale)
                                .round()
                                .max(1.0) as u32,
                            (frame.analysis_frame.height() as f32 * frame.scale)
                                .round()
                                .max(1.0) as u32,
                            FilterType::CatmullRom,
                        );
                        &resized
                    };
                    fallback.push(detect_image(
                        &mut self.session,
                        image,
                        self.config.confidence_threshold,
                        self.model_size,
                        &mut self.model_input_buffer,
                    )?);
                }
                fallback
            }
        };
        let mut aggregate_detections = Vec::new();
        for (frame, crop_detections) in pending.into_iter().zip(detections_by_frame) {
            self.frame_width = frame.source_width;
            self.frame_height = frame.source_height;
            self.last_time_ms = frame.time_ms;
            if !self.config.detection_only {
                self.update_net_motion(
                    frame.time_ms,
                    &frame.analysis_frame,
                    &frame.net_roi,
                    frame.net_motion_roi.as_ref(),
                );
            }
            let detections = remap_detections(
                crop_detections,
                frame.offset_x,
                frame.offset_y,
                frame.source_width,
                frame.source_height,
                frame.coordinate_scale,
            );
            aggregate_detections.extend(detections.iter().cloned());
            self.processed_frames += 1;
            if self.config.detection_only {
                continue;
            }
            self.update_rim_from_detections(&detections, frame.source_width, frame.source_height);
            let balls: Vec<_> = detections
                .iter()
                .filter(|detection| detection.class_id == 0)
                .map(|ball| {
                    let (x, y) = center(ball);
                    (
                        x / frame.source_width as f32,
                        y / frame.source_height as f32,
                        ball.confidence,
                        (ball.x2 - ball.x1).max(1.0) / frame.source_width as f32,
                        (ball.y2 - ball.y1).max(1.0) / frame.source_height as f32,
                    )
                })
                .collect();
            if self.config.coarse_mode {
                if let Some(point) = balls
                    .iter()
                    .copied()
                    .max_by(|left, right| left.2.total_cmp(&right.2))
                {
                    self.coarse_points.push((
                        frame.time_ms,
                        point.0,
                        point.1,
                        point.2,
                        point.3,
                        point.4,
                    ));
                }
                continue;
            }
            self.ball_history
                .extend(balls.iter().map(|(x, y, confidence, width, height)| {
                    (frame.time_ms, *x, *y, *confidence, *width, *height)
                }));
            self.ball_history
                .retain(|point| point.0 >= frame.time_ms - 5_000);
            let updated_tracks = self.push_ball_detections(frame.time_ms, balls);
            let legacy_track_id = self.update_legacy_track();
            for track_id in updated_tracks.into_iter().chain(legacy_track_id) {
                self.detect_crossing(track_id);
            }
            for (source_track_id, points) in recover_track_points(
                &self.tracks,
                &self.ball_history,
                &self.rim_roi,
                self.frame_width,
                self.frame_height,
                self.config.max_cross_gap_ms,
            ) {
                let already_present =
                    self.tracks.iter().any(|track| {
                        track.id != source_track_id
                            && track.points.len() >= points.len()
                            && track.points.last().zip(points.last()).is_some_and(
                                |(left, right)| {
                                    left.0 == right.0
                                        && (left.1 - right.1).abs()
                                            < 0.1 / self.frame_width.max(1) as f32
                                        && (left.2 - right.2).abs()
                                            < 0.1 / self.frame_height.max(1) as f32
                                },
                            )
                    });
                if already_present {
                    continue;
                }
                let last = points.last().copied().expect("recovery track is non-empty");
                let track_id = self.next_track_id;
                self.next_track_id += 1;
                self.tracks.push(BallTrack {
                    id: track_id,
                    points,
                    last_width: last.4,
                    last_height: last.5,
                });
                self.detect_crossing(track_id);
            }
            self.resolve_verdict();
        }
        Ok(FrameResponse {
            detections: aggregate_detections,
            candidates: if self.config.coarse_mode || self.config.detection_only {
                Vec::new()
            } else {
                dedupe_runtime_candidates(self.candidates.clone(), self.config.dedupe_ms)
            },
            processed_frames: self.processed_frames,
        })
    }

    fn push_ball_detections(
        &mut self,
        time_ms: i64,
        detections: Vec<(f32, f32, f32, f32, f32)>,
    ) -> Vec<u64> {
        associate_ball_tracks(
            &mut self.tracks,
            &mut self.next_track_id,
            time_ms,
            detections,
            self.rim_roi.right - self.rim_roi.left,
            self.frame_width,
            self.frame_height,
        )
    }

    /// Keep the desktop fallback track in the streaming runtime as well.
    /// Python runs this confidence-flattened track alongside the motion
    /// tracker; omitting it made a clean single-ball sequence disappear on
    /// mobile when the multi-track association briefly split it.
    fn update_legacy_track(&mut self) -> Option<u64> {
        let points = continuous_flatten_balls(
            &self.ball_history,
            0.2,
            500,
            self.rim_roi.right - self.rim_roi.left,
            self.frame_width,
            self.frame_height,
        );
        if points.len() < 2 {
            return None;
        }
        let track_id = if let Some(track_id) = self.legacy_track_id {
            if let Some(track) = self.tracks.iter_mut().find(|track| track.id == track_id) {
                track.points = points;
                let last = track.points.last().copied().unwrap();
                track.last_width = last.4;
                track.last_height = last.5;
                return Some(track_id);
            }
            track_id
        } else {
            let track_id = self.next_track_id;
            self.next_track_id += 1;
            track_id
        };
        let last = points.last().copied().unwrap();
        self.tracks.push(BallTrack {
            id: track_id,
            points,
            last_width: last.4,
            last_height: last.5,
        });
        self.legacy_track_id = Some(track_id);
        Some(track_id)
    }

    fn update_rim_from_detections(&mut self, detections: &[Detection], width: u32, height: u32) {
        // A supplied rim is the user's/desktop-calibrated geometry contract;
        // never let a later model box silently replace it. Auto calibration
        // is only for mobile sessions that omit `rim`.
        let observations: Vec<_> = detections
            .iter()
            .filter(|detection| detection.class_id == 1)
            .cloned()
            .collect();
        if observations.is_empty() {
            return;
        }
        self.rim_observations.extend(observations);
        // The PC coarse scan takes a median over the entire proxy video.
        // Keep that complete observation set in coarse mode; the fine
        // streaming path only needs a bounded history for online calibration.
        if !self.config.coarse_mode && self.rim_observations.len() > 64 {
            let keep_from = self.rim_observations.len() - 64;
            self.rim_observations.drain(..keep_from);
        }
        if self.config.coarse_mode || self.config.rim.is_some() {
            return;
        }
        if self.rim_observations.len() < 2 {
            return;
        }
        // Match Python's stable-hoop selection instead of taking a median of
        // every hoop box. A player/scoreboard false positive must not move the
        // physical rim used by the crossing geometry.
        // Detection boxes are kept in decoded pixel coordinates here. The
        // Python selector uses the same pixel-space radius; using 60 / width
        // would make a 1920px frame cluster only nearly identical boxes.
        let radius = 60.0_f32.max(width as f32 * 0.10);
        let mut clusters: Vec<Vec<Detection>> = Vec::new();
        for observation in &self.rim_observations {
            let center_x = (observation.x1 + observation.x2) / 2.0;
            let center_y = (observation.y1 + observation.y2) / 2.0;
            let mut best_index = None;
            let mut best_distance = f32::MAX;
            for (index, cluster) in clusters.iter().enumerate() {
                let cluster_x = median_f32(
                    &mut cluster
                        .iter()
                        .map(|item| (item.x1 + item.x2) / 2.0)
                        .collect::<Vec<_>>(),
                );
                let cluster_y = median_f32(
                    &mut cluster
                        .iter()
                        .map(|item| (item.y1 + item.y2) / 2.0)
                        .collect::<Vec<_>>(),
                );
                let distance =
                    ((center_x - cluster_x).powi(2) + (center_y - cluster_y).powi(2)).sqrt();
                if distance <= radius && distance < best_distance {
                    best_index = Some(index);
                    best_distance = distance;
                }
            }
            if let Some(index) = best_index {
                clusters[index].push(observation.clone());
            } else {
                clusters.push(vec![observation.clone()]);
            }
        }
        let Some(selected) = clusters
            .into_iter()
            .filter(|cluster| cluster.len() >= 2)
            .max_by(|left, right| {
                let mut left_confidence =
                    left.iter().map(|item| item.confidence).collect::<Vec<_>>();
                let mut right_confidence =
                    right.iter().map(|item| item.confidence).collect::<Vec<_>>();
                let mut left_area = left
                    .iter()
                    .map(|item| (item.x2 - item.x1) * (item.y2 - item.y1))
                    .collect::<Vec<_>>();
                let mut right_area = right
                    .iter()
                    .map(|item| (item.x2 - item.x1) * (item.y2 - item.y1))
                    .collect::<Vec<_>>();
                left.len()
                    .cmp(&right.len())
                    .then_with(|| {
                        median_f32(&mut left_confidence)
                            .total_cmp(&median_f32(&mut right_confidence))
                    })
                    .then_with(|| {
                        median_f32(&mut left_area).total_cmp(&median_f32(&mut right_area))
                    })
            })
        else {
            return;
        };
        let mut left = selected.iter().map(|item| item.x1).collect::<Vec<_>>();
        let mut top = selected.iter().map(|item| item.y1).collect::<Vec<_>>();
        let mut right = selected.iter().map(|item| item.x2).collect::<Vec<_>>();
        let mut bottom = selected.iter().map(|item| item.y2).collect::<Vec<_>>();
        let selected_bbox = Detection {
            class_id: 1,
            confidence: median_f32(
                &mut selected
                    .iter()
                    .map(|item| item.confidence)
                    .collect::<Vec<_>>(),
            ),
            x1: median_f32(&mut left),
            y1: median_f32(&mut top),
            x2: median_f32(&mut right),
            y2: median_f32(&mut bottom),
        };
        self.rim_roi = hoop_detection_to_rim(&selected_bbox, width, height);
        self.rim_calibrated = true;
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
    detections: Vec<(f32, f32, f32, f32, f32)>,
    rim_width: f32,
    frame_width: u32,
    frame_height: u32,
) -> Vec<u64> {
    let rim_width_px = rim_width.max(0.01) * frame_width.max(1) as f32;
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
        let last_ball_size_px = (track.last_width * frame_width.max(1) as f32)
            .max(track.last_height * frame_height.max(1) as f32);
        let gate_px = (1.75 * rim_width_px)
            .max((12.0 * rim_width_px).min(45.0 * rim_width_px * gap_s + 2.0 * last_ball_size_px));
        for (detection_index, (x, y, _, _, _)) in detections.iter().enumerate() {
            let distance = (((x - predicted_x) * frame_width.max(1) as f32).powi(2)
                + ((y - predicted_y) * frame_height.max(1) as f32).powi(2))
            .sqrt();
            if distance <= gate_px {
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
        let (x, y, confidence, width, height) = detections[detection_index];
        let track = &mut tracks[track_index];
        track
            .points
            .push((time_ms, x, y, confidence, width, height));
        track.last_width = width;
        track.last_height = height;
        updated.push(track.id);
    }
    for (detection_index, (x, y, confidence, width, height)) in detections.into_iter().enumerate() {
        if used_detections.contains(&detection_index) {
            continue;
        }
        let track_id = *next_track_id;
        *next_track_id += 1;
        tracks.push(BallTrack {
            id: track_id,
            points: vec![(time_ms, x, y, confidence, width, height)],
            last_width: width,
            last_height: height,
        });
        updated.push(track_id);
    }
    updated
}

fn continuous_flatten_balls(
    points: &[BallPoint],
    min_confidence: f32,
    max_gap_ms: i64,
    rim_width: f32,
    frame_width: u32,
    frame_height: u32,
) -> Vec<BallPoint> {
    let mut ordered = points.to_vec();
    ordered.sort_by_key(|point| point.0);
    let mut flattened = Vec::new();
    let mut index = 0;
    while index < ordered.len() {
        let time_ms = ordered[index].0;
        let mut best = ordered[index];
        index += 1;
        while index < ordered.len() && ordered[index].0 == time_ms {
            if ordered[index].3 > best.3 {
                best = ordered[index];
            }
            index += 1;
        }
        if best.3 >= min_confidence {
            flattened.push(best);
        }
    }
    if flattened.len() < 2 {
        return Vec::new();
    }

    let frame_width = frame_width.max(1) as f32;
    let frame_height = frame_height.max(1) as f32;
    let rim_width_px = rim_width.max(0.01) * frame_width;
    for pair in flattened.windows(2) {
        let previous = pair[0];
        let current = pair[1];
        let gap_ms = current.0 - previous.0;
        if gap_ms <= 0 || gap_ms > max_gap_ms {
            return Vec::new();
        }
        let gap_s = gap_ms as f32 / 1_000.0;
        let distance =
            ((current.1 - previous.1) * frame_width).hypot((current.2 - previous.2) * frame_height);
        // Keep the legacy flatten gate identical to Python: the previous
        // detection determines the tolerated ball size. Including the
        // current box makes a newly inflated/misdetected box widen the gate.
        let point_size_px = 2.0 * (previous.4 * frame_width).max(previous.5 * frame_height);
        let gate = (1.75 * rim_width_px)
            .max((12.0 * rim_width_px).min(45.0 * rim_width_px * gap_s + point_size_px));
        if distance > gate {
            return Vec::new();
        }
    }
    flattened
}

/// Stitches a short detector handoff back into the original trajectory.
///
/// A ball can disappear at the rim and reappear as a new track below the net.
/// Only a below-net point whose interpolated crossing is inside the rim and
/// whose own track already has post-rim persistence is eligible. This keeps a
/// nearby player's ball from being joined merely because it is visible after
/// an occlusion.
fn recover_track_points(
    tracks: &[BallTrack],
    raw_points: &[BallPoint],
    rim: &Roi,
    frame_width: u32,
    frame_height: u32,
    max_cross_gap_ms: i64,
) -> Vec<(u64, Vec<BallPoint>)> {
    let rim_y = (rim.top + rim.bottom) / 2.0;
    let frame_width_f = frame_width.max(1) as f32;
    let frame_height_f = frame_height.max(1) as f32;
    let rim_height = (rim.bottom - rim.top).max(1.0 / frame_height_f);
    let rim_width = (rim.right - rim.left).max(1.0 / frame_width_f);
    let above_y = rim_y - 0.6 * rim_height;
    let below_y = rim_y + 0.9 * rim_height;
    let (rim_width_px, _) = rim_pixel_dimensions(rim, frame_width, frame_height);
    let rim_height_for_crossing_px = ((rim.bottom - rim.top) * frame_height_f).max(8.0);
    let below_depth = rim_y
        + (rim_width_px * 0.35 / frame_height_f)
            .max(rim_height_for_crossing_px * 0.5 / frame_height_f);
    let center_x = (rim.left + rim.right) / 2.0;
    let half_width = rim_width / 2.0;
    let gate_margin = rim_width * 0.1;
    let mut recoveries = Vec::new();

    for source in tracks.iter().filter(|track| track.points.len() >= 2) {
        let mut best: Option<(f32, i64, i64, Vec<BallPoint>)> = None;
        for above in source.points.iter().copied() {
            if above.2 > above_y {
                continue;
            }
            let source_has_same_detection = |below: BallPoint| {
                source.points.iter().any(|point| {
                    (point.0 - below.0).abs() < 1
                        && (point.1 - below.1).abs() < 0.1 / frame_width.max(1) as f32
                        && (point.2 - below.2).abs() < 0.1 / frame_height.max(1) as f32
                })
            };
            for below in raw_points.iter().copied() {
                let gap = below.0 - above.0;
                if !(0..=max_cross_gap_ms).contains(&gap) || below.2 < below_y {
                    continue;
                }
                if source_has_same_detection(below) {
                    continue;
                }
                let Some((_, crossing_x)) = crossing_at_rim(above, below, rim_y) else {
                    continue;
                };
                if crossing_x < rim.left - gate_margin || crossing_x > rim.right + gate_margin {
                    continue;
                }
                let post: Vec<_> =
                    post_corridor_points(raw_points, below, rim, frame_width, frame_height)
                        .into_iter()
                        .filter(|point| point.2 >= below_depth)
                        .collect();
                if post.len() < 2 {
                    continue;
                }

                let transition = raw_points.iter().copied().filter(|point| {
                    point.0 >= above.0
                        && point.0 <= below.0
                        && point.2 >= rim_y - 1.5 * rim_height
                        && point.2 <= rim_y + 0.5 * rim_height
                        && point_in_rim_corridor(point, center_x, half_width, 0.25, frame_width)
                });
                let mut stitched: Vec<_> = source
                    .points
                    .iter()
                    .copied()
                    .filter(|point| point.0 <= above.0)
                    .chain(transition)
                    .chain(post_corridor_points(
                        raw_points,
                        below,
                        rim,
                        frame_width,
                        frame_height,
                    ))
                    .collect();
                stitched.sort_by_key(|point| point.0);
                stitched.dedup_by(|left, right| {
                    left.0 == right.0
                        && (left.1 - right.1).abs() < 1e-6
                        && (left.2 - right.2).abs() < 1e-6
                });
                let rank = ((crossing_x - center_x).abs(), -(post.len() as i64), gap);
                if best
                    .as_ref()
                    .is_none_or(|(distance, best_post_count, best_gap, _)| {
                        rank < (*distance, *best_post_count, *best_gap)
                    })
                {
                    best = Some((rank.0, rank.1, rank.2, stitched));
                }
            }
        }
        if let Some((_, _, _, points)) = best {
            recoveries.push((source.id, points));
        }
    }
    recoveries
}

fn post_corridor_points(
    raw_points: &[BallPoint],
    below: BallPoint,
    rim: &Roi,
    frame_width: u32,
    frame_height: u32,
) -> Vec<BallPoint> {
    let rim_width_px = (rim.right - rim.left).max(0.01) * frame_width.max(1) as f32;
    let mut ordered = raw_points.to_vec();
    ordered.sort_by_key(|point| point.0);
    let mut result = vec![below];
    let mut previous = below;
    let mut index = 0;
    while index < ordered.len() {
        let time_ms = ordered[index].0;
        if time_ms <= below.0 {
            index += 1;
            continue;
        }
        if time_ms > below.0 + 800 {
            break;
        }
        if time_ms - previous.0 > 250 {
            break;
        }
        let mut detections = Vec::new();
        while index < ordered.len() && ordered[index].0 == time_ms {
            detections.push(ordered[index]);
            index += 1;
        }
        let gap_s = (time_ms - previous.0) as f32 / 1_000.0;
        let predicted = if result.len() >= 2 {
            let prior = result[result.len() - 2];
            let dt = ((previous.0 - prior.0) as f32 / 1_000.0).max(0.001);
            (
                previous.1 + (previous.1 - prior.1) / dt * gap_s,
                previous.2 + (previous.2 - prior.2) / dt * gap_s,
            )
        } else {
            (previous.1, previous.2)
        };
        // Match Python's recovery gate: only the previous accepted box size
        // contributes to the jump allowance; a new oversized detection must
        // not widen the gate before it has been accepted.
        let point_size_px = 2.0
            * (previous.4 * frame_width.max(1) as f32).max(previous.5 * frame_height.max(1) as f32);
        let gate = (1.75 * rim_width_px)
            .max((12.0 * rim_width_px).min(45.0 * rim_width_px * gap_s + point_size_px));
        let Some(next) = detections
            .into_iter()
            .filter(|point| {
                point_in_rim_corridor(
                    point,
                    (rim.left + rim.right) / 2.0,
                    (rim.right - rim.left) / 2.0,
                    0.35,
                    frame_width,
                ) && (((point.1 - predicted.0) * frame_width.max(1) as f32).powi(2)
                    + ((point.2 - predicted.1) * frame_height.max(1) as f32).powi(2))
                .sqrt()
                    <= gate
            })
            .min_by(|left, right| {
                let left_distance = ((left.1 - predicted.0) * frame_width.max(1) as f32)
                    .hypot((left.2 - predicted.1) * frame_height.max(1) as f32);
                let right_distance = ((right.1 - predicted.0) * frame_width.max(1) as f32)
                    .hypot((right.2 - predicted.1) * frame_height.max(1) as f32);
                left_distance
                    .total_cmp(&right_distance)
                    .then_with(|| right.3.total_cmp(&left.3))
            })
        else {
            break;
        };
        previous = next;
        result.push(next);
    }
    result
}

impl RuntimeSession {
    /// Three-zone net motion analysis (mirrors desktop algorithm).
    ///
    /// A made basket should produce activity in the net's lower zone
    /// followed by activity in the zone below it (ball enters net top,
    /// pushes through, drops below). Simultaneous activation suggests
    /// camera shake; reversed order (below before lower) is suspicious.
    fn update_net_motion(
        &mut self,
        time_ms: i64,
        image: &RgbImage,
        net_roi: &Roi,
        net_motion_roi: Option<&Roi>,
    ) {
        let current_zones = net_zone_grays(image, net_roi);
        let (components, changed_ratios) =
            net_pixel_components(image, net_roi, &current_zones, &self.net_gray_history);
        let lower_inside = zone_inside_score(components[1], changed_ratios[1]);
        let below_inside = zone_inside_score(components[2], changed_ratios[2]);
        let whole = components
            .iter()
            .flat_map(|values| values.iter().copied())
            .fold(0.0, f32::max);
        let (motion, global_changed) = net_motion_roi
            .map(|roi| net_global_motion(image, roi, &self.previous_net_gray))
            .unwrap_or((0.0, 0.0));
        let measurement_valid = self.net_gray_history.len() >= 5;
        if measurement_valid {
            self.net_zone_history.push(NetHistoryPoint {
                time_ms,
                measurement_valid: true,
                lower_inside,
                below_inside,
                upper_components: components[0],
                lower_components: components[1],
                below_components: components[2],
                motion,
                changed_ratio: global_changed,
                whole,
            });
        }
        self.net_gray_history.push((time_ms, current_zones));
        if self.net_gray_history.len() > 15 {
            self.net_gray_history.remove(0);
        }
        self.previous_net_gray = net_motion_roi
            .map(|roi| net_gray(image, roi))
            .unwrap_or_default();

        // Trim history to ±2s around the newest event.
        let cutoff = time_ms - 3000;
        let first_relevant = self
            .net_zone_history
            .iter()
            .position(|point| point.time_ms >= cutoff)
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
            candidate.net_motion_score = candidate.net_motion_score.max(evidence.motion_score);
            candidate.net_inside_motion_score =
                candidate.net_inside_motion_score.max(evidence.inside_score);
            candidate.net_sequence_score =
                candidate.net_sequence_score.max(evidence.sequence_score);
            candidate.net_score = candidate.net_score.max(evidence.score);
            candidate.net_changed_ratio = candidate.net_changed_ratio.max(evidence.changed_ratio);
            candidate.net_lower_peak = candidate.net_lower_peak.max(evidence.lower_peak);
            candidate.net_below_peak = candidate.net_below_peak.max(evidence.below_peak);
            candidate.net_support |= evidence.support;
            candidate.signals = candidate_signals(candidate);
        }
    }

    /// Resolve verdict from accumulated evidence using the desktop decision
    /// semantics. Candidate creation stays optimistic for recall; the delayed
    /// decision requires the same post-crossing evidence categories as Python.
    fn resolve_verdict(&mut self) {
        if !self.rim_calibrated {
            return;
        }
        // Decision timing follows source-frame time, not the last successful
        // ball detection. A detector miss after the crossing must still allow
        // the 800ms verification window to close.
        let current_time = self.last_time_ms;
        let rim = &self.rim_roi;
        let tracks = self.tracks.clone();

        for candidate in &mut self.candidates {
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
                self.frame_width,
                self.frame_height,
            );
            let post = post_crossing_evidence(
                &track.points,
                candidate.below.time_ms,
                rim,
                self.frame_width,
                self.frame_height,
            );
            candidate.ball_persistence = post.persistence;
            candidate.post_crossing_points = post.post_crossing_points;
            candidate.rebound |= post.rebound;
            candidate.lateral_exit = post.lateral_exit;
            candidate.post_crossing_lateral_recovery = post.lateral_recovery;

            let net = net_zone_evidence(&self.net_zone_history, candidate.event_ms);
            candidate.net_signal_available = net.signal_available;
            candidate.net_support = net.support;
            candidate.net_no_motion = net.no_motion;
            candidate.net_motion_score = net.motion_score;
            candidate.net_inside_motion_score = net.inside_score;
            candidate.net_sequence_score = net.sequence_score;
            candidate.net_score = net.score;
            candidate.net_changed_ratio = net.changed_ratio;
            candidate.net_lower_peak = net.lower_peak;
            candidate.net_below_peak = net.below_peak;
            let gates = calibrated_gates_with_dimensions(
                &track.points,
                candidate.above.time_ms,
                candidate.below.time_ms,
                rim,
                &net,
                candidate.complete_crossing,
                self.frame_width,
                self.frame_height,
            );
            let later = continuous_post_points(
                &track.points,
                ball_point_from_evidence(&candidate.below),
                rim,
                self.frame_width,
                self.frame_height,
            );
            candidate.composite_score = score_crossing(
                ball_point_from_evidence(&candidate.above),
                ball_point_from_evidence(&candidate.below),
                &later,
                &track.points,
                candidate.trajectory_score,
                candidate.net_score,
                candidate.net_inside_motion_score,
                candidate.horizontal_ratio,
                rim,
                self.frame_width,
                self.frame_height,
            );
            let positive_gate = if candidate.net_signal_available {
                candidate.net_support
            } else {
                gates.high_precision
                    || candidate.net_score >= 0.55
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
            let mut final_gates = gates;
            // Python clears the nested automatic gate for every non-made
            // verdict. Keep the raw gate for confidence calculation, but
            // persist the same post-verdict export contract as desktop.
            final_gates.automatic_goal = candidate.verdict == "made" && gates.automatic_goal;
            candidate.auto_export_eligible = final_gates.automatic_goal;
            candidate.confidence_label =
                confidence_label(candidate.composite_score, candidate.net_score, &gates);
            candidate.decision_time_ms = Some(candidate.below.time_ms + 800);
            refresh_candidate_evidence(candidate, &final_gates, "confirmed");
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
                    width: Some(point.4),
                    height: Some(point.5),
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
        if !self.rim_calibrated {
            return;
        }
        let Some(track) = self.tracks.iter().find(|track| track.id == track_id) else {
            return;
        };
        let points = track.points.clone();
        let rim_y = (self.rim_roi.top + self.rim_roi.bottom) / 2.0;
        let frame_width_f = self.frame_width.max(1) as f32;
        let frame_height_f = self.frame_height.max(1) as f32;
        let rim_width = (self.rim_roi.right - self.rim_roi.left).max(1.0 / frame_width_f);
        // Python's refined crossing search uses an 8px minimum rim height.
        // Apply that minimum in normalized coordinates before deriving the
        // above/below bands; otherwise small detector boxes create a tighter
        // mobile crossing band and different candidates.
        let rim_height = (self.rim_roi.bottom - self.rim_roi.top).max(8.0 / frame_height_f);
        let rim_center_x = (self.rim_roi.left + self.rim_roi.right) / 2.0;
        let rim_left = rim_center_x - rim_width / 2.0;
        let rim_right = rim_center_x + rim_width / 2.0;
        let above_y = rim_y - 0.6 * rim_height;
        let below_y = rim_y + 0.9 * rim_height;
        let gate_margin = (rim_right - rim_left) * 0.1;

        // Python does not require the below point to be adjacent: at a low
        // sample rate the ball can have an intermediate rim-band point. Keep
        // the same 1.8s search horizon and select the first valid deep below
        // point, rather than fabricating a crossing from a shallow sample.
        for (index, above) in points.iter().copied().enumerate() {
            if above.2 > above_y {
                continue;
            }
            if index + 1 < points.len() && points[index + 1].2 <= above_y {
                continue;
            }
            for below in points[index + 1..].iter().copied() {
                if below.0 <= above.0 {
                    continue;
                }
                if below.0 - above.0 > self.config.max_cross_gap_ms {
                    break;
                }
                if below.2 < below_y || below.2 <= above.2 {
                    continue;
                }
                let intermediate_side_deviation = points.iter().any(|point| {
                    point.0 > above.0
                        && point.0 < below.0
                        && point.2 >= rim_y - 1.5 * rim_height
                        && point.2 <= rim_y + 0.5 * rim_height
                        && !point_in_rim_corridor(
                            point,
                            (rim_left + rim_right) / 2.0,
                            (rim_right - rim_left) / 2.0,
                            0.15,
                            self.frame_width,
                        )
                        && (point.1 - (rim_left + rim_right) / 2.0).abs()
                            <= (rim_right - rim_left) * 4.0
                });
                if intermediate_side_deviation {
                    break;
                }
                let Some((crossing, crossing_x)) = crossing_at_rim(above, below, rim_y) else {
                    continue;
                };
                if crossing_x < rim_left - gate_margin || crossing_x > rim_right + gate_margin {
                    continue;
                }

                let event_ms = crossing_event_ms(above, below, rim_y).unwrap_or_else(|| {
                    above.0 + ((below.0 - above.0) as f32 * crossing).round() as i64
                });

                // Keep the same evidence windows as Python. `recent` used to
                // keep only the last 12 detections, which made the mobile
                // predictor and score depend on the detector sample rate.
                // Python fits prediction on the complete pre-crossing event
                // track and computes trajectory/score from the full track.
                let event_track = event_track_points(&points, above.0, below.0);

                let (trajectory_score, approach_span_px) = trajectory_features(
                    &points,
                    above,
                    below,
                    &self.rim_roi,
                    self.frame_width,
                    self.frame_height,
                );
                let crossing_score = (1.0
                    - ((crossing_x - (rim_left + rim_right) / 2.0).abs()
                        / ((rim_right - rim_left) / 2.0).max(1e-6)))
                .clamp(0.0, 1.0);
                let rim_center_x = (rim_left + rim_right) / 2.0;
                let rim_half_width = (rim_right - rim_left) / 2.0;
                let prediction = prediction_evidence_for_frame(
                    &event_track,
                    rim_y,
                    rim_center_x,
                    rim_half_width,
                    self.frame_height,
                );
                let prediction_review = prediction_reviewable_for_frame(
                    &event_track,
                    rim_y,
                    rim_center_x,
                    rim_half_width,
                    self.frame_height,
                );
                let later = continuous_post_points(
                    &points,
                    below,
                    &self.rim_roi,
                    self.frame_width,
                    self.frame_height,
                );
                let rim_width_px = rim_width * frame_width_f;
                let below_depth = (rim_width_px * 0.35 / frame_height_f).max(rim_height * 0.5);
                let post_rim_points = later
                    .iter()
                    .filter(|point| point.2 >= rim_y + below_depth.max(rim_height * 0.5))
                    .count();
                if !self.config.coarse_mode && post_rim_points < 2 && !prediction_review {
                    continue;
                }
                let transition_points: Vec<_> = points
                    .iter()
                    .filter(|point| {
                        point.0 >= above.0
                            && point.0 <= below.0
                            && point.2 >= rim_y - 1.5 * rim_height
                            && point.2 <= rim_y + 0.5 * rim_height
                    })
                    .collect();
                let transition_inside = transition_points
                    .iter()
                    .filter(|point| {
                        point_in_rim_corridor(
                            point,
                            (rim_left + rim_right) / 2.0,
                            (rim_right - rim_left) / 2.0,
                            0.15,
                            self.frame_width,
                        )
                    })
                    .count();
                let crossing_inside = crossing_x >= rim_left && crossing_x <= rim_right;
                let reviewable_crossing = crossing_inside
                    && (transition_points.is_empty()
                        || transition_inside as f32 / transition_points.len() as f32 >= 0.75);
                if !self.config.coarse_mode && !reviewable_crossing && !prediction_review {
                    continue;
                }
                let post = post_crossing_evidence(
                    &points,
                    below.0,
                    &self.rim_roi,
                    self.frame_width,
                    self.frame_height,
                );
                if !self.config.coarse_mode
                    && (post.rebound || (post.lateral_exit && !post.lateral_recovery))
                {
                    continue;
                }
                let gap_s = ((below.0 - above.0) as f32 / 1_000.0).max(0.001);
                let speed_px_s = (below.2 - above.2).max(0.0) * self.frame_height as f32 / gap_s;
                let horizontal_ratio = ((below.1 - above.1).abs() * self.frame_width as f32)
                    / ((below.2 - above.2).max(0.0001) * self.frame_height as f32);
                if horizontal_ratio > 0.95 {
                    break;
                }
                if speed_px_s / rim_width_px.max(1.0) > 16.0 {
                    continue;
                }
                let trajectory = overlay_trajectory(&points, event_ms);
                let complete_crossing = complete_rim_crossing(
                    &points,
                    above.0,
                    below.0,
                    &self.rim_roi,
                    self.frame_width,
                    self.frame_height,
                );
                let initial_gates = calibrated_gates_with_dimensions(
                    &points,
                    above.0,
                    below.0,
                    &self.rim_roi,
                    &NetEvidence::default(),
                    complete_crossing,
                    self.frame_width,
                    self.frame_height,
                );
                let mut candidate = Candidate {
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
                    confidence_label: "low".into(),
                    speed_px_s,
                    horizontal_ratio,
                    approach_horizontal_span_px: approach_span_px,
                    speed_per_rim: speed_px_s / rim_width_px.max(1.0),
                    approach_span_per_rim: approach_span_px / rim_width_px.max(1.0),
                    trajectory_score,
                    crossing_score,
                    net_score: 0.0,
                    net_motion_score: 0.0,
                    net_inside_motion_score: 0.0,
                    net_changed_ratio: 0.0,
                    net_sequence_score: 0.0,
                    prediction_score: prediction
                        .as_ref()
                        .map(|value| value.predict_score)
                        .unwrap_or(0.0),
                    prediction,
                    prediction_review,
                    composite_score: score_crossing(
                        above,
                        below,
                        &later,
                        &points,
                        trajectory_score,
                        0.0,
                        0.0,
                        horizontal_ratio,
                        &self.rim_roi,
                        self.frame_width,
                        self.frame_height,
                    ),
                    trajectory,
                    above: EvidencePoint {
                        time_ms: above.0,
                        x: above.1,
                        y: above.2,
                        confidence: above.3,
                        width: Some(above.4),
                        height: Some(above.5),
                    },
                    below: EvidencePoint {
                        time_ms: below.0,
                        x: below.1,
                        y: below.2,
                        confidence: below.3,
                        width: Some(below.4),
                        height: Some(below.5),
                    },
                    crossing: EvidencePoint {
                        time_ms: event_ms,
                        x: crossing_x,
                        y: rim_y,
                        confidence: (above.3 + below.3) / 2.0,
                        width: None,
                        height: None,
                    },
                    reason: "uncertain".into(),
                    verdict: "ambiguous".into(),
                    complete_crossing,
                    rebound: post.rebound,
                    lateral_exit: post.lateral_exit,
                    post_crossing_lateral_recovery: post.lateral_recovery,
                    post_crossing_points: post.post_crossing_points,
                    ball_persistence: post.persistence,
                    net_signal_available: false,
                    net_support: false,
                    net_no_motion: false,
                    net_lower_peak: 0.0,
                    net_below_peak: 0.0,
                    auto_export_eligible: false,
                    decision_time_ms: None,
                    algorithm_version: ANALYSIS_CONTRACT_VERSION.into(),
                    evidence_source: "rust_onnx:analysis-contract-v1".into(),
                    signals: serde_json::json!({}),
                    gates: serde_json::json!({}),
                    verification: serde_json::json!({}),
                };
                refresh_candidate_evidence(&mut candidate, &initial_gates, "pending");
                if let Some(index) = self.candidates.iter().position(|current| {
                    current.track_id == track_id
                        && current.above.time_ms == above.0
                        && current.below.time_ms == below.0
                }) {
                    if runtime_candidate_priority(&candidate)
                        > runtime_candidate_priority(&self.candidates[index])
                    {
                        self.candidates[index] = candidate;
                    }
                } else {
                    self.candidates.push(candidate);
                }
                // Don't clear all ball points — the ball continues to be tracked
                // after a made shot. Only trim to prevent re-detecting the same
                // crossing (the duplicate check above handles this).
                break;
            }
        }
    }
}

/// Direct port of Python `find_candidate_crossings` for the coarse pass.
///
/// The coarse pass intentionally has no track, net, rebound or verdict gate:
/// it only finds high-recall time windows for the native-frame refiner.
fn coarse_crossing_candidates(
    points: &[BallPoint],
    rim: &Roi,
    frame_width: u32,
    frame_height: u32,
    config: &RuntimeConfig,
) -> Vec<Candidate> {
    let frame_width_f = frame_width.max(1) as f32;
    let frame_height_f = frame_height.max(1) as f32;
    let rim_y = (rim.top + rim.bottom) / 2.0;
    let rim_width_px = ((rim.right - rim.left) * frame_width_f).max(1.0);
    let rim_left = (rim.left + rim.right) / 2.0 - (rim.right - rim.left) / 2.0;
    let rim_right = (rim.left + rim.right) / 2.0 + (rim.right - rim.left) / 2.0;
    let pixel_scale = rim_width_px / 50.0;
    let above_clearance = (3.0_f32.max(8.0 * pixel_scale)) / frame_height_f;
    let below_clearance = (4.0_f32.max(10.0 * pixel_scale)) / frame_height_f;
    let crossing_margin = (4.0_f32.max(16.0 * pixel_scale)) / frame_width_f;
    let minimum_descent = (8.0_f32.max(20.0 * pixel_scale)) / frame_height_f;
    let mut ordered = points.to_vec();
    ordered.sort_by_key(|point| point.0);
    let mut candidates = Vec::new();

    for (index, above) in ordered.iter().copied().enumerate() {
        if above.2 > rim_y - above_clearance {
            continue;
        }
        for below in ordered[index + 1..].iter().copied() {
            let gap_ms = below.0 - above.0;
            if gap_ms <= 0 {
                continue;
            }
            if gap_ms > 2_500 {
                break;
            }
            if below.2 < rim_y + below_clearance || below.2 - above.2 < minimum_descent {
                continue;
            }
            let Some((_, crossing_x)) = crossing_at_rim(above, below, rim_y) else {
                continue;
            };
            if crossing_x < rim_left - crossing_margin || crossing_x > rim_right + crossing_margin {
                continue;
            }
            // Python's coarse event is the midpoint, rounded to centiseconds,
            // rather than the refined interpolated rim-plane time.
            let event_ms = (((above.0 + below.0) as f64 / 20.0).round() * 10.0) as i64;
            if candidates
                .last()
                .is_some_and(|candidate: &Candidate| event_ms - candidate.event_ms <= 800)
            {
                break;
            }
            let crossing = EvidencePoint {
                time_ms: event_ms,
                x: crossing_x,
                y: rim_y,
                confidence: (above.3 + below.3) / 2.0,
                width: None,
                height: None,
            };
            candidates.push(Candidate {
                id: format!("coarse_{event_ms}"),
                track_id: 0,
                start_ms: (event_ms - config.clip_before_ms).max(0),
                end_ms: clip_end_ms(event_ms, config.clip_after_ms, config.duration_ms),
                event_ms,
                confidence: (above.3 + below.3) / 2.0,
                confidence_label: "review".into(),
                speed_px_s: (below.2 - above.2) * frame_height_f
                    / (gap_ms as f32 / 1_000.0).max(0.001),
                horizontal_ratio: ((below.1 - above.1) * frame_width_f).abs()
                    / ((below.2 - above.2) * frame_height_f).max(1.0),
                approach_horizontal_span_px: 0.0,
                speed_per_rim: 0.0,
                approach_span_per_rim: 0.0,
                trajectory_score: 0.0,
                crossing_score: 0.0,
                net_score: 0.0,
                net_motion_score: 0.0,
                net_changed_ratio: 0.0,
                net_inside_motion_score: 0.0,
                net_sequence_score: 0.0,
                prediction_score: 0.0,
                prediction: None,
                prediction_review: false,
                composite_score: 0.0,
                trajectory: vec![evidence_point(above), evidence_point(below)],
                above: evidence_point(above),
                below: evidence_point(below),
                crossing,
                reason: "coarse_crossing".into(),
                verdict: "ambiguous".into(),
                complete_crossing: false,
                rebound: false,
                lateral_exit: false,
                post_crossing_lateral_recovery: false,
                post_crossing_points: 0,
                ball_persistence: 0.0,
                net_signal_available: false,
                net_support: false,
                net_no_motion: false,
                net_lower_peak: 0.0,
                net_below_peak: 0.0,
                auto_export_eligible: false,
                decision_time_ms: None,
                algorithm_version: "analysis-contract-v1".into(),
                evidence_source: "coarse_crossing".into(),
                signals: serde_json::json!({}),
                gates: serde_json::json!({}),
                verification: serde_json::json!({}),
            });
            break;
        }
    }
    candidates
}

fn evidence_point(point: BallPoint) -> EvidencePoint {
    EvidencePoint {
        time_ms: point.0,
        x: point.1,
        y: point.2,
        confidence: point.3,
        width: Some(point.4),
        height: Some(point.5),
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

fn ball_point_from_evidence(point: &EvidencePoint) -> BallPoint {
    (
        point.time_ms,
        point.x,
        point.y,
        point.confidence,
        point.width.unwrap_or(0.0),
        point.height.unwrap_or(0.0),
    )
}

fn crossing_at_rim(above: BallPoint, below: BallPoint, rim_y: f32) -> Option<(f32, f32)> {
    if !(above.2 < rim_y && below.2 >= rim_y && below.2 > above.2) {
        return None;
    }
    let crossing = ((rim_y - above.2) / (below.2 - above.2).max(1e-6)).clamp(0.0, 1.0);
    let crossing_x = above.1 + (below.1 - above.1) * crossing;
    Some((crossing, crossing_x))
}

fn components_or_legacy(components: [f32; 4], legacy: f32) -> [f32; 4] {
    if components.iter().all(|value| *value == 0.0) && legacy != 0.0 {
        [legacy, 0.0, 0.0, 0.0]
    } else {
        components
    }
}

fn crossing_event_ms(above: BallPoint, below: BallPoint, rim_y: f32) -> Option<i64> {
    let denominator = below.2 as f64 - above.2 as f64;
    if !((above.2 as f64) < (rim_y as f64)
        && (below.2 as f64) >= (rim_y as f64)
        && (below.2 as f64) > (above.2 as f64)
        && denominator > 0.0)
    {
        return None;
    }
    let ratio = (rim_y as f64 - above.2 as f64) / denominator;
    let value = above.0 as f64 + (below.0 - above.0) as f64 * ratio;
    // Python exposes crossing time rounded to 4 decimal seconds before
    // converting to milliseconds. `value` is already in milliseconds, so
    // first round to a tenth of a millisecond, then apply the shared
    // non-banker's millisecond rule. Do not multiply by 1,000 again.
    let rounded_tenth_ms = (value * 10.0 + 0.5).floor() / 10.0;
    Some((rounded_tenth_ms + 0.5).floor() as i64)
}

fn rim_pixel_dimensions(rim: &Roi, frame_width: u32, frame_height: u32) -> (f32, f32) {
    let frame_width = frame_width.max(1) as f32;
    let frame_height = frame_height.max(1) as f32;
    (
        (rim.right - rim.left).max(1.0 / frame_width) * frame_width,
        (rim.bottom - rim.top).max(1.0 / frame_height) * frame_height,
    )
}

fn continuous_post_points(
    points: &[BallPoint],
    below: BallPoint,
    rim: &Roi,
    frame_width: u32,
    frame_height: u32,
) -> Vec<BallPoint> {
    let (rim_width_px, rim_height_px) = rim_pixel_dimensions(rim, frame_width, frame_height);
    let mut later = vec![below];
    let mut previous = below;
    let mut ordered: Vec<_> = points
        .iter()
        .copied()
        .filter(|point| point.0 > below.0 && point.0 <= below.0 + 800)
        .collect();
    ordered.sort_by_key(|point| point.0);
    for point in ordered {
        let gap = (point.0 - previous.0) as f32 / 1_000.0;
        if gap <= 0.0 {
            continue;
        }
        if (previous.2 - point.2) * frame_height.max(1) as f32 > 2.0_f32.max(rim_height_px * 0.30)
            && (point.1 - previous.1).abs() * frame_width.max(1) as f32 > 1.5 * rim_width_px
        {
            break;
        }
        let distance = (((point.1 - previous.1) * frame_width.max(1) as f32).powi(2)
            + ((point.2 - previous.2) * frame_height.max(1) as f32).powi(2))
        .sqrt();
        let point_size_px = 2.0
            * (previous.4 * frame_width.max(1) as f32)
                .max(previous.5 * frame_height.max(1) as f32)
                .max(point.4 * frame_width.max(1) as f32)
                .max(point.5 * frame_height.max(1) as f32);
        let gate = (1.75 * rim_width_px)
            .max((12.0 * rim_width_px).min(45.0 * rim_width_px * gap + point_size_px));
        if distance > gate {
            break;
        }
        later.push(point);
        previous = point;
    }
    later
}

#[cfg(test)]
fn complete_crossing(points: &[BallPoint], rim_y: f32, rim_left: f32, rim_right: f32) -> bool {
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
    points: &[BallPoint],
    above_time_ms: i64,
    below_time_ms: i64,
    rim: &Roi,
    frame_width: u32,
    frame_height: u32,
) -> bool {
    let rim_y = (rim.top + rim.bottom) / 2.0;
    let frame_width_f = frame_width.max(1) as f32;
    let frame_height_f = frame_height.max(1) as f32;
    let rim_height = (rim.bottom - rim.top).max(8.0 / frame_height_f);
    let rim_width = (rim.right - rim.left).max(1.0 / frame_width_f);
    let center_x = (rim.left + rim.right) / 2.0;
    let half_width = rim_width / 2.0;
    let rim_left = center_x - half_width;
    let rim_right = center_x + half_width;
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
    if !(rim_left..=rim_right).contains(&crossing_x) {
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
        .filter(|point| point_in_rim_corridor(point, center_x, half_width, 0.15, frame_width))
        .count();
    let (rim_width_px, _) = rim_pixel_dimensions(rim, frame_width, frame_height);
    let rim_height_for_crossing_px = ((rim.bottom - rim.top) * frame_height_f).max(8.0);
    let below_depth = rim_y
        + (rim_width_px * 0.35 / frame_height_f)
            .max(rim_height_for_crossing_px * 0.5 / frame_height_f);
    let later = continuous_post_points(points, below, rim, frame_width, frame_height);
    let post: Vec<_> = later
        .iter()
        .copied()
        .filter(|point| point.2 >= below_depth)
        .collect();
    let post_inside = post
        .iter()
        .take(3)
        .filter(|point| {
            let fall = (point.2 - below_depth).max(0.0);
            let fall_x = fall * frame_height.max(1) as f32 / frame_width.max(1) as f32;
            let allowance = rim_width * 0.35 + fall_x * 0.35;
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
    point: &BallPoint,
    center_x: f32,
    half_width: f32,
    tolerance_ratio: f32,
    frame_width: u32,
) -> bool {
    let half_width = half_width.max(1.0 / frame_width.max(1) as f32);
    let ball_half_width = (2.0 / frame_width.max(1) as f32).max(point.4 * 0.5);
    let tolerance = (half_width * tolerance_ratio).min(ball_half_width);
    point.1 >= center_x - half_width - tolerance && point.1 <= center_x + half_width + tolerance
}

fn post_crossing_evidence(
    points: &[BallPoint],
    below_time_ms: i64,
    rim: &Roi,
    frame_width: u32,
    frame_height: u32,
) -> PostCrossingEvidence {
    let rim_y = (rim.top + rim.bottom) / 2.0;
    let frame_width_f = frame_width.max(1) as f32;
    let frame_height_f = frame_height.max(1) as f32;
    let rim_height = (rim.bottom - rim.top).max(1.0 / frame_height_f);
    let rim_width = (rim.right - rim.left).max(1.0 / frame_width_f);
    let center_x = (rim.left + rim.right) / 2.0;
    let half_width = rim_width / 2.0;
    let Some(below) = points
        .iter()
        .copied()
        .find(|point| point.0 == below_time_ms)
    else {
        return PostCrossingEvidence::default();
    };
    let later = continuous_post_points(points, below, rim, frame_width, frame_height);
    if later.is_empty() {
        return PostCrossingEvidence::default();
    }
    let (rim_width_px, rim_height_px) = rim_pixel_dimensions(rim, frame_width, frame_height);
    let below_depth =
        rim_y + (rim_width_px * 0.35 / frame_height_f).max(rim_height_px * 0.5 / frame_height_f);
    let persistence_points: Vec<_> = later
        .iter()
        .copied()
        .filter(|point| point.2 >= below_depth)
        .collect();
    let rebound_zone_bottom =
        rim_y + (2.5 * rim_height_px / frame_height_f).max(2.5 * rim_width_px / frame_height_f);
    let mut previous_y = below.2;
    let mut rebound = false;
    let rebound_delta =
        (rim_width_px * 0.25 / frame_height_f).max(rim_height_px * 0.18 / frame_height_f);
    for point in later.iter().skip(1) {
        if point.2 >= rebound_zone_bottom {
            break;
        }
        if point.2 < previous_y - rebound_delta {
            rebound = true;
            break;
        }
        previous_y = point.2;
    }
    let lateral_exit = later.iter().any(|point| {
        (point.1 - center_x).abs() > 3.0 * half_width
            && point.2 <= rim_y + (4.0 * rim_height).max(4.0 * rim_width_px / frame_height_f)
    });
    let deep_corridor = persistence_points
        .iter()
        .filter(|point| (point.1 - center_x).abs() <= half_width)
        .count();
    let lateral_recovery =
        lateral_exit && persistence_points.len() >= 3 && deep_corridor == 1 && !rebound;
    PostCrossingEvidence {
        persistence: (persistence_points.len() as f32 / 3.0).min(1.0),
        post_crossing_points: later.len(),
        rebound,
        // Python treats the single deep in-corridor sample as a recovery
        // exception and clears the lateral-exit evidence before returning it.
        lateral_exit: lateral_exit && !lateral_recovery,
        lateral_recovery,
    }
}

pub fn evaluate_decision_replay(request: DecisionReplayRequest) -> DecisionReplayResult {
    let mut points: Vec<_> = request
        .trajectory
        .iter()
        .map(ball_point_from_evidence)
        .collect();
    points.push(ball_point_from_evidence(&request.above));
    points.push(ball_point_from_evidence(&request.below));
    points.sort_by_key(|point| point.0);
    points.dedup_by(|left, right| left.0 == right.0);

    let computed_complete_crossing = complete_rim_crossing(
        &points,
        request.above.time_ms,
        request.below.time_ms,
        &request.hoop_roi,
        request.frame_width.unwrap_or(1),
        request.frame_height.unwrap_or(1),
    );
    let computed_post = post_crossing_evidence(
        &points,
        request.below.time_ms,
        &request.hoop_roi,
        request.frame_width.unwrap_or(1),
        request.frame_height.unwrap_or(1),
    );
    let complete_crossing = request
        .candidate_complete_crossing
        .unwrap_or(computed_complete_crossing);
    let persistence = request
        .candidate_ball_persistence
        .unwrap_or(computed_post.persistence);
    let rebound = request.candidate_rebound.unwrap_or(computed_post.rebound);
    let lateral_exit = request
        .candidate_lateral_exit
        .unwrap_or(computed_post.lateral_exit);
    let lateral_recovery = request
        .candidate_post_crossing_lateral_recovery
        .unwrap_or(computed_post.lateral_recovery);
    let history: Vec<_> = request
        .net_history
        .iter()
        .map(|point| NetHistoryPoint {
            time_ms: point.time_ms,
            // Legacy replay records predate the explicit validity bit and
            // Python treats those measurements as usable. Only an explicit
            // false disables the sample.
            measurement_valid: point.measurement_valid.unwrap_or(true),
            lower_inside: if point.lower_inside == 0.0 {
                point.lower
            } else {
                point.lower_inside
            },
            below_inside: if point.below_inside == 0.0 {
                point.below
            } else {
                point.below_inside
            },
            upper_components: components_or_legacy(point.upper_components, point.upper),
            lower_components: components_or_legacy(point.lower_components, point.lower),
            below_components: components_or_legacy(point.below_components, point.below),
            motion: point.motion,
            changed_ratio: point.changed_ratio,
            whole: point.whole,
        })
        .collect();
    let rim_y = (request.hoop_roi.top + request.hoop_roi.bottom) / 2.0;
    let event_ms = crossing_event_ms(
        ball_point_from_evidence(&request.above),
        ball_point_from_evidence(&request.below),
        rim_y,
    )
    .unwrap_or(request.below.time_ms);
    let mut net = net_zone_evidence(&history, event_ms);
    if let Some(value) = request.candidate_net_signal_available {
        net.signal_available = value;
    }
    if let Some(value) = request.candidate_net_no_motion {
        net.no_motion = value;
    }
    if let Some(value) = request.candidate_net_support {
        net.support = value;
    }
    if let Some(value) = request.candidate_net_inside_motion_score {
        net.inside_score = value;
    }
    if let Some(value) = request.candidate_net_sequence_score {
        net.sequence_score = value;
    }
    if let Some(value) = request.candidate_net_lower_peak {
        net.lower_peak = value;
    }
    if let Some(value) = request.candidate_net_below_peak {
        net.below_peak = value;
    }
    if let Some(value) = request.candidate_net_score {
        net.score = value;
    }
    if let Some(value) = request.candidate_net_motion_score {
        net.motion_score = value;
    }
    if let Some(value) = request.candidate_net_changed_ratio {
        net.changed_ratio = value;
    }
    let frame_width = request.frame_width.unwrap_or(1).max(1) as f32;
    let frame_height = request.frame_height.unwrap_or(1).max(1) as f32;
    let rim_width_px = ((request.hoop_roi.right - request.hoop_roi.left) * frame_width).max(1.0);
    let gap_s = ((request.below.time_ms - request.above.time_ms) as f32 / 1_000.0).max(0.001);
    let computed_speed = ((request.below.y - request.above.y).max(0.0) * frame_height / gap_s)
        / rim_width_px
        * 30.54;
    let computed_span = {
        let rim_y = (request.hoop_roi.top + request.hoop_roi.bottom) / 2.0;
        let approach: Vec<_> = points
            .iter()
            .copied()
            .filter(|point| {
                point.0 >= request.above.time_ms - 800
                    && point.0 <= request.above.time_ms
                    && point.2 <= rim_y - 0.25 * rim_width_px / frame_height
            })
            .collect();
        if approach.is_empty() {
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
            (max_x - min_x) * frame_width / rim_width_px * 30.54
        }
    };
    let computed_horizontal = ((request.below.x - request.above.x).abs() * frame_width)
        / ((request.below.y - request.above.y).max(0.001) * frame_height);
    let (trajectory_score, _) = trajectory_features(
        &points,
        ball_point_from_evidence(&request.above),
        ball_point_from_evidence(&request.below),
        &request.hoop_roi,
        request.frame_width.unwrap_or(1),
        request.frame_height.unwrap_or(1),
    );
    let later = continuous_post_points(
        &points,
        ball_point_from_evidence(&request.below),
        &request.hoop_roi,
        request.frame_width.unwrap_or(1),
        request.frame_height.unwrap_or(1),
    );
    let computed_score = score_crossing(
        ball_point_from_evidence(&request.above),
        ball_point_from_evidence(&request.below),
        &later,
        &points,
        trajectory_score,
        net.score,
        net.inside_score,
        computed_horizontal,
        &request.hoop_roi,
        request.frame_width.unwrap_or(1),
        request.frame_height.unwrap_or(1),
    );
    let gates = calibrated_gates_from_features(
        request
            .candidate_speed_per_rim
            .map(|value| value * 30.54)
            .unwrap_or(computed_speed),
        request
            .candidate_approach_span_per_rim
            .map(|value| value * 30.54)
            .unwrap_or(computed_span),
        request
            .candidate_horizontal_ratio
            .unwrap_or(computed_horizontal),
        &net,
        complete_crossing,
    );
    let positive_gate = if net.signal_available {
        net.support
    } else {
        gates.high_precision
            || net.score >= 0.55
            || request.candidate_score.unwrap_or(computed_score) >= 0.72
    };
    let verdict = if rebound || (lateral_exit && !lateral_recovery) {
        "missed"
    } else if persistence >= 0.67 && complete_crossing && positive_gate {
        "made"
    } else {
        "ambiguous"
    };
    DecisionReplayResult {
        algorithm_version: ANALYSIS_CONTRACT_VERSION.into(),
        event_ms,
        complete_crossing,
        ball_persistence: round3(persistence),
        rebound,
        lateral_exit,
        post_crossing_lateral_recovery: lateral_recovery,
        net_signal_available: net.signal_available,
        net_support: net.support,
        net_no_motion: net.no_motion,
        net_score: round3(net.score),
        net_motion_score: round3(net.motion_score),
        net_changed_ratio: round3(net.changed_ratio),
        net_inside_motion_score: round3(net.inside_score),
        net_sequence_score: round3(net.sequence_score),
        net_lower_peak: round3(net.lower_peak),
        net_below_peak: round3(net.below_peak),
        strict_low_speed: gates.strict_low_speed,
        high_speed_net: gates.high_speed_net,
        high_speed_drop: gates.high_speed_drop,
        high_precision: gates.high_precision,
        automatic_goal: verdict == "made" && gates.automatic_goal,
        review: gates.review,
        recall_review: gates.recall_review,
        verdict: verdict.into(),
        auto_export_eligible: verdict == "made" && gates.automatic_goal,
    }
}

#[allow(clippy::too_many_arguments)]
fn calibrated_gates_with_dimensions(
    points: &[BallPoint],
    above_time_ms: i64,
    below_time_ms: i64,
    rim: &Roi,
    net: &NetEvidence,
    complete_crossing: bool,
    frame_width: u32,
    frame_height: u32,
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
    let frame_width_f = frame_width.max(1) as f32;
    let frame_height_f = frame_height.max(1) as f32;
    let rim_width_px = ((rim.right - rim.left) * frame_width_f).max(1.0);
    let rim_width = rim_width_px / frame_width_f;
    let gap_s = ((below.0 - above.0) as f32 / 1_000.0).max(0.001);
    let speed = ((below.2 - above.2) * frame_height.max(1) as f32 / gap_s)
        / (rim_width * frame_width.max(1) as f32)
        * 30.54;
    let approach: Vec<_> = points
        .iter()
        .copied()
        .filter(|point| {
            point.0 >= above_time_ms - 800
                && point.0 <= above_time_ms
                && point.2 <= rim_y - 0.25 * rim_width_px / frame_height_f
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
        (max_x - min_x) * frame_width_f / rim_width_px * 30.54
    };
    let horizontal_ratio = ((below.1 - above.1).abs() * frame_width.max(1) as f32)
        / ((below.2 - above.2).max(0.001) * frame_height.max(1) as f32);
    // `speed` and `span` above are already rim-relative values projected
    // onto Python's 30.54px historical reference size.
    calibrated_gates_from_features(speed, span, horizontal_ratio, net, complete_crossing)
}

fn calibrated_gates_from_features(
    speed: f32,
    span: f32,
    horizontal_ratio: f32,
    net: &NetEvidence,
    complete_crossing: bool,
) -> CalibratedGates {
    let net_gate = if net.signal_available {
        net.support
    } else {
        net.motion_score >= 0.90
    };
    let high_speed_net = (150.0..=260.0).contains(&speed) && horizontal_ratio >= 0.50 && net_gate;
    let high_speed_drop = (150.0..=220.0).contains(&speed)
        && span <= 130.0
        && (!net.signal_available || net.support)
        && horizontal_ratio >= 0.55;
    let strict_low_speed = speed <= 95.0 && span <= 100.0;
    let review_low_speed = speed <= 95.0 && span <= 192.0;
    let review = review_low_speed || high_speed_net || high_speed_drop;
    let recall_review = review
        || net.score >= 0.45
        || (speed <= 110.0 && span <= 190.0)
        || (speed <= 260.0 && span <= 45.0 && horizontal_ratio <= 0.20);
    let high_precision = complete_crossing
        && (strict_low_speed || high_speed_net || high_speed_drop)
        && !net.no_motion;
    let automatic_goal = complete_crossing
        && !net.no_motion
        && (speed <= 102.0
            || strict_low_speed
            || high_speed_net
            || high_speed_drop
            || (!net.signal_available && net.changed_ratio >= 0.129));
    CalibratedGates {
        high_precision,
        automatic_goal,
        review,
        recall_review,
        strict_low_speed,
        high_speed_net,
        high_speed_drop,
    }
}

#[cfg(test)]
fn calibrated_gates(
    points: &[BallPoint],
    above_time_ms: i64,
    below_time_ms: i64,
    rim: &Roi,
    net: &NetEvidence,
    complete_crossing: bool,
) -> CalibratedGates {
    calibrated_gates_with_dimensions(
        points,
        above_time_ms,
        below_time_ms,
        rim,
        net,
        complete_crossing,
        1,
        1,
    )
}

fn confidence_label(score: f32, net_score: f32, gates: &CalibratedGates) -> String {
    if gates.high_precision && score >= 0.55 {
        "high".into()
    } else if (gates.review && score >= 0.42) || (score >= 0.48 && net_score >= 0.1) {
        "review".into()
    } else {
        "low".into()
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

fn intersect_roi(left: &Roi, right: &Roi) -> Option<Roi> {
    let roi = Roi {
        left: left.left.max(right.left),
        top: left.top.max(right.top),
        right: left.right.min(right.right),
        bottom: left.bottom.min(right.bottom),
    };
    (roi.right > roi.left && roi.bottom > roi.top).then_some(roi)
}

fn relative_roi(roi: &Roi, parent: &Roi) -> Roi {
    let width = (parent.right - parent.left).max(f32::EPSILON);
    let height = (parent.bottom - parent.top).max(f32::EPSILON);
    Roi {
        left: ((roi.left - parent.left) / width).clamp(0.0, 1.0),
        top: ((roi.top - parent.top) / height).clamp(0.0, 1.0),
        right: ((roi.right - parent.left) / width).clamp(0.0, 1.0),
        bottom: ((roi.bottom - parent.top) / height).clamp(0.0, 1.0),
    }
}

fn validate_model_input_shape(session: &Session, model_size: u32) -> Result<(), RuntimeError> {
    let input = session
        .inputs()
        .first()
        .ok_or_else(|| RuntimeError::InvalidRequest("model has no inputs".into()))?;
    let shape = input
        .dtype()
        .tensor_shape()
        .ok_or_else(|| RuntimeError::InvalidRequest("model input is not a tensor".into()))?;
    if shape.len() != 4 {
        return Err(RuntimeError::InvalidRequest(format!(
            "model input rank {} is not NCHW",
            shape.len()
        )));
    }
    if shape[1] >= 0 && shape[1] != 3 {
        return Err(RuntimeError::InvalidRequest(format!(
            "model input channel count {} is not 3",
            shape[1]
        )));
    }
    for (axis, dimension) in [(2, shape[2]), (3, shape[3])] {
        if dimension >= 0 && dimension != model_size as i64 {
            return Err(RuntimeError::InvalidRequest(format!(
                "model input shape {:?} does not match model_size {}",
                shape, model_size
            )));
        }
        if dimension == 0 {
            return Err(RuntimeError::InvalidRequest(format!(
                "model input dimension {} is invalid",
                axis
            )));
        }
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
    if config.max_cross_gap_ms <= 0 || config.dedupe_ms < 0 {
        return Err(RuntimeError::InvalidRequest(
            "crossing gap and dedupe window are invalid".into(),
        ));
    }
    if config.intra_threads == 0 || config.intra_threads > 8 {
        return Err(RuntimeError::InvalidRequest(
            "intra-op thread count is invalid".into(),
        ));
    }
    if config.inference_batch_size == 0 || config.inference_batch_size > 8 {
        return Err(RuntimeError::InvalidRequest(
            "inference batch size must be between 1 and 8".into(),
        ));
    }
    if config.model_size < 320 || !config.model_size.is_multiple_of(32) {
        return Err(RuntimeError::InvalidRequest(
            "model size must be a multiple of 32 and at least 320".into(),
        ));
    }
    if !config.crop_scale.is_finite() || !(1.0..=8.0).contains(&config.crop_scale) {
        return Err(RuntimeError::InvalidRequest(
            "crop scale must be between 1 and 8".into(),
        ));
    }
    Ok(())
}

fn clip_end_ms(event_ms: i64, after_ms: i64, duration_ms: Option<i64>) -> i64 {
    duration_ms
        .map(|duration| (event_ms + after_ms).min(duration))
        .unwrap_or(event_ms + after_ms)
}

fn roi_pixel_bounds_for_dimensions(width: u32, height: u32, roi: &Roi) -> (u32, u32, u32, u32) {
    let left = (roi.left.clamp(0.0, 1.0) * width as f32).floor() as u32;
    let top = (roi.top.clamp(0.0, 1.0) * height as f32).floor() as u32;
    let right = ((roi.right.clamp(0.0, 1.0) * width as f32).ceil() as u32)
        .min(width)
        .max((left + 1).min(width));
    let bottom = ((roi.bottom.clamp(0.0, 1.0) * height as f32).ceil() as u32)
        .min(height)
        .max((top + 1).min(height));
    (
        left.min(width.saturating_sub(1)),
        top.min(height.saturating_sub(1)),
        right,
        bottom,
    )
}

fn source_coordinates_for_rotation(
    logical_x: u32,
    logical_y: u32,
    source_width: u32,
    source_height: u32,
    rotation: i32,
) -> (u32, u32) {
    match rotation {
        90 => (logical_y, source_height - 1 - logical_x),
        180 => (source_width - 1 - logical_x, source_height - 1 - logical_y),
        270 => (source_width - 1 - logical_y, logical_x),
        _ => (logical_x, logical_y),
    }
}

fn roi_pixel_bounds(image: &RgbImage, roi: &Roi) -> (u32, u32, u32, u32) {
    roi_pixel_bounds_for_dimensions(image.width(), image.height(), roi)
}

fn zone_rois(roi: &Roi) -> [Roi; 3] {
    let height = roi.bottom - roi.top;
    [
        Roi {
            left: roi.left,
            right: roi.right,
            top: roi.top,
            bottom: roi.top + height * 0.42,
        },
        Roi {
            left: roi.left,
            right: roi.right,
            top: roi.top + height * 0.28,
            bottom: roi.top + height * 0.74,
        },
        Roi {
            left: roi.left,
            right: roi.right,
            top: roi.top + height * 0.58,
            bottom: roi.bottom,
        },
    ]
}

fn net_gray(image: &RgbImage, roi: &Roi) -> Vec<u8> {
    let (left, top, right, bottom) = roi_pixel_bounds(image, roi);
    let width = (right - left) as usize;
    let mut values = Vec::with_capacity(width * (bottom - top) as usize);
    let source_width = image.width() as usize;
    let pixels = image.as_raw();
    for y in top as usize..bottom as usize {
        let row_start = (y * source_width + left as usize) * 3;
        let row_end = row_start + width * 3;
        for pixel in pixels[row_start..row_end].chunks_exact(3) {
            values.push(
                (0.299 * pixel[0] as f32 + 0.587 * pixel[1] as f32 + 0.114 * pixel[2] as f32)
                    .round()
                    .clamp(0.0, 255.0) as u8,
            );
        }
    }
    values
}

fn net_zone_grays(image: &RgbImage, roi: &Roi) -> [Vec<u8>; 3] {
    let rois = zone_rois(roi);
    std::array::from_fn(|index| net_gray(image, &rois[index]))
}

fn rgb_hsv(pixel: &image::Rgb<u8>) -> (f32, f32, f32) {
    let red = pixel[0] as f32 / 255.0;
    let green = pixel[1] as f32 / 255.0;
    let blue = pixel[2] as f32 / 255.0;
    let max = red.max(green).max(blue);
    let min = red.min(green).min(blue);
    let delta = max - min;
    let mut hue = if delta == 0.0 {
        0.0
    } else if max == red {
        60.0 * (((green - blue) / delta) % 6.0)
    } else if max == green {
        60.0 * ((blue - red) / delta + 2.0)
    } else {
        60.0 * ((red - green) / delta + 4.0)
    };
    if hue < 0.0 {
        hue += 360.0;
    }
    let saturation = if max == 0.0 { 0.0 } else { delta / max * 255.0 };
    (hue / 2.0, saturation, max * 255.0)
}

fn median_u8_background(history: &[(i64, [Vec<u8>; 3])], zone: usize, index: usize) -> f32 {
    let mut values = [0.0_f32; 16];
    let mut count = 0;
    for (_, zones) in history {
        if let Some(value) = zones[zone].get(index) {
            if count == values.len() {
                break;
            }
            values[count] = *value as f32;
            count += 1;
        }
    }
    median_f32(&mut values[..count])
}

fn median_blur_gray(values: &[f32], width: usize, height: usize) -> Vec<f32> {
    if width < 1 || height < 1 || values.len() != width * height {
        return values.to_vec();
    }
    let mut blurred = vec![0.0; values.len()];
    for y in 0..height {
        for x in 0..width {
            let mut neighborhood = [0.0_f32; 9];
            let mut count = 0;
            for yy in y.saturating_sub(1)..=(y + 1).min(height - 1) {
                for xx in x.saturating_sub(1)..=(x + 1).min(width - 1) {
                    neighborhood[count] = values[yy * width + xx];
                    count += 1;
                }
            }
            blurred[y * width + x] = median_f32(&mut neighborhood[..count]);
        }
    }
    blurred
}

fn net_pixel_components(
    image: &RgbImage,
    roi: &Roi,
    current: &[Vec<u8>; 3],
    history: &[(i64, [Vec<u8>; 3])],
) -> ([[f32; 4]; 3], [f32; 3]) {
    if history.len() < 5 {
        return ([[0.0; 4]; 3], [0.0; 3]);
    }
    let rois = zone_rois(roi);
    let mut components = [[0.0; 4]; 3];
    let mut changed_ratios = [0.0; 3];
    for zone in 0..3 {
        let values = &current[zone];
        if values.is_empty() {
            continue;
        }
        let (left, top, right, bottom) = roi_pixel_bounds(image, &rois[zone]);
        let width = (right - left) as usize;
        let height = (bottom - top) as usize;
        let background: Vec<_> = (0..values.len())
            .map(|index| median_u8_background(history, zone, index))
            .collect();
        let background = median_blur_gray(&background, width, height);
        let mut changed = 0usize;
        let mut orange = 0usize;
        let mut white = 0usize;
        for (index, value) in values.iter().enumerate() {
            let diff = (*value as f32 - background[index]).abs();
            if diff > 25.0 {
                changed += 1;
            }
            let x = left + (index % width) as u32;
            let y = top + (index / width) as u32;
            let pixel = image.get_pixel(x, y);
            let (hue, saturation, brightness) = rgb_hsv(pixel);
            if (0.0..=25.0).contains(&hue)
                && saturation >= 45.0
                && brightness >= 35.0
                && diff > 25.0
            {
                orange += 1;
            }
            if saturation <= 90.0 && brightness >= 145.0 && diff > 18.0 {
                white += 1;
            }
        }
        let area = values.len() as f32;
        let changed_ratio = changed as f32 / area;
        changed_ratios[zone] = changed_ratio;
        components[zone][0] = (changed_ratio / 0.12).clamp(0.0, 1.0);
        components[zone][1] = ((orange as f32 / area) / 0.035).clamp(0.0, 1.0);
        components[zone][2] = ((white as f32 / area) / 0.020).clamp(0.0, 1.0);
        // The native core does not include OpenCV's Farneback flow. Keep this
        // directional component neutral rather than inferring direction from
        // raw RGB differences; white motion remains available above.
    }
    (components, changed_ratios)
}

fn zone_inside_score(components: [f32; 4], changed_ratio: f32) -> f32 {
    components
        .iter()
        .copied()
        .fold((changed_ratio / 0.12).clamp(0.0, 1.0), f32::max)
}

fn net_global_motion(image: &RgbImage, roi: &Roi, previous: &[u8]) -> (f32, f32) {
    let current = net_gray(image, roi);
    if current.is_empty() || current.len() != previous.len() {
        return (0.0, 0.0);
    }
    let mut sum = 0.0;
    let mut changed = 0usize;
    for (value, old) in current.iter().zip(previous) {
        let diff = (*value as i32 - *old as i32).unsigned_abs() as f32;
        sum += diff;
        if diff > 15.0 {
            changed += 1;
        }
    }
    (
        sum / current.len() as f32,
        changed as f32 / current.len() as f32,
    )
}

/// Samples the upper, middle and lower thirds of the net separately. Motion
/// is calculated against the previous frame's local contrast signature rather
/// than the zone's absolute brightness.
#[cfg(test)]
fn net_zone_signatures(image: &RgbImage, roi: &Roi) -> [Vec<f32>; 3] {
    let height = roi.bottom - roi.top;
    // Keep the overlapping zones used by the desktop refiner when an
    // explicit net ROI is supplied. Disjoint thirds make the lower-zone
    // activation much weaker and change the meaning of net_support.
    let zone = |top_ratio: f32, bottom_ratio: f32| Roi {
        left: roi.left,
        right: roi.right,
        top: roi.top + height * top_ratio,
        bottom: roi.top + height * bottom_ratio,
    };
    [
        net_signature(image, &zone(0.0, 0.42)),
        net_signature(image, &zone(0.28, 0.74)),
        net_signature(image, &zone(0.58, 1.0)),
    ]
}

/// Computes inside-motion score and sequence score from zone history.
///
/// inside_score: how much the lower zone activated above baseline during
/// the event window (ball pushing through the net).
/// sequence_score: whether lower activated before below (correct order
/// for a made basket: ball enters net, then drops below).
#[cfg(test)]
fn net_zone_scores(history: &[NetHistoryPoint], event_ms: i64) -> (f32, f32) {
    let baseline: Vec<_> = history
        .iter()
        .filter(|point| point.time_ms < event_ms - 100 && point.time_ms >= event_ms - 800)
        .collect();
    let active: Vec<_> = history
        .iter()
        .filter(|point| point.time_ms >= event_ms - 100 && point.time_ms <= event_ms + 800)
        .collect();

    if active.len() < 2 || baseline.is_empty() {
        return (0.0, 0.0);
    }

    let baseline_lower =
        baseline.iter().map(|point| point.lower_inside).sum::<f32>() / baseline.len() as f32;
    let baseline_below =
        baseline.iter().map(|point| point.below_inside).sum::<f32>() / baseline.len() as f32;

    // Inside motion: how much the lower zone exceeded baseline.
    let max_lower_delta = active
        .iter()
        .map(|point| (point.lower_inside - baseline_lower).abs())
        .fold(0.0f32, f32::max);
    let inside_score = (max_lower_delta / 0.08).clamp(0.0, 1.0);

    // Sequence: did lower activate before below?
    let lower_first = active
        .iter()
        .find(|point| (point.lower_inside - baseline_lower).abs() > 0.03)
        .map(|point| point.time_ms);
    let below_first = active
        .iter()
        .find(|point| (point.below_inside - baseline_below).abs() > 0.03)
        .map(|point| point.time_ms);

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

fn net_zone_evidence(history: &[NetHistoryPoint], event_ms: i64) -> NetEvidence {
    let history: Vec<_> = history
        .iter()
        .filter(|point| point.measurement_valid)
        .collect();
    // Keep the legacy whole-net signal independent from the directional
    // three-zone signal. Python can still calculate this fallback when a
    // directional baseline/active window is incomplete.
    let mut motion_baseline: Vec<_> = history
        .iter()
        .filter(|point| point.time_ms >= event_ms - 500 && point.time_ms < event_ms - 100)
        .map(|point| point.motion)
        .collect();
    let mut all_motion: Vec<_> = history.iter().map(|point| point.motion).collect();
    let baseline_motion = if motion_baseline.is_empty() {
        median_f32(&mut all_motion)
    } else {
        median_f32(&mut motion_baseline)
    };
    let active_motion: Vec<_> = history
        .iter()
        .filter(|point| point.time_ms >= event_ms - 50 && point.time_ms <= event_ms + 800)
        .collect();
    let motion_peak = active_motion
        .iter()
        .map(|point| point.motion)
        .fold(baseline_motion, f32::max);
    let changed_ratio = active_motion
        .iter()
        .map(|point| point.changed_ratio)
        .fold(0.0, f32::max);
    let motion_score = ((motion_peak - baseline_motion).max(0.0) / 12.0)
        .max(changed_ratio / 0.35)
        .min(1.0);
    let baseline: Vec<_> = history
        .iter()
        .filter(|point| point.time_ms < event_ms - 100 && point.time_ms >= event_ms - 800)
        .collect();
    let active: Vec<_> = history
        .iter()
        .filter(|point| point.time_ms >= event_ms - 100 && point.time_ms <= event_ms + 800)
        .collect();
    if active.len() < 2 || baseline.is_empty() {
        return NetEvidence {
            motion_score,
            changed_ratio,
            ..NetEvidence::default()
        };
    }

    let mut lower_values: Vec<_> = baseline.iter().map(|point| point.lower_inside).collect();
    let mut below_values: Vec<_> = baseline.iter().map(|point| point.below_inside).collect();
    let baseline_lower = median_f32(&mut lower_values);
    let baseline_below = median_f32(&mut below_values);
    let lower_peak = active
        .iter()
        .map(|point| (point.lower_inside - baseline_lower).max(0.0))
        .fold(0.0_f32, f32::max);
    let below_peak = active
        .iter()
        .map(|point| (point.below_inside - baseline_below).max(0.0))
        .fold(0.0_f32, f32::max);
    let threshold = 0.25;
    let lower_first = active
        .iter()
        .find(|point| (point.lower_inside - baseline_lower).max(0.0) >= threshold)
        .map(|point| point.time_ms);
    let below_first = active
        .iter()
        .find(|point| (point.below_inside - baseline_below).max(0.0) >= threshold)
        .map(|point| point.time_ms);
    let sequence_score = match (lower_first, below_first) {
        (Some(lower), Some(below)) if below - lower >= 50 => 1.0,
        (Some(lower), Some(below)) if below >= lower && lower_peak >= 0.4 && below_peak >= 0.4 => {
            0.8
        }
        (Some(lower), Some(below)) if below >= lower => 0.45,
        (Some(_), Some(_)) => 0.15,
        (Some(_), None) => 0.45,
        (None, Some(_)) => 0.15,
        (None, None) => 0.0,
    };
    let active_count = active
        .iter()
        .filter(|point| {
            (point.lower_inside - baseline_lower).max(0.0) >= threshold
                || (point.below_inside - baseline_below).max(0.0) >= threshold
        })
        .count();
    let persistence = (active_count as f32 / 3.0).min(1.0);
    let inside_score =
        (0.55 * lower_peak + 0.25 * below_peak + 0.12 * sequence_score + 0.08 * persistence)
            .min(1.0);
    let mut multi_baseline_whole: Vec<_> = history
        .iter()
        .filter(|point| point.time_ms < event_ms - 200 && point.time_ms >= event_ms - 1_000)
        .map(|point| point.whole)
        .collect();
    let multi_baseline_whole_value = if multi_baseline_whole.is_empty() {
        0.0
    } else {
        median_f32(&mut multi_baseline_whole)
    };
    // Python computes the delta for each raw component first, then takes the
    // maximum. Taking the maximum component per frame before subtracting a
    // baseline is not equivalent when the dominant component changes between
    // the quiet and active windows.
    let component_delta = |zone: usize, component: usize| {
        let baseline_value = history
            .iter()
            .filter(|point| point.time_ms < event_ms - 200 && point.time_ms >= event_ms - 1_000)
            .map(|point| match zone {
                0 => point.upper_components[component],
                1 => point.lower_components[component],
                _ => point.below_components[component],
            })
            .collect::<Vec<_>>();
        let baseline_value = if baseline_value.is_empty() {
            0.0
        } else {
            let mut values = baseline_value;
            median_f32(&mut values)
        };
        history
            .iter()
            .filter(|point| point.time_ms >= event_ms - 100 && point.time_ms <= event_ms + 800)
            .map(|point| {
                let value = match zone {
                    0 => point.upper_components[component],
                    1 => point.lower_components[component],
                    _ => point.below_components[component],
                };
                (value - baseline_value).max(0.0)
            })
            .fold(0.0_f32, f32::max)
    };
    let component_peak = |zone: usize| {
        (0..4)
            .map(|component| component_delta(zone, component))
            .fold(0.0_f32, f32::max)
    };
    let multi_lower = component_peak(1);
    let multi_below = component_peak(2);
    let multi_upper = component_peak(0);
    let multi_whole = history
        .iter()
        .filter(|point| point.time_ms >= event_ms - 100 && point.time_ms <= event_ms + 800)
        .map(|point| (point.whole - multi_baseline_whole_value).max(0.0))
        .fold(0.0_f32, f32::max);
    let score = (0.55 * multi_lower + 0.25 * multi_below + 0.10 * multi_upper + 0.10 * multi_whole)
        .min(1.0);
    let baseline_quiet = baseline_lower < 0.35 && baseline_below < 0.35;
    let no_motion = active.len() >= 2
        && !baseline.is_empty()
        && baseline_quiet
        && lower_peak < 0.12
        && below_peak < 0.12
        && inside_score < 0.12;
    NetEvidence {
        signal_available: true,
        no_motion,
        inside_score,
        sequence_score,
        lower_peak,
        below_peak,
        support: inside_score >= 0.35 && sequence_score >= 0.80 && below_peak >= 0.25,
        score,
        motion_score,
        changed_ratio,
    }
}

#[cfg(test)]
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

#[cfg(test)]
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

fn preprocess_into(
    image: &RgbImage,
    model_size: u32,
    input_buffer: &mut Vec<f32>,
) -> Result<(f32, f32, f32), RuntimeError> {
    let (width, height) = image.dimensions();
    if width == 0 || height == 0 || model_size == 0 {
        return Err(RuntimeError::InvalidRequest("empty frame".into()));
    }
    let scale = (model_size as f32 / width as f32).min(model_size as f32 / height as f32);
    let resized = resize(
        image,
        (width as f32 * scale).round().max(1.0) as u32,
        (height as f32 * scale).round().max(1.0) as u32,
        FilterType::Triangle,
    );
    let offset_x = (model_size as i32 - resized.width() as i32).max(0) / 2;
    let offset_y = (model_size as i32 - resized.height() as i32).max(0) / 2;
    let input_len = (model_size as usize)
        .checked_mul(model_size as usize)
        .and_then(|size| size.checked_mul(3))
        .ok_or_else(|| RuntimeError::InvalidRequest("model size is too large".into()))?;
    if input_buffer.len() != input_len {
        input_buffer.resize(input_len, 114.0 / 255.0);
    } else {
        input_buffer.fill(114.0 / 255.0);
    }
    let plane_size = model_size as usize * model_size as usize;
    for (x, y, pixel) in resized.enumerate_pixels() {
        let xx = (x as i32 + offset_x) as usize;
        let yy = (y as i32 + offset_y) as usize;
        let index = yy * model_size as usize + xx;
        input_buffer[index] = pixel[0] as f32 / 255.0;
        input_buffer[plane_size + index] = pixel[1] as f32 / 255.0;
        input_buffer[plane_size * 2 + index] = pixel[2] as f32 / 255.0;
    }
    Ok((scale, offset_x as f32, offset_y as f32))
}

#[cfg(test)]
fn preprocess(
    image: &RgbImage,
    model_size: u32,
) -> Result<(Array4<f32>, f32, f32, f32), RuntimeError> {
    let mut buffer = Vec::new();
    let (scale, offset_x, offset_y) = preprocess_into(image, model_size, &mut buffer)?;
    let input = Array4::from_shape_vec((1, 3, model_size as usize, model_size as usize), buffer)
        .map_err(|error| RuntimeError::InvalidRequest(error.to_string()))?;
    Ok((input, scale, offset_x, offset_y))
}

#[cfg(test)]
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
#[cfg(test)]
fn prediction_score(
    points: &[BallPoint],
    rim_y: f32,
    rim_center_x: f32,
    rim_half_width: f32,
) -> f32 {
    prediction_score_with_clearance(points, rim_y, rim_center_x, rim_half_width, 0.01, 0.004)
        .map(|(_, score)| score)
        .unwrap_or(0.0)
}

fn prediction_evidence_for_frame(
    points: &[BallPoint],
    rim_y: f32,
    rim_center_x: f32,
    rim_half_width: f32,
    frame_height: u32,
) -> Option<PredictionEvidence> {
    let height = frame_height.max(1) as f32;
    let (landing_x, fit_r2, landing_center, predict_score, point_count) =
        prediction_result_with_clearance(
            points,
            rim_y,
            rim_center_x,
            rim_half_width,
            8.0 / height,
            2.0 / height,
        )?;
    Some(PredictionEvidence {
        landing_x: round3(landing_x),
        landing_y: round3(rim_y),
        landing_center: round3(landing_center),
        fit_r2: round3(fit_r2),
        point_count,
        predict_score: round3(predict_score),
    })
}

fn prediction_reviewable_for_frame(
    points: &[BallPoint],
    rim_y: f32,
    rim_center_x: f32,
    rim_half_width: f32,
    frame_height: u32,
) -> bool {
    let height = frame_height.max(1) as f32;
    prediction_score_with_clearance(
        points,
        rim_y,
        rim_center_x,
        rim_half_width,
        8.0 / height,
        2.0 / height,
    )
    .is_some_and(|(landing_center, score)| landing_center >= 0.5 && score >= 0.8)
}

fn prediction_score_with_clearance(
    points: &[BallPoint],
    rim_y: f32,
    rim_center_x: f32,
    rim_half_width: f32,
    clearance: f32,
    min_fall: f32,
) -> Option<(f32, f32)> {
    let (landing_x, _, _, predict_score, _) = prediction_result_with_clearance(
        points,
        rim_y,
        rim_center_x,
        rim_half_width,
        clearance,
        min_fall,
    )?;
    let landing_center =
        (1.0 - (landing_x - rim_center_x).abs() / rim_half_width.max(0.01)).clamp(0.0, 1.0);
    Some((landing_center, predict_score))
}

fn prediction_result_with_clearance(
    points: &[BallPoint],
    rim_y: f32,
    rim_center_x: f32,
    rim_half_width: f32,
    clearance: f32,
    min_fall: f32,
) -> Option<(f32, f32, f32, f32, usize)> {
    let above: Vec<_> = points
        .iter()
        .copied()
        .filter(|(_, _, y, _, _, _)| *y < rim_y - clearance)
        .collect();
    if above.len() < 5 {
        return None;
    }
    let apex = above
        .iter()
        .enumerate()
        .min_by(|(_, left), (_, right)| left.2.total_cmp(&right.2))
        .map(|(index, _)| index)
        .unwrap_or(0);
    let descent = &above[apex..];
    if descent.len() < 5 {
        return None;
    }
    let descent = &descent[descent.len().saturating_sub(8)..];
    if descent
        .last()
        .is_none_or(|last| last.2 <= descent[0].2 + min_fall)
        || descent.last().unwrap().0 - descent[0].0 < 120
    {
        return None;
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
    let (a, b, c) = fit_weighted_quadratic(&samples)?;
    let (x_slope, x_intercept) = fit_weighted_linear(&samples)?;
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
        return None;
    }
    let roots = if a.abs() < 1e-8 {
        if b.abs() < 1e-8 {
            return None;
        }
        vec![(rim_y - c) / b]
    } else {
        let discriminant = b * b - 4.0 * a * (c - rim_y);
        if discriminant < 0.0 {
            return None;
        }
        let root = discriminant.sqrt();
        vec![(-b - root) / (2.0 * a), (-b + root) / (2.0 * a)]
    };
    let time_to_rim = roots
        .into_iter()
        .filter(|root| *root > 0.0)
        .min_by(|left, right| left.total_cmp(right))?;
    let predicted_x = x_slope * time_to_rim + x_intercept;
    let distance = (predicted_x - rim_center_x).abs();
    let landing_center = (1.0 - distance / rim_half_width.max(0.01)).clamp(0.0, 1.0);
    Some((
        predicted_x,
        r2,
        landing_center,
        (0.6 * r2 + 0.4 * landing_center).clamp(0.0, 1.0),
        descent.len(),
    ))
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

fn event_track_points(
    points: &[BallPoint],
    above_time_ms: i64,
    below_time_ms: i64,
) -> Vec<BallPoint> {
    points
        .iter()
        .copied()
        .filter(|point| point.0 >= above_time_ms - 1_200 && point.0 <= below_time_ms)
        .collect()
}

fn overlay_trajectory(points: &[BallPoint], event_ms: i64) -> Vec<EvidencePoint> {
    let mut selected = event_track_points(points, event_ms, event_ms + 800);
    if selected.len() > 24 {
        let step = (selected.len() / 24).max(1);
        selected = selected.into_iter().step_by(step).take(24).collect();
    }
    selected
        .into_iter()
        .map(|point| EvidencePoint {
            time_ms: point.0,
            x: point.1,
            y: point.2,
            confidence: point.3,
            width: Some(point.4),
            height: Some(point.5),
        })
        .collect()
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

fn trajectory_features(
    points: &[BallPoint],
    above: BallPoint,
    below: BallPoint,
    rim: &Roi,
    frame_width: u32,
    frame_height: u32,
) -> (f32, f32) {
    let rim_y = (rim.top + rim.bottom) / 2.0;
    let frame_width_f = frame_width.max(1) as f32;
    let frame_height_f = frame_height.max(1) as f32;
    let rim_width_px = ((rim.right - rim.left) * frame_width_f).max(1.0);
    let mut approach: Vec<_> = points
        .iter()
        .copied()
        .filter(|point| {
            point.0 >= above.0 - 800
                && point.0 <= above.0
                && point.2 <= rim_y - 0.25 * rim_width_px / frame_height_f
        })
        .collect();
    if approach.is_empty() {
        approach.push(above);
    }
    let min_y = approach
        .iter()
        .map(|point| point.2)
        .fold(f32::INFINITY, f32::min);
    let max_y = approach
        .iter()
        .map(|point| point.2)
        .fold(f32::NEG_INFINITY, f32::max);
    let min_x = approach
        .iter()
        .map(|point| point.1)
        .fold(f32::INFINITY, f32::min);
    let max_x = approach
        .iter()
        .map(|point| point.1)
        .fold(f32::NEG_INFINITY, f32::max);
    let rise = (max_y - min_y).max(0.0);
    let span_px = (max_x - min_x).max(0.0) * frame_width as f32;
    let gap_s = ((below.0 - above.0) as f32 / 1_000.0).max(0.001);
    let descent_speed_px_s = (below.2 - above.2).max(0.0) * frame_height as f32 / gap_s;
    let arc_score = (rise / (1.15 * rim_width_px / frame_height_f)).min(1.0);
    let descent_score = (descent_speed_px_s / (4.0 * rim_width_px.max(1.0))).min(1.0);
    let direction_steps = approach
        .windows(2)
        .map(|pair| pair[1].2 - pair[0].2)
        .collect::<Vec<_>>();
    let downward_ratio = if direction_steps.is_empty() {
        0.5
    } else {
        direction_steps
            .iter()
            .filter(|delta| **delta >= -4.0 / frame_height.max(1) as f32)
            .count() as f32
            / direction_steps.len() as f32
    };
    (
        round2((0.45 * arc_score + 0.35 * descent_score + 0.20 * downward_ratio).clamp(0.0, 1.0)),
        span_px,
    )
}

#[allow(clippy::too_many_arguments)]
fn score_crossing(
    above: BallPoint,
    below: BallPoint,
    later: &[BallPoint],
    track: &[BallPoint],
    trajectory: f32,
    signals_net_score: f32,
    signals_net_inside: f32,
    horizontal_ratio: f32,
    rim: &Roi,
    frame_width: u32,
    frame_height: u32,
) -> f32 {
    let gap = ((below.0 - above.0) as f32 / 1_000.0).max(0.001);
    let frame_width_f = frame_width.max(1) as f32;
    let frame_height_f = frame_height.max(1) as f32;
    let rim_width_px = ((rim.right - rim.left) * frame_width_f).max(1.0);
    let descent_speed = (below.2 - above.2).max(0.0) * frame_height_f / gap;
    let normalized_speed = descent_speed / rim_width_px.max(1.0) * 30.54;
    let rim_y = (rim.top + rim.bottom) / 2.0;
    let rim_height_px = ((rim.bottom - rim.top) * frame_height_f).max(1.0);
    let below_depth =
        (rim_width_px * 0.35 / frame_height_f).max(rim_height_px * 0.5 / frame_height_f);
    let persistence = later
        .iter()
        .filter(|point| point.2 >= rim_y + below_depth)
        .count() as f32
        / 3.0;
    let geometry = 0.30 * (normalized_speed / 120.0).clamp(0.0, 1.0)
        + 0.45 * persistence.min(1.0)
        + 0.25 * (0.8 / gap).min(1.0);
    let confidence = {
        let mut values: Vec<_> = track.iter().rev().take(6).map(|point| point.3).collect();
        median_f32(&mut values)
    };
    let track_quality =
        0.65 * (confidence / 0.75).min(1.0) + 0.35 * (track.len() as f32 / 6.0).min(1.0);
    let crossing_quality = (1.0 - (horizontal_ratio / 0.9).min(1.0)).max(0.0);
    let net_quality = 0.5 * signals_net_score + 0.5 * signals_net_inside;
    let speed_penalty = (normalized_speed - 240.0).max(0.0) / 240.0;
    let penalty = (horizontal_ratio - 0.55).max(0.0) * 0.25 + (speed_penalty * 0.22).min(0.25);
    round3(
        (0.38 * geometry
            + 0.22 * trajectory
            + 0.10 * net_quality
            + 0.20 * track_quality
            + 0.10 * crossing_quality
            - penalty)
            .clamp(0.0, 1.0),
    )
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
            other.class_id != candidate.class_id || iou(other, &candidate) < DETECTION_NMS_IOU
        }) {
            kept.push(candidate);
            if kept.len() == DETECTION_MAX_COUNT {
                break;
            }
        }
    }
    kept
}

fn detect_image(
    session: &mut Session,
    image: &RgbImage,
    threshold: f32,
    model_size: u32,
    input_buffer: &mut Vec<f32>,
) -> Result<Vec<Detection>, RuntimeError> {
    let (scale, offset_x, offset_y) = preprocess_into(image, model_size, input_buffer)?;
    let input = ArrayView4::from_shape(
        (1, 3, model_size as usize, model_size as usize),
        input_buffer.as_slice(),
    )
    .map_err(|error| RuntimeError::InvalidRequest(error.to_string()))?;
    let tensor = TensorRef::from_array_view(input)?;
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

fn detect_pending_frames_batch(
    session: &mut Session,
    frames: &[PendingFrame],
    threshold: f32,
    model_size: u32,
    frame_input_buffer: &mut Vec<f32>,
    batch_input_buffer: &mut Vec<f32>,
) -> Result<Vec<Vec<Detection>>, RuntimeError> {
    if frames.is_empty() {
        return Ok(Vec::new());
    }
    let frame_len = model_size as usize * model_size as usize * 3;
    batch_input_buffer.clear();
    batch_input_buffer.reserve(frame_len * frames.len());
    let mut transforms = Vec::with_capacity(frames.len());
    for frame in frames {
        let resized;
        let image = if (frame.scale - 1.0).abs() < f32::EPSILON {
            &frame.analysis_frame
        } else {
            resized = resize(
                &frame.analysis_frame,
                (frame.analysis_frame.width() as f32 * frame.scale)
                    .round()
                    .max(1.0) as u32,
                (frame.analysis_frame.height() as f32 * frame.scale)
                    .round()
                    .max(1.0) as u32,
                FilterType::CatmullRom,
            );
            &resized
        };
        let transform = preprocess_into(image, model_size, frame_input_buffer)?;
        transforms.push((image.width(), image.height(), transform));
        batch_input_buffer.extend_from_slice(frame_input_buffer);
    }
    let input = ArrayView4::from_shape(
        (frames.len(), 3, model_size as usize, model_size as usize),
        batch_input_buffer.as_slice(),
    )
    .map_err(|error| RuntimeError::InvalidRequest(error.to_string()))?;
    let tensor = TensorRef::from_array_view(input)?;
    let outputs = session.run(ort::inputs![tensor])?;
    let (_, values) = outputs[0].try_extract_tensor::<f32>()?;
    let grid = [8_u32, 16, 32]
        .into_iter()
        .map(|stride| {
            let side = model_size / stride;
            (side * side) as usize
        })
        .sum::<usize>();
    let output_len = 6 * grid;
    if values.len() < output_len * frames.len() {
        return Err(RuntimeError::InvalidRequest(
            "batched model output has an invalid shape".into(),
        ));
    }
    Ok(transforms
        .into_iter()
        .enumerate()
        .map(|(index, (width, height, (scale, offset_x, offset_y)))| {
            decode_output(
                &values[index * output_len..(index + 1) * output_len],
                width,
                height,
                scale,
                offset_x,
                offset_y,
                threshold,
                model_size,
            )
        })
        .collect())
}

fn detect_yuv_sampled(
    session: &mut Session,
    width: u32,
    height: u32,
    y: &[u8],
    y_row_stride: usize,
    y_pixel_stride: usize,
    u: &[u8],
    u_row_stride: usize,
    u_pixel_stride: usize,
    v: &[u8],
    v_row_stride: usize,
    v_pixel_stride: usize,
    rotation: i32,
    roi_left: u32,
    roi_top: u32,
    roi_right: u32,
    roi_bottom: u32,
    sampled_width: u32,
    sampled_height: u32,
    downsample: f32,
    threshold: f32,
    model_size: u32,
    input_buffer: &mut Vec<f32>,
) -> Result<Vec<Detection>, RuntimeError> {
    if sampled_width == 0 || sampled_height == 0 || model_size == 0 {
        return Err(RuntimeError::InvalidRequest("empty sampled frame".into()));
    }
    let scale =
        (model_size as f32 / sampled_width as f32).min(model_size as f32 / sampled_height as f32);
    let resized_width = (sampled_width as f32 * scale).round().max(1.0) as u32;
    let resized_height = (sampled_height as f32 * scale).round().max(1.0) as u32;
    let offset_x = (model_size - resized_width.min(model_size)) / 2;
    let offset_y = (model_size - resized_height.min(model_size)) / 2;
    let input_len = (model_size as usize)
        .checked_mul(model_size as usize)
        .and_then(|size| size.checked_mul(3))
        .ok_or_else(|| RuntimeError::InvalidRequest("model size is too large".into()))?;
    if input_buffer.len() != input_len {
        input_buffer.resize(input_len, 114.0 / 255.0);
    } else {
        input_buffer.fill(114.0 / 255.0);
    }
    let plane_size = model_size as usize * model_size as usize;
    for local_y in 0..resized_height {
        let sampled_y = ((local_y as f32 / scale).floor() as usize)
            .min(sampled_height.saturating_sub(1) as usize);
        let logical_y = (sampled_y as f32 * downsample).floor() as u32 + roi_top;
        let logical_y = logical_y.min(roi_bottom.saturating_sub(1));
        for local_x in 0..resized_width {
            let sampled_x = ((local_x as f32 / scale).floor() as usize)
                .min(sampled_width.saturating_sub(1) as usize);
            let logical_x = (sampled_x as f32 * downsample).floor() as u32 + roi_left;
            let logical_x = logical_x.min(roi_right.saturating_sub(1));
            let (col, row) =
                source_coordinates_for_rotation(logical_x, logical_y, width, height, rotation);
            let y_index = row as usize * y_row_stride + col as usize * y_pixel_stride;
            let chroma_row = row as usize / 2;
            let chroma_col = col as usize / 2;
            let u_index = chroma_row * u_row_stride + chroma_col * u_pixel_stride;
            let v_index = chroma_row * v_row_stride + chroma_col * v_pixel_stride;
            if y_index >= y.len() || u_index >= u.len() || v_index >= v.len() {
                return Err(RuntimeError::InvalidRequest(
                    "YUV plane buffer is too small".into(),
                ));
            }
            let y_value = (y[y_index] as f32 - 16.0).max(0.0);
            let u_value = u[u_index] as f32 - 128.0;
            let v_value = v[v_index] as f32 - 128.0;
            let red = (1.164 * y_value + 1.596 * v_value)
                .round()
                .clamp(0.0, 255.0)
                / 255.0;
            let green = (1.164 * y_value - 0.391 * u_value - 0.813 * v_value)
                .round()
                .clamp(0.0, 255.0)
                / 255.0;
            let blue = (1.164 * y_value + 2.018 * u_value)
                .round()
                .clamp(0.0, 255.0)
                / 255.0;
            let target = (local_y as usize + offset_y as usize) * model_size as usize
                + local_x as usize
                + offset_x as usize;
            input_buffer[target] = red;
            input_buffer[plane_size + target] = green;
            input_buffer[plane_size * 2 + target] = blue;
        }
    }
    let input = ArrayView4::from_shape(
        (1, 3, model_size as usize, model_size as usize),
        input_buffer.as_slice(),
    )
    .map_err(|error| RuntimeError::InvalidRequest(error.to_string()))?;
    let tensor = TensorRef::from_array_view(input)?;
    let outputs = session.run(ort::inputs![tensor])?;
    let (_, values) = outputs[0].try_extract_tensor::<f32>()?;
    Ok(decode_output(
        values,
        sampled_width,
        sampled_height,
        scale,
        offset_x as f32,
        offset_y as f32,
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

fn crop_analysis_roi_reuse(
    image: &RgbImage,
    roi: &Roi,
    buffer: &mut Vec<u8>,
    dimensions: &mut (u32, u32),
) -> Result<(RgbImage, u32, u32), RuntimeError> {
    let width = image.width();
    let height = image.height();
    let left = (roi.left.clamp(0.0, 1.0) * width as f32).floor() as u32;
    let top = (roi.top.clamp(0.0, 1.0) * height as f32).floor() as u32;
    let right = (roi.right.clamp(0.0, 1.0) * width as f32).ceil() as u32;
    let bottom = (roi.bottom.clamp(0.0, 1.0) * height as f32).ceil() as u32;
    let right = right.min(width);
    let bottom = bottom.min(height);
    if right <= left || bottom <= top {
        return Err(RuntimeError::InvalidRequest(
            "analysis ROI is outside the video frame".into(),
        ));
    }
    let crop_width = right - left;
    let crop_height = bottom - top;
    let required = crop_width as usize * crop_height as usize * 3;
    if buffer.len() != required {
        buffer.resize(required, 0);
    }
    for y in 0..crop_height as usize {
        let source_start = ((top as usize + y) * image.width() as usize + left as usize) * 3;
        let source_end = source_start + crop_width as usize * 3;
        let destination_start = y * crop_width as usize * 3;
        buffer[destination_start..destination_start + crop_width as usize * 3]
            .copy_from_slice(&image.as_raw()[source_start..source_end]);
    }
    *dimensions = (crop_width, crop_height);
    let crop =
        RgbImage::from_raw(crop_width, crop_height, std::mem::take(buffer)).ok_or_else(|| {
            RuntimeError::InvalidRequest("analysis ROI dimensions are invalid".into())
        })?;
    Ok((crop, left, top))
}

fn resize_reuse(
    image: &RgbImage,
    width: u32,
    height: u32,
    filter: FilterType,
    buffer: &mut Vec<u8>,
    dimensions: &mut (u32, u32),
) -> RgbImage {
    let resized = resize(image, width, height, filter);
    let required = width as usize * height as usize * 3;
    if buffer.len() != required {
        buffer.resize(required, 0);
    }
    buffer.copy_from_slice(resized.as_raw());
    *dimensions = (width, height);
    RgbImage::from_raw(width, height, std::mem::take(buffer)).expect("resize dimensions are valid")
}

fn remap_detections(
    detections: Vec<Detection>,
    offset_x: u32,
    offset_y: u32,
    width: u32,
    height: u32,
    crop_scale: f32,
) -> Vec<Detection> {
    let crop_scale = crop_scale.max(1.0);
    detections
        .into_iter()
        .map(|detection| Detection {
            class_id: detection.class_id,
            confidence: detection.confidence,
            x1: ((detection.x1 / crop_scale + offset_x as f32) / width as f32).clamp(0.0, 1.0),
            y1: ((detection.y1 / crop_scale + offset_y as f32) / height as f32).clamp(0.0, 1.0),
            x2: ((detection.x2 / crop_scale + offset_x as f32) / width as f32).clamp(0.0, 1.0),
            y2: ((detection.y2 / crop_scale + offset_y as f32) / height as f32).clamp(0.0, 1.0),
        })
        .map(|detection| Detection {
            x1: detection.x1 * width as f32,
            y1: detection.y1 * height as f32,
            x2: detection.x2 * width as f32,
            y2: detection.y2 * height as f32,
            ..detection
        })
        .collect()
}

fn hoop_detection_to_rim(detection: &Detection, width: u32, height: u32) -> Roi {
    let box_width = (detection.x2 - detection.x1).max(1.0);
    let box_height = (detection.y2 - detection.y1).max(1.0);
    let center_x = (detection.x1 + detection.x2) / 2.0;
    let center_y = (detection.y1 + detection.y2) / 2.0;
    let rim_y = center_y - box_height * 0.28;
    let rim_height = box_height * 0.45;
    Roi {
        left: ((center_x - box_width / 2.0) / width as f32).clamp(0.0, 1.0),
        top: ((rim_y - rim_height / 2.0) / height as f32).clamp(0.0, 1.0),
        right: ((center_x + box_width / 2.0) / width as f32).clamp(0.0, 1.0),
        bottom: ((rim_y + rim_height / 2.0) / height as f32).clamp(0.0, 1.0),
    }
}

/// Matches `generate_candidates.py::_hoops_from`: median detector box
/// geometry over the complete coarse scan, without the refined plane offset.
fn coarse_rim_from_observations(
    observations: &[Detection],
    width: u32,
    height: u32,
) -> Option<Roi> {
    let hoops: Vec<_> = observations
        .iter()
        .filter(|detection| detection.class_id == 1)
        .collect();
    if hoops.is_empty() || width == 0 || height == 0 {
        return None;
    }
    let mut centers_x: Vec<_> = hoops.iter().map(|item| (item.x1 + item.x2) / 2.0).collect();
    let mut centers_y: Vec<_> = hoops.iter().map(|item| (item.y1 + item.y2) / 2.0).collect();
    let mut widths: Vec<_> = hoops
        .iter()
        .map(|item| (item.x2 - item.x1).max(1.0))
        .collect();
    let mut heights: Vec<_> = hoops
        .iter()
        .map(|item| (item.y2 - item.y1).max(1.0))
        .collect();
    let center_x = median_f32(&mut centers_x);
    let center_y = median_f32(&mut centers_y);
    let rim_width = median_f32(&mut widths);
    let rim_height = median_f32(&mut heights);
    Some(Roi {
        left: ((center_x - rim_width / 2.0) / width as f32).clamp(0.0, 1.0),
        top: ((center_y - rim_height / 2.0) / height as f32).clamp(0.0, 1.0),
        right: ((center_x + rim_width / 2.0) / width as f32).clamp(0.0, 1.0),
        bottom: ((center_y + rim_height / 2.0) / height as f32).clamp(0.0, 1.0),
    })
}

fn median_f32(values: &mut [f32]) -> f32 {
    if values.is_empty() {
        return 0.0;
    }
    values.sort_by(|left, right| left.total_cmp(right));
    let middle = values.len() / 2;
    if values.len().is_multiple_of(2) {
        (values[middle - 1] + values[middle]) / 2.0
    } else {
        values[middle]
    }
}

fn round3(value: f32) -> f32 {
    (value * 1_000.0).round() / 1_000.0
}

fn round2(value: f32) -> f32 {
    (value * 100.0).round() / 100.0
}

fn candidate_signals(candidate: &Candidate) -> serde_json::Value {
    serde_json::json!({
        "net_score": round3(candidate.net_score),
        "net_motion_score": round3(candidate.net_motion_score),
        "net_inside_motion_score": round3(candidate.net_inside_motion_score),
        "net_sequence_score": round3(candidate.net_sequence_score),
        "net_changed_ratio": round3(candidate.net_changed_ratio),
        "net_lower_peak": round3(candidate.net_lower_peak),
        "net_below_peak": round3(candidate.net_below_peak),
        "net_signal_available": candidate.net_signal_available,
        "net_support": candidate.net_support,
        "net_no_motion": candidate.net_no_motion,
    })
}

fn refresh_candidate_evidence(candidate: &mut Candidate, gates: &CalibratedGates, state: &str) {
    candidate.signals = candidate_signals(candidate);
    candidate.gates = serde_json::json!({
        "high_precision": gates.high_precision,
        "automatic_goal": gates.automatic_goal,
        "review": gates.review,
        "strict_low_speed": gates.strict_low_speed,
        "high_speed_net": gates.high_speed_net,
        "high_speed_drop": gates.high_speed_drop,
        "prediction_review": candidate.prediction_review,
        "recall_review": gates.recall_review || candidate.prediction_review,
    });
    candidate.verification = serde_json::json!({
        "state": state,
        "verdict": candidate.verdict,
        "trajectory_cross": candidate.complete_crossing,
        "complete_crossing": candidate.complete_crossing,
        "ball_persistence": round3(candidate.ball_persistence),
        "post_crossing_points": candidate.post_crossing_points,
        "verification_window_s": 0.8,
        "rebound": candidate.rebound,
        "rim_rebound": candidate.rebound,
        "lateral_exit": candidate.lateral_exit,
        "post_crossing_lateral_recovery": candidate.post_crossing_lateral_recovery,
        "net_signal_available": candidate.net_signal_available,
        "net_support": candidate.net_support,
        "net_swish": candidate.net_support,
        "net_no_motion": candidate.net_no_motion,
        "decision_time_ms": candidate.decision_time_ms,
        "event_time_source": "rim_crossing_interpolated",
    });
}

fn dedupe_runtime_candidates(mut candidates: Vec<Candidate>, dedupe_ms: i64) -> Vec<Candidate> {
    let dedupe_ms = dedupe_ms.max(0);
    candidates.sort_by_key(|candidate| candidate.event_ms);
    let mut deduped = Vec::new();
    let mut cluster_start = None;
    let mut winner: Option<Candidate> = None;
    for candidate in candidates {
        let start = cluster_start.get_or_insert(candidate.event_ms);
        if candidate.event_ms - *start <= dedupe_ms {
            let replace = winner.as_ref().is_none_or(|current| {
                runtime_candidate_priority(&candidate) > runtime_candidate_priority(current)
            });
            if replace {
                winner = Some(candidate);
            }
            continue;
        }
        if let Some(previous) = winner.take() {
            deduped.push(previous);
        }
        cluster_start = Some(candidate.event_ms);
        winner = Some(candidate);
    }
    if let Some(last) = winner {
        deduped.push(last);
    }
    deduped
}

fn runtime_candidate_priority(candidate: &Candidate) -> (u8, bool, bool, f32) {
    let verdict = match candidate.verdict.as_str() {
        "made" => 3,
        "ambiguous" => 2,
        "missed" => 1,
        _ => 0,
    };
    (
        verdict,
        candidate.complete_crossing,
        !candidate.prediction_review,
        candidate.composite_score,
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
        analysis_roi: request.analysis_roi,
        rim: request.rim,
        duration_ms: request.duration_ms,
        confidence_threshold: request.confidence_threshold,
        clip_before_ms: request.clip_before_ms,
        clip_after_ms: request.clip_after_ms,
        model_size: request.model_size,
        crop_scale: request.crop_scale,
        max_cross_gap_ms: request.max_cross_gap_ms,
        dedupe_ms: request.dedupe_ms,
        intra_threads: request.intra_threads,
        inference_batch_size: request.inference_batch_size,
        execution_provider: request.execution_provider,
        execution_provider_backend: request.execution_provider_backend,
        optimized_model_path: request.optimized_model_path,
        input_max_dimension: request.input_max_dimension,
        detection_only: request.detection_only,
        coarse_mode: false,
    };
    let mut session = RuntimeSession::new(config)?;
    for frame in &request.frames {
        session.push_frame(frame.clone())?;
    }
    let final_response = session.finish()?;
    Ok(AnalysisResponse {
        candidates: final_response.candidates,
        processed_frames: request.frames.len(),
        total_frames: request.frames.len(),
    })
}

#[cfg(test)]
#[allow(clippy::items_after_test_module)]
mod tests {
    use super::*;

    fn point(time_ms: i64, x: f32, y: f32, confidence: f32) -> BallPoint {
        (time_ms, x, y, confidence, 0.01, 0.01)
    }

    fn roi() -> Roi {
        Roi {
            left: 0.4,
            top: 0.4,
            right: 0.6,
            bottom: 0.7,
        }
    }

    #[test]
    fn rotated_yuv_coordinates_use_display_orientation() {
        assert_eq!(source_coordinates_for_rotation(0, 0, 4, 3, 90), (0, 2));
        assert_eq!(source_coordinates_for_rotation(2, 0, 4, 3, 90), (0, 0));
        assert_eq!(source_coordinates_for_rotation(0, 0, 4, 3, 270), (3, 0));
        assert_eq!(source_coordinates_for_rotation(2, 2, 4, 3, 180), (1, 0));
    }

    fn net_history_point(time_ms: i64, upper: f32, lower: f32, below: f32) -> NetHistoryPoint {
        NetHistoryPoint {
            time_ms,
            measurement_valid: true,
            lower_inside: lower,
            below_inside: below,
            upper_components: [upper, 0.0, 0.0, 0.0],
            lower_components: [lower, 0.0, 0.0, 0.0],
            below_components: [below, 0.0, 0.0, 0.0],
            motion: upper.max(lower).max(below),
            changed_ratio: 0.0,
            whole: upper.max(lower).max(below),
        }
    }

    #[test]
    fn association_prefers_nearest_prediction_over_detection_order() {
        let mut tracks = vec![BallTrack {
            id: 1,
            points: vec![point(0, 0.45, 0.45, 0.8), point(100, 0.50, 0.50, 0.8)],
            last_width: 0.01,
            last_height: 0.01,
        }];
        let mut next_track_id = 2;

        let updated = associate_ball_tracks(
            &mut tracks,
            &mut next_track_id,
            200,
            vec![
                (0.58, 0.58, 0.99, 0.01, 0.01),
                (0.55, 0.55, 0.4, 0.01, 0.01),
            ],
            0.20,
            1,
            1,
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
            points: vec![point(0, 0.50, 0.50, 0.8)],
            last_width: 0.01,
            last_height: 0.01,
        }];
        let mut next_track_id = 8;

        let recovered = associate_ball_tracks(
            &mut tracks,
            &mut next_track_id,
            300,
            vec![(0.54, 0.54, 0.8, 0.01, 0.01)],
            0.20,
            1,
            1,
        );
        assert_eq!(recovered, vec![7]);
        assert_eq!(tracks[0].points.len(), 2);

        let restarted = associate_ball_tracks(
            &mut tracks,
            &mut next_track_id,
            700,
            vec![(0.58, 0.58, 0.8, 0.01, 0.01)],
            0.20,
            1,
            1,
        );
        assert_eq!(restarted, vec![8]);
        assert_eq!(tracks.len(), 2);
    }

    #[test]
    fn legacy_flatten_track_matches_desktop_confidence_fallback() {
        let points = vec![
            point(0, 0.40, 0.20, 0.30),
            point(0, 0.41, 0.20, 0.90),
            point(100, 0.42, 0.24, 0.80),
            point(200, 0.43, 0.29, 0.80),
        ];
        let flattened = continuous_flatten_balls(&points, 0.2, 500, 0.20, 1_000, 1_000);
        assert_eq!(flattened.len(), 3);
        assert_eq!(flattened[0].3, 0.90);

        let mut broken = points;
        broken.push(point(800, 0.45, 0.35, 0.80));
        assert!(continuous_flatten_balls(&broken, 0.2, 500, 0.20, 1_000, 1_000).is_empty());
    }

    #[test]
    fn recovery_stitches_a_rim_occlusion_between_two_tracks() {
        let tracks = vec![
            BallTrack {
                id: 1,
                points: vec![point(0, 0.50, 0.25, 0.8), point(100, 0.50, 0.34, 0.8)],
                last_width: 0.01,
                last_height: 0.01,
            },
            BallTrack {
                id: 2,
                points: vec![point(300, 0.50, 0.82, 0.7), point(400, 0.50, 0.88, 0.7)],
                last_width: 0.01,
                last_height: 0.01,
            },
        ];

        let raw_points = tracks
            .iter()
            .flat_map(|track| track.points.iter().copied())
            .collect::<Vec<_>>();
        let recoveries = recover_track_points(&tracks, &raw_points, &roi(), 1_000, 1_000, 1_800);

        assert_eq!(recoveries.len(), 1);
        assert_eq!(recoveries[0].0, 1);
        assert_eq!(recoveries[0].1.first().unwrap().0, 0);
        assert_eq!(recoveries[0].1.last().unwrap().0, 400);
        assert!(complete_rim_crossing(
            &recoveries[0].1,
            100,
            300,
            &roi(),
            1_000,
            1_000
        ));
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
            analysis_roi: None,
            rim: None,
            duration_ms: None,
            confidence_threshold: 0.1,
            clip_before_ms: 6_000,
            clip_after_ms: 3_000,
            model_size: MODEL_SIZE_DEFAULT,
            crop_scale: default_crop_scale(),
            max_cross_gap_ms: default_max_cross_gap_ms(),
            dedupe_ms: default_dedupe_ms(),
            intra_threads: default_intra_threads(),
            inference_batch_size: default_inference_batch_size(),
            execution_provider: None,
            execution_provider_backend: None,
            optimized_model_path: None,
            input_max_dimension: None,
            detection_only: false,
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
            analysis_roi: None,
            rim: None,
            duration_ms: None,
            confidence_threshold: 0.1,
            clip_before_ms: 6_000,
            clip_after_ms: 3_000,
            model_size: MODEL_SIZE_DEFAULT,
            crop_scale: default_crop_scale(),
            max_cross_gap_ms: default_max_cross_gap_ms(),
            dedupe_ms: default_dedupe_ms(),
            intra_threads: default_intra_threads(),
            inference_batch_size: default_inference_batch_size(),
            execution_provider: None,
            execution_provider_backend: None,
            optimized_model_path: None,
            input_max_dimension: None,
            detection_only: false,
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
    fn global_net_motion_roi_matches_desktop_analysis_crop_intersection() {
        let net = Roi {
            left: 0.10,
            top: 0.20,
            right: 0.90,
            bottom: 0.80,
        };
        let analysis = Roi {
            left: 0.30,
            top: 0.40,
            right: 0.70,
            bottom: 0.60,
        };
        assert_eq!(intersect_roi(&net, &analysis), Some(analysis));
        assert!(intersect_roi(
            &net,
            &Roi {
                left: 0.91,
                top: 0.20,
                right: 1.0,
                bottom: 0.80,
            }
        )
        .is_none());
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
        let result = crossing_at_rim(point(0, 0.2, 0.3, 0.9), point(100, 0.8, 0.7, 0.9), 0.5)
            .expect("descending points should cross the rim");
        assert!((result.0 - 0.5).abs() < 1e-6);
        assert!((result.1 - 0.5).abs() < 1e-6);
    }

    #[test]
    fn lateral_pass_is_not_a_rim_crossing() {
        assert!(crossing_at_rim(point(0, 0.2, 0.5, 0.9), point(100, 0.8, 0.5, 0.9), 0.5).is_none());
    }

    #[test]
    fn complete_crossing_requires_a_stable_vertical_path_through_the_rim() {
        let points = [
            point(0, 0.48, 0.30, 0.9),
            point(300, 0.49, 0.42, 0.9),
            point(600, 0.50, 0.54, 0.9),
        ];
        assert!(complete_crossing(&points, 0.48, 0.42, 0.58));
    }

    #[test]
    fn complete_crossing_rejects_a_side_pass_that_only_interpolates_inside() {
        let points = [
            point(0, 0.05, 0.30, 0.9),
            point(300, 0.18, 0.42, 0.9),
            point(600, 0.50, 0.54, 0.9),
        ];
        assert!(!complete_crossing(&points, 0.48, 0.42, 0.58));
    }

    #[test]
    fn complete_rim_crossing_requires_post_rim_persistence() {
        let points = [
            point(0, 0.50, 0.34, 0.9),
            point(200, 0.50, 0.84, 0.9),
            point(400, 0.51, 0.90, 0.9),
        ];
        assert!(complete_rim_crossing(&points, 0, 200, &roi(), 1_000, 1_000));
        assert!(!complete_rim_crossing(
            &points[..2],
            0,
            200,
            &roi(),
            1_000,
            1_000
        ));
    }

    #[test]
    fn post_crossing_evidence_marks_lateral_exit_as_negative_evidence() {
        let points = [
            point(0, 0.50, 0.34, 0.9),
            point(200, 0.50, 0.84, 0.9),
            point(400, 0.10, 0.90, 0.9),
        ];
        let evidence = post_crossing_evidence(&points, 200, &roi(), 1_000, 1_000);
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
    fn preprocess_uses_ultralytics_letterbox_padding() {
        let image = RgbImage::from_pixel(4, 2, image::Rgb([0, 0, 0]));
        let (input, _, offset_x, offset_y) = preprocess(&image, 8).expect("valid image");
        assert_eq!(offset_x, 0.0);
        assert_eq!(offset_y, 2.0);
        assert!((input[[0, 0, 0, 0]] - 114.0 / 255.0).abs() < 1e-6);
        assert_eq!(input[[0, 0, 2, 0]], 0.0);
    }

    #[test]
    fn rim_corridor_keeps_python_one_pixel_minimum_at_small_scales() {
        let rim = Roi {
            left: 0.499,
            top: 0.4,
            right: 0.501,
            bottom: 0.6,
        };
        let point = point(0, 0.5013, 0.5, 0.9);
        assert!(!point_in_rim_corridor(
            &point,
            (rim.left + rim.right) / 2.0,
            (rim.right - rim.left) / 2.0,
            0.15,
            1_000,
        ));
    }

    #[test]
    fn net_sequence_contributes_only_after_lower_zone_activation() {
        let history = [
            net_history_point(-800, 0.0, 0.0, 0.0),
            net_history_point(-400, 0.0, 0.0, 0.0),
            net_history_point(0, 0.0, 0.10, 0.0),
            net_history_point(200, 0.0, 0.12, 0.10),
        ];
        let (inside, sequence) = net_zone_scores(&history, 0);
        assert!(inside > 0.9);
        assert_eq!(sequence, 1.0);
    }

    #[test]
    fn net_evidence_keeps_missing_measurement_distinct_from_no_motion() {
        assert!(!net_zone_evidence(&[net_history_point(0, 0.0, 0.0, 0.0)], 0).signal_available);

        let mut unavailable = net_history_point(-400, 0.0, 0.8, 0.8);
        unavailable.measurement_valid = false;
        assert!(!net_zone_evidence(&[unavailable], 0).signal_available);

        let history = [
            net_history_point(-800, 0.0, 0.0, 0.0),
            net_history_point(-400, 0.0, 0.0, 0.0),
            net_history_point(0, 0.0, 0.0, 0.0),
            net_history_point(100, 0.0, 0.0, 0.0),
        ];
        let no_motion = net_zone_evidence(&history, 0);
        assert!(no_motion.signal_available);
        assert!(no_motion.no_motion);

        let supported = [
            net_history_point(-800, 0.0, 0.0, 0.0),
            net_history_point(-400, 0.0, 0.0, 0.0),
            net_history_point(0, 0.0, 0.50, 0.0),
            net_history_point(100, 0.0, 0.60, 0.50),
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
                width: Some(0.01),
                height: Some(0.01),
            },
            below: EvidencePoint {
                time_ms: 200,
                x: 0.50,
                y: 0.84,
                confidence: 0.9,
                width: Some(0.01),
                height: Some(0.01),
            },
            trajectory: vec![
                EvidencePoint {
                    time_ms: 100,
                    x: 0.50,
                    y: 0.54,
                    confidence: 0.9,
                    width: Some(0.01),
                    height: Some(0.01),
                },
                EvidencePoint {
                    time_ms: 400,
                    x: 0.51,
                    y: 0.90,
                    confidence: 0.9,
                    width: Some(0.01),
                    height: Some(0.01),
                },
                EvidencePoint {
                    time_ms: 600,
                    x: 0.51,
                    y: 0.95,
                    confidence: 0.9,
                    width: Some(0.01),
                    height: Some(0.01),
                },
            ],
            net_history: vec![
                NetReplayPoint {
                    time_ms: -800,
                    measurement_valid: Some(true),
                    upper: 0.0,
                    lower: 0.0,
                    below: 0.0,
                    lower_inside: 0.0,
                    below_inside: 0.0,
                    upper_components: [0.0; 4],
                    lower_components: [0.0; 4],
                    below_components: [0.0; 4],
                    motion: 0.0,
                    changed_ratio: 0.0,
                    whole: 0.0,
                },
                NetReplayPoint {
                    time_ms: -400,
                    measurement_valid: Some(true),
                    upper: 0.0,
                    lower: 0.0,
                    below: 0.0,
                    lower_inside: 0.0,
                    below_inside: 0.0,
                    upper_components: [0.0; 4],
                    lower_components: [0.0; 4],
                    below_components: [0.0; 4],
                    motion: 0.0,
                    changed_ratio: 0.0,
                    whole: 0.0,
                },
                NetReplayPoint {
                    time_ms: 0,
                    measurement_valid: Some(true),
                    upper: 0.0,
                    lower: 0.50,
                    below: 0.0,
                    lower_inside: 0.50,
                    below_inside: 0.0,
                    upper_components: [0.0; 4],
                    lower_components: [0.50, 0.0, 0.0, 0.0],
                    below_components: [0.0; 4],
                    motion: 0.50,
                    changed_ratio: 0.0,
                    whole: 0.50,
                },
                NetReplayPoint {
                    time_ms: 300,
                    measurement_valid: Some(true),
                    upper: 0.0,
                    lower: 0.60,
                    below: 0.50,
                    lower_inside: 0.60,
                    below_inside: 0.50,
                    upper_components: [0.0; 4],
                    lower_components: [0.60, 0.0, 0.0, 0.0],
                    below_components: [0.50, 0.0, 0.0, 0.0],
                    motion: 0.60,
                    changed_ratio: 0.0,
                    whole: 0.60,
                },
            ],
            frame_width: Some(1_000),
            frame_height: Some(1_000),
            candidate_speed_per_rim: None,
            candidate_approach_span_per_rim: None,
            candidate_horizontal_ratio: None,
            candidate_complete_crossing: None,
            candidate_ball_persistence: None,
            candidate_rebound: None,
            candidate_lateral_exit: None,
            candidate_post_crossing_lateral_recovery: None,
            candidate_score: None,
            candidate_net_score: None,
            candidate_net_motion_score: None,
            candidate_net_changed_ratio: None,
            candidate_net_signal_available: None,
            candidate_net_no_motion: None,
            candidate_net_support: None,
            candidate_net_inside_motion_score: None,
            candidate_net_sequence_score: None,
            candidate_net_lower_peak: None,
            candidate_net_below_peak: None,
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
            point(0, 0.50, 0.45, 0.9),
            point(600, 0.50, 0.85, 0.9),
            point(700, 0.51, 0.90, 0.9),
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
            point(0, 0.50, 0.292, 0.9),
            point(100, 0.50, 0.338, 0.9),
            point(200, 0.50, 0.388, 0.9),
            point(300, 0.50, 0.442, 0.9),
            point(400, 0.50, 0.500, 0.9),
        ];
        assert!(prediction_score(&points, 0.60, 0.50, 0.10) > 0.9);
    }

    #[test]
    fn prediction_evidence_exposes_the_landing_point_and_fit() {
        let points = [
            point(0, 0.50, 0.292, 0.9),
            point(100, 0.50, 0.338, 0.9),
            point(200, 0.50, 0.388, 0.9),
            point(300, 0.50, 0.442, 0.9),
            point(400, 0.50, 0.500, 0.9),
        ];
        let evidence = prediction_evidence_for_frame(&points, 0.60, 0.50, 0.10, 1_000)
            .expect("clean descent should produce prediction evidence");
        assert!((evidence.landing_x - 0.50).abs() < 0.01);
        assert!((evidence.landing_y - 0.60).abs() < 1e-6);
        assert!(evidence.fit_r2 >= 0.85);
        assert_eq!(evidence.point_count, 5);
    }

    #[test]
    fn prediction_rejects_non_descending_or_sparse_tracks() {
        let flat = [
            point(0, 0.50, 0.30, 0.9),
            point(100, 0.50, 0.30, 0.9),
            point(200, 0.50, 0.30, 0.9),
            point(300, 0.50, 0.30, 0.9),
            point(400, 0.50, 0.30, 0.9),
        ];
        assert_eq!(prediction_score(&flat, 0.60, 0.50, 0.10), 0.0);
        assert_eq!(prediction_score(&flat[..4], 0.60, 0.50, 0.10), 0.0);
    }

    #[test]
    fn event_track_uses_the_full_pre_crossing_window() {
        let points = [
            point(-1_500, 0.50, 0.25, 0.9),
            point(-1_200, 0.50, 0.28, 0.9),
            point(-900, 0.50, 0.32, 0.9),
            point(-600, 0.50, 0.38, 0.9),
            point(-300, 0.50, 0.46, 0.9),
            point(0, 0.50, 0.56, 0.9),
        ];
        let selected = event_track_points(&points, 0, 0);
        assert_eq!(selected.len(), 5);
        assert_eq!(selected.first().unwrap().0, -1_200);
        assert_eq!(selected.last().unwrap().0, 0);
    }

    #[test]
    fn confidence_label_matches_desktop_review_gates() {
        let gates = CalibratedGates {
            high_precision: false,
            automatic_goal: false,
            review: true,
            recall_review: true,
            strict_low_speed: false,
            high_speed_net: false,
            high_speed_drop: false,
        };
        assert_eq!(confidence_label(0.42, 0.0, &gates), "review");
        assert_eq!(confidence_label(0.50, 0.0, &gates), "review");

        let no_review = CalibratedGates {
            review: false,
            ..gates
        };
        assert_eq!(confidence_label(0.50, 0.0, &no_review), "low");
        assert_eq!(confidence_label(0.50, 0.1, &no_review), "review");
    }

    #[test]
    fn crossing_context_stays_at_the_crossing_pair_not_the_track_tail() {
        let points = [
            point(0, 0.50, 0.30, 0.9),
            point(100, 0.50, 0.44, 0.9),
            point(200, 0.50, 0.56, 0.9),
            point(300, 0.70, 0.74, 0.9),
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
    fn decode_output_applies_ultralytics_max_det_after_nms() {
        const GRID: usize = 8_400;
        let count = DETECTION_MAX_COUNT + 1;
        let mut output = vec![0.0; 6 * GRID];
        for index in 0..count {
            let column = index % 50;
            let row = index / 50;
            output[index] = (column * 10 + 5) as f32;
            output[GRID + index] = (row * 10 + 5) as f32;
            output[2 * GRID + index] = 1.0;
            output[3 * GRID + index] = 1.0;
            output[4 * GRID + index] = 0.9;
        }
        let detections = decode_output(&output, 640, 640, 1.0, 0.0, 0.0, 0.5, 640);
        assert_eq!(detections.len(), DETECTION_MAX_COUNT);
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
        false
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

/// Returns the configured runtime backend and current batch status.
///
/// `provider_registered` reports the execution provider registered with
/// ONNX Runtime. Individual unsupported operators may still execute on the
/// ORT CPU fallback and are measured separately by the Android benchmark.
#[no_mangle]
pub unsafe extern "C" fn bhe_runtime_session_info(session: *mut RuntimeSession) -> *mut c_char {
    if session.is_null() {
        return std::ptr::null_mut();
    }
    let output = serde_json::to_string(&(*session).session_info())
        .unwrap_or_else(|error| serde_json::json!({"error": error.to_string()}).to_string());
    CString::new(output).unwrap().into_raw()
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
    let Ok(actual) = usize::try_from(rgba_len) else {
        return CString::new(r#"{"error":"raw frame length is invalid"}"#)
            .unwrap()
            .into_raw();
    };
    bhe_runtime_push_frame_raw_strided(
        session,
        time_ms,
        width,
        height,
        width as usize * 4,
        rgba_data,
        actual as i64,
    )
}

/// Processes raw BGRA pixels with an explicit row stride.
#[no_mangle]
pub unsafe extern "C" fn bhe_runtime_push_frame_bgra_strided(
    session: *mut RuntimeSession,
    time_ms: i64,
    width: u32,
    height: u32,
    row_stride: usize,
    bgra_data: *const u8,
    bgra_len: i64,
    rotation_degrees: i32,
) -> *mut c_char {
    if session.is_null() || bgra_data.is_null() || bgra_len < 0 {
        return std::ptr::null_mut();
    }
    let Ok(actual) = usize::try_from(bgra_len) else {
        return CString::new(r#"{"error":"BGRA frame length is invalid"}"#)
            .unwrap()
            .into_raw();
    };
    let bgra = std::slice::from_raw_parts(bgra_data, actual);
    let output = match (*session)
        .push_frame_bgra_strided(time_ms, width, height, bgra, row_stride, rotation_degrees)
        .and_then(|response| serde_json::to_string(&response).map_err(RuntimeError::from))
    {
        Ok(output) => output,
        Err(error) => serde_json::json!({"error": error.to_string()}).to_string(),
    };
    CString::new(output).unwrap().into_raw()
}

/// Processes raw RGBA pixels with an explicit row stride.
///
/// The stride-aware entry point lets Android pass a locked Bitmap buffer
/// directly without creating an IntArray or a second ByteArray in Kotlin.
#[no_mangle]
pub unsafe extern "C" fn bhe_runtime_push_frame_raw_strided(
    session: *mut RuntimeSession,
    time_ms: i64,
    width: u32,
    height: u32,
    row_stride: usize,
    rgba_data: *const u8,
    rgba_len: i64,
) -> *mut c_char {
    if session.is_null() || rgba_data.is_null() || rgba_len < 0 {
        return std::ptr::null_mut();
    }
    let Ok(actual) = usize::try_from(rgba_len) else {
        return CString::new(r#"{"error":"raw frame length is invalid"}"#)
            .unwrap()
            .into_raw();
    };
    let rgba = std::slice::from_raw_parts(rgba_data, actual);
    let output = match (*session)
        .push_frame_raw_strided(time_ms, width, height, rgba, row_stride)
        .and_then(|response| serde_json::to_string(&response).map_err(RuntimeError::from))
    {
        Ok(output) => output,
        Err(error) => serde_json::json!({"error": error.to_string()}).to_string(),
    };
    CString::new(output).unwrap().into_raw()
}

/// Processes Android YUV_420_888 planes without creating a Bitmap in Kotlin.
/// The planes are borrowed only for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn bhe_runtime_push_frame_yuv(
    session: *mut RuntimeSession,
    time_ms: i64,
    width: u32,
    height: u32,
    y_data: *const u8,
    y_len: usize,
    y_row_stride: usize,
    y_pixel_stride: usize,
    u_data: *const u8,
    u_len: usize,
    u_row_stride: usize,
    u_pixel_stride: usize,
    v_data: *const u8,
    v_len: usize,
    v_row_stride: usize,
    v_pixel_stride: usize,
    rotation_degrees: i32,
) -> *mut c_char {
    if session.is_null()
        || y_data.is_null()
        || u_data.is_null()
        || v_data.is_null()
        || y_len == 0
        || u_len == 0
        || v_len == 0
    {
        return CString::new(r#"{"error":"invalid YUV frame"}"#)
            .unwrap()
            .into_raw();
    }
    let y = std::slice::from_raw_parts(y_data, y_len);
    let u = std::slice::from_raw_parts(u_data, u_len);
    let v = std::slice::from_raw_parts(v_data, v_len);
    let output = match (*session)
        .push_frame_yuv(
            time_ms,
            width,
            height,
            y,
            y_row_stride,
            y_pixel_stride,
            u,
            u_row_stride,
            u_pixel_stride,
            v,
            v_row_stride,
            v_pixel_stride,
            rotation_degrees,
        )
        .and_then(|response| serde_json::to_string(&response).map_err(RuntimeError::from))
    {
        Ok(output) => output,
        Err(error) => serde_json::json!({"error": error.to_string()}).to_string(),
    };
    CString::new(output).unwrap().into_raw()
}

/// Resolves candidates that are waiting for the final post-crossing window.
/// The returned JSON has the same shape as `bhe_runtime_push_frame_raw`.
///
/// # Safety
/// `session` must be a valid pointer returned by `bhe_runtime_create_session`.
#[no_mangle]
pub unsafe extern "C" fn bhe_runtime_finish_session(session: *mut RuntimeSession) -> *mut c_char {
    if session.is_null() {
        return std::ptr::null_mut();
    }
    let output = match (*session)
        .finish()
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
    CString::new(RUNTIME_VERSION).unwrap().into_raw()
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
