# saprobe

The safe-area probe that `tool/safe_area/run_matrix.sh` builds. Each page
prints `SAFEAREA|` lines with `MediaQuery`'s insets; the page and the
simulator's label come from files in the app's data container
(`Documents/saprobe_PAGE.txt`, `Documents/saprobe_DEV.txt`), and the mode label
from `--dart-define=MODE=`. See `lib/main.dart` for the pages.

The harness builds a copy of this directory and adds `watchos/` to the copy
with `flutter-watchos create --platforms=watchos`. To analyse the probe:

```sh
cd tool/safe_area/saprobe
flutter pub get --offline
flutter analyze
```
