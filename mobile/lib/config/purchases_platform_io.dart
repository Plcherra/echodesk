import 'dart:io' show Platform;

/// True on iOS, including the iOS simulator. False on Android and desktop.
bool get isIosPlatform => Platform.isIOS;
