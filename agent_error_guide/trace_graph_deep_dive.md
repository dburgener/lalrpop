# Deep Dive: Trace Graph Mechanism and Why It Fails at Start States

## How Trace Graphs Work (Current Implementation)

The trace graph is a DAG (directed acyclic graph) that represents how the parser arrived at a conflicting state. It's built in two phases:

### Phase 1: Backtrace Shift (lalrpop/src/lr1/trace/shift/mod.rs)

For a shift item like `X = α • β` in state S with lookahead L:

```
1. Extract symbol_sets from item:
   - prefix: α (symbols before cursor)
   - cursor: β[0] (next symbol to match)
   - suffix: β[1..] (remaining symbols)

2. Trace backward through states:
   pred_states = state_graph.trace_back(S, α)
   (Find states where `X = • α` exists)

3. Add edge to graph:
   [X] → [X = α • β] labeled with symbol_sets

4. For each predecessor state, trace epsilon edges:
   For each item like `Z = ...p • X ...s` in pred_state:
     - If ...p is non-empty: add edge [Z = ...p • X ...s] → [X]
     - If ...p is empty: recursively trace [Z]

Result: A DAG showing paths from various nonterminals down to the shift item
```

### Phase 2: Example Enumeration (lalrpop/src/lr1/trace/trace_graph/mod.rs)

The `PathEnumerator` walks this DAG to find paths:

```rust
pub struct PathEnumerator {
    graph: &TraceGraph,
    stack: Vec<EnumeratorState>,
}

struct EnumeratorState {
    index: NodeIndex,           // Current node in graph
    symbol_sets: SymbolSets,    // Symbols on this edge
    edges: Edges,               // Outgoing edges from this node
}
```

Walking algorithm:
1. Start at the given item node (e.g., shift item)
2. Get **incoming** edges to this node (reverse direction!)
3. For each incoming edge, try to push the source node onto the stack
4. If source is an Item node → found a complete trace, return it
5. If source is a Nonterminal node → continue searching backward
6. Cycle detection prevents infinite loops

## Why It Fails at Start States

```
Grammar:
  pub A = B "x" "y" | "a" "x"
  B = "a"

State Structure (simplified):
  S0 (start state)
    - [A = • B "x" "y"]
    - [A = • "a" "x"]
    - [B = • "a"]    (epsilon move from first item)

Conflict occurs at S1-ish:
    - [A = B • "x" "y", lookahead="x"]
    - [A = "a" • "x", lookahead="x"]
    - (shift/reduce conflict on "x")

When we build trace for the reduce item `A = "a" •`:

trace_reduce_item(state, item) is called
  1. Add edge: [A] → [A = "a" •]
  
  2. Find predecessor states:
     pred_states = trace_back(state, ["a"])
     
  3. Try to find who can shift A:
     trace_reduce_from_state(pred_state, "A")
     
     Look for: Z = ...p • A ...s
     
     But in S0, we have:
     - [A = • B "x" "y"]  - doesn't shift A
     - [A = • "a" "x"]    - doesn't shift A
     - [B = • "a"]        - doesn't shift A
     
     No one shifts A! We're at the grammar root.

  4. Result: No incoming edges added to trace graph for [A]
  
  5. When PathEnumerator tries to walk:
     - Get incoming edges for [A = "a" •]
     - Incoming edges: EMPTY
     - find_next_trace() immediately returns false
     - No paths found → no examples generated
     - Empty example list → Naive error
```

## Root Cause Analysis

```
The fundamental problem:

    Trace graphs require predecessor context
                ↓
    They're built by walking backward through the state machine
                ↓
    At grammar start states, there IS no predecessor context
                ↓
    Example enumeration fails to find any paths
                ↓
    Empty examples → fallback to naive error

Key insight:
    - For nested grammars (e.g., C = { "pre" A "post" }),
      the conflict in A is "wrapped" in C's context
    - Rule A still produces no local trace, BUT
    - Rule C can provide context for where A appears
    - So examples are generated from C's perspective
    
    - For top-level public rules:
      Nothing wraps them, no outer context exists
      So trace graphs are truly empty
```

## What Synthetic Examples Solve

Instead of requiring backward-walking context, synthetic examples construct forward-looking examples:

```
For item `A = "a" •` with lookahead "x":

Traditional trace approach:
  1. Walk backward: Who called/wrapped A?
  2. At start state: Nobody!
  3. Result: No paths, no examples

Synthetic approach:
  1. What are the symbols that led to this item?
     → ["a"]
  2. What's the lookahead?
     → "x"
  3. What would happen if we reduce?
     → Reduce ["a"] to A, then see "x"
  4. Result: Example with symbols=["a","x"], cursor=1, reductions=[{0,1,A}]
  5. This is enough for classification logic to detect ambiguity!
```

## Comparison: Trace-based vs. Synthetic

| Aspect | Trace-based | Synthetic |
|--------|-------------|-----------|
| **When works** | Items with incoming context | Any item |
| **What shows** | Deep parse tree with full context | Minimal symbols + cursor |
| **Construction** | Backward walk through state graph | Direct from item structure |
| **Overhead** | Complex graph building & traversal | Simple symbol extraction |
| **At start states** | Fails (no incoming edges) | Succeeds (no predecessors needed) |
| **Ambiguity detection** | Full tree context | Symbols sufficient |
| **Precedence hints** | Shows structure | Shows conflict point |

## Implementation Implications

```
Current flow:
  Tracer.backtrace_shift() → TraceGraph with 0+ paths → Examples

New flow:
  Tracer.backtrace_shift() → TraceGraph with 0+ paths
                                          ↓
                    If empty: synthetic_example_from_item()
                                    ↓
                    → Examples guaranteed (fallback guarantee)
```

The synthetic generator acts as a safety net that ensures we always have examples to classify, even when the trace graph is empty.

## Why This Doesn't Break Anything

1. **Only activates on failure**: Synthetic examples only generate if tracer returns empty
2. **Uses same Example struct**: Works with existing classification logic
3. **Non-intrusive**: Doesn't modify trace graph building or walking
4. **Composable**: Sits entirely in error reporting layer
5. **Testable in isolation**: Can be tested independently

## Future Enhancements

1. **Richer synthesis**: Generate multiple examples showing different reduction chains
2. **Context hints**: Even without full trace, infer likely enclosing constructs
3. **User guidance**: Suggest "did you mean to nest this in...?" based on syntax
4. **Hybrid approach**: Mix synthetic symbols with trace-based reductions when partially available
