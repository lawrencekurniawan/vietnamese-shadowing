import 'package:shared_preferences/shared_preferences.dart';

/// The subset of preference operations used by the app.
///
/// This keeps widget tests independent of platform plugin registration while
/// preserving the same behavior as [SharedPreferencesAsync].
abstract interface class PreferenceStore {
  Future<String?> getString(String key);

  Future<double?> getDouble(String key);

  Future<int?> getInt(String key);

  Future<bool?> getBool(String key);

  Future<void> setString(String key, String value);

  Future<void> setDouble(String key, double value);

  Future<void> setInt(String key, int value);

  Future<void> setBool(String key, bool value);
}

class SharedPreferencesStore implements PreferenceStore {
  SharedPreferencesStore({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;

  @override
  Future<String?> getString(String key) => _preferences.getString(key);

  @override
  Future<double?> getDouble(String key) => _preferences.getDouble(key);

  @override
  Future<int?> getInt(String key) => _preferences.getInt(key);

  @override
  Future<bool?> getBool(String key) => _preferences.getBool(key);

  @override
  Future<void> setString(String key, String value) =>
      _preferences.setString(key, value);

  @override
  Future<void> setDouble(String key, double value) =>
      _preferences.setDouble(key, value);

  @override
  Future<void> setInt(String key, int value) => _preferences.setInt(key, value);

  @override
  Future<void> setBool(String key, bool value) =>
      _preferences.setBool(key, value);
}
