// The tier-free Live Activity payload and the re-import identity path.
//
// Upstream 1.2.0 deleted `tier` from LiveActivity and `packToken` from
// LivePush, and the round-8 fix followed upstream by deleting the two
// pet live-activity test files that referenced them. This file restores
// coverage for the behavior that remains, without reviving tier:
//  - no payload ever carries a 'tier' key, in any phase;
//  - a tier-less payload reads the tier-0 animation on the island;
//  - re-importing a pack (same id, new object) does not reuse the old
//    still and does not restart the push identity.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_app/notify/live_activity.dart';
import 'package:dsh_app/notify/notify_channel.dart';
import 'package:dsh_app/notify/pet_live_activity.dart';
import 'package:dsh_app/notify/pet_live_activity_art.dart';
import 'package:dsh_app/pets/codex_pet_converter.dart';
import 'package:dsh_app/pets/pet_pack.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

LivePush push({
  LiveKind kind = LiveKind.running,
  PetStateName mood = PetStateName.thinking,
  String? packId,
  String? eventId = 'private request',
}) => LivePush(
  enabled: true,
  packId: packId,
  activity: LiveActivity(
    kind: kind,
    mood: mood,
    title: 'private title',
    text: 'private text',
    chip: 'Status',
    publicText: 'Public status',
    target: const PetTarget(HostRef.relay('host-id', name: 'private host name'), 'session / 中文'),
    eventId: eventId,
  ),
);

LivePush _push(String packId) => LivePush(
  enabled: true,
  packId: packId,
  activity: LiveActivity(
    kind: LiveKind.running,
    mood: PetStateName.working,
    title: 'private title',
    text: 'private text',
    chip: 'Status',
    publicText: 'Public status',
    target: const PetTarget(HostRef.relay('host-id'), 'session'),
  ),
);

Future<Map<String, Object?>> _sourceJson() async =>
    jsonDecode(File('assets/pets/deepy-whale/pack.json').readAsStringSync()) as Map<String, Object?>;

Future<PetPack> _assetPack(String id) async => PetPack.parse(await _sourceJson());

Future<PetPack> _filePack(String id, Directory dir) async {
  final json = await _sourceJson();
  json['id'] = id;
  final sheets = {for (final animation in (json['animations'] as Map).values.cast<Map>()) animation['sheet'] as String};
  for (final sheet in sheets) {
    await File('assets/pets/deepy-whale/$sheet').copy('${dir.path}/$sheet');
  }
  return PetPack.parse(json, dir: dir.path);
}

Uint8List _codexAtlas({required int red}) {
  final image = img.Image(width: 1536, height: 2288, numChannels: 4);
  const counts = [6, 8, 8, 4, 5, 8, 6, 6, 6, 8, 8];
  for (var row = 0; row < 11; row++) {
    for (var col = 0; col < counts[row]; col++) {
      img.fillRect(
        image,
        x1: col * 192 + 40,
        y1: row * 208 + 40,
        x2: col * 192 + 151,
        y2: row * 208 + 167,
        color: img.ColorRgba8(red + (row * 19) % 60, 64 + (col * 23) % 160, 160, 255),
      );
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

PetPack _codexPack(Directory dir, {required int red}) {
  final archive = Archive()..add(ArchiveFile.bytes('pet.json', utf8.encode(jsonEncode(_codexMetadata))));
  archive.add(ArchiveFile.bytes('spritesheet.png', _codexAtlas(red: red)));
  final converted = CodexPetConverter.convertArchive(Uint8List.fromList(ZipEncoder().encode(archive)));
  for (final entry in converted.validated.sheets.entries) {
    File('${dir.path}/${entry.key}').writeAsBytesSync(entry.value);
  }
  return PetPack.parse(converted.validated.json, dir: dir.path);
}

const _codexMetadata = {
  'id': 'imported-codex',
  'displayName': 'Imported Codex',
  'spritesheetPath': 'spritesheet.png',
  'spriteVersionNumber': 2,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('no tier anywhere: the payload never carries one, in any phase', () {
    final cases = [
      (push(packId: 'deepy-whale', mood: PetStateName.idle), 'idle', 'idle'),
      (push(packId: 'deepy-whale'), 'thinking', 'thinking'),
      (push(packId: 'deepy-whale', mood: PetStateName.working), 'working', 'working'),
      (push(packId: 'deepy-whale', mood: PetStateName.juggling), 'working', 'juggling'),
      (push(packId: 'deepy-whale', mood: PetStateName.sweeping), 'working', 'sweeping'),
      (push(packId: 'deepy-whale', mood: PetStateName.carrying), 'working', 'carrying'),
      (push(packId: 'deepy-whale', kind: LiveKind.waiting), 'waitingApproval', 'notification'),
      (push(packId: 'deepy-whale', kind: LiveKind.done), 'completed', 'attention'),
      (push(packId: 'deepy-whale', kind: LiveKind.failed), 'error', 'error'),
    ];
    for (final (value, phase, petState) in cases) {
      final payload = petLiveActivityPayload(value)!;
      expect(payload['phase'], phase);
      expect(payload['petState'], petState);
      expect(payload.keys.toSet(), {
        'host',
        'sessionId',
        'packId',
        'phase',
        'petState',
        'detail',
        'label',
        'staleLabel',
        if (value.activity!.kind == LiveKind.done) 'completionSeed',
      });
      // Upstream deleted tier from LiveActivity, so the island can no
      // longer tell a busy turn from an idle one: no payload carries
      // the key at all, including working/juggling and done turns.
      expect(payload.containsKey('tier'), isFalse);
      expect(jsonDecode(payload['host'] as String), {'kind': 'relay', 'id': 'host-id'});
      expect(payload['sessionId'], 'session / 中文');
      expect(jsonEncode(payload), isNot(contains('private')));
    }
    expect(petLiveActivityPayload(const LivePush(enabled: false)), isNull);
    expect(petLiveActivityPayload(const LivePush(enabled: true)), isNull);
  });

  test('a request waiting on the person wins over the pose around it', () {
    final waiting = petLiveActivityPayload(
      push(packId: 'deepy-whale', kind: LiveKind.waiting, mood: PetStateName.attention),
    )!;
    expect(waiting['phase'], 'waitingApproval');
    expect(waiting['petState'], 'notification');
    expect(waiting.containsKey('tier'), isFalse);
  });

  test('a finished turn keeps one celebration, chosen from its own turn', () {
    String seedFor(String? eventId) =>
        petLiveActivityPayload(push(packId: 'whale-girl', kind: LiveKind.done, eventId: eventId))!['completionSeed']!
            as String;

    final first = seedFor('event-a');
    expect(first, seedFor('event-a'));
    expect(first, matches(RegExp(r'^[0-9a-f]{8}$')));
    expect(first, isNot(seedFor('event-b')));
    // The opaque id itself never reaches the notification payload.
    expect(first, isNot(contains('event-a')));
    final payload = petLiveActivityPayload(push(packId: 'whale-girl', kind: LiveKind.done))!;
    expect(payload.containsKey('completionSeed'), isTrue);
    expect(payload.containsKey('tier'), isFalse);
  });

  test('the run start rides along so the chip can count', () {
    final activity = LiveActivity(
      kind: LiveKind.running,
      mood: PetStateName.working,
      title: 'private title',
      text: 'private text',
      chip: 'Status',
      publicText: 'Public status',
      target: const PetTarget(HostRef.relay('host-id'), 'session'),
      since: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );
    final payload = petLiveActivityPayload(LivePush(enabled: true, packId: 'deepy-whale', activity: activity))!;
    expect(payload['since'], 1700000000000);
    expect(payload.containsKey('tier'), isFalse);
  });

  test('selected pet idle fallback respects selection and enabled switch', () {
    const idle = LivePush(enabled: true, packId: 'deepy-whale');
    final payload = petLiveActivityPayload(idle)!;
    expect(payload['host'], 'local-pet');
    expect(payload['sessionId'], 'local-pet');
    expect(payload['packId'], 'deepy-whale');
    expect(payload['phase'], 'idle');
    expect(payload['petState'], 'idle');
    expect(petLiveActivityPayload(idle), payload);
    expect(petLiveActivityPayload(const LivePush(enabled: true, packId: noPetId)), isNull);
    expect(petLiveActivityPayload(const LivePush(enabled: false, packId: 'deepy-whale')), isNull);
    final active = petLiveActivityPayload(LivePush(enabled: true, packId: 'deepy-whale', activity: push().activity))!;
    expect(active['phase'], 'thinking');
    expect(active['sessionId'], 'session / 中文');
    expect(active['packId'], 'deepy-whale');
    expect(active['label'], 'Status');
  });

  test('a tier-less payload reads the tier-0 animation', () {
    // The island art path reads payload['tier'] ?? 0, so a payload
    // without tier always resolves the tier-0 animation. The pack's
    // tier table itself is untouched: it still answers tiered picks
    // when a caller passes one, but nothing in the Live Activity
    // path passes one any more.
    final pack = PetPack.parse(
      jsonDecode(File('assets/pets/deepy-whale/pack.json').readAsStringSync()) as Map<String, Object?>,
    );
    expect(pack.animFor(PetStateName.working, tier: 1).name, 'typing');
    expect(pack.animFor(PetStateName.working, tier: 2).name, 'music');
    expect(pack.animFor(PetStateName.working, tier: 3).name, 'building');
    expect(pack.animFor(PetStateName.juggling, tier: 1).name, 'music');
    expect(pack.animFor(PetStateName.juggling, tier: 2).name, 'conducting');
    expect(pack.animFor(PetStateName.working).name, 'typing');
  });

  test('a tier-less working turn still renders a bounded still', () async {
    final pushValue = _push('deepy-whale');
    final payload = petLiveActivityPayload(pushValue)!;
    expect(payload.containsKey('tier'), isFalse);
    final art = await renderPetLiveActivityArt(await _assetPack('deepy-whale'), pushValue, bundle: rootBundle);

    expect(art, isNotNull);
    final image = img.decodePng(art!.png);
    expect(image, isNotNull);
    expect(image!.width, lessThanOrEqualTo(64));
    expect(image.height, lessThanOrEqualTo(64));
    expect(art.png.length, lessThan(64 * 1024));
    expect(art.bodyRatio, greaterThanOrEqualTo(1));
    expect(image.any((pixel) => pixel.a == 0), isTrue);
    expect(image.any((pixel) => pixel.a > 0), isTrue);
    final size = utf8
        .encode(
          jsonEncode({
            ...payload,
            'art': base64Encode(art.png),
            'artBodyRatio': art.bodyRatio,
            'artPixelArt': art.pixelArt,
          }),
        )
        .length;
    expect(size, lessThanOrEqualTo(3300));
  });

  test('an imported pet renders from its app-sandbox folder without App Group', () async {
    final dir = await Directory.systemTemp.createTemp('dsh-pet-art-');
    addTearDown(() => dir.delete(recursive: true));
    final pushValue = _push('imported-whale');
    expect(petLiveActivityPayload(pushValue)!.containsKey('tier'), isFalse);
    final art = await renderPetLiveActivityArt(
      await _filePack('imported-whale', dir),
      pushValue,
      bundle: rootBundle,
    );

    expect(art, isNotNull);
    final image = img.decodePng(art!.png);
    expect(image, isNotNull);
    expect(image!.width, lessThanOrEqualTo(64));
    expect(image.height, lessThanOrEqualTo(64));
  });

  test('a missing or corrupt sheet degrades to no inline art', () async {
    final missing = await Directory.systemTemp.createTemp('dsh-pet-art-missing-');
    final corrupt = await Directory.systemTemp.createTemp('dsh-pet-art-corrupt-');
    addTearDown(() => missing.delete(recursive: true));
    addTearDown(() => corrupt.delete(recursive: true));
    final corruptPack = await _filePack('corrupt-whale', corrupt);
    final json = await _sourceJson();
    // `_push` is a tier-less working turn, so `typing` (not `idle`) is
    // the animation the inline still reads.
    final typing = (json['animations'] as Map)['typing'] as Map;
    await File('${corrupt.path}/${typing['sheet']}').writeAsString('not a png');

    expect(
      await renderPetLiveActivityArt(
        PetPack.parse(json..['id'] = 'missing-whale', dir: missing.path),
        _push('missing-whale'),
        bundle: rootBundle,
      ),
      isNull,
    );
    expect(await renderPetLiveActivityArt(corruptPack, _push('corrupt-whale'), bundle: rootBundle), isNull);
  });

  test('a full-size Codex v2 imported atlas fits the inline ActivityKit budget', () async {
    final dir = await Directory.systemTemp.createTemp('dsh-codex-art-');
    addTearDown(() => dir.delete(recursive: true));
    final pushValue = _push('imported-codex');
    final art = await renderPetLiveActivityArt(_codexPack(dir, red: 32), pushValue, bundle: rootBundle);
    final payload = petLiveActivityPayload(pushValue)!;

    expect(payload.containsKey('tier'), isFalse);
    expect(art, isNotNull);
    final image = img.decodePng(art!.png);
    expect(image, isNotNull);
    expect(image!.any((pixel) => pixel.a > 0), isTrue);
    expect(image.any((pixel) => pixel.a == 0), isTrue);
    final size = utf8
        .encode(
          jsonEncode({
            ...payload,
            'art': base64Encode(art.png),
            'artBodyRatio': art.bodyRatio,
            'artPixelArt': art.pixelArt,
          }),
        )
        .length;
    expect(size, lessThanOrEqualTo(3300));
  });

  test('re-importing the same pack id does not reuse the old still', () async {
    final firstDir = await Directory.systemTemp.createTemp('dsh-pet-art-reimport-a-');
    final secondDir = await Directory.systemTemp.createTemp('dsh-pet-art-reimport-b-');
    addTearDown(() => firstDir.delete(recursive: true));
    addTearDown(() => secondDir.delete(recursive: true));
    final pushValue = _push('imported-codex');
    final first = await renderPetLiveActivityArt(_codexPack(firstDir, red: 32), pushValue, bundle: rootBundle);
    // Same pack id and animation name, but a different pack object with
    // different bytes: the still cache keys by pack identity, so the
    // re-import must re-render instead of serving the first import's
    // pixels.
    final reimported = await renderPetLiveActivityArt(
      _codexPack(secondDir, red: 120),
      pushValue,
      bundle: rootBundle,
    );
    expect(first, isNotNull);
    expect(reimported, isNotNull);
    expect(reimported!.png, isNot(orderedEquals(first!.png)));
  });

  const channel = MethodChannel('test/pet_live_activity');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('re-importing a pack keeps the same push identity', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return call.method;
    });
    final bridge = PetLiveActivityChannel(channel: channel);
    // Same host + session, pushed again after a re-import: the island
    // updates in place instead of starting a new activity. The push
    // identity is the host + session, not the pack object — a pack
    // re-import alone never changes it.
    await bridge.push(push(packId: 'imported-whale'));
    await bridge.push(push(packId: 'imported-whale'));
    expect(calls, ['start', 'update']);
  });

  test('selection, session takeover, idle return, switch and removal', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method;
    });
    final bridge = PetLiveActivityChannel(channel: channel);
    const idle = LivePush(enabled: true, packId: 'deepy-whale');
    await bridge.push(idle);
    await bridge.push(idle);
    await bridge.push(LivePush(enabled: true, packId: 'deepy-whale', activity: push().activity));
    await bridge.push(idle);
    await bridge.push(const LivePush(enabled: true, packId: 'whale-girl'));
    await bridge.push(const LivePush(enabled: true, packId: noPetId));
    // A new pet is the same activity updated in place: switching one in the
    // app changes the island at once, instead of ending it and asking the
    // system for another (which the system may throttle).
    expect(calls.map((c) => c.method), ['start', 'update', 'start', 'start', 'update', 'end']);
    expect((calls[3].arguments as Map)['phase'], 'idle');
    expect((calls[4].arguments as Map)['packId'], 'whale-girl');
  });
}
