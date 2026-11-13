// The chosen pet's cells, copied where the widget extension can read them.
// An extension gets neither the app's asset bundle nor its sandbox, so the
// Live Activity would have only an emoji; instead the app writes the pack
// (`pack.json` plus the sheets it names, verbatim) into the App Group folder
// `PetArtStore` names (PetActivityAttributes.swift), and the widget crops the
// very cells the app draws. `stamp` lets the widget tell a new pack from a
// re-imported one.

import 'dart:io';

import 'package:flutter/services.dart';

import '../pets/pet_pack.dart';

/// Writes [PetPack] art to `<App Group>/pet-art/<pack id>/`.
class PetArtStage {
  PetArtStage({required this.channel, AssetBundle? bundle}) : bundle = bundle ?? rootBundle;

  final MethodChannel channel;
  final AssetBundle bundle;

  /// The shared folder; null when this build has no App Group (the island
  /// keeps its emoji).
  Future<String?>? _base;

  /// pack id → the stamp last written, so an unchanged pet writes nothing.
  final Map<String, String> _written = {};

  Future<void> stage(PetPack pack) async {
    final base = await (_base ??= _directory());
    if (base == null) return;
    final files = await _files(pack);
    final stamp = _stamp(pack, files);
    if (_written[pack.id] == stamp) return;
    final directory = Directory('$base/${pack.id}');
    final stampFile = File('${directory.path}/stamp');
    if (stampFile.existsSync() && await stampFile.readAsString() == stamp) {
      _written[pack.id] = stamp;
      return;
    }
    await directory.create(recursive: true);
    for (final file in files) {
      await File('${directory.path}/${file.name}').writeAsBytes(file.bytes);
    }
    // Written last: a stamp without its files never claims to be complete.
    await stampFile.writeAsString(stamp);
    _written[pack.id] = stamp;
  }

  Future<String?> _directory() async {
    try {
      final path = await channel.invokeMethod<String>('artDirectory');
      return path == null || path.isEmpty ? null : path;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// `pack.json` and one copy of every sheet the pack names.
  Future<List<_ArtFile>> _files(PetPack pack) async {
    final names = {'pack.json', for (final anim in pack.animations.values) anim.sheet};
    return [for (final name in names) _ArtFile(name, await _bytes(pack, name))];
  }

  Future<Uint8List> _bytes(PetPack pack, String name) async {
    // A brought pet's files are already files; the built-in ones are assets.
    if (pack.dir case final dir?) return File('$dir/$name').readAsBytes();
    final data = await bundle.load('${PetPack.folder(pack.id)}/$name');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  /// The pack's identity and the size of every file it wrote: a re-import
  /// loads a new [PetPack], so the widget is told to read the pack again.
  String _stamp(PetPack pack, List<_ArtFile> files) =>
      [pack.id, identityHashCode(pack), for (final file in files) '${file.name}=${file.bytes.length}'].join('\u0000');
}

class _ArtFile {
  const _ArtFile(this.name, this.bytes);

  final String name;
  final Uint8List bytes;
}
