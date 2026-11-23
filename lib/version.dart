/// Version of this build. Must match `version:` in pubspec.yaml
/// (checked by a test).
const appVersion = '1.3.3';

/// Compares "1.2.3" style versions. Returns <0, 0 or >0.
int compareVersions(String a, String b) {
  List<int> parts(String v) => v
      .split(RegExp(r'[.+]'))
      .take(3)
      .map((x) => int.tryParse(x) ?? 0)
      .toList();
  final x = parts(a), y = parts(b);
  for (var i = 0; i < 3; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}
