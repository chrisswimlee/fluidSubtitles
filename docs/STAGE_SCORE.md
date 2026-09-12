# Score a Theater talk

Do not invent WER or HUD numbers. After a real Listen:

1. Export bilingual text or copy `TheaterSession.jsonl` from Application Support.
2. Make a reference file with one JSON object per line:

```json
{"languageID":"en","reference":"Today we trained the model.","hypothesis":"Today we trained the model."}
```

3. Run:

```
python3 scripts/score-theater-talk.py reference.jsonl
```

Optional: pass `LastListenLatency.json` as the second argument. The script prints mean error and whether every line would pass the 15% “would I show this” bar.

English uses word error. Korean and Thai use character error. Same rule as `TheaterQualityScore`.

A 9 on ASR is about 8% English and 12% Korean/Thai on a 20-minute close-mic talk. A 9 on translation is every line at or under 15% against a bilingual reference.
