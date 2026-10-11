# RAR zoo (public-domain Jessie James pages only)

Source: Public-Domain-Comic-Jessie-James.cbz (36 JPEGs, 16 MB). Every archive here is built from only the first 6 pages (sorted by name: JJ1p00fc, JJ1p00ifc-Glow, JJ1p01..JJ1p04), each downscaled to 700 px on the long side, 4:2:0, quality 50 (~64 KB each, "all6" = 384 KB). "many" = 300 tiny 1x1 JPEGs (padded to distinct sizes) in s0..s9/, "deep" = 40-level directory chain with a page and a tiny image at the bottom (page downscaled to 500 px), "uni" = a CJK+emoji filename, a 200-char filename, and Ünï/Ελληνικά/русский.jpg (pages at 500 px). Every archive is under 1 MB (the SFX ones carry a ~250 KB stub); the whole set is about 12 MB, so it needs no Git LFS. The top-level Fixtures/jessie-james-rar4.cbr and jessie-james-rar5.cbr are the same 6 pages (`-ma4`, and `-ma5 -s-`, non-solid, Quick Open). Password for all encrypted files is TESTPW. The multi-volume sets use `-v70k` (6 rar5 parts, 5 rar4 volumes).

Tool notes:
- `rar` 7.00 cannot create RAR4 (`-ma4` is "Unknown option"). All rar4 files were made with RAR 6.24; all rar5 files with rar 7.00.
- Local `7zz` 26.03 (arm64) lists everything and tests stored (m0) entries, but reports "Unsupported Method" for every compressed (m3/m5) RAR entry, so it is only useful here for listing (-slt). Extraction/test results below come from `unrar` 7.00 (`unrar t -pTESTPW`).
- Rar stores JPEGs at m0 inside "m3" archives when it cannot compress them, so the per-entry Method column mixes m0/m3. Solid archives report m3 because entries are chained.
- rar 7 clamps the dictionary to the data size, so `-md1g -m5` only records a 1M dictionary (7zz shows v6:1M:m0:m5). The header flag is valid but the dictionary is not really 1 GB; a true 1 GB dict needs >1 GB of input.
- QO scan: a small Python rar5 block walker parsing service headers for name "QO"/"RR"/"CMT". Rar4 has no QO.

Common command form: `rar a -idq -r <opts> <out> .` run inside the page dir. Every file below that is not flagged parses cleanly with unrar (`unrar t -pTESTPW` exit clean, no output with -idq).

| File | Command opts | Size | Solid / Enc / QO | Notes and parse |
|---|---|---|---|---|
| jj-rar4-solid.cbr | -ma4 -s -m3 (6 pages) | see `ls -l` | solid, no enc, n/a QO | valid |
| jj-rar5-solid.cbr | -ma5 -s (6 pages) | see `ls -l` | solid, QO present (at 16278640) | valid |
| jj-rar5-nonsolid-noqo.cbr | -ma5 -s- -qo- (6 pages) | see `ls -l` | non-solid, NO QO (no services) | valid; `-qo-` is supported and works |
| jj-rar5-recovery-qo.cbr | -ma5 -rr5 (6 pages) | see `ls -l` | non-solid, QO + RR service headers | valid; QO before RR, RR ~850 KB, note QO is not the last data |
| jj-rar5-qo-forced.cbr | -ma5 -qo (6 pages) | see `ls -l` | non-solid, QO present | valid; byte-identical in size to default (default already emits QO for this archive) |
| jj-rar5-stale-qo.cbr | `rar a -ma5 -qo` then `rar a -ma5` adding tiny/t.jpg (7 entries) | see `ls -l` | non-solid, QO present and REWRITTEN (fresh, at end, covers 6 files) | valid; rar rewrites QO on append, so not stale |
| jj-rar5-stale-qo-b.cbr | qo-forced then `rar a -ma5 -qo-` adding t.jpg | see `ls -l` | non-solid, QO DROPPED (removed on append) | valid; shows append with -qo- strips QO |
| jj-rar5-stale-qo-c.cbr | solid rar5 then `rar a -ma5 -qo-` adding t.jpg | see `ls -l` | solid, QO dropped | valid |
| jj-rar5-qo-stale-crafted.cbr | HAND-SPLICED: stale-qo-b bytes with the old 6-file QO block from qo-forced inserted before the end block | see `ls -l` | non-solid, QO present but genuinely STALE (offsets from a 6-file archive, now after 7 file records) | 7zz lists 7 entries fine; unrar t clean (unrar ignores QO for full tests). Quick Open readers must validate offsets/CRC and fall back |
| jj-rar4-encheaders.cbr | -ma4 -hpTESTPW (6 pages) | see `ls -l` | non-solid, headers ENCRYPTED | unrar without pw: "Checksum error in the encrypted file"; with pw valid |
| jj-rar4-enccontent.cbr | -ma4 -pTESTPW (6 pages) | see `ls -l` | content encrypted, names visible | lists without pw; extraction w/o pw fails; valid with pw |
| jj-rar5-encheaders.cbr | -ma5 -hpTESTPW (6 pages) | see `ls -l` | headers encrypted (13 encrypted incl. all) | 7zz `l` without pw fails to list; unrar: "Incorrect password"; valid with pw |
| jj-rar5-enccontent.cbr | -ma5 -pTESTPW (6 pages) | see `ls -l` | content encrypted, names visible, QO present | lists w/o pw; valid with pw |
| jj-rar5-vol.part1..6.rar | -ma5 -v70k (6 pages) | see `ls -l` | 6 volumes, each with its own QO | valid when all parts present; open part1 |
| jj-rar4-vol.rar, .r00 .. .r04 | -ma4 -v70k -vn (6 pages) | see `ls -l` | 6 volumes old-style naming (first is .rar) | valid when all parts present |
| jj-rar5-dict1g.cbr | -ma5 -md1g -m5 (6 pages) | see `ls -l` | non-solid, QO | valid; dict recorded as 1M (clamped, see above) |
| jj-rar5-many-small.cbr | -ma5 (many: 300 tiny, 311 blocks) | see `ls -l` | non-solid, NO QO emitted by rar for this input | valid; unexpectedly no QO (rar seems to skip QO here) |
| jj-rar4-many-small.cbr | -ma4 (many) | see `ls -l` | non-solid | valid |
| jj-rar5-deep.cbr | -ma5 (deep, 40 levels) | see `ls -l` | QO present | valid |
| jj-rar4-deep.cbr | -ma4 (deep) | see `ls -l` | | valid |
| jj-rar5-unicode-longnames.cbr | -ma5 (uni) | see `ls -l` | QO present | valid; CJK/emoji/Cyrillic/Greek dirs and a 200-char name |
| jj-rar4-unicode-longnames.cbr | -ma4 (uni) | see `ls -l` | | valid (RAR4 stores unicode name pair) |
| jj-rar4-stored.cbr | -ma4 -m0 (6 pages) | see `ls -l` | non-solid | valid; 7zz t also OK |
| jj-rar5-stored.cbr | -ma5 -m0 (6 pages) | see `ls -l` | non-solid, QO | valid; 7zz t also OK |
| jj-rar5-sfx.exe | -ma5 -sfx (6 pages) | see `ls -l` | SFX-prefixed rar5, QO offsets shifted by the stub | 7zz lists 6 (warns "cannot open as PE" then falls back to RAR); unrar valid |
| jj-rar4-sfx.exe | -ma4 -sfx (6 pages) | see `ls -l` | SFX-prefixed rar4 | as above |
| jj-rar5-truncated.cbr | jj-rar5-solid cut to 95% | see `ls -l` | solid, tail/QO/end block lost | BROKEN: unrar "Unexpected end of archive" + checksum error on last entry; 7zz lists all but the last with ERRORS |
| jj-rar4-truncated.cbr | jj-rar4-solid cut to 95% | see `ls -l` | solid | BROKEN, same |
| jj-rar5-nonsolid-truncated.cbr | nonsolid-noqo cut to 95% | see `ls -l` | non-solid, no QO | BROKEN: earlier entries extract fine, last checksum error |
| jj-rar5-corrupt-middle.cbr | rar5-solid + 2048 random bytes at midpoint | see `ls -l` | solid, QO intact | BROKEN: listing works (headers before/QO intact), unrar checksum errors on the damaged entry and all later solid entries |
| jj-rar4-corrupt-middle.cbr | same on rar4 solid | see `ls -l` | solid | BROKEN: listing works, checksum errors from the damaged entry on |
| jj-rar5-comment.cbr | -ma5 -zcmt.txt (6 pages) | see `ls -l` | CMT service present, QO present | valid; comment text "Jessie James test archive comment" |
| jj-rar4-comment.cbr | -ma4 -zcmt.txt (6 pages) | see `ls -l` | comment in main-header area | valid |

Not produced: an SFX variant is only the stub-prefixed layout from `-sfx` (default.sfx, Linux stub); a rar5 locked archive (-k) was not made.
