# Good first issues

File these on the public GitHub repo with labels `good first issue` and `help wanted`. Each ticket stays inside Theater docs, `LiveTranslation/`, or a small test. Do not point first-time contributors at `ASRService` or FluidVoice grandparents.

`scripts/enable-github-gates.sh` files one GitHub issue per `##` heading below.

Settings search finds Theater, Voice, and Translate. The latency HUD tokens are in [docs/LIVE_TRANSLATION_LATENCY.md](../docs/LIVE_TRANSLATION_LATENCY.md). Stage-score JSONL layout is in [docs/STAGE_SCORE.md](../docs/STAGE_SCORE.md). Theater smoke looks for `theater.status` after Open Theater.

---

## Add a 30-second EN→KO Listen clip

**Labels:** `good first issue`, `documentation`

**Problem:** The README still uses stills. A stranger should see Korean type on top and the English undertone without reading the architecture note.

**Where to edit:** `docs/screenshots/` and `README.md`. Record Listen, one sentence, Korean title, English undertone, then hide the spoken line. Do not invent HUD numbers. Do not add Watch copy.

**Done when:** The README first screen includes that clip. No `ASRService` changes.

---

## Check in a real stage-score snippet

**Labels:** `good first issue`, `documentation`

**Problem:** Hosted CI cannot caption a live listen. [docs/STAGE_SCORE.md](../docs/STAGE_SCORE.md) is the only talk proof, and it is empty until someone scores a real Mac listen.

**Where to edit:** `docs/samples/` and `docs/STAGE_SCORE.md`. Export `LastListenLatency.json` or bilingual JSONL from Application Support, run `python3 scripts/score-theater-talk.py`, and check in that snippet. Do not invent WER or HUD numbers.

**Done when:** One dated lectern score is in the tree. Watch proof is not required.
