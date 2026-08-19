use std::ffi::{c_char, CStr, CString};
use std::path::Path;
use std::sync::Mutex;
use std::sync::OnceLock;

use base64::Engine;
use image::{imageops::FilterType, DynamicImage, RgbImage};
use ndarray::Array4;
use ort::{session::Session, value::Tensor};
use serde::{Deserialize, Serialize};
use thiserror::Error;

const MODEL_SIZE: u32 = 640;
static ORT_INIT: OnceLock<Result<(), String>> = OnceLock::new();
static ORT_LIBRARY_PATH: OnceLock<Mutex<Option<String>>> = OnceLock::new();

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
    #[serde(default = "default_confidence")]
    pub confidence_threshold: f32,
    #[serde(default = "default_before_ms")]
    pub clip_before_ms: i64,
    #[serde(default = "default_after_ms")]
    pub clip_after_ms: i64,
}

#[derive(Clone, Debug, Deserialize)]
pub struct AnalysisRequest {
    pub model_path: String,
    pub frames: Vec<FrameInput>,
    pub hoop_roi: Roi,
    pub net_roi: Roi,
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
pub struct Candidate {
    pub id: String,
    pub start_ms: i64,
    pub end_ms: i64,
    pub event_ms: i64,
    pub confidence: f32,
    pub trajectory_score: f32,
    pub crossing_score: f32,
    pub net_motion_score: f32,
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
    ball_points: Vec<(i64, f32, f32, f32)>,
    candidates: Vec<Candidate>,
}

impl RuntimeSession {
    pub fn new(config: RuntimeConfig) -> Result<Self, RuntimeError> {
        if config.hoop_roi.right <= config.hoop_roi.left
            || config.hoop_roi.bottom <= config.hoop_roi.top
        {
            return Err(RuntimeError::InvalidRequest("hoop ROI is invalid".into()));
        }
        init_onnx()?;
        let session = Session::builder()
            .map_err(|error| RuntimeError::InvalidRequest(error.to_string()))?
            .with_intra_threads(1)
            .map_err(|error| RuntimeError::InvalidRequest(error.to_string()))?
            .commit_from_file(Path::new(&config.model_path))?;
        Ok(Self {
            session,
            config,
            ball_points: Vec::new(),
            candidates: Vec::new(),
        })
    }

    pub fn candidates(&self) -> &[Candidate] {
        &self.candidates
    }

    pub fn push_frame(&mut self, frame: FrameInput) -> Result<FrameResponse, RuntimeError> {
        let detections = detect(&mut self.session, &frame, self.config.confidence_threshold)?;
        if let Some(ball) = detections
            .iter()
            .filter(|detection| detection.class_id == 0)
            .max_by(|a, b| a.confidence.total_cmp(&b.confidence))
        {
            let (x, y) = center(ball);
            self.ball_points.push((
                frame.time_ms,
                x / frame.width as f32,
                y / frame.height as f32,
                ball.confidence,
            ));
            self.detect_crossing();
        }
        Ok(FrameResponse {
            detections,
            candidates: self.candidates.clone(),
            processed_frames: self.ball_points.len(),
        })
    }

    fn detect_crossing(&mut self) {
        let Some(pair) = self.ball_points.windows(2).last() else {
            return;
        };
        let above = pair[0];
        let below = pair[1];
        let rim_y = (self.config.hoop_roi.top + self.config.hoop_roi.bottom) / 2.0;
        let rim_left = self.config.hoop_roi.left;
        let rim_right = self.config.hoop_roi.right;
        if !(above.2 < rim_y && below.2 >= rim_y && below.1 >= rim_left && below.1 <= rim_right) {
            return;
        }
        let crossing = ((rim_y - above.2) / (below.2 - above.2).max(1e-6)).clamp(0.0, 1.0);
        let event_ms = above.0 + ((below.0 - above.0) as f32 * crossing) as i64;
        if self
            .candidates
            .iter()
            .any(|candidate| (candidate.event_ms - event_ms).abs() <= 1_500)
        {
            return;
        }
        let trajectory_score = (0.5 + (below.2 - above.2) * 2.0).clamp(0.0, 1.0);
        let crossing_score = (1.0
            - ((below.1 - (rim_left + rim_right) / 2.0).abs()
                / ((rim_right - rim_left) / 2.0).max(1e-6)))
        .clamp(0.0, 1.0);
        self.candidates.push(Candidate {
            id: format!("candidate_{event_ms}"),
            start_ms: (event_ms - self.config.clip_before_ms).max(0),
            end_ms: event_ms + self.config.clip_after_ms,
            event_ms,
            confidence: (0.5 * above.3 + 0.5 * below.3).clamp(0.0, 1.0),
            trajectory_score,
            crossing_score,
            net_motion_score: 0.0,
        });
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

fn init_onnx() -> Result<(), RuntimeError> {
    let result = ORT_INIT.get_or_init(|| {
        let library = std::env::var_os("BHE_ORT_LIBRARY");
        if let Some(path) = library {
            ORT_LIBRARY_PATH
                .get_or_init(|| Mutex::new(None))
                .lock()
                .expect("ORT library path lock poisoned")
                .replace(path.to_string_lossy().into_owned());
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

fn preprocess(image: &RgbImage) -> Result<(Array4<f32>, f32, f32, f32), RuntimeError> {
    let (width, height) = image.dimensions();
    if width == 0 || height == 0 {
        return Err(RuntimeError::InvalidRequest("empty frame".into()));
    }
    let scale = (MODEL_SIZE as f32 / width as f32).min(MODEL_SIZE as f32 / height as f32);
    let resized = DynamicImage::ImageRgb8(image.clone())
        .resize_exact(
            (width as f32 * scale).round() as u32,
            (height as f32 * scale).round() as u32,
            FilterType::Triangle,
        )
        .to_rgb8();
    let offset_x = (MODEL_SIZE - resized.width()) / 2;
    let offset_y = (MODEL_SIZE - resized.height()) / 2;
    let mut input = Array4::<f32>::zeros((1, 3, MODEL_SIZE as usize, MODEL_SIZE as usize));
    for (x, y, pixel) in resized.enumerate_pixels() {
        let xx = (x + offset_x) as usize;
        let yy = (y + offset_y) as usize;
        input[[0, 0, yy, xx]] = pixel[0] as f32 / 255.0;
        input[[0, 1, yy, xx]] = pixel[1] as f32 / 255.0;
        input[[0, 2, yy, xx]] = pixel[2] as f32 / 255.0;
    }
    Ok((input, scale, offset_x as f32, offset_y as f32))
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
) -> Vec<Detection> {
    if values.len() < 6 * 8_400 {
        return Vec::new();
    }
    let mut candidates = Vec::new();
    for index in 0..8_400 {
        let score_ball = values[4 * 8_400 + index];
        let score_hoop = values[5 * 8_400 + index];
        let (class_id, confidence) = if score_ball >= score_hoop {
            (0, score_ball)
        } else {
            (1, score_hoop)
        };
        if confidence < threshold {
            continue;
        }
        let cx = values[index];
        let cy = values[8_400 + index];
        let w = values[2 * 8_400 + index];
        let h = values[3 * 8_400 + index];
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

fn detect(
    session: &mut Session,
    frame: &FrameInput,
    threshold: f32,
) -> Result<Vec<Detection>, RuntimeError> {
    let image = decode_rgb(frame)?;
    let (input, scale, offset_x, offset_y) = preprocess(&image)?;
    let tensor = Tensor::from_array(input)?;
    let outputs = session.run(ort::inputs![tensor])?;
    let (_, values) = outputs[0].try_extract_tensor::<f32>()?;
    Ok(decode_output(
        values,
        frame.width,
        frame.height,
        scale,
        offset_x,
        offset_y,
        threshold,
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
    if request.hoop_roi.right <= request.hoop_roi.left
        || request.hoop_roi.bottom <= request.hoop_roi.top
    {
        return Err(RuntimeError::InvalidRequest("hoop ROI is invalid".into()));
    }
    init_onnx()?;
    let mut session = Session::builder()
        .map_err(|error| RuntimeError::InvalidRequest(error.to_string()))?
        .with_intra_threads(1)
        .map_err(|error| RuntimeError::InvalidRequest(error.to_string()))?
        .commit_from_file(Path::new(&request.model_path))?;
    let mut ball_points: Vec<(i64, f32, f32, f32)> = Vec::new();
    for frame in &request.frames {
        let detections = detect(&mut session, frame, request.confidence_threshold)?;
        if let Some(ball) = detections
            .iter()
            .filter(|d| d.class_id == 0)
            .max_by(|a, b| a.confidence.total_cmp(&b.confidence))
        {
            let (x, y) = center(ball);
            ball_points.push((
                frame.time_ms,
                x / frame.width as f32,
                y / frame.height as f32,
                ball.confidence,
            ));
        }
    }
    let rim_y = (request.hoop_roi.top + request.hoop_roi.bottom) / 2.0;
    let rim_left = request.hoop_roi.left;
    let rim_right = request.hoop_roi.right;
    let mut candidates = Vec::new();
    for pair in ball_points.windows(2) {
        let above = pair[0];
        let below = pair[1];
        if above.2 < rim_y && below.2 >= rim_y && below.1 >= rim_left && below.1 <= rim_right {
            let crossing = ((rim_y - above.2) / (below.2 - above.2).max(1e-6)).clamp(0.0, 1.0);
            let event_ms = above.0 + ((below.0 - above.0) as f32 * crossing) as i64;
            let trajectory_score = (0.5 + (below.2 - above.2) * 2.0).clamp(0.0, 1.0);
            let crossing_score = (1.0
                - ((below.1 - (rim_left + rim_right) / 2.0).abs()
                    / ((rim_right - rim_left) / 2.0).max(1e-6)))
            .clamp(0.0, 1.0);
            let confidence = (0.5 * above.3 + 0.5 * below.3).clamp(0.0, 1.0);
            let id = format!("candidate_{event_ms}");
            if candidates
                .iter()
                .all(|candidate: &Candidate| (candidate.event_ms - event_ms).abs() > 1_500)
            {
                candidates.push(Candidate {
                    id,
                    start_ms: (event_ms - request.clip_before_ms).max(0),
                    end_ms: event_ms + request.clip_after_ms,
                    event_ms,
                    confidence,
                    trajectory_score,
                    crossing_score,
                    net_motion_score: 0.0,
                });
            }
        }
    }
    Ok(AnalysisResponse {
        candidates,
        processed_frames: request.frames.len(),
        total_frames: request.frames.len(),
    })
}

#[cfg(test)]
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
    fn empty_request_has_zero_frame_counts() {
        let result = analyze(AnalysisRequest {
            model_path: "missing.onnx".into(),
            frames: Vec::new(),
            hoop_roi: roi(),
            net_roi: roi(),
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
            confidence_threshold: 0.1,
            clip_before_ms: 6_000,
            clip_after_ms: 3_000,
        });
        assert!(
            matches!(result, Err(RuntimeError::InvalidRequest(message)) if message == "hoop ROI is invalid")
        );
    }
}

pub fn analyze_json(input: &str) -> Result<String, RuntimeError> {
    let request: AnalysisRequest = serde_json::from_str(input)?;
    Ok(serde_json::to_string(&analyze(request)?)?)
}

pub fn create_session_json(input: &str) -> Result<RuntimeSession, RuntimeError> {
    Ok(RuntimeSession::new(serde_json::from_str(input)?)?)
}

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

#[no_mangle]
pub unsafe extern "C" fn bhe_runtime_free_string(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}
