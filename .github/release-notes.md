## Downloads

| Platform | File | How to install |
| --- | --- | --- |
| Windows 10/11 (x64) | `Multiplex-{{VERSION}}-windows-x64-setup.exe` | Run the installer. It needs no administrator rights. |
| | `Multiplex-{{VERSION}}-windows-x64.zip` | Portable: extract the zip and run `Multiplex\multiplex.exe`. |
| macOS 12+ (Apple silicon and Intel) | `Multiplex-{{VERSION}}-macos.dmg` | Open the disk image and drag Multiplex to Applications. |
| Linux x64 (Debian, Ubuntu) | `Multiplex-{{VERSION}}-linux-x64.deb` | `sudo apt install ./Multiplex-{{VERSION}}-linux-x64.deb` |
| Linux x64 (other distributions) | `Multiplex-{{VERSION}}-linux-x64.tar.gz` | Extract the archive and run `./multiplex`. It needs GTK 3. |
| Android 7.0+ | `Multiplex-{{VERSION}}-android.apk` | Open the APK on the phone and allow installing from that app. |
| iOS 15+ | `Multiplex-{{VERSION}}-ios-unsigned.ipa` | Unsigned. Sideload it with AltStore or Sideloadly, which sign it with your Apple ID. |

`SHA256SUMS.txt` lists the checksum of every file.

### First launch

- The desktop builds are not code-signed, so the system asks once before opening them:
  - **Windows**: SmartScreen shows "Windows protected your PC". Click **More info**, then **Run anyway**.
  - **macOS**: if macOS says the app can't be verified, open **System Settings → Privacy & Security** and
    click **Open Anyway**. Alternatively, run `xattr -dr com.apple.quarantine /Applications/Multiplex.app`.
- Start Stable Diffusion WebUI with `--api`. To connect from a phone or another computer, add `--listen` (also
  for ComfyUI) and enter the server's LAN address, such as `http://192.168.0.10:7860`, in the app.
- Projects exported from WebuiMultiflex (single projects or bundles) can be imported directly.
