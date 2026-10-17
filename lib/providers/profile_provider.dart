import 'dart:convert';
import '../core/services/deeplink_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/models/profile.dart';
import '../core/models/profile_bundle.dart';
import '../core/models/connections_bundle.dart';
import '../core/services/profile_storage_service.dart';
import '../core/services/settings_service.dart';
import 'settings_provider.dart';
import 'config_provider.dart';

class ProfileState {
  final List<Profile> profiles;
  final String activeProfileId;
  final int revision;

  const ProfileState({
    required this.profiles,
    required this.activeProfileId,
    this.revision = 0,
  });

  Profile? get activeProfile =>
      profiles.where((p) => p.id == activeProfileId).firstOrNull;

  bool get isReadonly => activeProfile?.readonly ?? false;

  ProfileState copyWith({List<Profile>? profiles, String? activeProfileId}) =>
      ProfileState(
        profiles: profiles ?? this.profiles,
        activeProfileId: activeProfileId ?? this.activeProfileId,
        revision: revision,
      );
}

class ProfileNotifier extends AsyncNotifier<ProfileState> {
  final _storage = ProfileStorageService();
  final _refresh = <String, int>{};
  ProfileState? get _current => state.value;

  @override
  Future<ProfileState> build() async {
    var snapshot = await _storage.load();
    if (snapshot.profiles.isEmpty) {
      final settings = await SettingsService().load();
      snapshot = await _storage.commit(
        (s) => (
          profiles: [
            Profile(
              id: 'default',
              name: 'По умолчанию',
              isDefault: true,
              settings: settings,
              createdAt: DateTime.now(),
            ),
          ],
          activeProfileId: 'default',
          revision: s.revision,
        ),
      );
    }
    if (!snapshot.profiles.any((p) => p.id == snapshot.activeProfileId)) {
      snapshot = await _storage.commit(
        (s) => (
          profiles: s.profiles,
          activeProfileId: s.profiles.first.id,
          revision: s.revision,
        ),
      );
    }
    return ProfileState(
      profiles: snapshot.profiles,
      activeProfileId: snapshot.activeProfileId,
      revision: snapshot.revision,
    );
  }

  Future<void> _commit(ProfileSnapshot Function(ProfileSnapshot) update) async {
    await future;
    final next = await _storage.commit(update);
    if (ref.mounted && next.revision >= (_current?.revision ?? -1)) {
      state = AsyncData(
        ProfileState(
          profiles: next.profiles,
          activeProfileId: next.activeProfileId,
          revision: next.revision,
        ),
      );
    }
  }

  Future<void> reload() async {
    final snapshot = await _storage.load();
    if (ref.mounted && snapshot.revision >= (_current?.revision ?? -1)) {
      state = AsyncData(
        ProfileState(
          profiles: snapshot.profiles,
          activeProfileId: snapshot.activeProfileId,
          revision: snapshot.revision,
        ),
      );
    }
  }

  Future<void> switchProfile(String id) async {
    await _commit(
      (s) => s.profiles.any((p) => p.id == id)
          ? (profiles: s.profiles, activeProfileId: id, revision: s.revision)
          : s,
    );
    final profile = _current?.activeProfile;
    if (profile == null) return;
    await SettingsService().save(profile.settings, updateProfile: false);
    ref.invalidate(settingsProvider);
    await ref.read(settingsProvider.future);
  }

  Future<void> createProfile(String name, {bool copyFromCurrent = true}) async {
    final settings = copyFromCurrent
        ? await ref.read(settingsProvider.future)
        : const AppSettings();
    await _commit(
      (s) => (
        profiles: [
          ...s.profiles,
          Profile(
            id: 'profile_${DateTime.now().microsecondsSinceEpoch}',
            name: name,
            settings: settings,
            createdAt: DateTime.now(),
          ),
        ],
        activeProfileId: s.activeProfileId,
        revision: s.revision,
      ),
    );
  }

  Future<void> renameProfile(String id, String name) => _commit(
    (s) => (
      profiles: s.profiles
          .map((p) => p.id == id ? p.copyWith(name: name) : p)
          .toList(),
      activeProfileId: s.activeProfileId,
      revision: s.revision,
    ),
  );

  Future<void> deleteProfile(String id) => _commit((s) {
    _refresh[id] = (_refresh[id] ?? 0) + 1;
    return (
      profiles: s.profiles
          .where((p) => p.id != id || p.isDefault || s.activeProfileId == id)
          .toList(),
      activeProfileId: s.activeProfileId,
      revision: s.revision,
    );
  });

  Future<void> toggleReadonly(String id) => _commit(
    (s) => (
      profiles: s.profiles
          .map((p) => p.id == id ? p.copyWith(readonly: !p.readonly) : p)
          .toList(),
      activeProfileId: s.activeProfileId,
      revision: s.revision,
    ),
  );

  Future<void> syncActiveSettings(AppSettings settings, {String? profileId}) =>
      _commit(
        (s) => (
          profiles: s.profiles
              .map(
                (p) => p.id == (profileId ?? s.activeProfileId)
                    ? p.copyWith(settings: settings)
                    : p,
              )
              .toList(),
          activeProfileId: s.activeProfileId,
          revision: s.revision,
        ),
      );

  ProfileBundle exportBundle(String id, {bool includeConnections = false}) {
    final profile = _current!.profiles.firstWhere((p) => p.id == id);
    final configs = ref.read(configProvider).value;
    return ProfileBundle(
      exportedAt: DateTime.now(),
      profile: includeConnections
          ? profile
          : Profile(
              id: profile.id,
              name: profile.name,
              createdAt: profile.createdAt,
              settings: profile.settings.copyWith(
                socksUser: '',
                socksPassword: '',
                randomCredentials: true,
                subUserAgent: '',
                dnsPreset: 'cf_udp',
                customDnsAddress: '1.1.1.1',
                customDnsType: 'udp',
                geoipUrl: GeoPresets.defaultGeoipUrl,
                geositeUrl: GeoPresets.defaultGeositeUrl,
              ),
            ),
      configs: includeConnections ? configs?.configs : null,
      subscriptions: includeConnections ? configs?.subscriptions : null,
    );
  }

  Future<String?> importBundle(
    ProfileBundle bundle, {
    bool switchToProfile = true,
    bool makeReadonly = false,
    String? sourceUrl,
  }) async {
    await future;
    ProfileBundle.fromJson(bundle.toJson());
    if (bundle.hasConnections) {
      await ref
          .read(configProvider.notifier)
          .importBundle(
            ConnectionsBundle(
              exportedAt: bundle.exportedAt,
              configs: bundle.configs ?? [],
              subscriptions: bundle.subscriptions ?? [],
            ),
          );
    }
    var id = 'profile_${DateTime.now().microsecondsSinceEpoch}';
    final profile = Profile(
      id: id,
      name: bundle.profile.name,
      readonly: makeReadonly,
      settings: bundle.profile.settings,
      createdAt: DateTime.now(),
      sourceUrl: sourceUrl ?? bundle.sourceUrl ?? bundle.profile.sourceUrl,
    );
    await _commit((s) {
      final existing = s.profiles
          .where(
            (p) => profile.sourceUrl != null
                ? p.sourceUrl == profile.sourceUrl
                : p.name == profile.name &&
                      jsonEncode(p.settings.toJson()) ==
                          jsonEncode(profile.settings.toJson()),
          )
          .firstOrNull;
      if (existing != null) {
        id = existing.id;
        return s;
      }
      return (
        profiles: [...s.profiles, profile],
        activeProfileId: s.activeProfileId,
        revision: s.revision,
      );
    });
    if (switchToProfile) await switchProfile(id);
    return id;
  }

  Future<String?> refreshProfile(String id, String url) async {
    await future;
    final generation = (_refresh[id] ?? 0) + 1;
    _refresh[id] = generation;
    final bundle = await DeeplinkRouter.fetchFromUrl(
      DeeplinkParseResult.urlProfile(url),
    );
    if (bundle is! ProfileBundle) return null;
    if (_refresh[id] != generation ||
        !_current!.profiles.any((p) => p.id == id && p.sourceUrl == url)) {
      return null;
    }
    if (bundle.hasConnections) {
      await ref
          .read(configProvider.notifier)
          .importBundle(
            ConnectionsBundle(
              exportedAt: bundle.exportedAt,
              configs: bundle.configs ?? [],
              subscriptions: bundle.subscriptions ?? [],
            ),
          );
    }
    var applied = false;
    await _commit((s) {
      if (_refresh[id] != generation || !s.profiles.any((p) => p.id == id)) {
        return s;
      }
      applied = true;
      return (
        profiles: s.profiles
            .map(
              (p) => p.id == id
                  ? p.copyWith(
                      name: bundle.profile.name,
                      settings: bundle.profile.settings,
                      lastFetchedAt: DateTime.now(),
                    )
                  : p,
            )
            .toList(),
        activeProfileId: s.activeProfileId,
        revision: s.revision,
      );
    });
    if (!applied) return null;
    if (_current?.activeProfileId == id) {
      ref.invalidate(settingsProvider);
      await ref.read(settingsProvider.future);
    }
    return id;
  }
}

final profileProvider = AsyncNotifierProvider<ProfileNotifier, ProfileState>(
  ProfileNotifier.new,
);
