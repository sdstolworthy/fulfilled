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
/// **Persistence** is a Hive box (`outbox_log`). `toJson` / `fromJson`
/// is the serialization seam — Hive holds the JSON strings, the notifier
/// holds the typed records.
///
/// `attempt` increments after each failed flush. The notifier caps at 3
/// before marking the entry "failed" and surfacing it to the user
/// (architecture §6 "Offline log outbox" terminal-failure rule).
class OutboxEntry {
  const OutboxEntry({
    required this.id,
    required this.payload,
    required this.queuedAt,
    this.attempt = 0,
    this.lastError,
  });

  /// Client-generated UUID. Doubles as the optimistic LogEntry id so the
  /// day-view row can be matched and replaced when the server response
  /// returns a different server-side id (conflict policy: server wins).
  final String id;

  /// Raw `LogCreate` JSON. Map values are `String | num | bool | null`
  /// only — Hive cannot round-trip arbitrary Dart objects.
  final Map<String, dynamic> payload;

  /// Local wall-clock timestamp at enqueue. Surfaced on terminal failure
  /// so the retry sheet can say "logged at 12:42, failed to sync".
  final DateTime queuedAt;

  /// Number of attempted flushes so far. New entries start at 0.
  final int attempt;

  /// Last error message, set after a failed flush. Null until the first
  /// failure.
  final String? lastError;

  OutboxEntry copyWith({
    String? id,
    Map<String, dynamic>? payload,
    DateTime? queuedAt,
    int? attempt,
    Object? lastError = _sentinel,
  }) =>
      OutboxEntry(
        id: id ?? this.id,
        payload: payload ?? this.payload,
        queuedAt: queuedAt ?? this.queuedAt,
        attempt: attempt ?? this.attempt,
        lastError: identical(lastError, _sentinel)
            ? this.lastError
            : lastError as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'payload': payload,
        'queuedAt': queuedAt.toIso8601String(),
        'attempt': attempt,
        if (lastError != null) 'lastError': lastError,
      };

  factory OutboxEntry.fromJson(Map<String, dynamic> json) => OutboxEntry(
        id: json['id'] as String,
        payload: Map<String, dynamic>.from(json['payload'] as Map),
        queuedAt: DateTime.parse(json['queuedAt'] as String),
        attempt: (json['attempt'] as num?)?.toInt() ?? 0,
        lastError: json['lastError'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OutboxEntry &&
          other.id == id &&
          other.queuedAt == queuedAt &&
          other.attempt == attempt &&
          other.lastError == lastError;

  @override
  int get hashCode => Object.hash(id, queuedAt, attempt, lastError);
}

const Object _sentinel = Object();
