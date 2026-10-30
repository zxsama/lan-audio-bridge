#!/bin/sh
# Read-only inventory. Run on the actual Linux/TrueNAS host, not in the container.
set -u
printf '\n== Host ==\n'
uname -a
printf '\n== USB ==\n'
if command -v lsusb >/dev/null 2>&1; then lsusb; else printf 'lsusb unavailable; nothing installed.\n'; fi
printf '\n== ALSA cards ==\n'
if [ -r /proc/asound/cards ]; then cat /proc/asound/cards; else printf 'No /proc/asound/cards.\n'; fi
printf '\n== USB audio stream capabilities ==\n'
for stream in /proc/asound/card*/stream*; do
  if [ -f "$stream" ] && [ -r "$stream" ]; then
    printf '\n-- %s --\n' "$stream"
    cat "$stream"
  fi
done
printf '\n== ALSA named devices ==\n'
if command -v aplay >/dev/null 2>&1; then aplay -l; aplay -L; else printf 'aplay unavailable; nothing installed.\n'; fi
printf '\n== Device nodes ==\n'
if [ -d /dev/snd ]; then ls -l /dev/snd; else printf 'No /dev/snd.\n'; fi
printf '\n== Network links ==\n'
if command -v ip >/dev/null 2>&1; then ip -brief link; ip -brief address; fi
printf '\n== Relevant listening sockets (review owners; no service changes) ==\n'
if command -v ss >/dev/null 2>&1; then
  ss -H -lntup | awk '$5 ~ /:(319|320|1900|5353|7000|8899|9000|24879|49494)$/ {print}'
else
  printf 'ss unavailable; nothing installed.\n'
fi
printf '\nReview UDP 319/320/9000 (NQPTP), UDP 5353 (mDNS), UDP 1900 (SSDP), TCP 7000/8899/24879/49494.\n'
printf 'Shared discovery sockets may coexist; timing/control conflicts need investigation.\n'
printf 'Configured non-default receiver ports and dynamic media ports need separate inspection.\n'
printf 'This script did not install packages, play audio, open devices, or stop services.\n'
