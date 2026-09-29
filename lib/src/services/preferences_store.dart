import 'dart:convert';
import 'dart:io';

import '../models/app_preferences.dart';
import 'file_io.dart';

class PreferencesStore {
  PreferencesStore(this.filePath);

  final String filePath;
  Future<void> _chain = Future<void>.value();

  Future<AppPreferences> load() async {
    final file = File(filePath);
    if (!await file.exists()) {
      return AppPreferences();
    }

    return AppPreferences.fromJson(await FileIo.readJson(filePath));
  }

  Future<void> save(AppPreferences preferences) {
    final json = const JsonEncoder.withIndent('  ').convert(preferences.toJson());
    final write = _chain.then((_) => FileIo.writeStringAtomic(filePath, json));
    _chain = write.catchError((Object _) {});
    return write;
  }
}
