/// Bounded batches. Cancellation stops scheduling and discards in-flight results.
class ProbeScheduler {
  final int concurrency;
  int _generation = 0;
  ProbeScheduler({this.concurrency = 6}) : assert(concurrency > 0);
  void cancel() => _generation++;
  Future<Map<String, int?>?> run<T>(
    Map<String, T> jobs,
    Future<int?> Function(T) probe,
  ) async {
    final generation = ++_generation;
    final entries = jobs.entries.toList();
    final results = <String, int?>{};
    var next = 0;
    Future<void> worker() async {
      while (generation == _generation && next < entries.length) {
        final entry = entries[next++];
        int? latency;
        try {
          latency = await probe(entry.value);
        } catch (_) {
          latency = null;
        }
        if (generation != _generation) return;
        results[entry.key] = latency;
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
    return generation == _generation ? results : null;
  }
}
