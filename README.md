# MRSeqStudio.jl

Editable MRI sequences for KomaMRI. A `StudioSequence` stores variables and a tree of loop and event blocks. `Sequence(studio)` unrolls that tree into a KomaMRI `Sequence`.

Event blocks are a single `StudioSeqBlock`: gradients on x, y, and z, one RF pulse, and one ADC, all present and off by default. Variables and block fields are scripts in one whitelist: numbers, names, `pi`, `γ`, `+ - * / ^` and their dotted forms, ranges, vector literals `[a, b]`, local assignment, `return`, and calls to `ones`, `zeros`, `collect`, `sin`, `cos`, and `length`. The interpreter reads Julia's parse tree and does not call `eval`. A script sees the variables defined above it. `return` sets the value; without it, the last expression does. Loop iterators run from 0 and are visible in block fields, not in variable scripts.

Units match KomaMRI (s, T, T/m, Hz, rad).

`StudioUI` opens a `SeqStudioWindow`, the same role `KomaUI` has for a `KomaWindow`. The window owns `w.seq`. `studio_panel` is the Bonito node inside that window, and KomaMRI can mount the same node in its own window. 

The existing web application remains [MRSeqStudio](https://github.com/pvillacorta/MRSeqStudio).
