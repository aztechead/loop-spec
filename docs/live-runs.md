# loop-spec 8.x live runs

For a contributor who needs to show, or check, how loop-spec behaves with a real
model. Unit tests cover the program's deterministic Python; everything a model does
in a run is shown here by a recorded live run, never simulated.

No 8.x run is recorded yet. Record one per row below as it happens.

## How to record a run

1. Run an entry against a throwaway repository with an `origin` you can push to, in
   Claude Code (`claude -p ... --output-format stream-json --verbose > run.jsonl`) or
   with [examples/sdk-plugin](../examples/sdk-plugin/README.md).
2. Add a row: the date, the loop-spec commit, the entry and mode, the lead's model,
   what the run showed, and its result (`status`, PR link if public).
3. Keep the transcript out of the repository; note where it is kept, if anywhere.

| Date | Commit | Entry, mode | Lead model | What it showed | Result |
|---|---|---|---|---|---|
