# Visual Summary: LALRPOP Start-State Conflict Solution

## Problem Flow Diagram

```
Grammar Input (sr.lalrpop)
         |
         v
    Parse Analysis
         |
         v
  Conflict Detected at State S
  (shift "x" vs reduce to B on lookahead "x")
         |
         v
Error Reporting Pipeline
         |
    +----v----+
    | Classify|
    +----+----+
         |
    Need Examples
         |
    +----v---------+
    | Tracer       |
    | backtrace    |  <-- PROBLEM: At start state,
    +----+----+----+      no predecessor states exist
         |    |
    +----v-+  +-v------+
    | Shift|  | Reduce |  <-- Empty results!
    | Trace|  | Trace  |
    +----+----+-------+
         |      |
    +----v------v----+
    | PathEnumerator |  <-- Tries to walk backward,
    +----+-----------+      finds no incoming edges
         |
    +----v----------+
    | Examples Empty|  <-- Falls back to Naive error
    +----+----------+
         |
         v
    Naive Error Message
    (just dumps states - unhelpful!)

GOAL: Generate Examples Anyway
         |
         v
    Proper Error Message
```

## Solution: Synthetic Example Generation

```
Grammar Input
     |
     v
Conflict Detected at State S
     |
     +-----+
     |     |
     v     v
  Tracer  [NEW] Synthetic 
  Path    Generator
     |     |
     +-----+
        |
        v
   Examples Generated
        |
        v
   Classification
   (Ambiguity, Precedence, etc.)
        |
        v
   Proper Error Message!
```

## Data Flow for Synthetic Examples

```
FOR REDUCE CONFLICT:

Item: X = a b • 
Lookahead: "x"

     +--------------------------------+
     | Create Example Synthetically:  |
     +--------+-----+--------+--------+
              |
     symbols: ["a", "b", "x"]
     cursor:  2 (at lookahead)
     reductions: [{start:0, end:2, nonterminal:X}]
              |
              v
     Shows: "a b" could reduce to X,
            then lookahead "x" would be examined


FOR SHIFT CONFLICT:

Item: Y = • c d
Lookahead: "x"

     +--------------------------------+
     | Create Example Synthetically:  |
     +--------+-----+--------+--------+
              |
     symbols: ["x", ...]
     cursor:  0 (at lookahead)
     reductions: [] (none yet)
              |
              v
     Shows: "x" could be shifted,
            then "c d" would follow
```

## Example Error Output Improvement

### Before (Naive)
```
Conflict detected
when in this state:
  item A { [production: pub A = B "x" "y", index: 1, lookahead: "x"],
           [production: pub A = "a" "x", index: 1, lookahead: "x"] }
and looking at a token `"x"`
we can reduce by production B = "a"
but we can also shift
```

### After (With Synthetic Examples)
```
Ambiguous grammar detected
The following symbols can be reduced in two ways:
  "a"

They could be reduced like so:
  "a"
  |   |
  +-B-+

Alternatively, they could be reduced like so:
  "a" "x"
  |        |
  +--------+
  [Parse tree showing shift path]

LALRPOP does not yet support ambiguous grammars.
See the LALRPOP manual for advice...
```

## Implementation Checklist

- [ ] **Analysis Phase**: Understand trace graph failure at start states ✓
- [ ] **Solution Design**: Synthetic example generation ✓
- [ ] **Code Planning**: Identify modification points ✓
  - [ ] Modify `shift_examples()` in error/mod.rs
  - [ ] Modify `reduce_examples()` in error/mod.rs
  - [ ] Add `synthetic_example_from_item()` method
  - [ ] Add `synthetic_examples_for_conflict()` helper
- [ ] **Implementation**: Write the synthetic generator
  - [ ] Handle reduce items (complete: index == len)
  - [ ] Handle shift items (incomplete)
  - [ ] Handle empty productions
  - [ ] Handle various lookahead types
- [ ] **Testing**:
  - [ ] Test on sr.lalrpop
  - [ ] Run existing test suite
  - [ ] Verify no regressions
  - [ ] Check improved error messages
- [ ] **Validation**:
  - [ ] Verify assertion "really shouldn't happen" holds true
  - [ ] Peer review solution

## Why This Is Elegant

1. **Non-invasive**: Only modifies error reporting, not grammar parsing
2. **Fallback only**: Doesn't affect existing trace-based examples
3. **Reuses infrastructure**: Works with existing `Example` structure and classification logic
4. **Solves specific problem**: Targets start-state conflicts without over-complicating
5. **Future-proof**: Can be enhanced with better heuristics later
