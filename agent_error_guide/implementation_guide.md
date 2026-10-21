# Implementation Guide: Synthetic Examples for Start-State Conflicts

## Data Structures

From `lalrpop/src/lr1/example/mod.rs`:
```rust
pub struct Example {
    pub symbols: Vec<ExampleSymbol>,  // Input symbols on the parse stack + lookahead
    pub cursor: usize,                 // Index of lookahead position
    pub reductions: Vec<Reduction>,   // Nesting of reductions (smallest to largest)
}

pub enum ExampleSymbol {
    Symbol(Symbol),
    Epsilon,
}

pub struct Reduction {
    pub start: usize,      // Start index in symbols
    pub end: usize,        // End index (exclusive)
    pub nonterminal: NonterminalString,
}
```

## Key Types to Reference

From `lalrpop/src/lr1/core.rs`:
- `Lr0Item<'grammar>`: Represents an item with production and cursor position
  - `.production`: The production rule
  - `.index`: Position of the dot (0 = at start, len = at end)
  - `.production.symbols`: The RHS symbols
  - `.production.nonterminal`: The LHS

From `lalrpop/src/lr1/lookahead.rs`:
- `Token`: Terminal, Error, or Eof

## Proposed Implementation

### Add to `ErrorReportingCx` in `lalrpop/src/lr1/error/mod.rs`

```rust
impl<'cx, 'grammar> ErrorReportingCx<'cx, 'grammar> {
    /// Generate a synthetic example from a single item when trace-based
    /// enumeration fails (typically at grammar start states).
    /// 
    /// For a reduce item `X = α •`, shows what happens when we reduce.
    /// For a shift item `Y = β • L ...`, shows what happens when we shift L.
    fn synthetic_example_from_item(
        &self,
        item: Lr0Item<'grammar>,
        lookahead: Token,
        first_sets: &FirstSets,
    ) -> Option<Example> {
        // Extract symbols that would be on the stack
        let prefix_symbols: Vec<ExampleSymbol> = item
            .production
            .symbols[..item.index]
            .iter()
            .map(|s| match s {
                Symbol::Terminal(t) => ExampleSymbol::Symbol(Symbol::Terminal(t.clone())),
                Symbol::Nonterminal(n) => ExampleSymbol::Symbol(Symbol::Nonterminal(n.clone())),
            })
            .collect();

        if prefix_symbols.is_empty() && item.index == 0 {
            // Item like `X = • ...` with no prefix context
            // This is a start symbol or epsilon case; still try to generate something
            if item.index == item.production.symbols.len() {
                // Complete item `X = •` (all consumed)
                // Show just the reduction of epsilon to X
                return Some(Example {
                    symbols: vec![],
                    cursor: 0,
                    reductions: vec![],
                });
            }
            // Otherwise we'll construct below
        }

        let cursor = prefix_symbols.len();
        let mut symbols = prefix_symbols;

        // Add the lookahead as the "cursor" symbol
        if let Token::Terminal(term) = lookahead {
            symbols.push(ExampleSymbol::Symbol(Symbol::Terminal(term.clone())));
        } else {
            // EOF or Error case - represent as end
            symbols.push(ExampleSymbol::Epsilon);
        }

        // Determine reductions:
        // If this is a complete item (item.index == production.symbols.len()),
        // then we're looking at a reduce, so show the reduction of prefix to nonterminal
        let reductions = if item.index == item.production.symbols.len() {
            vec![Reduction {
                start: 0,
                end: cursor,
                nonterminal: item.production.nonterminal.clone(),
            }]
        } else {
            // Shift case - no reductions shown in the basic example
            vec![]
        };

        Some(Example {
            symbols,
            cursor,
            reductions,
        })
    }

    /// Generate synthetic examples when trace-based enumeration fails.
    /// Returns Vec of synthetic examples as a fallback.
    fn synthetic_examples_for_conflict(
        &self,
        item: Lr0Item<'grammar>,
        lookahead: Token,
        is_complete_item: bool, // true if it's a reduce item
    ) -> Vec<Example> {
        if let Some(example) = self.synthetic_example_from_item(item, lookahead, &self.first_sets) {
            vec![example]
        } else {
            vec![]
        }
    }
}
```

### Modify `shift_examples()` method

```rust
fn shift_examples(&self, conflict: &TokenConflict<'grammar>) -> Vec<Example> {
    log!(Tls::session(), Verbose, "Gathering shift examples");
    let state = &self.states[conflict.state.0];
    let conflicting_items = self.conflicting_shift_items(state, conflict);
    let mut examples: Vec<Example> = conflicting_items
        .into_iter()
        .flat_map(|item| {
            let tracer = Tracer::new(&self.first_sets, self.states);
            let shift_trace = tracer.backtrace_shift(conflict.state, item);
            let local_examples: Vec<Example> = shift_trace.lr0_examples(item).collect();
            local_examples
        })
        .collect();

    // FALLBACK: If we got no examples through trace-based enumeration,
    // try generating synthetic examples directly from the items
    if examples.is_empty() {
        for item in self.conflicting_shift_items(state, conflict) {
            examples.extend(self.synthetic_examples_for_conflict(
                item,
                conflict.lookahead.clone(),
                false, // not a complete item (shift items have dot before something)
            ));
        }
    }

    examples
}
```

### Modify `reduce_examples()` method

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
    let mut examples: Vec<Example> = reduce_trace.lr1_examples(&self.first_sets, &item).collect();

    // FALLBACK: If we got no examples through trace-based enumeration,
    // try generating synthetic examples directly from the item
    if examples.is_empty() {
        examples.extend(self.synthetic_examples_for_conflict(
            item.to_lr0(),
            lookahead,
            true, // this is a complete item (reduce)
        ));
    }

    examples
}
```

## Validation & Testing

After implementation:

1. **Test on sr.lalrpop**: 
   ```bash
   cd /root/Overlake/src/lalrpop
   cargo build
   # Build should process sr.lalrpop and generate a helpful error instead of naive
   ```

2. **Verify no regressions**: Run existing tests
   ```bash
   cargo test --lib lr1::error
   ```

3. **Check the assertion**: Look for the comment in error reporting that says this "really shouldn't happen" - after our fix, it truly shouldn't.

## Edge Cases to Consider

### 1. Empty productions
If the reduce item is `X = • ` (epsilon production), the prefix_symbols will be empty.
- Handle: Generate example with empty symbols, cursor=0, reduction [0,0]

### 2. Nonterminal-only items
Items like `X = • Y Z` with no terminals.
- Handle: Include nonterminals in symbols (they'll display as-is)

### 3. Very long productions
If prefix has many symbols (e.g., `X = a b c d e • f`), it might be verbose.
- Consider: Truncate/summarize long prefixes (future enhancement)

### 4. Multiple lookaheads
The lookahead could be Terminal, Eof, or Error.
- Handle: Display appropriately for each

## Why This Solution Works

1. **Addresses root cause**: Generates examples even when trace graph has no paths
2. **Minimal but complete**: Shows enough information for error classification
3. **Backwards compatible**: Falls back without breaking existing code
4. **Composable**: Works with existing classification logic (ambiguity, precedence, etc.)
5. **Targeted**: Only activates when trace-based enumeration fails

## Potential Enhancements (Future)

1. **Multi-example synthesis**: Generate multiple synthetic examples to show different reduction chains
2. **Truncation for large productions**: Handle very long symbols with "..." notation
3. **Epsilon transparency**: Better visual representation of epsilon productions
4. **Context hints**: Even without full trace, suggest what constructs might contain the conflict
