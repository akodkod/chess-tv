# Architecture review

Date: 2026-11-03

The architecture is sound for the current scope. The extension owns observed game truth, the relay routes messages, and the TV owns presentation. Full snapshots, SQLite for pairings only, and native platform modules keep it reasonably simple.

Extensibility is weaker inside the extension worker and TV session: adding behavior requires understanding several interacting flags. Improve those areas before adding infrastructure or a generic adapter framework.

This review covers the working tree, including uncommitted changes. Backward compatibility is not required. No implementation changes were made during the review.

## 1. Replace Swift’s all-purpose Message with typed payloads

[Protocol.swift](tv/ChessTV/Models/Protocol.swift) represents every message using a string discriminator and roughly 30 optional properties. Consequently, snapshots, pending moves, and previews all use the same permissive type, and validation requires parallel field tables and runtime checks.

Use a message enum with payloads such as `Snapshot`, `MoveRequest`, and `SessionContext`. Keep genuinely unknown values nullable, but make structurally required fields nonoptional. This would remove defensive branching throughout the TV app and make protocol extensions safer. Add shared valid/invalid fixtures for every message kind to catch TypeScript–Swift drift.

## 2. Give recovery state explicit owners

[worker.ts](extension/src/worker.ts) spreads attachment and move state across `binding`, `generation`, `attached`, `phase`, `risk`, `commandId`, and `locked`. [TVSession.swift](tv/ChessTV/Models/TVSession.swift) similarly combines pairing, transport recovery, pending moves, history, previews, and sounds.

Keep one root session, but extract small modules for attachment/move lifecycle and position history. Represent related states explicitly—for example, idle, pending(command), and interrupted(command)—so transitions update the complete state together. Preserve the persisted uncertainty marker before page interaction; that complexity serves a real purpose.

## 3. Make snapshots and input availability coherent

[chesscom-adapter.ts](extension/src/chesscom-adapter.ts) emits a snapshot followed by a separate status message. The TV then maintains separate freshness timestamps and combines both to decide whether moves are allowed.

Since breaking changes are acceptable, include observed availability and its reason in the full snapshot. Keep transport/session connectivity separate. If standalone invalidations remain necessary, bind them to an observation revision. This reduces ordering assumptions and makes “this position is playable” one coherent fact.

## 4. Optimize repeated observation before optimizing transport

[chesscom-game.ts](extension/src/chesscom-game.ts) reconstructs the entire game on each read; the worker synchronizes every second, and snapshots regenerate legal moves. During move execution, [chesscom-move.ts](extension/src/chesscom-move.ts) observes mutations across the entire document body.

Cache reconstructed chess state and legal moves by exact move history, while continuing to verify rendered squares and refresh clocks. Narrow move observation to the board and move list. Keep periodic full snapshots for freshness and recovery. These are concrete opportunities, although their runtime cost has not been measured.

## 5. Consolidate command deduplication

Both [ChessComAdapter](extension/src/chesscom-adapter.ts) and [createMoveController](extension/src/chesscom-move.ts) maintain outcome maps, with different keys and lifetime rules.

Let the adapter own command identity, payload matching, and cached outcomes. Let the move controller own page interaction and unresolved execution. Also pass its `Document` explicitly: the adapter accepts an injected document, but the controller uses the global one.

## Recommended order

1. Typed protocol payloads.
2. Coherent snapshot/availability contract.
3. Explicit recovery states.
4. Measured observation optimizations.

Consolidate command deduplication with the recovery-state work. Update both clients, relay, fixtures, and documentation together, without compatibility shims.

## Validation

`bun run test` passed: 142 TypeScript tests across 11 files.

Swift tests and live browser/TV performance were not run.
