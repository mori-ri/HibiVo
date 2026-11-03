//! Microphone capture with cpal (WASAPI): the default input device, converted to 16-bit mono PCM at the rate the
//! STT provider wants and streamed to the main window in ~100 ms chunks.
//!
//! The stream lives on its own thread, which owns it from start to stop. The audio callback only converts samples
//! and hands them to that thread, which does the IPC.

use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::Mutex;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, SampleFormat, SizedSample, StreamConfig};
use hibivo_core::resample::{downmix, Resampler};
use tauri::ipc::{Channel, InvokeResponseBody};
use tauri::State;

/// 100 ms at 16 kHz. Small enough for live partials, large enough to keep IPC overhead low.
const CHUNK_SAMPLES: usize = 1_600;

enum Message {
    Samples(Vec<i16>),
    Stop,
}

struct Running {
    sender: Sender<Message>,
    thread: JoinHandle<()>,
}

#[derive(Default)]
pub struct AudioState {
    running: Mutex<Option<Running>>,
}

/// Starts recording. Resolves once the microphone is running.
/// Chunks arrive on `on_chunk` as raw little-endian PCM16; an empty chunk marks the end after `audio_stop`.
#[tauri::command]
pub async fn audio_start(
    state: State<'_, AudioState>,
    sample_rate: u32,
    on_chunk: Channel<InvokeResponseBody>,
) -> Result<(), String> {
    stop_running(&state);
    let (sender, receiver) = mpsc::channel::<Message>();
    let (ready_sender, ready_receiver) = mpsc::channel::<Result<(), String>>();
    let callback_sender = sender.clone();
    let thread = thread::Builder::new()
        .name("audio".into())
        .spawn(move || run(sample_rate, callback_sender, receiver, ready_sender, on_chunk))
        .map_err(|e| e.to_string())?;
    let ready = tauri::async_runtime::spawn_blocking(move || {
        ready_receiver
            .recv_timeout(Duration::from_secs(10))
            .unwrap_or_else(|_| Err("microphone start timed out".into()))
    })
    .await
    .map_err(|e| e.to_string())?;
    match ready {
        Ok(()) => {
            *state.running.lock().map_err(|e| e.to_string())? = Some(Running { sender, thread });
            Ok(())
        }
        Err(error) => {
            let _ = sender.send(Message::Stop);
            Err(error)
        }
    }
}

/// Stops recording. Returns after the last chunk and the end marker have been sent.
#[tauri::command]
pub async fn audio_stop(state: State<'_, AudioState>) -> Result<(), String> {
    let running = state.running.lock().map_err(|e| e.to_string())?.take();
    if let Some(running) = running {
        tauri::async_runtime::spawn_blocking(move || {
            let _ = running.sender.send(Message::Stop);
            let _ = running.thread.join();
        })
        .await
        .map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn stop_running(state: &AudioState) {
    if let Some(running) = state.running.lock().ok().and_then(|mut r| r.take()) {
        let _ = running.sender.send(Message::Stop);
        let _ = running.thread.join();
    }
}

fn run(
    sample_rate: u32,
    sender: Sender<Message>,
    receiver: Receiver<Message>,
    ready: Sender<Result<(), String>>,
    on_chunk: Channel<InvokeResponseBody>,
) {
    let stream = match open_stream(sample_rate, sender) {
        Ok(stream) => stream,
        Err(error) => {
            log::error!("Microphone start failed: {error}");
            let _ = ready.send(Err(error));
            return;
        }
    };
    let _ = ready.send(Ok(()));

    let mut pending: Vec<i16> = Vec::with_capacity(CHUNK_SAMPLES * 2);
    let flush = |pending: &mut Vec<i16>| {
        if pending.is_empty() {
            return;
        }
        let bytes: Vec<u8> = pending.iter().flat_map(|s| s.to_le_bytes()).collect();
        pending.clear();
        let _ = on_chunk.send(InvokeResponseBody::Raw(bytes));
    };
    for message in receiver.iter() {
        match message {
            Message::Samples(samples) => {
                pending.extend_from_slice(&samples);
                if pending.len() >= CHUNK_SAMPLES {
                    flush(&mut pending);
                }
            }
            Message::Stop => break,
        }
    }
    drop(stream);
    // Samples the callback queued before the stream stopped still belong to the utterance.
    while let Ok(Message::Samples(samples)) = receiver.try_recv() {
        pending.extend_from_slice(&samples);
    }
    flush(&mut pending);
    let _ = on_chunk.send(InvokeResponseBody::Raw(Vec::new()));
}

fn open_stream(sample_rate: u32, sender: Sender<Message>) -> Result<cpal::Stream, String> {
    let host = cpal::default_host();
    let device = host.default_input_device().ok_or("no input device")?;
    let supported = device.default_input_config().map_err(|e| e.to_string())?;
    let config: StreamConfig = supported.config();
    let stream = match supported.sample_format() {
        SampleFormat::F32 => build::<f32>(&device, &config, sample_rate, sender),
        SampleFormat::I16 => build::<i16>(&device, &config, sample_rate, sender),
        SampleFormat::U16 => build::<u16>(&device, &config, sample_rate, sender),
        SampleFormat::I32 => build::<i32>(&device, &config, sample_rate, sender),
        other => return Err(format!("unsupported sample format {other:?}")),
    }?;
    stream.play().map_err(|e| e.to_string())?;
    Ok(stream)
}

fn build<T>(
    device: &cpal::Device,
    config: &StreamConfig,
    sample_rate: u32,
    sender: Sender<Message>,
) -> Result<cpal::Stream, String>
where
    T: SizedSample,
    f32: FromSample<T>,
{
    let channels = config.channels as usize;
    let mut resampler = Resampler::new(config.sample_rate, sample_rate);
    let mut floats: Vec<f32> = Vec::new();
    device
        .build_input_stream::<T, _, _>(
            *config,
            move |data: &[T], _| {
                floats.clear();
                floats.extend(data.iter().map(|s| s.to_sample::<f32>()));
                let mono = downmix(&floats, channels);
                let mut out = Vec::with_capacity(mono.len());
                resampler.process(&mono, &mut out);
                if !out.is_empty() {
                    let _ = sender.send(Message::Samples(out));
                }
            },
            |error| log::error!("Microphone stream error: {error}"),
            None,
        )
        .map_err(|e| e.to_string())
}
