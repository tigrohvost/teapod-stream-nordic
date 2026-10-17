import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/profile.dart';
import 'settings_service.dart';
import 'storage_secure_service.dart';

typedef ProfileSnapshot = ({
  List<Profile> profiles,
  String activeProfileId,
  int revision,
});

class ProfileStorageService {
  final _secure = StorageSecureService();
  static Future<void> _tail = Future.value();
  Future<T> _serial<T>(Future<T> Function() task) {
    final result = _tail.then((_) => task());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace stack) {});
    return result;
  }

  Future<ProfileSnapshot> load() => _serial(_load);
  Future<ProfileSnapshot> _load() async {
    final raw = await _secure.readProfilesRaw();
    if (raw == null || raw.isEmpty) {
      return (profiles: <Profile>[], activeProfileId: 'default', revision: 0);
    }
    final json = jsonDecode(raw);
    if (json is List) {
      final prefs = await SharedPreferences.getInstance();
      return (
        profiles: json
            .map((p) => Profile.fromJson(p as Map<String, dynamic>))
            .toList(),
        activeProfileId: prefs.getString('active_profile_id') ?? 'default',
        revision: 0,
      );
    }
    if (json is! Map || json['schema'] != 2) {
      throw const FormatException('Неверный снимок профилей');
    }
    return (
      profiles: (json['profiles'] as List)
          .map((p) => Profile.fromJson(p as Map<String, dynamic>))
          .toList(),
      activeProfileId: json['activeProfileId'] as String,
      revision: json['revision'] as int,
    );
  }

  Future<ProfileSnapshot> commit(
    ProfileSnapshot Function(ProfileSnapshot) update,
  ) => _serial(() async {
    final old = await _load();
    final next = update(old);
    final revised = (
      profiles: next.profiles,
      activeProfileId: next.activeProfileId,
      revision: old.revision + 1,
    );
    await _secure.writeProfilesRaw(
      jsonEncode({
        'schema': 2,
        'revision': revised.revision,
        'activeProfileId': revised.activeProfileId,
        'profiles': revised.profiles.map((p) => p.toJson()).toList(),
      }),
    );
    return revised;
  });

  Future<AppSettings?> loadActiveSettings() async {
    final snapshot = await load();
    return snapshot.profiles
        .where((p) => p.id == snapshot.activeProfileId)
        .firstOrNull
        ?.settings;
  }
}
