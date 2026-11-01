import 'package:audiojoe/updates.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('versions compare numerically, build number ignored', () {
    expect(compareVersions('0.0.21', '0.0.20'), greaterThan(0));
    expect(compareVersions('0.1.0', '0.0.99'), greaterThan(0));
    expect(compareVersions('0.0.21', '0.0.21+21'), 0);
    expect(compareVersions('1.0', '1.0.0'), 0);
    expect(compareVersions('0.0.9', '0.0.10'), lessThan(0));
  });
}
