# restic filter cases

`../data/restic_filter_cases.tsv` holds pattern results computed by restic 0.18.1 itself. The Rust filter
tests must agree with every line.

To regenerate:

1. `python3 gen.py` writes `/tmp/nl-filtergen/in.txt`.
2. Copy `nlgen_test.go` into a restic v0.18.1 checkout at `internal/filter/` and run
   `go test ./internal/filter -run TestNLGen`. It writes `/tmp/nl-filtergen/out.txt`.
3. Sample `out.txt` into `../data/restic_filter_cases.tsv`.

Line format: `M <pattern> <path> <Match>`, or `L <patterns> <path> <List> <ListWithChild matched> <child>`.
Patterns in an `L` line are separated by byte 0x1f. Results are `true`, `false` or `err`.
