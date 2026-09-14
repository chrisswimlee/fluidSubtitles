# Score a Theater talk

Do not invent WER or HUD numbers. After a real Listen:

1. Export bilingual text or copy `TheaterSession.jsonl` from Application Support.
2. Make a reference file with one JSON object per line. Layout only — these lines are not a scored talk:

```json
{"languageID":"en","reference":"Today we trained the model.","hypothesis":"Today we trained the model."}
{"languageID":"en","reference":"The next lecture starts at noon.","hypothesis":"The next lecture starts at noon."}
{"languageID":"en","reference":"Please take a seat.","hypothesis":"Please take a seat."}
{"languageID":"ko","reference":"오늘 모델을 학습했습니다.","hypothesis":"오늘 모델을 학습했습니다."}
```

3. Run:

```
python3 scripts/score-theater-talk.py reference.jsonl
```

Optional: pass `LastListenLatency.json` as the second argument. The script prints mean error and whether every line would pass the 15% “would I show this” bar.

English uses word error. Korean and Thai use character error. Same rule as `TheaterQualityScore`.

A 9 on ASR is about 8% English and 12% Korean/Thai on a 20-minute close-mic talk. A 9 on translation is every line at or under 15% against a bilingual reference.

## Maintainer first talk

Do this once on a real Mac before you treat Theater as proven. Do not invent WER.

1. One English lectern **or** one Watch clip (see [WATCH_PROOF.md](WATCH_PROOF.md)).
2. Export bilingual text or copy `TheaterSession.jsonl`.
3. Build `reference.jsonl` and run `python3 scripts/score-theater-talk.py reference.jsonl`.
4. Keep the script output next to the Watch proof note. That pair is the project proof, not a CI badge.
