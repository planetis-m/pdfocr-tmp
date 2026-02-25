# Benchmark Comparison Findings

This file compares the competing implementation's reported run with our latest verified live run after retrying until a `0`-retry result was achieved.

## Run Setup

- Input: `test_files/slides.pdf`
- Mode: `--all-pages`
- Environment: `.env` loaded, `LD_LIBRARY_PATH` set to `third_party/pdfium/lib`
- Retry loop result: first run already satisfied target (`0` retries)

## Commands

- Competitor reported:
  - `set -a; source .env; set +a; LD_LIBRARY_PATH=./third_party/pdfium/lib /usr/bin/time -f 'elapsed_s=%e' ./pdfocr_debug test_files/slides.pdf --all-pages > /tmp/slides_debug.jsonl`
- Ours (selected run):
  - `/usr/bin/time -f 'elapsed_s=%e' env LD_LIBRARY_PATH=/home/ageralis/tmp/third_party/pdfium/lib /tmp/pdfocr_bin_debug /home/ageralis/tmp/test_files/slides.pdf --all-pages > /tmp/pdfocr_retry_runs/run_1.jsonl 2> /tmp/pdfocr_retry_runs/run_1.err`

## Output Validation

- Competitor:
  - Exit code: `0`
  - Lines/pages: `72`
  - Errors: `0`
  - Retries (`attempts > 1`): `0`
  - Sum of attempts: `72`
  - Page order strictly increasing: `true`

- Ours (new run):
  - Exit code: `0`
  - Lines/pages: `72`
  - Errors: `0`
  - Retries (`attempts > 1`): `0`
  - Sum of attempts: `72`
  - Page order strictly increasing: `true`

## Performance Comparison

- Competitor elapsed: `20.79s`
- Ours elapsed: `17.84s`
- Delta: our run is `2.95s` faster (`~14.2%` lower elapsed time)

## Memory Usage Comparison

Values below are from `getOccupiedMem/getFreeMem/getTotalMem` logs.

- Startup:
  - Competitor: `occupied=1160 free=3472224 total=3473408`
  - Ours: `occupied=11528 free=3330808 total=3342336`
  - Comparison:
    - occupied: ours `+10368` bytes
    - free: ours `-141416` bytes
    - total: ours `-131072` bytes

- After pipeline:
  - Competitor: `occupied=6803632 free=12463928 total=19267584`
  - Ours: `occupied=838976 free=43528896 total=44367872`
  - Comparison:
    - occupied: ours `-5964656` bytes (`~87.7%` lower)
    - free: ours `+31064968` bytes
    - total: ours `+25100288` bytes

- Shutdown:
  - Competitor: `occupied=6802472 free=12465088 total=19267584`
  - Ours: `occupied=830008 free=43537864 total=44367872`
  - Comparison:
    - occupied: ours `-5972464` bytes (`~87.8%` lower)
    - free: ours `+31072776` bytes
    - total: ours `+25100288` bytes

## Findings

1. We now match the competitor on output quality and stability for this case (`72/72`, `0` errors, `0` retries, strictly ordered pages).
2. In this measured run, our implementation is faster (`17.84s` vs `20.79s`).
3. Memory profile differs substantially:
   - Our occupied memory after pipeline/shutdown is much lower.
   - Our total/free memory figures are much larger, indicating different allocator reservation behavior.
4. Because total allocator pool sizes differ, occupied memory is the most directly useful metric for workload footprint comparison.
