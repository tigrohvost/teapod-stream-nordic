import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'deeplink_router.dart';
import 'import_service.dart';
import '../models/profile_bundle.dart';
import '../models/connections_bundle.dart';
import '../../providers/profile_provider.dart';
import '../../providers/config_provider.dart';

/// Shared preview and commit for OS links, QR, clipboard, text and URLs.
class DeeplinkHandler {
  final WidgetRef ref;
  final BuildContext context;
  DeeplinkHandler(this.context, this.ref);

  Future<bool> handleUri(String uri, {bool allowSelfSigned = false}) async {
    Object? bundle;
    String? source;
    if (uri.trim().startsWith('teapod://')) {
      final parsed = DeeplinkRouter.parse(uri);
      if (parsed == null) {
        throw const FormatException('Не удалось распознать ссылку');
      }
      source = parsed.effectiveSourceUrl;
      bundle = parsed.source == DeeplinkSource.data
          ? parsed.profileBundle ?? parsed.connectionsBundle
          : await DeeplinkRouter.fetchFromUrl(parsed);
    } else if (ImportService.validUrl(uri.trim())) {
      source = uri.trim();
      bundle = ConnectionsBundle(
        exportedAt: DateTime.now(),
        subscriptionUrls: [source],
      );
    } else {
      bundle = ImportService.fromText(uri);
    }
    if (bundle == null) {
      throw const FormatException('Не удалось загрузить данные по ссылке');
    }
    if (bundle is ProfileBundle) {
      await ref.read(profileProvider.future);
      await ref.read(configProvider.future);
      if (!context.mounted) {
        return false;
      }
      final confirmed = await _confirm(
        'Импорт профиля',
        'Профиль: «${bundle.profile.name}»\n'
            '${bundle.configs?.length ?? 0} подключений, ${bundle.subscriptions?.length ?? 0} подписок',
        source,
      );
      if (!confirmed || !context.mounted) return false;
      await ref
          .read(profileProvider.notifier)
          .importBundle(bundle, sourceUrl: source);
      if (context.mounted) _message('Профиль импортирован');
      return true;
    }
    final notifier = ref.read(configProvider.notifier);
    final plan = await notifier.prepareImport(
      bundle as ConnectionsBundle,
      allowSelfSigned: allowSelfSigned,
    );
    final current = await ref.read(configProvider.future);
    final preview = ImportService.apply(current, plan).$2;
    if (!context.mounted) {
      return false;
    }
    final confirmed = await _confirm(
      'Импорт подключений',
      '${plan.label == null ? '' : '${plan.label}\n'}'
          'Добавить: ${preview.addedConfigs} подключений, ${preview.addedSubscriptions} подписок\n'
          'Пропустить дубликаты: ${preview.skippedConfigs}\n'
          'Некорректные элементы: ${preview.invalidItems}',
      source,
      canImport: preview.addedConfigs + preview.addedSubscriptions > 0,
    );
    if (!confirmed || !context.mounted) return false;
    final result = await notifier.applyImport(plan);
    if (context.mounted) {
      _message(
        'Добавлено: ${result.addedConfigs} подключений, '
        '${result.addedSubscriptions} подписок; пропущено: ${result.skippedConfigs + result.invalidItems}',
      );
    }
    return true;
  }

  Future<bool> _confirm(
    String title,
    String content,
    String? source, {
    bool canImport = true,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Text(
              '$content${source == null ? '' : '\nИсточник: ${ImportService.sourceLabel(source)}'}',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: canImport ? () => Navigator.pop(ctx, true) : null,
              child: const Text('Импортировать'),
            ),
          ],
        ),
      ) ??
      false;

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}
