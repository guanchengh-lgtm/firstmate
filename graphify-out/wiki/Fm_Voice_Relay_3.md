# Fm Voice Relay 3

> 17 nodes · cohesion 0.18

## Key Concepts

- **fm-voice-relay.py** (21 connections) — `bin/fm-voice-relay.py`
- **serve()** (9 connections) — `bin/fm-voice-relay.py`
- **handle_uplink_frame()** (6 connections) — `bin/fm-voice-relay.py`
- **main()** (5 connections) — `bin/fm-voice-relay.py`
- **renew()** (5 connections) — `bin/fm-voice-relay.py`
- **self_test()** (5 connections) — `bin/fm-voice-relay.py`
- **fail_turn()** (4 connections) — `bin/fm-voice-relay.py`
- **read_uplink_frame()** (3 connections) — `bin/fm-voice-relay.py`
- **resolve_settings()** (3 connections) — `bin/fm-voice-relay.py`
- **parse_args()** (2 connections) — `bin/fm-voice-relay.py`
- **Feed one PCM file through a real session and report the timings.** (1 connections) — `bin/fm-voice-relay.py`
- **Fill in what this home configures, refusing rather than guessing. Deliberately…** (1 connections) — `bin/fm-voice-relay.py`
- **Mark a session spent and name this turn's failure to the client. One place,…** (1 connections) — `bin/fm-voice-relay.py`
- **Replace a session that has already answered once, and return the new one.…** (1 connections) — `bin/fm-voice-relay.py`
- **Return the next (kind, payload) the client sent, or raise on a bad header. The…** (1 connections) — `bin/fm-voice-relay.py`
- **Act on one frame from the client. Returns (session to use next, keep serving).…** (1 connections) — `bin/fm-voice-relay.py`
- **Relay frames between the client on stdin/stdout and the model sessions behind…** (1 connections) — `bin/fm-voice-relay.py`

## Relationships

- [Fm Voice Relay 1](Fm_Voice_Relay_1.md) (9 shared connections)
- [Fm Voice Relay 2](Fm_Voice_Relay_2.md) (9 shared connections)
- [Fm Voice Relay 4](Fm_Voice_Relay_4.md) (2 shared connections)
- [Fm Voice Frame](Fm_Voice_Frame.md) (1 shared connections)
- [Fm Voice Records](Fm_Voice_Records.md) (1 shared connections)

## Source Files

- `bin/fm-voice-relay.py`

## Audit Trail

- EXTRACTED: 46 (100%)
- INFERRED: 0 (0%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*