import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class VieNeuAssetStager {
  static const _assetPrefixes = <String>['assets/vieneu/', 'assets/sea-g2p/'];

  static Future<Directory> stage() async {
    final applicationSupport = await getApplicationSupportDirectory();

    final destination = Directory('${applicationSupport.path}/vieneu/assets');

    await destination.create(recursive: true);

    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);

    final assets = manifest
        .listAssets()
        .where(
          (asset) => _assetPrefixes.any((prefix) => asset.startsWith(prefix)),
        )
        .toList();

    for (final assetPath in assets) {
      final relativePath = assetPath.substring('assets/'.length);
      final destinationFile = File('${destination.path}/$relativePath');

      await destinationFile.parent.create(recursive: true);

      if (await destinationFile.exists()) {
        continue;
      }

      final data = await rootBundle.load(assetPath);

      await destinationFile.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }

    return destination;
  }
}
