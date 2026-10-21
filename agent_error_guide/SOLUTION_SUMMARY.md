# Summary: Solution for LALRPOP Start-State Conflict Error Messages

## Executive Summary

LALRPOP's error reporting for shift/reduce conflicts relies on trace graphs to construct examples showing how the conflict arose. When conflicts occur at the **start of the grammar** (in public rules with no incoming context), the trace mechanism fails because there's nothing to trace back to. This results in a cryptic "naive" error message that just dumps parser states.

**Proposed Solution**: Generate synthetic examples when trace-based enumeration fails. These examples, constructed directly from the conflicting items, are sufficient for LALRPOP's error classification logic to produce proper, user-friendly error messages.

## Problem Summary

| Aspect | Details |
|--------|---------|
| **What happens** | Shift/reduce conflict at grammar start state |
| **Current behavior** | Example generation fails → naive error (state dump) |
| **Root cause** | Trace graphs built by walking backward; no predecessors at start state |
| **Example** | sr.lalrpop: conflict on "a" with lookahead "x" in rule A |
| **Impact** | Users see unhelpful error instead of clear ambiguity message |
| **Code location** | lalrpop/src/lr1/error/mod.rs, specifically `classify()` method line ~530 |

## Solution Overview

### Core Idea
When trace-based example generation produces no results, generate minimal examples directly from the conflicting items using their production structure and cursor position.

### Key Components

```
1. Synthetic Example Generator
   - Function: synthetic_example_from_item(item, lookahead)
   - Input: Lr0Item (the conflicting item), Token (lookahead)
   - Output: Example (symbols + cursor + reductions)
   - Algorithm: Extract prefix symbols → add lookahead → construct reduction info

2. Fallback Integration
   - Modify shift_examples(): if tracer returns empty, call synthetic generator
   - Modify reduce_examples(): same fallback pattern
   - No changes to trace mechanism itself

3. Result
   - Examples always generated
   - Same classification logic works (ambiguity detection, precedence, etc.)
   - Proper error messages instead of naive fallback
```

### Why It Works

```
Examples don't need full parse tree context:
  ✓ They need symbols to show what triggers the conflict
  ✓ They need cursor position to show lookahead
  ✓ They need reduction info to show what could be reduced
  
Trace graphs provide all this through context, but:
  ✗ At start states, there IS no context
  ✓ But we can extract it from the items themselves!
  
Synthetic examples:
  ✓ Show the same symbols (from production)
  ✓ Show the same cursor position
  ✓ Show the same reductions (from nonterminal)
  ✓ Enough for classification to work
```

## Implementation Plan

### Phase 1: Add Synthetic Generator
Add to `ErrorReportingCx` struct in `lalrpop/src/lr1/error/mod.rs`:
```rust
fn synthetic_example_from_item(
    &self,
    item: Lr0Item<'grammar>,
    lookahead: Token,
) -> Option<Example> {
    // Extract prefix symbols
    // Add lookahead symbol
    // Construct reductions if this is a complete item (reduce case)
    // Return Example struct
}
```

### Phase 2: Add Fallback Calls
Modify two methods in same file:

1. **shift_examples()** - After tracer produces results:
   ```rust
   if examples.is_empty() {
       examples.extend(self.synthetic_examples_for_conflict(...));
   }
   ```

2. **reduce_examples()** - After tracer produces results:
   ```rust
   if examples.is_empty() {
       examples.extend(self.synthetic_examples_for_conflict(...));
   }
   ```

### Phase 3: Test
- Build sr.lalrpop and verify improved error
- Run existing test suite for regressions
- Verify assertion "really shouldn't happen" is now always true

## Expected Outcome

### Before
```
Conflict detected
when in this state:
[complex state dump...]
and looking at a token `x`
we can reduce to B
but we can also shift
```

### After
```
Ambiguous grammar detected
The following symbols can be reduced in two ways:
  "a"

They could be reduced like so:
  "a"
  |  |
  +-B-+

Alternatively, they could be reduced like so:
  [parse tree showing shift path]

LALRPOP does not yet support ambiguous grammars...
```

## Advantages

1. **Solves the problem**: Handles start-state conflicts properly
2. **Non-invasive**: Only modifies error reporting layer
3. **Safe fallback**: Trace-based examples still used when available
4. **Works with existing logic**: No changes to classification, just ensures examples exist
5. **Simple to implement**: Direct symbol extraction, straightforward logic
6. **Well-scoped**: Minimal code changes, easy to review
7. **Future-proof**: Can enhance with better heuristics later

## Risk Assessment

| Risk | Probability | Mitigation |
|------|------------|-----------|
| Synthetic examples too simplistic | Low | They work with existing classification, users report if insufficient |
| Break existing functionality | Very low | Only activates on failure, doesn't modify trace mechanism |
| Miss edge cases | Low | Comprehensive test coverage of existing code |
| Performance regression | Very low | Only runs when trace fails (uncommon case) |

## Files Modified

| File | Changes |
|------|---------|
| `lalrpop/src/lr1/error/mod.rs` | Add synthetic generator, modify shift_examples/reduce_examples |

## Testing Checklist

- [ ] Build sr.lalrpop → verify better error message
- [ ] Run: `cargo test --lib lr1::error`
- [ ] Verify no naive errors reported (assertion holds)
- [ ] Test nested grammars (should still use trace-based examples)
- [ ] Test various conflict types (shift/reduce, reduce/reduce)
- [ ] Test empty productions, long productions
- [ ] Check error message formatting

## Conclusion

This solution elegantly addresses the start-state conflict problem by generating synthetic examples when the trace mechanism fails. It leverages existing infrastructure (Example struct, classification logic), minimizes code changes, and provides immediate user-facing benefits with proper error messages instead of state dumps.

The fix is targeted, composable, and maintains backward compatibility while eliminating a category of unhelpful error messages that users currently encounter.
