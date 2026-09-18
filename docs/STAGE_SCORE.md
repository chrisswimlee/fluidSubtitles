# Score a Theater talk

Do not invent WER or HUD numbers. After a real Listen:

1. Export bilingual text from the visible Theater board.
2. Make a reference file with one JSON object per line. Layout only — these lines are not a scored talk:

```json
{"languageID":"en","reference":"Today we trained the model.","hypothesis":"Today we trained the model."}
{"languageID":"en","reference":"The next lecture starts at noon.","hypothesis":"The next lecture starts at noon."}
{"languageID":"en","reference":"Please take a seat.","hypothesis":"Please take a seat."}
{"languageID":"ko","reference":"오늘 모델을 학습했습니다.","hypothesis":"오늘 모델을 학습했습니다."}
{"languageID":"ja","reference":"今日はモデルを学習しました。","hypothesis":"今日はモデルを学習しました。"}
```

3. Run:

```
python3 scripts/score-theater-talk.py reference.jsonl
```

Optional: pass `LastListenLatency.json` as the second argument. The script prints mean error and whether every line would pass the 15% “would I show this” bar.

English uses word error. Korean, Japanese, and Thai use character error. Same rule as `TheaterQualityScore`.

A 9 on ASR is about 8% English and 12% Korean/Thai on a 20-minute close-mic talk. A 9 on translation is every line at or under 15% against a bilingual reference.

## Maintainer first talk

Do this once on a real Mac before you treat Theater as proven. Do not invent WER.

1. One English lectern (or Korean / Thai / Japanese). Microphone only.
2. Export bilingual text from the visible Theater board.
3. Build `reference.jsonl` and run `python3 scripts/score-theater-talk.py reference.jsonl [LastListenLatency.json]`.
4. Check the script output and `LastListenLatency.json` into [docs/samples/](samples/). That file is the project proof. Hosted CI only stores it. Watch is not a required pair.

## Samples

`docs/samples/LastListenLatency.json` is a real lectern clock from the maintainer Mac: e2e 1969 ms, ASR 383 ms, MT 142 ms, thermal nominal. Hosted CI only stores it. A bilingual WER/CER score is still missing because there is no reference JSONL for that talk. Do not invent one.

Korean and Japanese leftover commits on EOU, silence, or Stop. The 1.0 s / 6.0 s settle helpers are unused; do not invent a new land clock. A long connective can print as a caption; that is a clause rule, not a new clock.
