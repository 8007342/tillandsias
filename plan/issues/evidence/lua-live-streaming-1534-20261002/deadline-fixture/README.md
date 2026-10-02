# Archived Python source data

`reproduce.py.source.txt` and `repo/producer.py.source.txt` are archived source
bytes from the measured deadline fixture, not executable repository tooling.
Their historical names and SHA-256 values remain recorded unchanged in
`final-summary.json` as the measured source identities.

To reproduce externally, copy the two files into a fresh scratch fixture and
materialize them under their original names (`reproduce.py` and
`repo/producer.py`) before invoking Python there. No repository runtime path
references a `.py` filename.

Captured test logs keep immutable base64 originals in
`../diagnostic-log-originals.json`; their SHA-256 values describe the
measurement-time blobs before displayed copies gain citation annotations.
