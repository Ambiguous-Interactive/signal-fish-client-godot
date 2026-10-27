use base64::{engine::general_purpose::STANDARD, Engine as _};
use serde_json::{json, Value};
use signal_fish_reference_native::engine::{ChannelProfile, Engine, EngineEvent, EngineSettings};
use signal_fish_server::protocol::{IceServer, PlayerId};
use std::future::Future;
use std::io::{BufRead, Write};
use std::pin::Pin;
use std::sync::OnceLock;
use std::time::Instant;
use tokio::sync::mpsc;

static START: OnceLock<Instant> = OnceLock::new();

fn emit(mut value: Value) {
    value["probe_us"] = json!(START.get_or_init(Instant::now).elapsed().as_micros() as u64);
    println!("{value}");
    std::io::stdout().flush().unwrap();
}

type SendFuture = Pin<Box<dyn Future<Output = anyhow::Result<Value>> + Send>>;

struct PendingSend {
    id: Option<Value>,
    generation: Value,
    future: SendFuture,
}

enum Action<T> {
    Command(String),
    Event(T),
    Sent(anyhow::Result<Value>),
}

async fn next_action<T>(
    input: &mut mpsc::UnboundedReceiver<String>,
    events: &mut mpsc::UnboundedReceiver<T>,
    pending: &mut Option<PendingSend>,
) -> Option<Action<T>> {
    tokio::select! {
        Some(line) = input.recv(), if pending.is_none() => Some(Action::Command(line)),
        Some(event) = events.recv() => Some(Action::Event(event)),
        result = async { pending.as_mut().unwrap().future.as_mut().await }, if pending.is_some() => Some(Action::Sent(result)),
        else => None,
    }
}

fn cancel_send(pending: &mut Option<PendingSend>, error: &str) {
    if let Some(cancelled) = pending.take() {
        if let Some(id) = cancelled.id {
            emit(json!({"id":id, "error":error}));
        }
    }
}

fn prepare_send(engine: &Engine, peer: PlayerId, value: &Value) -> anyhow::Result<SendFuture> {
    let batch = value["op"] == "send_batch";
    let packets = if batch {
        let packets = value["packets"].as_array().ok_or_else(|| anyhow::anyhow!("missing packets"))?;
        anyhow::ensure!(!packets.is_empty() && packets.len() <= 256, "invalid packet batch size");
        packets.clone()
    } else {
        vec![value.clone()]
    };
    let generation = engine.diagnostic_snapshot(peer)["generation"].clone();
    let mut writes = Vec::new();
    for packet in packets {
        let channel = engine.channel(peer, packet["label"].as_str().ok_or_else(|| anyhow::anyhow!("missing label"))?).ok_or_else(|| anyhow::anyhow!("missing channel"))?;
        let bytes = match packet["op"].as_str().unwrap_or("") {
            "send" => None,
            "send_binary" => Some(STANDARD.decode(packet["data_base64"].as_str().ok_or_else(|| anyhow::anyhow!("missing binary data"))?)?),
            _ => anyhow::bail!("invalid packet operation"),
        };
        if bytes.is_none() { anyhow::ensure!(packet["text"].is_string(), "missing text"); }
        writes.push((channel, packet, bytes));
    }
    Ok(Box::pin(async move {
        let count = writes.len();
        for (channel, packet, bytes) in writes {
            if let Some(data) = bytes {
                channel.send(data.as_slice().into()).await?;
            } else {
                channel.send_text(packet["text"].as_str().unwrap()).await?;
            }
            emit(json!({"event":"sent", "generation":generation, "label":packet["label"],
                "marker":packet["text"].as_str().map(|text| text.split(':').take(4).collect::<Vec<_>>().join(":"))}));
        }
        Ok(if batch { json!(count) } else { Value::Null })
    }))
}

fn rejected_receive(engine: &Engine, peer: PlayerId) -> Option<String> {
    let snapshot = engine.diagnostic_snapshot(peer);
    let channels = snapshot["channels"].as_object()?;
    channels.iter().find_map(|(label, channel)| {
        (channel["receipts"]["rejected"].as_u64().unwrap_or(0) > 0)
            .then(|| format!("native receive rejected: generation={} channel={label}", snapshot["generation"]))
    })
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    START.get_or_init(Instant::now);
    let peer: PlayerId = "10000000-0000-0000-0000-000000000001".parse()?;
    let (events_tx, mut events) = mpsc::unbounded_channel();
    let (input_tx, mut input) = mpsc::unbounded_channel();
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            let Ok(line) = line else { break };
            if input_tx.send(line).is_err() { break; }
        }
    });
    let mut engine = Engine::new(EngineSettings {
        channel_profile: ChannelProfile::Godot,
        ..EngineSettings::default()
    }, events_tx)?;
    let mut startup_phase = 0;
    let mut receive_failure: Option<String> = None;
    let mut pending = None;
    while let Some(action) = next_action(&mut input, &mut events, &mut pending).await {
        match action {
            Action::Command(line) => {
                let value: Value = serde_json::from_str(&line)?;
                let id = value["id"].clone();
                let result: anyhow::Result<Value> = async {
                    if receive_failure.is_none() { receive_failure = rejected_receive(&engine, peer); }
                    if let Some(error) = &receive_failure {
                        let _ = engine.remove_peer(peer).await;
                        anyhow::bail!("{error}");
                    }
                    match value["op"].as_str().unwrap_or("") {
                        "pair" => {
                            startup_phase = value["startup_phase"].as_u64().unwrap_or(0);
                            anyhow::ensure!(startup_phase <= 2, "invalid startup phase");
                            let servers: Vec<IceServer> = serde_json::from_value(value["ice_servers"].clone())?;
                            let offer = engine.pair_with(peer, value["offer"].as_bool().unwrap(), &servers).await?;
                            Ok(json!({"offer":offer,"generation":engine.diagnostic_snapshot(peer)["generation"]}))
                        }
                        "offer" => Ok(json!(engine.handle_offer(peer, value["sdp"].as_str().unwrap().to_owned()).await?)),
                        "answer" => { engine.handle_answer(peer, value["sdp"].as_str().unwrap().to_owned()).await?; Ok(Value::Null) }
                        "candidate" => { engine.handle_remote_candidate(peer, value["candidate"].as_str().unwrap()).await?; Ok(Value::Null) }
                        "send" | "send_binary" | "send_batch" => {
                            pending = Some(PendingSend {
                                id: Some(id.clone()),
                                generation: engine.diagnostic_snapshot(peer)["generation"].clone(),
                                future: prepare_send(&engine, peer, &value)?,
                            });
                            Ok(Value::Null)
                        }
                        "close" => {
                            let channel = engine.channel(peer, value["label"].as_str().unwrap()).ok_or_else(|| anyhow::anyhow!("missing channel"))?;
                            channel.close().await?;
                            Ok(Value::Null)
                        }
                        "remove" => { engine.remove_peer(peer).await?; Ok(json!(!engine.is_paired(peer))) }
                        "snapshot" => Ok(engine.diagnostic_snapshot(peer)),
                        _ => anyhow::bail!("unknown operation"),
                    }
                }.await;
                match result {
                    Ok(result) => if pending.is_none() { emit(json!({"id": id, "result": result})); },
                    Err(error) => emit(json!({"id": id, "error": error.to_string()})),
                }
            }
            Action::Sent(result) => {
                let finished = pending.take().unwrap();
                if let Some(id) = finished.id {
                    match result {
                        Ok(result) => emit(json!({"id":id, "result":result})),
                        Err(error) => emit(json!({"id":id, "error":error.to_string()})),
                    }
                } else {
                    result?;
                    emit(json!({"event":"startup_sent", "generation":finished.generation, "count":32}));
                }
            }
            Action::Event(event) => {
                if let EngineEvent::ChannelReceiveRejected {generation,label,..} = &event {
                    if receive_failure.is_none() {
                        receive_failure = Some(format!("native receive rejected: generation={generation} channel={label}"));
                        emit(json!({"event":"receive_rejected", "generation":generation, "label":label}));
                    }
                    cancel_send(&mut pending, receive_failure.as_deref().unwrap());
                    let _ = engine.remove_peer(peer).await;
                    continue;
                }
                if !engine.is_current_event(&event) { continue; }
                let (_, generation) = event.peer_generation();
                match event {
                    EngineEvent::LocalCandidate {candidate_json,..} => emit(json!({"event":"candidate", "generation":generation, "candidate":candidate_json})),
                    EngineEvent::ChannelOpen {label,..} => {
                        engine.note_channel_open(peer,&label).await;
                        let channel = engine.channel(peer, &label).unwrap();
                        if startup_phase > 0 && label == "reliable" {
                            anyhow::ensure!(pending.is_none(), "startup overlaps an active send");
                            let packets: Vec<Value> = (0..32).map(|sequence| json!({
                                "op":"send_binary", "label":"reliable",
                                "data_base64":STANDARD.encode(format!("startup:{startup_phase}:reference:{sequence}:{}", "0123456789abcdef".repeat(64)))
                            })).collect();
                            pending = Some(PendingSend {
                                id: None,
                                generation: json!(generation),
                                future: prepare_send(&engine, peer, &json!({"op":"send_batch", "packets":packets}))?,
                            });
                        }
                        emit(json!({"event":"open", "generation":generation, "label":label,
                            "properties": {"internal_id":channel.id(), "negotiated":channel.negotiated().await?,
                                "ordered":channel.ordered().await?,
                                "lifetime":channel.max_packet_life_time().await?,
                                "retransmits":channel.max_retransmits().await?}}));
                    }
                    EngineEvent::PcState {state,..} => emit(json!({"event":"state", "generation":generation, "state":state.to_string()})),
                    EngineEvent::ChannelMessage {label,text,queue_permit,received_at,..} => {
                        emit(json!({"event":"message", "generation":generation, "label":label,"text":text, "received_us":received_at.into_std().saturating_duration_since(*START.get().unwrap()).as_micros() as u64}));
                        drop(queue_permit);
                    }
                    EngineEvent::ChannelBinaryMessage {label,data,queue_permit,received_at,..} => {
                        emit(json!({"event":"binary", "generation":generation, "label":label,"data_base64":STANDARD.encode(data), "received_us":received_at.into_std().saturating_duration_since(*START.get().unwrap()).as_micros() as u64}));
                        drop(queue_permit);
                    }
                    EngineEvent::ChannelClosed {label,..} => {
                        cancel_send(&mut pending, &format!("native channel closed during send: generation={generation} channel={label}"));
                        emit(json!({"event":"closed", "generation":generation, "label":label}));
                    }
                    _ => {}
                }
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::oneshot;
    use tokio::time::{timeout, Duration};

    #[tokio::test]
    async fn held_send_drains_receives_without_overtaking_commands() {
        let (commands, mut input) = mpsc::unbounded_channel();
        let (callbacks, mut events) = mpsc::unbounded_channel();
        let (release, held) = oneshot::channel();
        let mut pending = Some(PendingSend {
            id: Some(json!(7)),
            generation: json!(1),
            future: Box::pin(async move { held.await?; Ok(json!(32)) }),
        });
        commands.send("snapshot".into()).unwrap();
        commands.send("remove".into()).unwrap();
        for sequence in 0..64 {
            callbacks.send(sequence).unwrap();
            let action = timeout(Duration::from_secs(1), next_action(&mut input, &mut events, &mut pending)).await.unwrap();
            assert!(matches!(action, Some(Action::Event(value)) if value == sequence));
            assert_eq!(input.len(), 2);
        }
        release.send(()).unwrap();
        let action = next_action(&mut input, &mut events, &mut pending).await;
        assert!(matches!(action, Some(Action::Sent(Ok(value))) if value == json!(32)));
        assert_eq!(pending.take().unwrap().id, Some(json!(7)));
        for expected in ["snapshot", "remove"] {
            assert!(matches!(next_action(&mut input, &mut events, &mut pending).await,
                Some(Action::Command(value)) if value == expected));
        }
        drop(commands);
        drop(callbacks);
        assert!(next_action(&mut input, &mut events, &mut pending).await.is_none());
    }

    #[tokio::test]
    async fn failed_sends_report_errors_and_cancellation_drops_the_future() {
        let (_commands, mut input) = mpsc::unbounded_channel();
        let (callbacks, mut events) = mpsc::unbounded_channel::<()>();
        let mut pending = Some(PendingSend {
            id: Some(json!(8)),
            generation: json!(1),
            future: Box::pin(async { anyhow::bail!("write failed") }),
        });
        let action = next_action(&mut input, &mut events, &mut pending).await;
        assert!(matches!(action, Some(Action::Sent(Err(error))) if error.to_string() == "write failed"));
        pending.take();
        let (release, held) = oneshot::channel::<()>();
        pending = Some(PendingSend {
            id: Some(json!(9)),
            generation: json!(1),
            future: Box::pin(async move { held.await?; Ok(Value::Null) }),
        });
        callbacks.send(()).unwrap();
        assert!(matches!(next_action(&mut input, &mut events, &mut pending).await, Some(Action::Event(()))));
        cancel_send(&mut pending, "receive rejected");
        assert!(pending.is_none());
        assert!(release.send(()).is_err());
    }
}
