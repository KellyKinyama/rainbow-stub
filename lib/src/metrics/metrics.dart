import 'dart:async';

/// Tiny in-process Prometheus-compatible metrics registry.
/// No external deps — emits the [Prometheus text exposition format]
/// (https://prometheus.io/docs/instrumenting/exposition_formats/).
class MetricsRegistry {
  final _counters = <_Series, double>{};
  final _gauges = <_Series, double>{};
  final _histograms = <_Series, _Histogram>{};
  final _help = <String, String>{};
  final _type = <String, String>{};

  final _gaugeProviders = <_Series, double Function()>{};

  void registerHelp({
    required String name,
    required String help,
    required String type,
  }) {
    _help[name] = help;
    _type[name] = type;
  }

  void inc(String name, {Map<String, String> labels = const {}, double v = 1}) {
    final k = _Series(name, labels);
    _counters[k] = (_counters[k] ?? 0) + v;
  }

  void setGauge(
    String name,
    double v, {
    Map<String, String> labels = const {},
  }) {
    _gauges[_Series(name, labels)] = v;
  }

  /// Register a live-computed gauge that will be evaluated at scrape time.
  void gaugeCallback(
    String name,
    double Function() provider, {
    Map<String, String> labels = const {},
  }) {
    _gaugeProviders[_Series(name, labels)] = provider;
  }

  void observe(
    String name,
    double v, {
    Map<String, String> labels = const {},
    List<double> buckets = _defaultBuckets,
  }) {
    final k = _Series(name, labels);
    final h = _histograms.putIfAbsent(k, () => _Histogram(buckets));
    h.observe(v);
  }

  String render() {
    final buf = StringBuffer();
    // Materialize provider-based gauges.
    for (final entry in _gaugeProviders.entries) {
      _gauges[entry.key] = entry.value();
    }

    final names = <String>{
      ..._counters.keys.map((s) => s.name),
      ..._gauges.keys.map((s) => s.name),
      ..._histograms.keys.map((s) => s.name),
    };

    for (final name in names) {
      final help = _help[name];
      final type = _type[name];
      if (help != null) buf.writeln('# HELP $name $help');
      if (type != null) buf.writeln('# TYPE $name $type');

      _counters.forEach((k, v) {
        if (k.name == name) buf.writeln('${k.render()} ${_num(v)}');
      });
      _gauges.forEach((k, v) {
        if (k.name == name) buf.writeln('${k.render()} ${_num(v)}');
      });
      _histograms.forEach((k, h) {
        if (k.name == name) buf.write(h.render(k));
      });
    }
    return buf.toString();
  }

  static String _num(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
}

class _Series {
  _Series(this.name, this.labels);
  final String name;
  final Map<String, String> labels;

  String render() {
    if (labels.isEmpty) return name;
    final parts = labels.entries.map((e) => '${e.key}="${_esc(e.value)}"');
    return '$name{${parts.join(',')}}';
  }

  @override
  bool operator ==(Object other) =>
      other is _Series && other.name == name && _mapEq(other.labels, labels);

  @override
  int get hashCode => Object.hash(name, _mapHash(labels));

  static String _esc(String s) =>
      s.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n');

  static bool _mapEq(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  static int _mapHash(Map<String, String> m) {
    var h = 0;
    for (final e in m.entries) {
      h ^= Object.hash(e.key, e.value);
    }
    return h;
  }
}

const _defaultBuckets = <double>[
  0.001,
  0.005,
  0.01,
  0.025,
  0.05,
  0.1,
  0.25,
  0.5,
  1,
  2.5,
  5,
  10,
];

class _Histogram {
  _Histogram(this.buckets) : counts = List<double>.filled(buckets.length, 0);

  final List<double> buckets;
  final List<double> counts;
  double sum = 0;
  double count = 0;

  void observe(double v) {
    sum += v;
    count += 1;
    for (var i = 0; i < buckets.length; i++) {
      if (v <= buckets[i]) counts[i] += 1;
    }
  }

  String render(_Series series) {
    final buf = StringBuffer();
    for (var i = 0; i < buckets.length; i++) {
      final labels = {...series.labels, 'le': _leLabel(buckets[i])};
      buf.writeln(
        '${_Series('${series.name}_bucket', labels).render()} '
        '${_intOrDouble(counts[i])}',
      );
    }
    final infLabels = {...series.labels, 'le': '+Inf'};
    buf.writeln(
      '${_Series('${series.name}_bucket', infLabels).render()} '
      '${_intOrDouble(count)}',
    );
    buf.writeln(
      '${_Series('${series.name}_sum', series.labels).render()} $sum',
    );
    buf.writeln(
      '${_Series('${series.name}_count', series.labels).render()} '
      '${_intOrDouble(count)}',
    );
    return buf.toString();
  }

  static String _leLabel(double v) =>
      v == v.roundToDouble() && v < 1e15 ? v.toStringAsFixed(0) : v.toString();

  static String _intOrDouble(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
}

/// Wraps a Stopwatch to feed a histogram on completion.
extension MetricsTimer on MetricsRegistry {
  Future<T> time<T>(
    String name,
    Future<T> Function() body, {
    Map<String, String> labels = const {},
  }) async {
    final sw = Stopwatch()..start();
    try {
      return await body();
    } finally {
      sw.stop();
      observe(name, sw.elapsedMicroseconds / 1e6, labels: labels);
    }
  }
}
