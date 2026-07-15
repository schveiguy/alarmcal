# 4H-Alarm Robotics Calendar

This is a custom-built calendar application to assist in tracking events, shop days, and attendance.

I'll fill this out more as I finish the application.

https://alarmrobotics.com

## Downloading the latest build

Every push to `master` builds the project on Ubuntu 24.04 (x86_64) with LDC and publishes the binary plus the `views/*.css` and `views/*.js` static assets to a rolling `latest` release. Download and extract it with:

```sh
curl -L -o alarmcal.tar.gz https://github.com/schveiguy/alarmcal/releases/latest/download/alarmcal.tar.gz
tar xzf alarmcal.tar.gz
chmod +x alarmcal
```

This extracts the `alarmcal` binary and a `views/` directory next to it, which is where the server expects to find its static CSS/JS assets at runtime.
