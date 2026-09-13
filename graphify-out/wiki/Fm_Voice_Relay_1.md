# Fm Voice Relay 1

> 20 nodes · cohesion 0.22

## Key Concepts

- **Session** (18 connections) — `bin/fm-voice-relay.py`
- **log()** (17 connections) — `bin/fm-voice-relay.py`
- **._send()** (8 connections) — `bin/fm-voice-relay.py`
- **._handle()** (6 connections) — `bin/fm-voice-relay.py`
- **._read_model()** (6 connections) — `bin/fm-voice-relay.py`
- **.audio()** (5 connections) — `bin/fm-voice-relay.py`
- **._run_tool()** (5 connections) — `bin/fm-voice-relay.py`
- **.talk_end()** (5 connections) — `bin/fm-voice-relay.py`
- **.start()** (4 connections) — `bin/fm-voice-relay.py`
- **.talk_start()** (4 connections) — `bin/fm-voice-relay.py`
- **.close()** (3 connections) — `bin/fm-voice-relay.py`
- **._mark()** (3 connections) — `bin/fm-voice-relay.py`
- **._trace()** (3 connections) — `bin/fm-voice-relay.py`
- **._event()** (2 connections) — `bin/fm-voice-relay.py`
- **One Nova Sonic bidirectional session, plus the turn bookkeeping around it.** (1 connections) — `bin/fm-voice-relay.py`
- **Open an audio block for a new turn, if one is not already open.** (1 connections) — `bin/fm-voice-relay.py`
- **Forward captured audio, chunked the way the measurements were taken. Audio with…** (1 connections) — `bin/fm-voice-relay.py`
- **Close the turn: pad with silence, then close the audio block. The padding is…** (1 connections) — `bin/fm-voice-relay.py`
- **Read the model's events until the stream ends or fails, and report which.…** (1 connections) — `bin/fm-voice-relay.py`
- **.__init__()** (1 connections) — `bin/fm-voice-relay.py`

## Relationships

- [Fm Voice Relay 3](Fm_Voice_Relay_3.md) (9 shared connections)
- [Fm Voice Relay 2](Fm_Voice_Relay_2.md) (4 shared connections)

## Source Files

- `bin/fm-voice-relay.py`

## Audit Trail

- EXTRACTED: 54 (100%)
- INFERRED: 0 (0%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*