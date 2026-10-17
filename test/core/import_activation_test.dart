import 'package:flutter_test/flutter_test.dart';
import 'package:teapodstream/core/models/config_state.dart';
import 'package:teapodstream/core/models/connections_bundle.dart';
import 'package:teapodstream/core/models/vpn_config.dart';
import 'package:teapodstream/core/services/import_service.dart';

const _link = 'trojan://secret@pasted.example.test:443#pasted';

VpnConfig _existing(String name) => VpnConfig(
  id: name,
  name: name,
  protocol: VpnProtocol.trojan,
  address: '$name.example.test',
  port: 443,
  uuid: '',
  password: 'secret',
  security: VpnSecurity.tls,
  transport: VpnTransport.tcp,
  createdAt: DateTime(2026),
);

Future<ImportPlan> _plan(String text) =>
    ImportService().prepare(ImportService.fromText(text), activateSingle: true);

void main() {
  final current = ConfigState(
    configs: [_existing('old')],
    activeConfigId: 'old',
    activeSubscriptionId: 'sub',
  );

  test('a single pasted link becomes the active connection (v1.6.6)', () async {
    final (next, result) = ImportService.apply(current, await _plan(_link));
    expect(result.addedConfigs, 1);
    expect(next.activeConfig?.address, 'pasted.example.test');
    expect(next.activeSubscriptionId, isNull);
  });

  test('re-pasting a saved link selects it instead of adding a copy', () async {
    final first = ImportService.apply(current, await _plan(_link)).$1;
    final reselect = first.copyWith(activeConfigId: 'old');
    final (next, result) = ImportService.apply(reselect, await _plan(_link));
    expect(result.addedConfigs, 0);
    expect(next.configs, hasLength(2));
    expect(next.activeConfig?.address, 'pasted.example.test');
  });

  test('several links or a bundle keep the current selection', () async {
    final (next, _) = ImportService.apply(
      current,
      await _plan('$_link\ntrojan://secret@second.example.test:443#2'),
    );
    expect(next.activeConfigId, 'old');
    final bundle = ImportService.apply(
      current,
      await ImportService().prepare(
        ConnectionsBundle(exportedAt: DateTime(2026), rawUris: [_link]),
      ),
    ).$1;
    expect(bundle.activeConfigId, 'old');
  });
}
