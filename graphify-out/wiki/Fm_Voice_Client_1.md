# Fm Voice Client 1

> 28 nodes · cohesion 0.11

## Key Concepts

- **Client** (19 connections) — `bin/fm-voice-client.py`
- **log()** (8 connections) — `bin/fm-voice-client.py`
- **say()** (8 connections) — `bin/fm-voice-client.py`
- **.take_turn()** (6 connections) — `bin/fm-voice-client.py`
- **._push_to_talk()** (5 connections) — `bin/fm-voice-client.py`
- **.run()** (5 connections) — `bin/fm-voice-client.py`
- **._downlink()** (4 connections) — `bin/fm-voice-client.py`
- **._let_reply_finish()** (4 connections) — `bin/fm-voice-client.py`
- **.open()** (4 connections) — `bin/fm-voice-client.py`
- **._quietly()** (4 connections) — `bin/fm-voice-client.py`
- **._say_stopped()** (4 connections) — `bin/fm-voice-client.py`
- **.close()** (3 connections) — `bin/fm-voice-client.py`
- **._say_dropped()** (3 connections) — `bin/fm-voice-client.py`
- **._unfinished()** (3 connections) — `bin/fm-voice-client.py`
- **._wait_audio_quiet()** (3 connections) — `bin/fm-voice-client.py`
- **._sender()** (2 connections) — `bin/fm-voice-client.py`
- **.__init__()** (1 connections) — `bin/fm-voice-client.py`
- **Run one turn and return its record, or None if the connection is gone. The…** (1 connections) — `bin/fm-voice-client.py`
- **Wait for the reply audio to stop arriving before reading the turn. Measured,…** (1 connections) — `bin/fm-voice-client.py`
- **Open the gate, close it, and return the moment the captain stopped. That…** (1 connections) — `bin/fm-voice-client.py`
- **Wait for the previous answer to finish before opening another turn. The model…** (1 connections) — `bin/fm-voice-client.py`
- **Name why no more turns can be taken, and which run was the first lost. The…** (1 connections) — `bin/fm-voice-client.py`
- **One relay connection and the turns taken over it.** (1 connections) — `bin/fm-voice-client.py`
- **Start the relay, the audio devices and the two frame threads. A startup that…** (1 connections) — `bin/fm-voice-client.py`
- **Run one cleanup step without letting it mask why we are cleaning up.** (1 connections) — `bin/fm-voice-client.py`
- *... and 3 more nodes in this community*

## Relationships

- [Fm Voice Client 2](Fm_Voice_Client_2.md) (7 shared connections)
- [Fm Voice Client 3](Fm_Voice_Client_3.md) (5 shared connections)
- [Fm Voice Client 6](Fm_Voice_Client_6.md) (1 shared connections)

## Source Files

- `bin/fm-voice-client.py`

## Audit Trail

- EXTRACTED: 54 (98%)
- INFERRED: 1 (2%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*