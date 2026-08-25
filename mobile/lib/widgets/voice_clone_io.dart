import 'dart:io';

String voiceCloneTempAudioPath() {
  final ts = DateTime.now().millisecondsSinceEpoch;
  final ext = Platform.isIOS ? 'm4a' : 'wav';
  return '${Directory.systemTemp.path}/echodesk_voice_clone_$ts.$ext';
}

int voiceCloneFileBytes(String path) {
  final file = File(path);
  if (!file.existsSync()) return 0;
  return file.lengthSync();
}

String voiceCloneUploadFilename(String path) {
  final name = path.split(RegExp(r'[/\\]')).last;
  if (name.contains('.') && name.length > 2) return name;
  return Platform.isIOS ? 'sample.m4a' : 'sample.wav';
}
