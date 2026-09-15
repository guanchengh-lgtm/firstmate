# Fm Voice Client 2

> 13 nodes · cohesion 0.15

## Key Concepts

- **._start()** (14 connections) — `bin/fm-voice-client.py`
- **sync_magic()** (5 connections) — `bin/fm-voice-client.py`
- **Uplink** (5 connections) — `bin/fm-voice-client.py`
- **._wait_ready()** (3 connections) — `bin/fm-voice-client.py`
- **open_file_end()** (3 connections) — `bin/fm-voice-client.py`
- **relay_command()** (3 connections) — `bin/fm-voice-client.py`
- **Discard anything ahead of the relay's magic preamble. `ssh host command` runs…** (1 connections) — `bin/fm-voice-client.py`
- **Return the argv that starts the relay, locally or over SSH.** (1 connections) — `bin/fm-voice-client.py`
- **Serialise every frame the client sends, from whichever thread sends it.** (1 connections) — `bin/fm-voice-client.py`
- **Open a file-backed end of the audio, naming the path and the flag for it. The…** (1 connections) — `bin/fm-voice-client.py`
- **Wait for the relay's ready notice, or for the connection to close first. A…** (1 connections) — `bin/fm-voice-client.py`
- **.__init__()** (1 connections) — `bin/fm-voice-client.py`
- **.send()** (1 connections) — `bin/fm-voice-client.py`

## Relationships

- [Fm Voice Client 1](Fm_Voice_Client_1.md) (7 shared connections)
- [Fm Voice Client 3](Fm_Voice_Client_3.md) (5 shared connections)
- [Fm Voice Client 7](Fm_Voice_Client_7.md) (1 shared connections)
- [Fm Voice Client 5](Fm_Voice_Client_5.md) (1 shared connections)
- [Fm Voice Client 6](Fm_Voice_Client_6.md) (1 shared connections)
- [Fm Voice Client 4](Fm_Voice_Client_4.md) (1 shared connections)

## Source Files

- `bin/fm-voice-client.py`

## Audit Trail

- EXTRACTED: 28 (100%)
- INFERRED: 0 (0%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*