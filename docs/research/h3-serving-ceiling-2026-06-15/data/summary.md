# Single-Spark serving-ceiling sweep (H3 / bd benchmarks-9g4.2.2)

safe-N criterion: num_preemptions==0 AND per-turn-wall inflation <= 1.5x vs c1, no failed turns.

## probe — 400 tok/turn  →  **safe N = 8**
_EC2-bound: one Spark serves c8+ freely — scale cheap harness boxes_

| N | per-turn wall (s) | decode tok/s | inflation vs c1 | preemptions | failed | safe |
|--:|--:|--:|--:|--:|--:|:--:|
| 1 | 55.8 | 9.3 | 1.00x | 0.0 | 0 | ✓ |
| 2 | 56.2 | 8.4 | 1.01x | 0.0 | 0 | ✓ |
| 3 | 45.4 | 8.9 | 0.81x | 0.0 | 0 | ✓ |
| 4 | 47.6 | 8.5 | 0.85x | 0.0 | 0 | ✓ |
| 6 | 76.3 | 6.4 | 1.37x | 0.0 | 0 | ✓ |
| 8 | 80.3 | 6.0 | 1.44x | 0.0 | 0 | ✓ |
| 12 | 111.9 | 3.6 | 2.01x | 0.0 | 0 | ✗ |
| 16 | 102.0 | 4.0 | 1.83x | 0.0 | 0 | ✗ |

## verbose — 4000 tok/turn  →  **safe N = 8**
_EC2-bound: one Spark serves c8+ freely — scale cheap harness boxes_

| N | per-turn wall (s) | decode tok/s | inflation vs c1 | preemptions | failed | safe |
|--:|--:|--:|--:|--:|--:|:--:|
| 1 | 433.4 | 9.2 | 1.00x | 0.0 | 0 | ✓ |
| 2 | 434.2 | 9.2 | 1.00x | 0.0 | 0 | ✓ |
| 4 | 476.2 | 8.4 | 1.10x | 0.0 | 0 | ✓ |
| 8 | 565.5 | 7.1 | 1.30x | 0.0 | 0 | ✓ |

