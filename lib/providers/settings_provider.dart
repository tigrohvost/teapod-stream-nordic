import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/services/settings_service.dart';
import 'profile_provider.dart';

class SettingsNotifier extends AsyncNotifier<AppSettings> {
  final _service = SettingsService();

  @override
  Future<AppSettings> build() => _service.load();

  Future<void> save(AppSettings settings) async {
    final profileState = ref
        .read(profileProvider)
        .maybeWhen(data: (d) => d, orElse: () => null);
    if (profileState?.isReadonly == true) return;

    await _service.save(
      settings,
      profileId: profileState?.activeProfileId,
      base: state.value,
    );
    if (ref.read(profileProvider).value?.activeProfileId ==
        profileState?.activeProfileId) {
      state = AsyncData(await _service.load());
    }

    // Keep profile snapshot in sync
    await ref.read(profileProvider.notifier).reload();
  }

  Future<void> cleanGhostPackages(Set<String> installedPackages) async {
    final current = state.maybeWhen(data: (d) => d, orElse: () => null);
    if (current == null) return;
    final newIncluded = current.includedPackages.intersection(
      installedPackages,
    );
    final newExcluded = current.excludedPackages.intersection(
      installedPackages,
    );
    if (newIncluded.length == current.includedPackages.length &&
        newExcluded.length == current.excludedPackages.length) {
      return;
    }
    await save(
      current.copyWith(
        includedPackages: newIncluded,
        excludedPackages: newExcluded,
      ),
    );
  }

  Future<void> toggleExcludedPackage(String package) async {
    final current = state.maybeWhen(data: (d) => d, orElse: () => null);
    if (current == null) return;
    final excluded = Set<String>.from(current.excludedPackages);
    if (excluded.contains(package)) {
      excluded.remove(package);
    } else {
      excluded.add(package);
    }
    await save(current.copyWith(excludedPackages: excluded));
  }
}

final settingsProvider = AsyncNotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);
