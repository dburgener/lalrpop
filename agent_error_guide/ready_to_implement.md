# Implementation Code: Ready-to-Use Snippets

This document contains code that can be directly integrated into lalrpop/src/lr1/error/mod.rs

## 1. Add This Import at the Top of the File

```rust
// Add to existing imports if not already present
use crate::lr1::example::Example;  // May already be imported
use crate::lr1::example::ExampleSymbol;  // May already be imported
use crate::lr1::example::Reduction;  // May already be imported
```

## 2. Add These Helper Methods to `ErrorReportingCx` impl Block

Find the `impl<'cx, 'grammar> ErrorReportingCx<'cx, 'grammar>` block and add these methods:

```rust
    /// Generate a synthetic example from a conflicting item when normal trace-based
    /// enumeration has failed (typically at grammar start states where there's no
    /// predecessor context to trace back to).
    ///
    /// For a reduce item (complete: index == production.symbols.len()),
    /// shows what happens when we reduce the prefix to the nonterminal.
    ///
    /// For a shift item (incomplete), shows what the symbols would be if we
    /// shift the lookahead.
    fn synthetic_example_from_item(
        &self,
        item: Lr0Item<'grammar>,
        lookahead: Token,
    ) -> Option<Example> {
        // Extract the symbols that came before the cursor (the "prefix")
        let prefix_symbols: Vec<ExampleSymbol> = item.production.symbols[..item.index]
            .iter()
            .map(|s| ExampleSymbol::Symbol(s.clone()))
            .collect();

        // The cursor position is where the lookahead appears in our symbol sequence
        let cursor = prefix_symbols.len();
        let mut symbols = prefix_symbols;

        // Add a representation of the lookahead as the symbol at the cursor
        match lookahead {
            Token::Terminal(term) => {
                symbols.push(ExampleSymbol::Symbol(Symbol::Terminal(term.clone())));
            }
            Token::Error => {
                symbols.push(ExampleSymbol::Epsilon);
            }
            Token::Eof => {
                symbols.push(ExampleSymbol::Epsilon);
            }
        }

        // Determine what reductions apply:
        // If this is a complete item (index == len of symbols), it's a reduce item,
        // so we show that the prefix reduces to the nonterminal
        let reductions = if item.index == item.production.symbols.len() && cursor > 0 {
            vec![Reduction {
                start: 0,
                end: cursor,
                nonterminal: item.production.nonterminal.clone(),
            }]
        } else {
            // For shift items or empty reductions, we don't show reductions in the basic example
            vec![]
        };

        Some(Example {
            symbols,
            cursor,
            reductions,
        })
    }

    /// Helper method to generate synthetic examples as a fallback when trace-based
    /// example enumeration produces no results. This is a wrapper around
    /// synthetic_example_from_item that handles the conversion to a Vec.
    fn synthetic_examples_for_conflict(
        &self,
        item: Lr0Item<'grammar>,
        lookahead: Token,
    ) -> Vec<Example> {
        self.synthetic_example_from_item(item, lookahead)
            .into_iter()
            .collect()
    }
```

## 3. Modify `shift_examples()` Method

Replace the entire method with this version:

```rust
    fn shift_examples(&self, conflict: &TokenConflict<'grammar>) -> Vec<Example> {
        log!(Tls::session(), Verbose, "Gathering shift examples");
        let state = &self.states[conflict.state.0];
        let conflicting_items = self.conflicting_shift_items(state, conflict);
        let mut examples: Vec<Example> = conflicting_items
            .iter()
            .flat_map(|&item| {
                let tracer = Tracer::new(&self.first_sets, self.states);
                let shift_trace = tracer.backtrace_shift(conflict.state, item);
                let local_examples: Vec<Example> = shift_trace.lr0_examples(item).collect();
                local_examples
            })
            .collect();

        // FALLBACK: If we got no examples through normal trace-based enumeration
        // (which can happen at grammar start states), try generating synthetic
        // examples directly from the items.
        if examples.is_empty() {
            log!(Tls::session(), Verbose, "No trace examples found, attempting synthetic generation");
            for item in conflicting_items.into_iter() {
                examples.extend(self.synthetic_examples_for_conflict(
                    item,
                    conflict.lookahead.clone(),
                ));
            }
        }

        examples
    }
```

## 4. Modify `reduce_examples()` Method

Replace the entire method with this version:

```rust
    fn reduce_examples(
        &self,
        state: StateIndex,
        production: &'grammar Production,
        lookahead: Token,
    ) -> Vec<Example> {
        log!(Tls::session(), Verbose, "Gathering reduce examples");
        let item = Item {
            production,
            index: production.symbols.len(),
            lookahead: TokenSet::from(lookahead.clone()),
        };
        let tracer = Tracer::new(&self.first_sets, self.states);
        let reduce_trace = tracer.backtrace_reduce(state, item.to_lr0());
        let mut examples: Vec<Example> = reduce_trace
            .lr1_examples(&self.first_sets, &item)
            .collect();

        // FALLBACK: If we got no examples through normal trace-based enumeration
        // (which can happen at grammar start states), try generating a synthetic
        // example directly from the reduce item.
        if examples.is_empty() {
            log!(Tls::session(), Verbose, "No trace examples found, attempting synthetic generation");
            examples.extend(self.synthetic_examples_for_conflict(
                item.to_lr0(),
                lookahead,
            ));
        }

        examples
    }
```

## Testing the Implementation

After making these changes:

### Test 1: Build sr.lalrpop
```bash
cd /root/Overlake/src/lalrpop
cargo build 2>&1 | head -50
```

Expected: Should see a proper ambiguity error with examples, not a naive error.

### Test 2: Run error tests
```bash
cargo test --lib lr1::error -- --nocapture
```

Expected: All tests pass with no regressions.

### Test 3: Verify assertion is correct
Search the code for the comment about "really shouldn't happen":
```bash
grep -n "really shouldn't happen" \
  /root/Overlake/src/lalrpop/lalrpop/src/lr1/error/mod.rs
```

The condition should now essentially never trigger.

## Validation Checklist

After implementation:

- [ ] Code compiles without warnings
- [ ] sr.lalrpop produces proper error (not naive)
- [ ] Existing tests pass (no regressions)
- [ ] Error messages are properly formatted
- [ ] Synthetic examples appear when trace is empty
- [ ] Classification logic works with synthetic examples
- [ ] No panics or unwraps in synthetic generation
- [ ] Lookahead variants handled (Terminal, Error, Eof)
- [ ] Empty productions handled correctly
- [ ] Performance is acceptable (synthetic generation is fast)

## Debugging Tips

If something doesn't work:

1. **Check log output**: Add `LALRPOP_LOG=verbose` when running
2. **Print synthetic example**: Add println! in synthetic_example_from_item to see what's generated
3. **Verify classifier receives examples**: Add debug output in classify() method
4. **Check Example structure**: Make sure symbols, cursor, and reductions are set correctly
5. **Test with simple grammar**: Use sr.lalrpop or similar minimal case first

## Common Issues & Solutions

| Issue | Solution |
|-------|----------|
| Compilation errors | Ensure Symbol, Token, etc. are imported correctly |
| Examples still empty | Check if synthetic generation is being called (check logs) |
| Error classification fails | Verify Example struct is populated correctly |
| Wrong cursor position | Ensure cursor = prefix_symbols.len() |
| Missing reductions | Verify item.index == production.symbols.len() check |
| Performance impact | Synthetic generation should only run on failure (rare) |

## Code Review Checklist

For someone reviewing this change:

- [ ] Synthetic examples only generate when trace fails (defensive)
- [ ] No modification to trace mechanism itself (non-invasive)
- [ ] Reuses existing Example struct (no new data structures)
- [ ] Works with existing classification logic (composable)
- [ ] Handles all Token variants (complete)
- [ ] Handles empty productions (correct)
- [ ] Logging in place for debugging (observable)
- [ ] Fallback is safe (won't create invalid examples)
- [ ] No performance regression (only on failure path)
- [ ] User-facing error messages improved (user benefit)
