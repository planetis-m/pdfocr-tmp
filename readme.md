# Benchmark Comparison Findings

This document compares the competing implementation's reported live benchmark against our most recent live debug run.

## Compared Runs

- Competitor command:
  - `set -a; source .env; set +a; LD_LIBRARY_PATH=./third_party/pdfium/lib /usr/bin/time -f 'elapsed_s=%e' ./pdfocr_debug test_files/slides.pdf --all-pages > /tmp/slides_debug.jsonl`
- Our command:
  - `set -a; source .env; set +a; /usr/bin/time -f 'WALL_SEC=%e' env LD_LIBRARY_PATH=/home/ageralis/tmp/third_party/pdfium/lib /tmp/pdfocr_bin_debug /home/ageralis/tmp/test_files/slides.pdf --all-pages > /tmp/pdfocr_debug_slides_all_pages.jsonl 2> /tmp/pdfocr_debug_slides_all_pages.err`

## Raw Results

- Competitor:
  - Exit code: `0`
  - Elapsed: `20.79s`
  - Pages: `72`
  - Errors: `0`
  - Retries (`attempts > 1`): `0`
  - Sum of attempts: `72`
  - Page order strictly increasing: `true`
  - Memory logs:
    - startup: `occupied=1160 free=3472224 total=3473408`
    - after_pipeline: `occupied=6803632 free=12463928 total=19267584`
    - shutdown: `occupied=6802472 free=12465088 total=19267584`

- Ours:
  - Exit code: `0`
  - Elapsed: `25.46s`
  - Pages: `72`
  - Errors: `0`
  - Retries (`attempts > 1`): `3`
  - Sum of attempts: `78`
  - Page order strictly increasing: `true`
  - Memory log (shutdown):
    - `occupied=945592B (0.90 MiB), free=40997448B (39.10 MiB), total=41943040B (40.00 MiB)`

## Comparison Summary

- Both implementations are functionally correct on this run: full success (`72/72`), no errors, ordered output.
- Competitor is faster by `4.67s` (`25.46s - 20.79s`), which is about `22.5%` lower elapsed time.
- Retry behavior differs:
  - Competitor: `0` retries (sum attempts `72`)
  - Ours: `3` retries (sum attempts `78`)
  - This likely contributed to part of the elapsed-time gap.
- Memory figures are **not directly comparable yet**:
  - Competitor reports 3 checkpoints (startup/after_pipeline/shutdown) in raw bytes.
  - Our current log reports one checkpoint (shutdown) and includes MiB formatting.
  - Different checkpoints and formats can hide peak/transient usage differences.

## Findings

1. Reliability parity was achieved for this workload (`72/72`, no errors, ordered output).
2. Performance is currently behind the competitor by ~22.5% in elapsed time on the same document.
3. The observed retry delta (`0` vs `3`) is a concrete behavioral difference and a plausible throughput factor.
4. Memory instrumentation should be aligned (same checkpoints and units) before drawing conclusions about relative memory efficiency.
