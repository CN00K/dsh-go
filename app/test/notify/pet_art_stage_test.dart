// The Live Activity's art comes from the app (not from the widget's own
// bundle): every sheet the island may crop is staged in the shared folder,
// an unchanged pet is not rewritten, and a build without the App Group leaves
// the widget's emoji fallback in place.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/notify/pet_art_stage.dart';
import 'package:dsh_app/pets/pet_pack.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

PetPack _diskPack(String id) =>
    PetPack.parse(jsonDecode(File('assets/pets/$id/pack.json').readAsStringSync()) as Map<String, Object?>);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/pet_art');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory group;

  setUp(() {
    group = Directory.systemTemp.createTempSync('pet-art-test');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'artDirectory') return null;
      return group.path;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    group.deleteSync(recursive: true);
  });

  test('stages the pack, its manifest and every sheet it names', () async {
    final stage = PetArtStage(channel: channel);
    final pack = _diskPack('deepy-whale');
    await stage.stage(pack);
    final dir = Directory('${group.path}/${pack.id}');
    expect(File('${dir.path}/pack.json').existsSync(), isTrue);
    for (final anim in pack.animations.values) {
      expect(File('${dir.path}/${anim.sheet}').existsSync(), isTrue, reason: anim.sheet);
    }
    // The widget crops the app's own sheet: same bytes, so same cells.
    final asset = await rootBundle.load('assets/pets/deepy-whale/idle.png');
    expect(File('${dir.path}/idle.png').lengthSync(), asset.lengthInBytes);
    expect(File('${dir.path}/stamp').readAsStringSync(), contains(pack.id));
  });

  test('an unchanged pet is not rewritten; another pet lands beside it', () async {
    final stage = PetArtStage(channel: channel);
    final deepy = _diskPack('deepy-whale');
    await stage.stage(deepy);
    final stamp = File('${group.path}/deepy-whale/stamp');
    final before = stamp.lastModifiedSync();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await stage.stage(deepy);
    expect(stamp.lastModifiedSync(), before);
    await stage.stage(_diskPack('whale-girl'));
    expect(File('${group.path}/whale-girl/idle.png').existsSync(), isTrue);
  });

  test('without the shared folder nothing is written and nothing throws', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    final stage = PetArtStage(channel: channel);
    await stage.stage(_diskPack('deepy-whale'));
    expect(group.listSync(), isEmpty);
  });
}
