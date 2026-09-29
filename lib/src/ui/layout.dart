import 'dart:io';

import 'package:flutter/material.dart';

/// Material 3 window size classes.
enum WindowClass {
  compact,
  medium,
  expanded,
  large;

  static WindowClass of(BuildContext context) => fromWidth(MediaQuery.sizeOf(context).width);

  static WindowClass fromWidth(double width) {
    if (width < 600) {
      return WindowClass.compact;
    }

    if (width < 840) {
      return WindowClass.medium;
    }

    return width < 1200 ? WindowClass.expanded : WindowClass.large;
  }

  /// Phones and narrow windows use the touch-first mobile layout.
  bool get usesMobileLayout => this == WindowClass.compact || this == WindowClass.medium;
}

abstract final class PlatformInfo {
  static bool get isMobile => Platform.isAndroid || Platform.isIOS;
  static bool get isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  static bool get canOpenFolders => isDesktop;
  static bool get canSaveToGallery => isMobile;
  static bool get canShareFiles => !Platform.isLinux;
}

const kGap = SizedBox(width: 12, height: 12);
const kSmallGap = SizedBox(width: 8, height: 8);
