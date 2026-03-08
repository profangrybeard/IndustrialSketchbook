import 'stroke.dart';

/// A reversible action for the undo/redo system (Phase 2.7).
///
/// Captures the strokes added and removed by an operation so it can be
/// undone (remove what was added, re-add what was removed) or redone
/// (re-add what was added, re-remove what was removed).
///
/// ## Action types
///
/// | Action         | strokesAdded              | strokesRemoved |
/// |----------------|---------------------------|----------------|
/// | Draw           | [newStroke]                | []             |
/// | Standard erase | [tombstone, ...segments]  | []             |
/// | History erase  | [tombstone]               | []             |
/// | Clear canvas   | [tombstones...]           | []             |
///
/// ## Undo semantics
///
/// To undo: delete all `strokesAdded` from the stroke list + DB,
/// then re-insert all `strokesRemoved`. The original erased strokes
/// reappear because their tombstones are removed.
class UndoAction {
  const UndoAction({
    this.strokesAdded = const [],
    this.strokesRemoved = const [],
  });

  /// Strokes that were added to the canvas by this action.
  final List<Stroke> strokesAdded;

  /// Strokes that were removed from the canvas by this action.
  final List<Stroke> strokesRemoved;
}
