use base64::{engine::general_purpose::STANDARD, Engine as _};
use serde_json::{json, Value};
use signal_fish_reference_native::engine::{ChannelProfile, Engine, EngineEvent, EngineSettings};
use signal_fish_server::protocol::{IceServer, PlayerId};
use std::io::{BufRead, Write};
use std::sync::OnceLock;
use std::time::Instant;
use tokio::sync::mpsc;

fn emit(mut value: Value) {
    static START: OnceLock<Instant> = OnceLock::new();
    value["probe_us"] = json!(START.get_or_init(Instant::now).elapsed().as_micros() as u64);
    println!("{value}");
    std::io::stdout().flush().unwrap();
}

async fn send_packet(engine: &Engine, peer: PlayerId, value: &Value) -> anyhow::Result<()> {
    let channel = engine.channel(peer, value["label"].as_str().ok_or_else(|| anyhow::anyhow!("missing label"))?).ok_or_else(|| anyhow::anyhow!("missing channel"))?;
    match value["op"].as_str().unwrap_or("") {
        "send" => { channel.send_text(value["text"].as_str().ok_or_else(|| anyhow::anyhow!("missing text"))?).await?; }
        "send_binary" => {
            let data = STANDARD.decode(value["data_base64"].as_str().ok_or_else(|| anyhow::anyhow!("missing binary data"))?)?;
            channel.send(data.as_slice().into()).await?;
        }
        _ => anyhow::bail!("invalid packet operation"),
    }
    Ok(())
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
    loop {
        tokio::select! {
            Some(line) = input.recv() => {
                let value: Value = serde_json::from_str(&line)?;
                let id = value["id"].clone();
                let result: anyhow::Result<Value> = async {
                    if receive_failure.is_none() { receive_failure = rejected_receive(&engine, peer); }
                    if let Some(error) = &receive_failure {
                        engine.remove_peer(peer).await?;
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
                        "send" | "send_binary" => { send_packet(&engine, peer, &value).await?; Ok(Value::Null) }
                        "send_batch" => {
                            let packets = value["packets"].as_array().ok_or_else(|| anyhow::anyhow!("missing packets"))?;
                            anyhow::ensure!(!packets.is_empty() && packets.len() <= 256, "invalid packet batch size");
                            for packet in packets { send_packet(&engine, peer, packet).await?; }
                            Ok(json!(packets.len()))
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
                    Ok(result) => emit(json!({"id": id, "result": result})),
                    Err(error) => emit(json!({"id": id, "error": error.to_string()})),
                }
            }
            Some(event) = events.recv() => {
                if let EngineEvent::ChannelReceiveRejected {generation,label,..} = &event {
                    receive_failure = Some(format!("native receive rejected: generation={generation} channel={label}"));
                    engine.remove_peer(peer).await?;
                    emit(json!({"event":"receive_rejected", "generation":generation, "label":label}));
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
                            for sequence in 0..32 {
                                let data = format!("startup:{startup_phase}:reference:{sequence}:{}", "0123456789abcdef".repeat(64));
                                channel.send(data.as_bytes().into()).await?;
                            }
                            emit(json!({"event":"startup_sent", "generation":generation, "count":32}));
                        }
                        emit(json!({"event":"open", "generation":generation, "label":label,
                            "properties": {"internal_id":channel.id(), "negotiated":channel.negotiated().await?,
                                "ordered":channel.ordered().await?,
                                "lifetime":channel.max_packet_life_time().await?,
                                "retransmits":channel.max_retransmits().await?}}));
                    }
                    EngineEvent::PcState {state,..} => emit(json!({"event":"state", "generation":generation, "state":state.to_string()})),
                    EngineEvent::ChannelMessage {label,text,queue_permit,..} => {
                        emit(json!({"event":"message", "generation":generation, "label":label,"text":text}));
                        drop(queue_permit);
                    }
                    EngineEvent::ChannelBinaryMessage {label,data,queue_permit,..} => {
                        emit(json!({"event":"binary", "generation":generation, "label":label,"data_base64":STANDARD.encode(data)}));
                        drop(queue_permit);
                    }
                    EngineEvent::ChannelClosed {label,..} => emit(json!({"event":"closed", "generation":generation, "label":label})),
                    _ => {}
                }
            }
            else => break,
        }
    }
    Ok(())
}
