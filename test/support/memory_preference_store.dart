import 'package:vietnamese_shadowing/app/preference_store.dart';

class MemoryPreferenceStore implements PreferenceStore {
  MemoryPreferenceStore([Map<String, Object>? initialValues])
    : _values = <String, Object>{...?initialValues};

  final Map<String, Object> _values;

  @override
  Future<String?> getString(String key) async => _values[key] as String?;

  @override
  Future<double?> getDouble(String key) async => _values[key] as double?;

  @override
  Future<int?> getInt(String key) async => _values[key] as int?;

  @override
  Future<bool?> getBool(String key) async => _values[key] as bool?;

  @override
  Future<void> setString(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> setDouble(String key, double value) async {
    _values[key] = value;
  }

  @override
  Future<void> setInt(String key, int value) async {
    _values[key] = value;
  }

  @override
  Future<void> setBool(String key, bool value) async {
    _values[key] = value;
  }
}
