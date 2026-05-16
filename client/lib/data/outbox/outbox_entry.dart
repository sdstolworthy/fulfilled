import 'package:freezed_annotation/freezed_annotation.dart';

part 'outbox_entry.freezed.dart';
part 'outbox_entry.g.dart';

/// One pending `POST /log` payload in the mobile outbox (T-22).
///
/// **Wire shape** (`payload`) is the raw `LogCreate` JSON from
/// `specs/openapi.yaml`:
/// ```
/// { food_id, serving_id, consumed_on, meal, quantity, note? }
/// ```
/// We carry the JSON map rather than a typed DTO so this file does not
/// depend on the generated `LogCreate` shape — the outbox is intentionally
/// boring storage, owned end-to-end by `LogOutboxNotifier`.
///
/// **Persistence** is a Hive box (`outbox_log`). The Freezed-generated
/// `toJson`/`fromJson` is the serialization seam — Hive holds the JSON
/// strings, the notifier holds the typed records.
///
/// `attempt` increments after each failed flush. The notifier caps at 3
/// before marking the entry "failed" and surfacing it to the user
/// (architecture §6 "Offline log outbox" terminal-failure rule).
@freezed
class OutboxEntry with _$OutboxEntry {
  const factory OutboxEntry({
    /// Client-generated UUID. Doubles as the optimistic LogEntry id so the
    /// day-view row can be matched and replaced when the server response
    /// returns a different server-side id (conflict policy: server wins).
    required String id,

    /// Raw `LogCreate` JSON. Map values are `String | num | bool | null`
    /// only — Hive cannot round-trip arbitrary Dart objects.
    required Map<String, dynamic> payload,

    /// Local wall-clock timestamp at enqueue. Surfaced on terminal failure
    /// so the retry sheet can say "logged at 12:42, failed to sync".
    required DateTime queuedAt,

    /// Number of attempted flushes so far. New entries start at 0.
    @Default(0) int attempt,

    /// Last error message, set after a failed flush. Optional because the
    /// first enqueue carries no error.
    String? lastError,
  }) = _OutboxEntry;

  factory OutboxEntry.fromJson(Map<String, dynamic> json) =>
      _$OutboxEntryFromJson(json);
}
